require "open3"

module Workspace
  # Identifies the coding agent calling `workspace lock`, and checks whether a
  # previously recorded holder or waiter is still alive.
  #
  # Identity is the agent process's pid plus its `ps` start time (`lstart`),
  # never a heartbeat: the start time guards against PID reuse without
  # costing the agent any tokens. Any registered {AgentProvider} counts as an
  # agent.
  #
  # The agent is the nearest matching ancestor of this process, since that is
  # the one that actually ran the command. A pane can hold more than one agent
  # (one launched from inside another), and walking down from the pane's root
  # would name the outermost one instead. Only when no ancestor matches does
  # it fall back to searching down from the pane's process with
  # {ProcessTree::Snapshot#find_descendant}.
  class LockHolder
    # @param holder [Hash, nil] a stored holder/waiter record with "pid" and "started"
    # @param identity [Hash] an identity from {#current}, with :pid and :started
    # @return [Boolean] whether the record and the identity name the same agent
    def self.same_agent?(holder, identity)
      !!holder && holder["pid"] == identity[:pid] && holder["started"] == identity[:started]
    end

    # @param process_tree [Workspace::ProcessTree] process table snapshots
    # @param providers [Array<Workspace::AgentProvider>] agent CLIs to look for
    #   (defaults to every registered provider)
    # @param env [Hash] environment lookup, injectable for tests
    def initialize(process_tree: Workspace::ProcessTree.new, providers: AgentProvider.all, env: ENV)
      @process_tree = process_tree
      @executables = providers.map(&:executable)
      duplicates = @executables.tally.select { |_, count| count > 1 }.keys
      if duplicates.any?
        raise Workspace::Error, "duplicate agent provider executable(s): #{duplicates.join(", ")}"
      end
      @background_markers = providers.to_h { |provider| [provider.executable, provider.background_markers] }
      @exact_only = providers.reject(&:path_segment_matching?).map(&:executable)
      @env = env
    end

    # @return [Hash, nil] the calling agent's identity: :kind, :pid, :started,
    #   :pane, :worktree — or nil if no agent process could be found
    def current
      snapshot = @process_tree.snapshot
      process = ancestor_process(snapshot) || pane_process(snapshot)
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
      snapshot.find_descendant(pane_pid, @executables, exclude: @background_markers, include_root: true, exact_only: @exact_only)
    end

    def ancestor_process(snapshot)
      snapshot.find_ancestor(Process.pid, @executables, exclude: @background_markers, exact_only: @exact_only)
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
