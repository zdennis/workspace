module Workspace
  # Waits until a coding agent in a tmux session is ready to take a prompt.
  #
  # Ready means two things: a known agent (see {AgentProvider}) is running in
  # one of the session's panes, and that pane has drawn something and then
  # stopped changing for a moment. An agent redraws its screen while it
  # starts up and then sits still at its input prompt, so a quiet screen is
  # the signal that works for every agent, with or without hooks. Text typed
  # before then can go to the shell that is still launching the agent, or be
  # lost while the agent sets up its terminal.
  class AgentReadiness
    # Seconds `launch --prompt` waits for an agent before giving up.
    DEFAULT_TIMEOUT = 60
    # Seconds between checks.
    POLL_INTERVAL = 0.5
    # Seconds the agent's screen must stay unchanged to count as ready.
    QUIET_FOR = 2.0

    # The outcome of {#wait}.
    #
    # @!attribute ready
    #   @return [Boolean] whether the agent is ready for input
    # @!attribute pane
    #   @return [String, nil] the agent's pane as a "window.pane" target
    # @!attribute label
    #   @return [String, nil] the agent's name, e.g. "Claude Code"
    # @!attribute reason
    #   @return [String, nil] why the agent is not ready, when it isn't
    Result = Struct.new(:ready, :pane, :label, :reason, keyword_init: true) do
      # @return [Boolean]
      def ready?
        ready
      end
    end

    # @param tmux [Workspace::Tmux] pane listing and screen reads
    # @param process_tree [Workspace::ProcessTree] process table snapshots
    # @param providers [Array<Workspace::AgentProvider>] agents to recognize,
    #   in order of preference when a session runs more than one
    # @param clock [#call] monotonic seconds
    # @param sleeper [#call] sleeps the given seconds
    # @param poll_interval [Numeric] seconds between checks
    # @param quiet_for [Numeric] seconds of unchanged screen that mean ready
    # @param logger [Workspace::Logger] debug logger
    def initialize(tmux:, process_tree:, providers: AgentProvider.all,
      clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) }, sleeper: ->(seconds) { sleep(seconds) },
      poll_interval: POLL_INTERVAL, quiet_for: QUIET_FOR, logger: Workspace::Logger.new)
      @tmux = tmux
      @process_tree = process_tree
      @providers = providers
      @clock = clock
      @sleeper = sleeper
      @poll_interval = poll_interval
      @quiet_for = quiet_for
      @logger = logger
    end

    # @param seconds [Numeric]
    # @return [Float] the time +seconds+ from now, on this object's clock, for
    #   {#wait}'s +deadline:+
    def deadline_in(seconds)
      @clock.call + seconds
    end

    # Checks the session until its agent is ready or +deadline+ passes. Always
    # checks at least once, so a deadline already past still gives an answer.
    #
    # @param session_name [String] tmux session name
    # @param deadline [Numeric] a time from {#deadline_in}
    # @return [Result]
    def wait(session_name, deadline:)
      screen = nil
      quiet_since = nil
      pane_id = nil
      found = {}

      loop do
        found = find_agent_pane(session_name)
        if found[:id]
          if found[:id] != pane_id
            pane_id = found[:id]
            screen = quiet_since = nil
          end
          current = @tmux.capture_screen(pane_id)
          now = @clock.call
          found[:reason] = "#{found[:label]} (pane #{found[:target]}) is still starting up"
          if current.nil? || current.strip.empty?
            found[:reason] = "#{found[:label]} (pane #{found[:target]}) has not drawn its screen yet"
            screen = quiet_since = nil
          elsif current != screen
            screen = current
            quiet_since = now
          elsif now - quiet_since >= @quiet_for
            @logger.debug { "agent readiness: #{found[:label]} ready in #{session_name}:#{found[:target]}" }
            return Result.new(ready: true, pane: found[:target], label: found[:label])
          end
        else
          pane_id = screen = quiet_since = nil
        end

        now = @clock.call
        if now >= deadline
          return Result.new(ready: false, pane: found[:target], label: found[:label], reason: found[:reason])
        end
        @sleeper.call([@poll_interval, deadline - now].min)
      end
    end

    private

    # Picks the session's agent pane: the most preferred provider first, then
    # the lowest pane index.
    #
    # @return [Hash] :id, :target and :label when an agent is running, or
    #   :reason when none is
    def find_agent_pane(session_name)
      details = @tmux.pane_details(session_name)
      return {reason: "tmux session '#{session_name}' has no panes (is it running?)"} if details.empty?

      begin
        tree = @process_tree.snapshot
      rescue Workspace::Error => e
        return {reason: e.message}
      end

      agents = details.filter_map do |detail|
        agent = AgentProvider.detect(command: detail[:command], pid: detail[:pid], tree: tree, providers: @providers)
        agent && detail.merge(provider: agent[:provider])
      end
      return {reason: "no coding agent is running in tmux session '#{session_name}' yet"} if agents.empty?

      chosen = agents.min_by { |detail| [@providers.index(detail[:provider]), detail[:index]] }
      {id: chosen[:id], target: "0.#{chosen[:index]}", label: chosen[:provider].label}
    end
  end
end
