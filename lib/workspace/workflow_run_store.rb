require "json"
require "fileutils"
require "securerandom"
require "time"

module Workspace
  # The files of workflow runs, in workspace's state directory (not the
  # worktree, which `git worktree remove` deletes): `<id>.json` holds a run's
  # current state and `<id>.events.jsonl` its history, one line per
  # transition. A run that is still going lives in the runs directory, which
  # is what keeps its locks alive (see {RunLiveness}); a finished run is moved
  # to the archive, so listing the runs still going reads only those.
  #
  # Every change to a run happens in {#update}, under an exclusive lock on the
  # run's own lock file, and the state file is replaced whole, so a reader
  # needs no lock and never sees a torn write.
  class WorkflowRunStore
    # Run states after which nothing more happens to a run.
    TERMINAL_STATES = RunLiveness::TERMINAL_STATES

    # Finished runs kept; the oldest are removed past this.
    ARCHIVE_LIMIT = 200

    # @param dir [String] the directory of runs still going ({Config#workflow_runs_dir})
    # @param archive_dir [String] the directory of finished runs
    # @param clock [#call] returns the current Time
    # @param id_generator [#call] returns a candidate run id
    def initialize(dir:, archive_dir:, clock: -> { Time.now }, id_generator: nil)
      @dir = dir
      @archive_dir = archive_dir
      @clock = clock
      @id_generator = id_generator || -> { "wr_#{@clock.call.utc.strftime("%y%m%d%H%M%S")}#{SecureRandom.alphanumeric(4).downcase}" }
    end

    # Writes a new run's file. The run gets its "id" here.
    #
    # @param run [Hash{String=>Object}] the run, without an id
    # @yieldparam run [Hash{String=>Object}] the run with its id, to fill in what depends on the id
    # @return [Hash{String=>Object}] the run as stored
    # @raise [Workspace::Error] if the store can't be written
    def create(run)
      FileUtils.mkdir_p(@dir, mode: 0o700)
      run = {"id" => unused_id}.merge(run)
      yield run if block_given?
      write(run)
      run
    rescue SystemCallError, JSON::GeneratorError, EncodingError => e
      raise store_error(e)
    end

    # @param id [String] a run id
    # @return [Hash{String=>Object}] the run, going or finished
    # @raise [Workspace::Error] code `unknown_run` when no run has that id
    def find(id)
      read(path_for(@dir, id)) || read(path_for(@archive_dir, id)) || raise_unknown(id)
    end

    # @return [Array<Hash>] every run that has not finished, oldest first
    def active
      runs_in(@dir).reject { |run| TERMINAL_STATES.include?(run["state"]) }.sort_by { |run| run["created_at"].to_s }
    end

    # @return [Array<Hash>] finished runs, newest first
    def archived
      runs_in(@archive_dir).sort_by { |run| run["ended_at"].to_s }.reverse
    end

    # Run files among the runs still going that can't be read as a run: not
    # JSON, not readable, naming another id than the file's, or without the
    # steps every verb goes by. The lock store counts such a run as alive
    # (see {RunLiveness}), so what it held stays held.
    #
    # @return [Array<String>] their paths, sorted
    def unreadable
      # A run that finished between the listing and the read is gone, not unreadable.
      Dir.glob(File.join(@dir, "*.json")).reject { |path| read(path) }.select { |path| File.exist?(path) }.sort
    end

    # Changes one run: yields it under the run's lock, then stores what the
    # block left in it. A run the block finished is moved to the archive.
    #
    # @param id [String] a run id
    # @param nonblocking [Boolean] return nil at once when another process is changing the run
    # @yieldparam run [Hash{String=>Object}] the stored run, to change in place
    # @return [Object, nil] what the block returned; nil when `nonblocking` and the run is busy
    # @raise [Workspace::Error] code `unknown_run`, or `run_not_active` for a finished run
    def update(id, nonblocking: false)
      raise_unknown(id) unless valid_id?(id)
      FileUtils.mkdir_p(@dir, mode: 0o700)
      File.open(File.join(@dir, "#{id}.lock"), File::RDWR | File::CREAT, 0o600) do |lock|
        return nil unless lock.flock(nonblocking ? File::LOCK_EX | File::LOCK_NB : File::LOCK_EX)
        run = read(path_for(@dir, id))
        unless run
          finished = read(path_for(@archive_dir, id))
          # An unreadable run file keeps its lock file; anything else leaves none behind.
          FileUtils.rm_f(lock.path) unless File.exist?(path_for(@dir, id))
          raise finished ? not_active(finished) : raise_unknown(id)
        end
        if TERMINAL_STATES.include?(run["state"])
          # A finished run still here: the move to the archive failed, so it is tried again.
          begin
            archive(run, lock.path)
          rescue SystemCallError
            nil
          end
          raise not_active(run)
        end
        result = yield run
        write(run)
        archive(run, lock.path) if TERMINAL_STATES.include?(run["state"])
        result
      end
    rescue SystemCallError, JSON::GeneratorError, EncodingError => e
      raise store_error(e)
    end

    # Appends one line to a run's history. Never raises: the history is a
    # record, and a run must not stop because it can't be written.
    #
    # @param id [String] a run id
    # @param type [String] what happened, e.g. "step_dispatched"
    # @param data [Hash{String=>Object}] details of it
    # @return [void]
    def record_event(id, type, data = {})
      line = JSON.generate({"ts" => @clock.call.utc.iso8601, "type" => type}.merge(data)) + "\n"
      File.open(events_path(id), File::WRONLY | File::APPEND | File::CREAT, 0o600) { |file| file.syswrite(line) }
    rescue SystemCallError, JSON::GeneratorError, EncodingError
      nil
    end

    # @param id [String] a run id
    # @return [String] the run's history file, wherever the run is now
    def events_path(id)
      dir = File.exist?(File.join(@archive_dir, "#{id}.json")) ? @archive_dir : @dir
      File.join(dir, "#{id}.events.jsonl")
    end

    private

    def valid_id?(id)
      id.is_a?(String) && RunLiveness::ID_PATTERN.match?(id)
    end

    def raise_unknown(id)
      path = path_for(@dir, id)
      if path && File.exist?(path)
        raise Workspace::Error.new("The file of workflow run #{id} can't be read as a run (#{path}). What it held stays held: " \
          "free a lock with `workspace lock clear NAME`, or delete the file.", code: "unknown_run", details: {"run_id" => id, "path" => path})
      end
      raise Workspace::Error.new("No workflow run #{id.to_s[0, 60].inspect}.", code: "unknown_run", details: {"run_id" => id.to_s[0, 60]})
    end

    def not_active(run)
      Workspace::Error.new("Workflow run #{run["id"]} is #{run["state"]}; nothing more can happen to it.",
        code: "run_not_active", details: {"run_id" => run["id"], "state" => run["state"]})
    end

    def path_for(dir, id)
      valid_id?(id) ? File.join(dir, "#{id}.json") : nil
    end

    # The file's name is the run's id: a file that names another is not read
    # as a run. Nor is one without a current step among its steps, since no
    # verb could show or change it; it is reported as unreadable instead.
    def read(path)
      return nil unless path && valid_id?(File.basename(path, ".json"))
      # Read as UTF-8, which is what is written, whatever the locale of the process reading it.
      text = File.read(path, encoding: Encoding::UTF_8)
      # The parser lets bytes that are not UTF-8 through, and such a run could never be written back.
      return nil unless text.valid_encoding?
      run = JSON.parse(text)
      (run.is_a?(Hash) && run["id"] == File.basename(path, ".json") && whole?(run)) ? run : nil
    rescue SystemCallError, JSON::ParserError, EncodingError
      nil
    end

    # Every step of the definition has its state here, and the current step is one of them.
    def whole?(run)
      steps = run["steps"]
      defined = run["definition"].is_a?(Hash) && run["definition"]["steps"]
      return false unless steps.is_a?(Hash) && defined.is_a?(Array) && defined.all?(Hash)
      defined.any? { |step| step["id"] == run["current"] } && defined.all? do |step|
        state = steps[step["id"]]
        state.is_a?(Hash) && state["attempts"].is_a?(Array) && state["attempts"].all?(Hash)
      end
    end

    def runs_in(dir)
      Dir.glob(File.join(dir, "*.json")).filter_map { |path| read(path) }
    end

    def write(run)
      path = File.join(@dir, "#{run["id"]}.json")
      temp = "#{path}.#{Process.pid}.tmp"
      begin
        File.open(temp, "w", 0o600, encoding: Encoding::UTF_8) do |file|
          file.write(JSON.pretty_generate(run))
          file.flush
          file.fsync
        end
        File.rename(temp, path)
      ensure
        FileUtils.rm_f(temp)
      end
    end

    # The state file moves last: until it does, the run still reads as going
    # from the runs directory, already finished.
    def archive(run, lock_path)
      FileUtils.mkdir_p(@archive_dir, mode: 0o700)
      events = File.join(@dir, "#{run["id"]}.events.jsonl")
      File.rename(events, File.join(@archive_dir, File.basename(events))) if File.exist?(events)
      File.rename(File.join(@dir, "#{run["id"]}.json"), File.join(@archive_dir, "#{run["id"]}.json"))
      FileUtils.rm_f(lock_path)
      archived.drop(ARCHIVE_LIMIT).each do |old|
        FileUtils.rm_f([File.join(@archive_dir, "#{old["id"]}.json"), File.join(@archive_dir, "#{old["id"]}.events.jsonl")])
      end
    end

    def unused_id
      loop do
        id = @id_generator.call
        return id unless File.exist?(File.join(@dir, "#{id}.json")) || File.exist?(File.join(@archive_dir, "#{id}.json"))
      end
    end

    def store_error(error)
      unless error.is_a?(SystemCallError)
        return Workspace::Error.new("Could not write the workflow run: it holds text that is not valid UTF-8 (#{error.class}).")
      end
      Workspace::Error.new("Could not access the workflow run store at #{@dir} (#{error.class}: errno #{error.errno})")
    end
  end
end
