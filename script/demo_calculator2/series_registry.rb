require "fileutils"
require "json"
require "socket"
require "time"

require_relative "shared_values"

module DemoCalculator2
  # The series that are running side by side in one repository, and the shared values (merge driver config, attributes line,
  # `workflows.sources` entry, per-id exclude line) they added, in `<git-common-dir>/demo-calc2/series.json`. Every change is a
  # read-modify-write under an exclusive flock on `series.json.lock`, written through a tmp file and a rename. It only records:
  # the caller does the writes to git config and `info/*`, and the undo of what `remove` returns.
  class SeriesRegistry
    SCHEMA = 1
    PREEXISTING = "preexisting".freeze

    # A shared value is live and belongs to another checkout, and the caller did not allow a take-over.
    class Refusal < StandardError; end

    # `series.json` exists but is not a registry: unparsable, or not the expected shape. It is never rewritten.
    class Corrupt < StandardError; end

    # A change was asked of a registry opened read-only.
    class ReadOnly < StandardError; end

    # @param path [String] the `series.json` file, or the directory that holds it
    # @param read_only [Boolean] never create a file or directory; reads see an empty registry when the file is missing
    # @param clock [#call] returns the current Time
    # @param pid [Integer] the pid recorded for a registered id
    # @param host [String] the host recorded for a registered id
    # @param alive [#call] `call(pid, started_at)` says whether that process still runs and started at that time
    def initialize(path, read_only: false, clock: -> { Time.now }, pid: Process.pid, host: Socket.gethostname, alive: method(:process_alive?))
      @path = (File.extname(path.to_s) == ".json") ? path.to_s : File.join(path.to_s, "series.json")
      @read_only = read_only
      @clock = clock
      @pid = pid
      @host = host
      @alive = alive
    end

    # Registers an id with its pid, start time and host. Registering again keeps the earlier entry.
    # @return [Hash] the entry
    def register(id, workspaces: [], branches: [], refs: [])
      modify do |data|
        data["series"][id] ||= {
          "pid" => @pid, "started_at" => now, "host" => @host,
          "workspaces" => [], "branches" => [], "refs" => []
        }
        append(data["series"][id], workspaces: workspaces, branches: branches, refs: refs)
        data["series"][id]
      end
    end

    # Records workspaces, branches and refs the id created, each call written before the caller's next command.
    # @return [Hash] the entry
    def record(id, workspaces: [], branches: [], refs: [])
      modify do |data|
        entry = data["series"][id] or raise ArgumentError, "series #{id} is not registered"
        append(entry, workspaces: workspaces, branches: branches, refs: refs)
        entry
      end
    end

    # Records a shared value for an id, by the state {SharedValues.classify} gave it.
    # @param live [String, nil] the value now, for the `replaced` record and the refusal message
    # @param take_over [Boolean] whether a `:foreign_live` value may be replaced
    # @return [Symbol] `:added`, `:preexisting` or `:unchanged`
    # @raise [Refusal] on `:foreign_live` without `take_over`
    def add(id, key, value, state:, take_over: false, live: nil)
      modify do |data|
        existing = data["shared"][key]
        if state == :equal && existing
          :unchanged
        elsif state == :equal
          data["shared"][key] = shared_entry(PREEXISTING, value, nil)
          :preexisting
        elsif state == :absent
          data["shared"][key] = shared_entry(id, value, nil)
          :added
        elsif existing && (state == :dangling || (state == :foreign_live && take_over))
          # Keep the first owner and the first-ever old value, so the last remove restores that one (and a preexisting
          # entry is never handed back); only the value now in place is updated.
          existing["value"] = value
          :unchanged
        elsif state == :dangling || (state == :foreign_live && take_over)
          data["shared"][key] = shared_entry(id, value, {"value" => live, "owner_path" => SharedValues.owner_path(key, live)})
          :added
        elsif state == :foreign_live
          raise Refusal, SharedValues.refusal(key, live, SharedValues.owner_path(key, live))
        else
          raise ArgumentError, "unknown state #{state.inspect}"
        end
      end
    end

    # Drops an id. Its own `exclude:/runs/<id>/` key is always returned. The keys the registry added come back only when no
    # series is left, with their `replaced` value; a `preexisting` key never does.
    # @return [Array<Hash>] `{"key", "value", "replaced"}` for each key to undo
    def remove(id)
      modify do |data|
        next [] unless data["series"].key?(id)
        data["series"].delete(id)
        undo = [{"key" => "exclude:/runs/#{id}/", "value" => (data["shared"].delete("exclude:/runs/#{id}/") || {})["value"], "replaced" => nil}]
        if data["series"].empty?
          data["shared"].each do |key, entry|
            next if entry["added_by"] == PREEXISTING
            undo << {"key" => key, "value" => entry["value"], "replaced" => entry["replaced"]}
          end
          data["shared"].clear
        end
        undo
      end
    end

    # @return [Boolean] whether this registry never writes
    def read_only? = @read_only

    # @return [Hash{String=>Hash}] the registered series by id
    def entries
      read["series"]
    end

    # @return [Hash{String=>Hash}] the recorded shared values by key
    def shared
      read["shared"]
    end

    # @return [Array<String>] ids whose process is gone or started at another time than recorded
    def stale
      entries.reject { |_id, entry| @alive.call(entry["pid"], entry["started_at"]) }.keys
    end

    private

    def process_alive?(pid, _started_at)
      Process.kill(0, pid)
      true
    rescue Errno::ESRCH
      false
    rescue Errno::EPERM
      true
    end

    def now = @clock.call.utc.iso8601

    def shared_entry(added_by, value, replaced)
      {"value" => value, "added_by" => added_by, "added_at" => now, "replaced" => replaced}
    end

    def append(entry, workspaces:, branches:, refs:)
      entry["workspaces"] |= workspaces
      entry["branches"] |= branches
      entry["refs"] |= refs
    end

    def empty = {"schema" => SCHEMA, "series" => {}, "shared" => {}}

    def read
      return empty unless File.exist?(@path)
      data = JSON.parse(File.read(@path))
      unless data.is_a?(Hash) && [data.fetch("series", {}), data.fetch("shared", {})].all?(Hash)
        raise Corrupt, "#{@path} is not a series registry; fix or remove it"
      end
      empty.merge(data)
    rescue JSON::ParserError => e
      raise Corrupt, "#{@path} is not valid JSON (#{e.message.lines.first.strip}); fix or remove it"
    end

    def modify
      raise ReadOnly, "the series registry is read-only" if @read_only
      FileUtils.mkdir_p(File.dirname(@path))
      File.open("#{@path}.lock", File::RDWR | File::CREAT, 0o644) do |lock|
        lock.flock(File::LOCK_EX)
        data = read
        result = yield data
        tmp = "#{@path}.#{Process.pid}.#{Thread.current.object_id}.tmp"
        File.write(tmp, JSON.pretty_generate(data) + "\n")
        File.rename(tmp, @path)
        result
      end
    end
  end
end
