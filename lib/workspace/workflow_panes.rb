require "socket"
require "json"
require "time"

module Workspace
  # The pane a workflow run works in: finds it, binds it to the run so the
  # agent is reminded of its step after `/clear` and compaction (see
  # {PaneBindings}), and types the one line that starts a step.
  #
  # A step that starts in a fresh conversation is started by the workspace's
  # agent daemon, which types `/clear`, waits for the new conversation and
  # then types the line (the `restart_agent` message). A step that continues
  # the conversation gets the line typed straight into the pane.
  class WorkflowPanes
    # Seconds to wait for the daemon's answer to `restart_agent`: a little
    # over the two minutes the daemon itself waits for a busy pane.
    REPLY_TIMEOUT = 150

    # Seconds to wait for the daemon when asking whether a pane is idle.
    IDLE_TIMEOUT = 1.0

    # Seconds since a pane's turn ended before that end counts as unhandled:
    # the `workflow advance` the daemon starts on it has taken the run's lock
    # long before.
    DONE_GRACE = 10

    # Seconds `type` gives a refused screen to clear: a Stop's `advance` can read
    # the pane before Claude Code has redrawn it.
    SCREEN_SETTLE = 5

    # Seconds between looks at a refused screen.
    SCREEN_POLL = 0.5

    # Seconds a pane must have shown a shell before its agent counts as gone: a
    # recovery retyping the agent's command leaves a shell for a moment.
    AGENT_GONE_AFTER = 30

    # What a daemon's snapshot must list before a resume is parked on it or its
    # rows are read for the new fields.
    PARKED_RESUME = "parked_resume"

    # Whether the agent in a pane, as the daemon's snapshot shows it, has
    # ended its turn with nothing going on to handle that: it is idle (no
    # turn's end was seen), or done (one was seen) for {DONE_GRACE} seconds.
    #
    # @param shown [Hash{String=>Object}, nil] the pane's entry in the snapshot
    # @param now [Time]
    # @return [Boolean]
    def self.turn_over?(shown, now)
      return false unless shown
      return false if shown["turn_failed"]
      return true if shown["state"] == "idle"
      shown["state"] == "done" && !shown["state_since"].nil? && now - Time.iso8601(shown["state_since"]) >= DONE_GRACE
    rescue ArgumentError
      false
    end

    # @param config [Workspace::Config] the daemon's socket path
    # @param bindings [Workspace::PaneBindings]
    # @param tmux [Workspace::Tmux]
    # @param locator [Workspace::PaneLocator] resolves a pane the caller named
    # @param binder [Workspace::Commands::Binding] binds a pane of the workspace's own session
    # @param snapshot_client [Workspace::AgentSnapshotClient] asks the daemon which panes run an agent
    # @param agent_ensurer [#call] starts the workspace's agent daemon when none runs (`name:`)
    # @param connector [#call] opens the daemon's socket for a path
    # @param reply_timeout [Numeric] see {REPLY_TIMEOUT}
    # @param clock [#call] returns the current Time
    # @param idle_check [Workspace::IdlePromptCheck] reads a pane's input box
    # @param transcript [Workspace::TranscriptSummary] says whether the main agent wrote anything after a time
    # @param sleeper [#call] waits a number of seconds
    def initialize(config:, bindings:, tmux:, locator:, binder:, snapshot_client:, agent_ensurer:, connector: ->(path) { UNIXSocket.open(path) },
      reply_timeout: REPLY_TIMEOUT, clock: -> { Time.now }, idle_check: IdlePromptCheck.new, transcript: TranscriptSummary.new,
      sleeper: ->(seconds) { sleep(seconds) })
      @reply_timeout = reply_timeout
      @clock = clock
      @config = config
      @bindings = bindings
      @tmux = tmux
      @locator = locator
      @binder = binder
      @snapshot_client = snapshot_client
      @agent_ensurer = agent_ensurer
      @connector = connector
      @idle_check = idle_check
      @transcript = transcript
      @sleeper = sleeper
    end

    # The pane a run uses when the caller names none: the workspace's first
    # Claude Code pane, as its agent daemon sees it.
    #
    # @param workspace [String]
    # @param start_daemon [Boolean] start the daemon when none is running; false
    #   (a dry run) returns nil instead
    # @return [String, nil] a pane id
    # @raise [Workspace::Error] code `no_daemon` when the daemon can't be started or
    #   doesn't answer, `no_agent_pane` when no pane runs Claude Code
    def default_pane(workspace, start_daemon: true)
      return nil unless start_daemon || @config.agent_running?(workspace)
      ensure_daemon!(workspace)
      snapshot = @snapshot_client.fetch(workspace)
      pane = Array(snapshot["panes"]).find { |each| each["kind"] == "claude" }
      return pane["pane_id"] if pane
      raise Workspace::Error.new("No pane of '#{workspace}' is running Claude Code. Start it, or name the pane with --pane.",
        code: "no_agent_pane", details: {"workspace" => workspace})
    rescue AgentSnapshotClient::Unavailable => e
      raise Workspace::Error.new(e.message, code: "no_daemon", details: {"workspace" => workspace})
    end

    # @param workspace [String]
    # @param spec [String] a pane id ("%19") or "window.pane" ("0.1")
    # @return [String] the pane's id
    # @raise [Workspace::Error] see {PaneLocator#locate}
    def locate(workspace, spec)
      @locator.locate(workspace, spec).fetch(:id)
    end

    # @param pane [String] a pane id
    # @return [String, nil] the run the pane is bound to now; nil for an unbound
    #   pane or a binding made for another pane (see {PaneBindings#stale?})
    def run_on(pane)
      entry = @bindings.binding_for(pane)
      return nil unless entry && entry["kind"] == "run"
      stale?(pane, entry) ? nil : entry["id"]
    end

    # @param run_id [String]
    # @return [String, nil] the pane bound to the run, wherever `restore` moved the binding
    def pane_of(run_id)
      @bindings.pane_for("run", run_id)
    end

    # @param run_id [String]
    # @return [Boolean] whether the run's bound pane is still the pane it was bound in
    def alive?(run_id)
      pane = pane_of(run_id)
      return false unless pane
      entry = @bindings.binding_for(pane)
      !entry.nil? && !stale?(pane, entry)
    end

    # @param workspace [String]
    # @return [Boolean] whether the workspace's agent daemon, which sees a step's turn end, is running
    def daemon_running?(workspace)
      @config.agent_running?(workspace)
    end

    # @param workspace [String]
    # @param pane [String] a pane id
    # @return [Boolean] true only when the workspace's agent daemon says the pane's agent has
    #   ended its turn (see {.turn_over?}); false when it is working or waiting, or the
    #   daemon does not answer
    def idle?(workspace, pane)
      return false unless daemon_running?(workspace)
      snapshot = @snapshot_client.fetch(workspace, timeout: IDLE_TIMEOUT)
      self.class.turn_over?(row_of(snapshot, pane), @clock.call)
    rescue Workspace::Error
      false
    end

    # Whether the turn of the Claude Code agent in a pane is proven over, so a
    # parked resume may start. Anything unproven is false, no daemon included.
    #
    # The input box must be empty with no busy row, which is also how a person
    # holds a release back with a draft. Then, with a main Stop to go by, the
    # transcript must show no main activity since it. With none, the pane must be
    # idle with no hook event for {SessionMonitor::DEFAULT_IDLE_AFTER} seconds: an
    # Esc, a pane with no hooks, or a daemon restarted since the Stop.
    #
    # @param workspace [String]
    # @param pane [String] a pane id
    # @return [Boolean]
    def main_turn_over?(workspace, pane)
      return false unless daemon_running?(workspace)
      row = row_of(@snapshot_client.fetch(workspace, timeout: IDLE_TIMEOUT), pane)
      return false unless row && row["kind"] == "claude"
      return false if row["turn_failed"] || row["state"] == "waiting"
      return false if screen_refusal(pane, row)
      turn_proven_over?(row)
    rescue Workspace::Error, ArgumentError, SystemCallError
      false
    end

    # Whether a resume from the pane itself can be parked: starts the daemon,
    # which must be one that can release a park, and the pane must run Claude
    # Code. A pane the daemon has no row for yet counts only in window 0, the one
    # it scans; a pane elsewhere would never get a row.
    #
    # @param workspace [String]
    # @param pane [String] a pane id
    # @return [Boolean]
    def parkable?(workspace, pane)
      ensure_daemon!(workspace)
      snapshot = @snapshot_client.fetch(workspace)
      return false unless parks?(snapshot)
      row = row_of(snapshot, pane)
      return row["kind"] == "claude" if row
      @tmux.pane_details(@tmux.session_name_for(workspace)).any? { |detail| detail[:id] == pane }
    rescue Workspace::Error
      false
    end

    # @param workspace [String]
    # @param pane [String] a pane id
    # @return [Boolean] whether the pane has shown a shell for {AGENT_GONE_AFTER}
    #   seconds; false when the daemon does not answer
    def agent_gone?(workspace, pane)
      row = row_of(@snapshot_client.fetch(workspace, timeout: IDLE_TIMEOUT), pane)
      !row.nil? && row["kind"] == "shell" && row["idle_seconds"].to_i >= AGENT_GONE_AFTER
    rescue Workspace::Error
      false
    end

    # @param pane [String] a pane id
    # @return [Boolean] whether tmux no longer has the pane; false when tmux can't be read
    def pane_gone?(pane)
      @tmux.session_name_for_pane(pane).nil?
    rescue SystemCallError
      false
    end

    # Binds the pane to a step of a run, replacing its earlier binding. The
    # paths are left out when they are longer than a binding field may be.
    #
    # @param workspace [String]
    # @param pane [String] a pane id
    # @param run_id [String]
    # @param step [String]
    # @param attempt [Integer]
    # @param instructions [String] the step's instructions file
    # @param artifacts [String] the run's artifacts directory
    # @return [Hash{String=>Object}] the stored binding
    # @raise [Workspace::Error] when the pane is not one of the workspace's
    def bind(workspace:, pane:, run_id:, step:, attempt:, instructions:, artifacts:)
      fields = {kind: "run", id: run_id, step: step, attempt: attempt, instructions: instructions, artifacts: artifacts}
      fields.delete_if { |key, value| %i[instructions artifacts].include?(key) && value.length > PaneBindings::MAX_FIELD_LENGTH }
      @binder.bind(workspace: workspace, pane: pane, **fields)
    end

    # Removes the run's binding, one `restore` has not carried to a pane yet included.
    #
    # @param run_id [String]
    # @return [void]
    def unbind(run_id)
      @bindings.unbind_all("run", run_id)
    rescue SystemCallError
      nil
    end

    # Types the line that starts a step. The workspace's agent daemon is
    # started first when none runs: it is what sees the step's turn end.
    #
    # @param workspace [String]
    # @param pane [String] a pane id
    # @param text [String] one line
    # @param fresh [Boolean] start a new conversation first
    # @param run_id [String, nil] the run the line is for; the daemon types nothing
    #   more once the pane is no longer bound to it. It applies only to a fresh
    #   step: a `context: continue` line is typed without the daemon's restart,
    #   so this does not stop it
    # @return [Hash] :ok, and :warning when the daemon gave one; when false, :code
    #   (an error code) and :message, with :reason and :proof_missing when the daemon gave them
    def kick(workspace:, pane:, text:, fresh:, run_id: nil)
      ensure_daemon!(workspace)
      fresh ? restart(workspace, pane, text, run_id) : type(workspace, pane, text)
    rescue Workspace::Error => e
      {ok: false, code: e.code, message: e.message.lines.first.to_s.strip}
    end

    private

    def stale?(pane, entry)
      @bindings.stale?(entry, session: @tmux.session_name_for_pane(pane), pane_slot: @tmux.pane_slot(pane))
    end

    def ensure_daemon!(workspace)
      result = @agent_ensurer.call(name: workspace)
      return if result.ok?
      raise Workspace::Error.new("Could not start the agent daemon for '#{workspace}'#{": #{result.detail}" if result.detail}. " \
        "A workflow needs it to see when a turn ends.", code: "no_daemon", details: {"workspace" => workspace})
    end

    def row_of(snapshot, pane)
      Array(snapshot["panes"]).find { |each| each["pane_id"] == pane }
    end

    def parks?(snapshot)
      Array(snapshot["features"]).include?(PARKED_RESUME)
    end

    # The facts are built here because {SessionMonitor#typing_facts} lives in the
    # daemon. `activity_state` tells waiting from idle and working, and unlike
    # `state` isn't masked by `done`.
    def screen_refusal(pane, row)
      facts = {kind: row["kind"], state: row["activity_state"], open_tools: Array(row["open_tools"])}
      @idle_check.refusal(facts, @tmux.capture_screen_styled(pane))
    end

    # With a Stop to go by, the transcript alone decides: a woken turn that has
    # fired no hook yet must not pass on the rule for a pane with no Stop.
    def turn_proven_over?(row)
      since = row["main_turn_over_since"]
      return @transcript.main_activity_after?(row["transcript_path"], Time.iso8601(since)).nil? if since

      last_event = row["last_event_at"]
      row["activity_state"] == "idle" &&
        (last_event.nil? || @clock.call - Time.iso8601(last_event) >= SessionMonitor::DEFAULT_IDLE_AFTER)
    end

    # The refusal still standing after {SCREEN_SETTLE} seconds, reading the
    # daemon again each time; nil when the line can be typed.
    def settled_refusal(workspace, pane)
      refused = typing_refusal(workspace, pane, nil)
      deadline = @clock.call + SCREEN_SETTLE
      while refused && @clock.call < deadline
        @sleeper.call(SCREEN_POLL)
        refused = typing_refusal(workspace, pane, refused)
      end
      refused
    end

    # A pane the daemon can't speak for gets +unknown+: nil on the first read, so
    # it types as today, and the standing refusal after that. A row from a daemon
    # before this code has no `activity_state` and is not read.
    def typing_refusal(workspace, pane, unknown)
      snapshot = @snapshot_client.fetch(workspace, timeout: IDLE_TIMEOUT)
      row = row_of(snapshot, pane)
      return unknown unless row && row["kind"] == "claude" && parks?(snapshot)
      screen_refusal(pane, row)
    rescue Workspace::Error
      unknown
    end

    # Whether the daemon shows the pane's agent working or waiting at a prompt, or a
    # shell where an agent's turn failed (nothing to type a step's line to); false when it can't say.
    def busy?(workspace, pane)
      shown = row_of(@snapshot_client.fetch(workspace, timeout: IDLE_TIMEOUT), pane)
      return true if shown && shown["turn_failed"] && shown["kind"] == "shell"
      %w[working waiting].include?(shown && shown["state"])
    rescue Workspace::Error
      false
    end

    def type(workspace, pane, text)
      session = @tmux.session_name_for_pane(pane)
      return {ok: false, code: "pane_gone", message: "pane #{pane} of '#{workspace}' is gone"} unless session
      # A line typed into a turn that is under way is queued into that turn, whose end would
      # then be taken for an earlier one's; so is one typed at a permission prompt.
      if busy?(workspace, pane)
        return {ok: false, code: "pane_busy", message: "the agent in pane #{pane} is in the middle of a turn; resume the run when it is done"}
      end
      refused = settled_refusal(workspace, pane)
      if refused
        return {ok: false, code: "pane_busy", reason: refused[:reason], message: "pane #{pane} can't take the step's line: #{refused[:message]}"}
      end
      delivery = @tmux.deliver(session, pane, text)
      return {ok: true} if delivery.landed?
      {ok: false, code: "not_delivered", message: delivery.message}
    end

    def restart(workspace, pane, text, run_id)
      message = {"type" => "restart_agent", "workspace" => workspace, "pane" => pane, "prompt" => text, "force" => false, "wait" => true}
      message["run_id"] = run_id if run_id
      reply = request(workspace, message)
      return {ok: true, warning: reply["warning"]}.compact if reply["ok"]
      {ok: false, code: reply["error"].to_s, message: [reply["message"], reply["fix"]].compact.join(" "), reason: reply["reason"],
       proof_missing: reply.dig("details", "proof_missing"), warning: reply["warning"]}.compact
    end

    def request(workspace, message)
      socket = @connector.call(@config.agent_socket_path(workspace))
      begin
        socket.puts(JSON.generate(message))
        # A step's dispatch waits for this, so it never waits for good.
        unless socket.wait_readable(@reply_timeout)
          raise Workspace::Error.new("The agent daemon for '#{workspace}' did not answer within #{@reply_timeout.round}s.", code: "connection_failed")
        end
        line = socket.gets
      ensure
        socket.close
      end
      reply = line && JSON.parse(line)
      return reply if reply.is_a?(Hash)
      raise Workspace::Error.new("The agent daemon for '#{workspace}' closed the connection without replying.", code: "connection_failed")
    rescue SystemCallError, IOError
      raise Workspace::Error.new("No agent daemon answered for '#{workspace}'.", code: "no_daemon")
    rescue JSON::ParserError
      raise Workspace::Error.new("Unreadable reply from the agent daemon for '#{workspace}'.", code: "unreadable_reply")
    end
  end
end
