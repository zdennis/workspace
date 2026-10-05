require "json"
require "fileutils"
require "securerandom"
require "time"

module Workspace
  # Records what each worktree workspace is for: a title, the ref it started
  # from and its branch. One JSON file per task in the CLI's own state
  # directory, never in the worktree, because `git worktree remove` deletes
  # untracked files and the main checkout hosts several agents.
  #
  # `start` creates a task, `finish` and `kill` archive it with an outcome.
  # Archived tasks move to an `archive/` subdirectory and only the newest
  # {ARCHIVE_LIMIT} are kept, so the store does not grow without bound.
  # Writes are serialised with `flock` on a lock file in the store directory
  # and land by tmp-file-then-rename, so concurrent CLI invocations never
  # clobber each other and a reader never sees a half-written file. A task
  # carries no status: status is derived when read.
  class TaskStore
    # Outcomes a task can be archived with.
    OUTCOMES = %w[merged discarded abandoned].freeze

    # Archived tasks kept; the oldest are removed past this.
    ARCHIVE_LIMIT = 200

    # @param dir [String] the directory holding `<id>.json` files and `archive/`
    # @param clock [#call] returns the current Time
    # @param error_output [IO] where a skipped unreadable file is reported
    def initialize(dir:, clock: -> { Time.now }, error_output: $stderr)
      @dir = dir
      @archive_dir = File.join(dir, "archive")
      @lockfile_path = File.join(dir, ".lock")
      @clock = clock
      @error_output = error_output
      @warned = {}
    end

    # Creates the task for a workspace, or returns the one already active
    # there (a worktree that is started again keeps its task). A title given
    # for an existing task replaces its title.
    #
    # @param workspace [String] the workspace (config) name
    # @param title [String, nil] a human title
    # @param ref [String, nil] what the task started from (a JIRA key, PR URL, branch name)
    # @param branch [String, nil]
    # @param path [String, nil] the worktree path
    # @return [Hash] the task record
    def start(workspace:, title: nil, ref: nil, branch: nil, path: nil)
      with_lock do
        existing = active_records.find { |r| r["workspace"] == workspace }
        if existing
          if title && existing["title"] != title
            existing["title"] = title
            write_record(@dir, existing)
          end
          next existing
        end
        record = {
          "id" => unused_id,
          "workspace" => workspace,
          "title" => title,
          "ref" => ref,
          "branch" => branch,
          "path" => path,
          "created_at" => now_iso
        }
        write_record(@dir, record)
        record
      end
    end

    # @param workspace [String] the workspace (config) name
    # @return [Hash, nil] the active task, or nil when it has none. Never
    #   creates the store.
    def active_for(workspace)
      active_records.find { |r| r["workspace"] == workspace }
    end

    # Archives a workspace's active task.
    #
    # @param workspace [String]
    # @param outcome [String] one of {OUTCOMES}
    # @return [Hash, nil] the archived record, or nil when the workspace has no active task
    def archive(workspace, outcome:)
      raise ArgumentError, "unknown outcome #{outcome.inspect}" unless OUTCOMES.include?(outcome)

      with_lock do
        record = active_records.find { |r| r["workspace"] == workspace }
        next nil unless record
        record = record.merge("outcome" => outcome, "archived_at" => now_iso)
        FileUtils.mkdir_p(@archive_dir, mode: 0o700)
        write_record(@archive_dir, record)
        File.delete(File.join(@dir, "#{record["id"]}.json"))
        prune_archive
        record
      end
    end

    # @return [Array<Hash>] archived tasks, newest first
    def archived
      records_in(@archive_dir).sort_by { |r| r["archived_at"].to_s }.reverse
    end

    private

    def active_records
      records_in(@dir)
    end

    def records_in(dir)
      Dir.glob(File.join(dir, "*.json")).filter_map { |path| read_record(path) }
    end

    # Anything that isn't a task object is skipped and left on disk, with a
    # warning once per version of the file: a daemon reads the store on every
    # snapshot and must not repeat it.
    def read_record(path)
      # Written as UTF-8 JSON; read as that whatever the locale of the process.
      parsed = JSON.parse(File.read(path, encoding: Encoding::UTF_8))
      return parsed if parsed.is_a?(Hash) && parsed["id"].is_a?(String) && parsed["workspace"].is_a?(String)
      warn_once(path, "not a task record")
    rescue JSON::ParserError
      warn_once(path, "not valid JSON")
    rescue Errno::ENOENT
      nil
    end

    def warn_once(path, reason)
      mtime = File.mtime(path)
      unless @warned[path] == mtime
        @warned[path] = mtime
        @error_output.puts "workspace: ignoring task file #{path} (#{reason})"
      end
      nil
    rescue Errno::ENOENT
      nil
    end

    def prune_archive
      stale = archived.drop(ARCHIVE_LIMIT)
      stale.each { |r| FileUtils.rm_f(File.join(@archive_dir, "#{r["id"]}.json")) }
    end

    def unused_id
      loop do
        id = SecureRandom.hex(4)
        return id unless File.exist?(File.join(@dir, "#{id}.json")) || File.exist?(File.join(@archive_dir, "#{id}.json"))
      end
    end

    def with_lock
      FileUtils.mkdir_p(@dir, mode: 0o700)
      File.open(@lockfile_path, File::RDWR | File::CREAT, 0o600) do |f|
        f.flock(File::LOCK_EX)
        yield
      end
    rescue SystemCallError => e
      raise Workspace::Error, "Could not access task store at #{@dir} (#{e.class}: errno #{e.errno})"
    end

    def write_record(dir, record)
      path = File.join(dir, "#{record["id"]}.json")
      tmp = "#{path}.#{Process.pid}.tmp"
      File.open(tmp, "w", 0o600) do |f|
        f.write(JSON.pretty_generate(record))
        f.flush
        f.fsync
      end
      File.rename(tmp, path)
    end

    def now_iso
      @clock.call.utc.iso8601
    end
  end
end
