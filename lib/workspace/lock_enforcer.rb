require "json"

module Workspace
  # Denies an Edit/Write/MultiEdit/NotebookEdit tool call when this namespace's
  # `edit` lock is held by another agent, and releases every lock this agent
  # holds when its session ends or is cleared.
  #
  # Runs from `workspace session-event` on every `PreToolUse`, `SessionEnd`
  # and `SessionStart` hook, so the common case — no lock store, or no `edit`
  # hold anywhere — has to be nearly free: a plain file read across namespace
  # directories, no `git` subprocess, before the real namespace is resolved.
  # It never raises; enforcement fails open rather than blocking an edit on
  # its own error.
  class LockEnforcer
    # Tools whose PreToolUse hook is gated. A Bash-based edit (`sed`, `git
    # apply`, codegen) isn't covered — the lock stays advisory for those.
    EDIT_TOOLS = %w[Edit Write MultiEdit NotebookEdit].freeze

    LOCK_NAME = "edit"

    # @param config [Workspace::Config] supplies the lock directory
    # @param lock_namespace [Workspace::LockNamespace] resolves the store for a cwd
    # @param lock_holder [Workspace::LockHolder] identifies the calling agent
    # @param logger [Workspace::Logger] debug logger
    def initialize(config:, lock_namespace:, lock_holder:, logger: Workspace::Logger.new)
      @config = config
      @lock_namespace = lock_namespace
      @lock_holder = lock_holder
      @logger = logger
    end

    # @param tool_name [String, nil] the PreToolUse payload's tool_name
    # @param cwd [String, nil] the agent's working directory, from the hook payload
    # @return [String, nil] a deny message for stderr, or nil to allow the tool call
    def check(tool_name:, cwd: nil)
      return nil unless EDIT_TOOLS.include?(tool_name)
      return nil unless Dir.exist?(@config.lock_dir)
      return nil unless any_edit_hold?

      store = store_for(cwd)
      holder = store.current_holder(LOCK_NAME)
      return nil unless holder

      identity = @lock_holder.current
      return nil unless identity
      return nil if same_agent?(holder, identity)

      deny_message(holder, identity, store)
    rescue => e
      @logger.debug { "session-event: edit lock check failed (#{e.class}: #{e.message})" }
      nil
    end

    # Releases every lock this agent holds, for `SessionEnd` and a `/clear`'d
    # `SessionStart`.
    #
    # @param cwd [String, nil] the agent's working directory, from the hook payload
    # @return [Array<String>] names of locks released
    def release_all(cwd: nil)
      return [] unless Dir.exist?(@config.lock_dir)

      identity = @lock_holder.current
      return [] unless identity

      released = store_for(cwd).release_all(identity)
      @logger.debug { "session-event: released #{released.join(", ")} on session end" } unless released.empty?
      released
    rescue => e
      @logger.debug { "session-event: release-all failed (#{e.class}: #{e.message})" }
      []
    end

    private

    def store_for(cwd)
      namespace = @lock_namespace.resolve(cwd: resolved_cwd(cwd))
      LockStore.new(dir: namespace[:dir], liveness: @lock_holder)
    end

    def resolved_cwd(cwd)
      (cwd && File.directory?(cwd)) ? cwd : Dir.pwd
    end

    def same_agent?(holder, identity)
      holder["pid"] == identity[:pid] && holder["started"] == identity[:started]
    end

    # Scans every namespace directory under lock_dir for an `edit` hold,
    # without shelling out: a plain read of `locks.json`, which is only ever
    # replaced by an atomic rename. This repo's own namespace is always among
    # these directories, so a real hold here can never be missed; a false
    # positive from another project's namespace just costs one extra (still
    # cheap) resolve below.
    #
    # An unreadable `locks.json` is skipped on its own, so one corrupt
    # namespace never hides a hold in another; if it is this repo's own, the
    # store could not have been read below either. An unlistable lock_dir
    # can't rule anything out, so it takes the slow path.
    def any_edit_hold?
      Dir.children(@config.lock_dir).any? { |name| edit_hold_in?(File.join(@config.lock_dir, name)) }
    rescue SystemCallError
      true
    end

    def edit_hold_in?(dir)
      data_path = File.join(dir, "locks.json")
      return false unless File.file?(data_path)
      data = JSON.parse(File.read(data_path))
      data.is_a?(Hash) && data[LOCK_NAME].is_a?(Hash) && data[LOCK_NAME]["holder"].is_a?(Hash)
    rescue SystemCallError, JSON::ParserError
      false
    end

    def deny_message(holder, identity, store)
      "#{displaced_notice(identity, store)}Workspace edit lock held by #{holder["pane"] || "?"} " \
        "(#{holder["task"] || holder["worktree"] || "?"}). Run: workspace lock acquire edit --wait"
    end

    # The displaced holder learns about a takeover at its next edit, the same
    # way `lock acquire`/`release` tell it: consumed once via {LockStore#pop_displaced}.
    def displaced_notice(identity, store)
      records = store.pop_displaced(identity, name: LOCK_NAME)
      return "" if records.empty?
      records.map { |record| format_displaced(record) }.join
    end

    def format_displaced(record)
      by = record["by"] || {}
      idle_for = record["at"].to_i - record["idle_since"].to_i
      described = by["task"] ? "#{by["pane"] || "?"} \"#{by["task"]}\"" : (by["pane"] || "?")
      "Your edit lock was taken over by #{described} at #{Time.at(record["at"].to_i).utc.iso8601}, " \
        "after this agent had been idle for #{idle_for}s.\n"
    end
  end
end
