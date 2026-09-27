require "open3"

module Workspace
  # Identifies the coding agent calling `workspace lock`, and checks whether a
  # previously recorded holder or waiter is still alive.
  #
  # Identity is the agent process's pid plus its `ps` start time (`lstart`),
  # never a heartbeat: the start time guards against PID reuse without
  # costing the agent any tokens. Inside tmux the agent is found by walking
  # down from the pane's own process with {ProcessTree::Snapshot#find_descendant};
  # outside tmux (or when the pane's process cannot be resolved), the nearest
  # matching ancestor of this process is used instead.
  class LockHolder
    # @param holder [Hash, nil] a stored holder/waiter record with "pid" and "started"
    # @param identity [Hash] an identity from {#current}, with :pid and :started
    # @return [Boolean] whether the record and the identity name the same agent
    def self.same_agent?(holder, identity)
      !!holder && holder["pid"] == identity[:pid] && holder["started"] == identity[:started]
    end

    # @param process_tree [Workspace::ProcessTree] process table snapshots
    # @param provider [Workspace::AgentProvider] agent CLI to look for (defaults to Claude Code)
    # @param env [Hash] environment lookup, injectable for tests
    def initialize(process_tree: Workspace::ProcessTree.new, provider: AgentProvider.find("claude"), env: ENV)
      @process_tree = process_tree
      @provider = provider
      @env = env
    end

    # @return [Hash, nil] the calling agent's identity: :kind, :pid, :started,
    #   :pane, :worktree — or nil if no agent process could be found
    def current
      snapshot = @process_tree.snapshot
      process = pane_process(snapshot) || ancestor_process(snapshot)
      return nil unless process

      {
        kind: "agent",
        pid: process[:pid],
        started: process[:lstart],
        pane: pane_id,
        worktree: Dir.pwd
      }
    end

    # @param pid [Integer] process to look up
    # @return [String, nil] that process's `ps` start time, or nil if it is not running
    def start_time(pid = Process.pid)
      process_snapshot.find(pid)&.dig(:lstart)
    end

    # Answers every {#alive?} and {#start_time} call inside the block from one
    # process-table snapshot, taken on first use, so a caller checking many
    # entries forks `ps` once rather than once per entry.
    #
    # @yield the checks to share one snapshot
    # @return [Object] the block's result
    def within_snapshot
      outer = @scope
      @scope ||= {}
      yield
    ensure
      @scope = outer
    end

    # A holder or waiter is alive only if its pid is still running *and* its
    # start time still matches, which is what rules out a reused pid.
    #
    # @param pid [Integer, nil]
    # @param started [String, nil]
    # @return [Boolean]
    # @raise [Workspace::Error] if the process table cannot be read, since
    #   liveness is then unknown rather than false
    def alive?(pid:, started:)
      return false unless pid
      process = process_snapshot.find(pid.to_i)
      !process.nil? && process[:lstart] == started
    end

    private

    def process_snapshot
      return @process_tree.snapshot unless @scope
      raise @scope[:error] if @scope[:error]
      @scope[:snapshot] ||= @process_tree.snapshot
    rescue Workspace::Error => e
      @scope[:error] = e if @scope
      raise
    end

    def pane_id
      @env["TMUX_PANE"]
    end

    def pane_process(snapshot)
      pane = pane_id
      return nil if pane.nil? || pane.empty?
      pane_pid = pane_pid_for(pane)
      return nil unless pane_pid
      snapshot.find_descendant(pane_pid, [@provider.executable], exclude: @provider.background_markers, include_root: true)
    end

    def ancestor_process(snapshot)
      snapshot.find_ancestor(Process.pid, [@provider.executable], exclude: @provider.background_markers)
    end

    PANE_PID_FORMAT = "#" + "{pane_pid}"
    private_constant :PANE_PID_FORMAT

    def pane_pid_for(pane)
      stdout, _, status = Open3.capture3("tmux", "display-message", "-p", "-t", pane, PANE_PID_FORMAT)
      return nil unless status.success?
      value = stdout.strip
      value.empty? ? nil : value.to_i
    end
  end
end
