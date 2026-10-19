require "time"

module Workspace
  # Watches one workspace's `spine/` folder and records `spine_changed` in the event log when a
  # stage's `status`, `note` or `owner` changes, or a stage file is added or removed, however it happened
  # (an editor, an agent's edit tool, a script). It follows {PlanProgressWatcher}: a stat of the
  # folder on a short tick, a read with {SpineTree} only once the folder has sat still for
  # {SETTLE} seconds (so a burst of saves is one line per stage), and a baseline taken at the
  # start that is never reported. An edit that leaves every stage's status and note alone, and
  # the set of stage files, writes nothing. Links are never followed.
  #
  # `spine set` records its own `spine_changed` line, carrying the revision of the file it wrote.
  # A changed stage whose file has the revision of the newest such line for its path, written in
  # the last {OWN_WINDOW} seconds, is that write: the watcher takes it as the new state and
  # writes nothing.
  class SpineWatcher
    # Seconds between stats of the folder.
    TICK = 0.25

    # Seconds the folder must stay unchanged before a change is recorded.
    SETTLE = 0.4

    # Seconds between looks at where the notes directory is.
    RESOLVE_EVERY = 5

    # Seconds back in the event log the line of a `spine set` write is looked for.
    OWN_WINDOW = 120

    # Entries the stat walk looks at, and levels it goes down.
    MAX_WALK = 600
    MAX_LEVELS = SpineTree::MAX_DEPTH + 1
    private_constant :MAX_WALK, :MAX_LEVELS

    # @param workspace [String] the workspace name
    # @param dir_resolver [#call] given the workspace name, returns its notes directory, or nil
    # @param event_log [Workspace::EventLog] gets `spine_changed`, and says what `spine set` wrote
    # @param clock [#call] returns a monotonic number of seconds
    # @param wall_clock [#call] returns the current Time
    # @param logger [Workspace::Logger] debug logger
    def initialize(workspace:, dir_resolver:, event_log:, clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) },
      wall_clock: -> { Time.now }, logger: Workspace::Logger.new)
      @workspace = workspace
      @dir_resolver = dir_resolver
      @event_log = event_log
      @clock = clock
      @wall_clock = wall_clock
      @logger = logger
      @notes_dir = nil
      @resolved_at = nil
      @signature = nil
      @stages = nil
      @changed_at = nil
      @thread = nil
      @stopping = false
    end

    # Reads the spine as it is now, so only later changes are recorded, and starts the watch thread.
    #
    # @return [void]
    def start
      return if @thread
      begin
        baseline
      rescue => e
        @logger.debug { "spine watch: #{e.class}: #{e.message}" }
      end
      @thread = Thread.new do
        until @stopping
          sleep TICK
          begin
            poll
          rescue => e
            @logger.debug { "spine watch: #{e.class}: #{e.message}" }
          end
        end
      end
    end

    # Stops the watch thread.
    #
    # @return [void]
    def stop
      @stopping = true
      @thread&.join(1)
      @thread&.kill
      @thread = nil
    end

    # Takes the spine as it is now as the state later changes are measured against. Records nothing.
    #
    # @return [void]
    def baseline
      resolve(@clock.call, force: true)
      take_baseline
    end

    # One look at the folder: notes a change, and records it once the folder has settled.
    #
    # @return [Boolean] whether any line was written
    def poll
      now = @clock.call
      before = @notes_dir
      resolve(now)
      if @notes_dir != before
        take_baseline
        return false
      end
      return false unless @notes_dir
      signature = signature_of
      if signature != @signature
        @signature = signature
        @changed_at = now
        return false
      end
      return false unless @changed_at && now - @changed_at >= SETTLE
      record_changes.tap { @changed_at = nil }
    end

    private

    def take_baseline
      @signature = @notes_dir && signature_of
      @stages = @notes_dir && read_stages(nil)
      @changed_at = nil
    end

    def resolve(now, force: false)
      return if !force && @resolved_at && now - @resolved_at < RESOLVE_EVERY
      @resolved_at = now
      @notes_dir = begin
        @dir_resolver.call(@workspace)
      rescue Workspace::Error, SystemCallError
        nil
      end
    end

    # A fingerprint of the names, sizes and modification times under `spine/`, links not followed.
    def signature_of
      entries = []
      walk(File.join(@notes_dir, SpineTree::DIR_NAME), "", 0, entries)
      entries.join("|")
    end

    def walk(dir, prefix, level, entries)
      info = File.lstat(dir)
      entries << "#{prefix}.:#{info.ftype}" if level.zero?
      return unless info.directory? && level < MAX_LEVELS
      Dir.children(dir).sort.each do |name|
        break if entries.size >= MAX_WALK
        next if name.start_with?(".")
        path = File.join(dir, name)
        child = File.lstat(path)
        entries << "#{prefix}#{name}:#{child.ftype}:#{child.size}:#{child.mtime.to_i}.#{child.mtime.nsec}"
        walk(path, "#{prefix}#{name}/", level + 1, entries) if child.directory?
      rescue SystemCallError
        entries << "#{prefix}#{name}:gone"
      end
    rescue SystemCallError
      entries << "#{prefix}.:missing"
    end

    # @return [Hash{String => Hash}] what is compared, by stage file name below `spine/`, in tree order
    def read_stages(previous)
      stages = {}
      SpineTree.read(@notes_dir).each_stage do |stage|
        file = stage.file
        next unless file
        unless file.read?
          stages[stage.relative] = previous[stage.relative] if previous&.key?(stage.relative)
          next
        end
        stages[stage.relative] = {"path" => stage.path, "status" => file.status, "note" => file.value("note"), "owner" => file.value("owner"),
                                  "updated" => file.value("updated"), "updated_by" => file.value("updated_by"),
                                  "revision" => file.revision}
      end
      stages
    end

    def record_changes
      previous = @stages
      current = read_stages(previous)
      @stages = current
      return false if previous.nil?
      own = nil
      wrote = false
      (current.keys + previous.keys).uniq.each do |file|
        before = previous[file]
        after = current[file]
        data =
          if before.nil?
            {"workspace" => @workspace, "path" => after["path"], "change" => "added"}
          elsif after.nil?
            {"workspace" => @workspace, "path" => before["path"], "change" => "removed"}
          elsif %w[status note owner].any? { |key| before[key] != after[key] }
            own ||= own_revisions
            next if own[after["path"]] == after["revision"]
            line = {"workspace" => @workspace, "path" => after["path"], "status" => after["status"], "previous" => before["status"],
                    "note" => after["note"], "owner" => after["owner"], "by" => by(before, after), "revision" => after["revision"]}
            line["change"] = "owner" if before["status"] == after["status"] && before["note"] == after["note"]
            line
          end
        wrote = true if data && @event_log.record(type: "spine_changed", project: @workspace, data: data)
      end
      wrote
    end

    # The `updated_by` label when `updated` moved in this change, else `file`.
    def by(before, after)
      moved = after["updated"] && after["updated"] != before["updated"]
      (moved && after["updated_by"]) || "file"
    end

    # @return [Hash{String => String}] the revision of the newest change line of each path, within {OWN_WINDOW}
    def own_revisions
      since = @wall_clock.call - OWN_WINDOW
      @event_log.recent(type: "spine_changed", project: @workspace, since: since).each_with_object({}) do |data, latest|
        latest[data["path"]] = data["revision"] if data["revision"]
      end
    end
  end
end
