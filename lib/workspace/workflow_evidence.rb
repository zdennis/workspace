require "fileutils"

module Workspace
  # Copies what an attempt left in the checkout (its prompt, its check log and each declared `produces`
  # file) into the state directory, `<dir>/<run id>/<name>`, with the SHA-256 of the bytes copied. The
  # checkout is the agent's to edit and `git worktree remove` deletes it; the copy outlives both. It runs
  # under the run's lock, so a file past {MAX_BYTES}, or past {BUDGET} for one attempt, is not copied, and a
  # problem is a note on the entry, never an error.
  #
  # The files are the agent's: each must lie under the run's artifacts directory once links in its parent
  # directories are resolved, is opened without following a link, taken only when a regular file, and hashed
  # and copied from that one handle, so the hash covers the bytes copied. An agent under the same account
  # can still change a file before it is copied; the copy makes that visible, it does not prevent it.
  class WorkflowEvidence
    # A file above this many bytes is recorded with its size and no copy.
    MAX_BYTES = WorkflowAttemptRecord::MAX_HASH_BYTES

    # The most bytes copied for one attempt, over all its files.
    BUDGET = 64 * 1024 * 1024

    # A temp file this old, or one whose process is gone, is a failed copy's leftover.
    STALE_TEMP = 3600

    UNSAFE = /[^A-Za-z0-9._-]/

    # A stand-in for the destination file that remembers why a write failed, since the digest
    # reading the source reports any system error as "no such file".
    class Sink
      attr_reader :error

      def initialize(io)
        @io = io
      end

      def <<(chunk)
        @io.write(chunk)
      rescue => e
        @error = e
        raise
      end
    end
    private_constant :Sink

    # @param dir [String] the evidence directory ({Config#workflow_evidence_dir})
    # @param clock [#call] returns the current Time
    # @param opener [#call] opens a copy's temporary file like `File.open` (path, flags, mode, block)
    # @param max_bytes [Integer] the largest file copied
    # @param budget [Integer] the most bytes copied for one attempt
    def initialize(dir:, clock: -> { Time.now }, opener: File.method(:open), max_bytes: MAX_BYTES, budget: BUDGET)
      @dir = dir
      @max_bytes = max_bytes
      @budget = budget
      @clock = clock
      @opener = opener
    end

    # Copies the attempt's prompt file as it was written, before it is delivered. The attempt's `prompt_sha256`
    # hashes the composed text, which may differ from the file's bytes, so the copy's `sha256` and
    # `prompt_sha256` are not always equal.
    #
    # @param run [Hash{String=>Object}] a stored run
    # @param step_id [String]
    # @param attempt [Hash{String=>Object}] with `n` and `prompt_file`
    # @return [Array<Hash{String=>Object}>] one entry; never raises
    def prompt(run:, step_id:, attempt:)
      batch(run, attempt, [["prompt", "#{base(step_id, attempt)}.prompt.md", attempt["prompt_file"].to_s]], 0)
    end

    # Copies the check log (when the attempt had a check) and each `produces` file as the attempt ends.
    #
    # @param run [Hash{String=>Object}] a stored run; its `artifacts_dir` holds the files
    # @param step [Hash{String=>Object}] the step's definition
    # @param attempt [Hash{String=>Object}] the attempt that is ending; its prompt entry counts against the budget
    # @return [Array<Hash{String=>Object}>] `{name, kind, source, sha256, bytes}` per file, with `problem`
    #   (`missing`, `outside_artifacts`, `copy_failed`) or `too_large` (and `budget` when the attempt's total did it)
    #   when nothing was copied; never raises
    def copy(run:, step:, attempt:)
      steps = File.join(run["artifacts_dir"].to_s, "steps")
      base = base(step["id"], attempt)
      wanted = []
      wanted << ["check_log", "#{base}.check.log", File.join(steps, "#{step["id"]}.#{attempt["n"]}.check.log")] if attempt["check"].is_a?(Hash)
      Array(step["produces"]).each_with_index do |file, index|
        wanted << ["output", "#{base}.out.#{index}.#{safe(file)}", File.join(run["artifacts_dir"].to_s, file)]
      end
      used = Array(attempt["evidence"]).grep(Hash).sum { |each| (each["kind"] == "prompt") ? each["bytes"].to_i : 0 }
      batch(run, attempt, wanted, used)
    end

    # Removes a finished run's evidence directory.
    #
    # @param id [String] a run id
    # @return [void]
    def remove(id)
      FileUtils.rm_rf(File.join(@dir, id)) if id.is_a?(String) && RunLiveness::ID_PATTERN.match?(id)
    rescue SystemCallError
      nil
    end

    private

    def base(step_id, attempt)
      "#{safe(step_id)}.#{attempt["n"].to_i}"
    end

    def safe(text)
      text.to_s.gsub(UNSAFE, "_")
    end

    def batch(run, attempt, wanted, used)
      id = run["id"].to_s
      return [] unless RunLiveness::ID_PATTERN.match?(id)
      directory = File.join(@dir, id)
      sweep(directory)
      wanted.map do |kind, name, source|
        record = entry(run, directory, kind, name, source, used)
        used += record["bytes"].to_i if record["sha256"]
        record
      end
    rescue
      []
    end

    def entry(run, directory, kind, name, source, used)
      record = {"name" => name, "kind" => kind, "source" => source, "sha256" => nil, "bytes" => nil}
      path, problem = placement(run["artifacts_dir"].to_s, source)
      return record.merge("problem" => problem) if problem
      FileUtils.mkdir_p(directory, mode: 0o700)
      store(record, directory, name, path, run["artifacts_dir"].to_s, [@max_bytes, @budget - used].min)
    rescue
      record.merge("problem" => "copy_failed")
    end

    # The file's path with its directory's links resolved, or a problem when that directory is not the
    # artifacts directory or inside it.
    #
    # @return [Array(String, String)] the path to open and nil, or nil and the problem
    def placement(artifacts, source)
      root = File.realpath(artifacts)
      parent = File.realpath(File.dirname(source))
      return [nil, "outside_artifacts"] unless inside?(root, parent)
      [File.join(parent, File.basename(source)), nil]
    rescue SystemCallError
      [nil, "missing"]
    end

    def inside?(root, path)
      path == root || path.start_with?(root.end_with?("/") ? root : "#{root}/")
    end

    # Whether the opened handle is the file at the resolved path now, and that path still lies in the
    # artifacts directory: a directory swapped for a link after the first check shows up here.
    def same_file?(root, path, io)
      fresh = File.realpath(path)
      return false unless inside?(root, fresh)
      stat = File.stat(fresh)
      handle = io.stat
      stat.dev == handle.dev && stat.ino == handle.ino
    rescue SystemCallError
      false
    end

    def store(record, directory, name, source, artifacts, limit)
      target = File.join(directory, name)
      temp = File.join(directory, ".tmp.#{Process.pid}.#{name}")
      content = failure = nil
      swapped = false
      root = File.realpath(artifacts)
      check = lambda do |io|
        next true if same_file?(root, source, io)
        swapped = true
        false
      end
      begin
        @opener.call(temp, File::WRONLY | File::CREAT | File::EXCL | File::NOFOLLOW, 0o600) do |io|
          sink = Sink.new(io)
          content = WorkflowProduced.digest(source, max_bytes: limit, sink: sink, check: check)
          failure = sink.error
        end
        if failure
          record["problem"] = "copy_failed"
        elsif swapped
          record["problem"] = "outside_artifacts"
        elsif content.nil?
          record["problem"] = "missing"
        elsif content.too_large
          record["bytes"] = content.bytes
          record["too_large"] = true
          record["budget"] = true if content.bytes <= @max_bytes
        else
          File.rename(temp, target)
          record["sha256"] = content.sha256
          record["bytes"] = content.bytes
        end
      ensure
        FileUtils.rm_f(temp)
      end
      record
    end

    # Temp files of copies that died: a process that is gone, or an hour old. A live process may own the rest.
    def sweep(directory)
      Dir.glob(File.join(directory, ".tmp.*")).each do |path|
        pid = File.basename(path)[/\A\.tmp\.(\d+)\./, 1]&.to_i
        stale = (@clock.call - File.lstat(path).mtime) > STALE_TEMP
        FileUtils.rm_f(path) if stale || (pid && !alive?(pid))
      end
    rescue SystemCallError
      nil
    end

    def alive?(pid)
      Process.kill(0, pid)
      true
    rescue Errno::ESRCH
      false
    rescue SystemCallError
      true
    end
  end
end
