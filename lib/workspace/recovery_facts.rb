module Workspace
  # What {AgentRecoveryDesk#check} reads about a pane, one named method per
  # read: tmux's pane details, the process table and the agent in it, whether
  # the agent holds the terminal, the screen and the monitor's hold-offs, the
  # ledger and the transcript. Each method makes only its own read, at the
  # moment it is called, so the desk keeps today's order and only reads what
  # its earlier checks let it reach. What a reading means is
  # {RecoveryVerdicts}'.
  class RecoveryFacts
    # The process table and the agent found in it, nil when the pane has none.
    # The table goes on to the checks that read it again ({#pane_clear?},
    # {AgentStopper#session_held?}, {AgentStopper#restartable?}).
    Agent = Struct.new(:found, :tree, keyword_init: true)

    # @param panes [Workspace::PaneFactory] lists a pane to look it up, builds one to read
    # @param process_tree [Workspace::ProcessTree] the process table
    # @param stopper [Workspace::AgentStopper] finds the agent and reads the process groups
    # @param detector [Workspace::AgentDetector] the workspace's way to name the agent
    # @param ledger [Workspace::SessionLedger] the session open in a pane, and its starts
    # @param transcript [Workspace::TranscriptSummary] reads the last turn record
    # @param session_monitor [Workspace::SessionMonitor] delivery facts and running sub-agents
    # @param prompt_typer [Workspace::PromptTyper] checks the input line
    # @param clock [#now] time source
    # @param sleeper [#call] sleeps the given seconds
    # @param logger [Workspace::Logger] debug logger
    def initialize(panes:, process_tree:, stopper:, detector:, ledger:, transcript:, session_monitor:, prompt_typer:,
      clock: Time, sleeper: ->(seconds) { sleep(seconds) }, logger: Workspace::Logger.new)
      @panes = panes
      @process_tree = process_tree
      @stopper = stopper
      @detector = detector
      @ledger = ledger
      @transcript = transcript
      @session_monitor = session_monitor
      @prompt_typer = prompt_typer
      @clock = clock
      @sleeper = sleeper
      @logger = logger
    end

    # The pane's details, nil when the session doesn't have it, or :unknown
    # when tmux listed no pane at all and doesn't say the session is gone: a
    # failed tmux call must not read as the pane being gone.
    #
    # @param pane_id [String]
    # @return [Hash, nil, Symbol]
    def pane_detail(pane_id)
      pane = @panes.call(pane_id)
      return nil if pane == :gone
      if pane == :unlisted
        gone = @panes.for(pane_id)
        return (gone.is_a?(Symbol) || gone.session_gone?) ? nil : :unknown
      end
      pane.details
    end

    # @return [ProcessTree::Snapshot, nil] nil when the table can't be read,
    #   which isn't the same as no agent
    def tree
      @process_tree.snapshot
    rescue Workspace::Error => e
      @logger.debug { "agent recovery: #{e.message}" }
      nil
    end

    # Reads the process table, then finds the agent under the pane in it.
    #
    # @param detail [Hash] the pane's details ({#pane_detail})
    # @return [Agent, nil] nil when the table can't be read
    def agent(detail)
      snapshot = tree
      return nil unless snapshot
      Agent.new(found: @stopper.find_agent(pane_pid: detail[:pid], detector: @detector, tree: snapshot), tree: snapshot)
    end

    # Looks the pane up, then reads the agent under it ({#pane_detail}, then {#agent}).
    #
    # @param pane_id [String]
    # @return [Hash, nil] the agent found; nil when there is none, or when the
    #   pane or the process table can't be read
    def live_agent(pane_id)
      detail = pane_detail(pane_id)
      return nil unless detail.is_a?(Hash)
      agent(detail)&.found
    end

    # @param agent [Hash] the agent found (+:pid+)
    # @param detail [Hash] the pane's details
    # @return [Boolean] whether the agent's process group holds the pane's terminal, read now
    def foreground?(agent, detail)
      @stopper.foreground?(pid: agent[:pid], pane_pid: detail[:pid])
    end

    # Whatever holds an attempt off, read in this order and only until one
    # holds: a draft in the input line (our own message doesn't count), a
    # prompt since the failure, sub-agents still running, then a screen that
    # is busy or didn't stand still.
    #
    # @param pane_id [String]
    # @param entry [Hash] the pane's stored entry
    # @param screen [String, nil] a screen that already stood still, compared
    #   with one capture in place of the wait
    # @return [Boolean]
    def held_off?(pane_id, entry, screen)
      !input_free?(pane_id, entry) || prompt_since_failure?(pane_id, entry) || subagents_running?(pane_id, entry) ||
        RecoveryVerdicts.screen_busy?(still_screen(pane_id, screen))
    end

    # Captures the screen, waits {AgentRestart::QUIET_FOR} and captures it again.
    #
    # @param pane_id [String]
    # @param quiet [String, nil] a screen that already stood still, compared
    #   with one capture in place of the first capture and the wait
    # @return [String, nil] the screen, when it stayed unchanged
    def still_screen(pane_id, quiet = nil)
      before = quiet || screen_of(pane_id)
      return nil unless before
      @sleeper.call(AgentRestart::QUIET_FOR) unless quiet
      (screen_of(pane_id) == before) ? before : nil
    end

    # Reads the process table, then whether a process in it still holds the
    # session. A table that can't be read counts as held.
    #
    # @param session_id [String]
    # @return [Boolean]
    def session_held?(session_id)
      snapshot = tree
      snapshot.nil? || @stopper.session_held?(session_id: session_id, tree: snapshot)
    end

    # @param detail [Hash] the pane's details
    # @param tree [ProcessTree::Snapshot]
    # @return [Boolean] whether the pane is at a shell prompt that holds the terminal, with no agent under it
    def pane_clear?(detail, tree)
      @stopper.pane_clear?(pane_pid: detail[:pid], command: detail[:command], detector: @detector, tree: tree)
    end

    # @param entry [Hash]
    # @return [Boolean] whether the entry's transcript is still a file
    def transcript_file?(entry)
      File.file?(entry["transcript_path"].to_s)
    end

    # @param entry [Hash]
    # @return [Hash, nil] the transcript's last turn record
    def transcript_error(entry)
      @transcript.last_turn_record(entry["transcript_path"])
    end

    # The ledger is written by the hook, not the daemon, so it knows of a new
    # agent whose SessionStart came while the daemon was down. A ledger that
    # can't be read raises.
    #
    # @param entry [Hash]
    # @return [String, nil] the ledger's last SessionStart of the entry's session
    def ledger_start(entry)
      @ledger.last_start_at(entry["session_id"])
    end

    # @param pane_id [String]
    # @return [Hash, nil, Symbol] the open session's entry, nil when none is
    #   open, or :unreadable when the ledger or the tmux server can't be read
    def ledger_session(pane_id)
      pane = @panes.for(pane_id)
      server = pane.is_a?(Symbol) ? nil : pane.server_pid
      return :unreadable if server.to_s.empty?
      @ledger.read_open_record(pane_id: pane_id, tmux_server: server)
    rescue SystemCallError => e
      @logger.debug { "agent recovery: ledger not readable (#{e.class}: #{e.message})" }
      :unreadable
    end

    # @param pane_id [String]
    # @return [String, nil, Symbol] the pane's start command, +:gone+ when the pane can't be built
    def start_command(pane_id)
      pane = @panes.for(pane_id)
      pane.is_a?(Symbol) ? :gone : pane.start_command
    end

    # The monitor records a prompt when its hook arrives, ahead of the desk's
    # queue, so a prompt just submitted can't get a signal while its event waits.
    #
    # @param pane_id [String]
    # @param entry [Hash]
    # @return [Boolean] whether a prompt came after the entry's failure; true
    #   with no failure time, read from the monitor only when there is one
    def prompt_since_failure?(pane_id, entry)
      failed = RecoveryVerdicts.time_of(entry["failed_at"])
      failed.nil? || prompt_after?(pane_id, failed)
    end

    # @param pane_id [String]
    # @param time [Time]
    # @return [Boolean] whether the monitor holds a prompt later than +time+;
    #   true when it has no facts for the pane
    def prompt_after?(pane_id, time)
      RecoveryVerdicts.prompt_after?(@session_monitor.delivery_facts(pane_id), time)
    end

    private

    def input_free?(pane_id, entry)
      draft = entry["draft_text"]
      return true if draft.is_a?(String) && @prompt_typer.check(pane_id, exact: draft).nil?
      @prompt_typer.check(pane_id).nil?
    end

    def subagents_running?(pane_id, entry)
      running = @session_monitor.running_subagents(pane_id)
      return true if running.nil?
      return false unless running.positive?
      RecoveryVerdicts.subagents_recent?(entry, @clock.now)
    end

    def screen_of(pane_id)
      pane = @panes.for(pane_id)
      pane.is_a?(Symbol) ? nil : pane.capture
    end
  end
end
