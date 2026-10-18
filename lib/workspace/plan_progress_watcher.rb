module Workspace
  # Watches one workspace's plan file and records `plan_progress` in the event
  # log when its `## Tasks` checklist changes, however the file was edited (a
  # plan verb, an agent, an editor). It stats the file on a short tick, parses
  # it with {PlanFile} only when the file changed, and waits for the file to
  # sit still for {SETTLE} seconds before writing one line, so a burst of
  # edits is one event. A change that leaves every task as it was (prose,
  # frontmatter) writes nothing.
  class PlanProgressWatcher
    # Seconds between stats of the plan file.
    TICK = 0.25

    # Seconds the file must stay unchanged before a change is recorded.
    SETTLE = 0.4

    # Seconds between looks at where the plan file is (the notes directory can move).
    RESOLVE_EVERY = 5

    # @param workspace [String] the workspace name
    # @param path_resolver [#call] given the workspace name, returns the plan's absolute path, or nil
    # @param event_log [Workspace::EventLog] gets `plan_progress`
    # @param clock [#call] returns a monotonic number of seconds
    # @param logger [Workspace::Logger] debug logger
    def initialize(workspace:, path_resolver:, event_log:, clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) },
      logger: Workspace::Logger.new)
      @workspace = workspace
      @path_resolver = path_resolver
      @event_log = event_log
      @clock = clock
      @logger = logger
      @path = nil
      @resolved_at = nil
      @signature = nil
      @tasks = nil
      @changed_at = nil
      @thread = nil
      @stopping = false
    end

    # Reads the plan as it is now, so only later changes are recorded, and starts the watch thread.
    #
    # @return [void]
    def start
      return if @thread
      begin
        baseline
      rescue => e
        @logger.debug { "plan progress watch: #{e.class}: #{e.message}" }
      end
      @thread = Thread.new do
        until @stopping
          sleep TICK
          begin
            poll
          rescue => e
            @logger.debug { "plan progress watch: #{e.class}: #{e.message}" }
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

    # Takes the plan as it is now as the state later changes are measured against. Records nothing.
    #
    # @return [void]
    def baseline
      resolve(@clock.call, force: true)
      @signature = signature_of(@path)
      @tasks = read_tasks.first
      @changed_at = nil
    end

    # One look at the file: notes a change, and records it once the file has settled.
    #
    # @return [Boolean] whether a `plan_progress` line was written
    def poll
      now = @clock.call
      resolve(now)
      signature = signature_of(@path)
      if signature != @signature
        @signature = signature
        @changed_at = now
        return false
      end
      return false unless @changed_at && now - @changed_at >= SETTLE
      @changed_at = nil
      record_change
    end

    private

    def resolve(now, force: false)
      return if !force && @resolved_at && now - @resolved_at < RESOLVE_EVERY
      @resolved_at = now
      path = begin
        @path_resolver.call(@workspace)
      rescue Workspace::Error, SystemCallError
        nil
      end
      @path = path
    end

    def signature_of(path)
      return nil unless path
      stat = File.stat(path)
      "#{stat.mtime.to_i}.#{stat.mtime.nsec}:#{stat.size}"
    rescue SystemCallError
      nil
    end

    # @return [Array] the tasks keyed to their states (nil when the file can't be read), and the parsed plan
    def read_tasks
      plan = @path && PlanFile.read(@path)
      return [nil, nil] if plan&.warnings&.any? { |w| w["code"] == "unreadable" }
      [keyed(plan ? plan.tasks : []), plan]
    end

    def record_change
      tasks, plan = read_tasks
      return false unless tasks
      previous = @tasks
      @tasks = tasks
      return false if previous.nil?
      changed = (previous.keys | tasks.keys).select { |key| previous[key] != tasks[key] }
      return false if changed.empty?
      @event_log.record(type: "plan_progress", project: @workspace, data: {
        "workspace" => @workspace,
        "counts" => plan ? plan.counts : PlanFile.parse("").counts,
        "current" => plan&.current&.fetch("id"),
        "changed" => changed.map { |key| key.is_a?(Array) ? key.first : key }.compact.uniq
      })
    end

    # Tasks by id (a repeat of an id, or a task without one, is keyed by its place), each as its state.
    def keyed(tasks)
      seen = Hash.new(0)
      tasks.each_with_index.to_h do |task, index|
        key = task.id
        if key.nil?
          key = [nil, index]
        elsif (seen[key] += 1) > 1
          key = [key, seen[key]]
        end
        [key, task.state]
      end
    end
  end
end
