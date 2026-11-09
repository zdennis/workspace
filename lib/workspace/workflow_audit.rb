require "digest"

module Workspace
  # Checks the evidence copies a stored run kept (see {WorkflowEvidence}) against the SHA-256 recorded for
  # each. It reads the run hash it is given and the evidence directory and writes nothing.
  #
  # Each recorded entry gets one status. `ok` means the copy still hashes to the recorded `sha256`;
  # `changed`, `missing` (the copy is gone) and `replaced` (it is now a link or not a regular file) mean the
  # copy no longer holds what was recorded. `not_copied` (the entry has a `problem`) and `too_large`
  # mean nothing was copied, which is not tampering, unless a copy is there anyway (`changed`, `unexpected_copy`).
  # An entry with no hash, no `problem` and no `too_large` is `changed` (`no_recorded_hash`). The check always uses the entry's own
  # `sha256`, never the attempt's `prompt_sha256`, which hashes the composed text and may differ from the file.
  #
  # The stored `name` and `source` are data from the run file: a copy is read only when its name is a plain
  # file name, directly inside the run's own evidence directory, and is never read through a link. A prompt
  # or check log's source in the checkout is also compared with the copy (`source`: `same`, `differs`,
  # `gone`, `outside`); that is a note, because a cancelled check can legitimately keep writing its log.
  # The run file is the trust root: an edit to both a copy and its recorded hash is not detected.
  class WorkflowAudit
    # Statuses meaning the copy no longer holds what was recorded.
    MISMATCHES = %w[changed missing replaced].freeze

    # Entry kinds whose source file in the checkout is compared with the copy.
    SOURCE_KINDS = %w[prompt check_log].freeze

    NAME = /\A[A-Za-z0-9][A-Za-z0-9._-]*\z/

    # @param attempts [Workspace::WorkflowAttempts] reads the run's attempt rows
    # @param dir [String] the evidence directory ({Config#workflow_evidence_dir})
    def initialize(attempts:, dir:)
      @attempts = attempts
      @dir = dir
    end

    # @param run [WorkflowRun, Hash{String=>Object}] a stored run, going or finished
    # @param step [String, nil] only this step's attempts
    # @return [Hash{String=>Object}] `"files"`, one row per recorded entry (`step`, `attempt`, `name`, `kind`,
    #   `source`, `status`, `reason`, `recorded_sha256`, `now_sha256`, `bytes`, `source_status`), `"without_evidence"`
    #   (`{step, attempt}` of each attempt with no `evidence` key, as in a run stored before it existed),
    #   `"counts"` (rows per status), `"clean"` (no copy mismatched) and `"directory"`
    # @raise [Workspace::Error] code `unknown_step` when +step+ is not one of the run's steps
    def read(run, step: nil)
      run = WorkflowRun.from_h(run)
      rows = @attempts.read(run, step: step)["attempts"]
      files = []
      without = []
      rows.each do |row|
        if row["evidence"].is_a?(Array)
          row["evidence"].grep(Hash).each { |entry| files << check(run, row, entry) }
        else
          without << {"step" => row["step"], "attempt" => row["attempt"]}
        end
      end
      counts = files.map { |each| each["status"] }.tally
      {"directory" => directory(run), "files" => files, "without_evidence" => without, "counts" => counts,
       "clean" => (counts.keys & MISMATCHES).empty?}
    end

    private

    def directory(run)
      id = run.id.to_s
      RunLiveness::ID_PATTERN.match?(id) ? File.join(@dir, id) : nil
    end

    def check(run, row, entry)
      result = {"step" => row["step"], "attempt" => row["attempt"], "name" => entry["name"], "kind" => entry["kind"],
                "source" => entry["source"], "status" => nil, "reason" => nil, "recorded_sha256" => entry["sha256"],
                "now_sha256" => nil, "bytes" => nil, "source_status" => nil}
      if entry["problem"]
        return unexpected_copy(run, entry, result) || result.merge("status" => "not_copied", "reason" => entry["problem"].to_s[0, 40])
      end
      if entry["too_large"]
        return unexpected_copy(run, entry, result) ||
            result.merge("status" => "too_large", "reason" => entry["budget"] ? "budget" : "size", "bytes" => entry["bytes"])
      end
      return result.merge("status" => "changed", "reason" => "no_recorded_hash") unless entry["sha256"].is_a?(String)
      result.merge(compare(run, entry)).tap { |each| each["source_status"] = source_status(run, entry) }
    end

    # An entry that says nothing was kept, yet a copy is there: {WorkflowEvidence} renames a copy into place only
    # when it succeeded, so the run file was edited (or the copy came from elsewhere).
    def unexpected_copy(run, entry, result)
      path, = copy_path(run, entry["name"])
      return nil unless path && File.lstat(path)
      result.merge("status" => "changed", "reason" => "unexpected_copy")
    rescue SystemCallError
      nil
    end

    def compare(run, entry)
      path, problem = copy_path(run, entry["name"])
      return {"status" => "missing", "reason" => problem} unless path
      begin
        stat = File.lstat(path)
      rescue SystemCallError
        return {"status" => "missing"}
      end
      return {"status" => "replaced", "reason" => stat.symlink? ? "symlink" : "not_regular_file"} unless stat.file?
      content = WorkflowProduced.digest(path, max_bytes: WorkflowEvidence::MAX_BYTES)
      return {"status" => "changed", "reason" => "unreadable"} unless content
      return {"status" => "changed", "reason" => "too_large", "bytes" => content.bytes} if content.too_large
      {"status" => (content.sha256 == entry["sha256"]) ? "ok" : "changed", "now_sha256" => content.sha256, "bytes" => content.bytes}
    end

    # The copy's path when the name is a plain file name and the run's evidence directory is a real directory,
    # else nil and why: `invalid_name`, or `no_evidence_directory` (absent, a link, or a run id that is not one).
    #
    # @return [Array(String, nil), Array(nil, String)]
    def copy_path(run, name)
      dir = directory(run)
      return [nil, "no_evidence_directory"] unless dir && File.lstat(dir).directory?
      return [nil, "invalid_name"] unless name.is_a?(String) && NAME.match?(name)
      [File.join(dir, name), nil]
    rescue SystemCallError
      [nil, "no_evidence_directory"]
    end

    def source_status(run, entry)
      return nil unless SOURCE_KINDS.include?(entry["kind"])
      return nil unless [entry["source"], run.artifacts_dir].all? { |each| each.is_a?(String) && !each.include?("\0") }
      artifacts = File.realpath(run.artifacts_dir.to_s)
      parent = File.realpath(File.dirname(entry["source"]))
      return "outside" unless parent == artifacts || parent.start_with?("#{artifacts}/")
      return "gone" unless File.exist?(File.join(parent, File.basename(entry["source"])))
      content = WorkflowProduced.digest(File.join(parent, File.basename(entry["source"])), max_bytes: WorkflowEvidence::MAX_BYTES)
      return "differs" unless content&.sha256
      (content.sha256 == entry["sha256"]) ? "same" : "differs"
    rescue SystemCallError, ArgumentError
      "gone"
    end
  end
end
