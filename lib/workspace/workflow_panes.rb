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

    # Whether the agent in a pane, as the daemon's snapshot shows it, has
    # ended its turn with nothing going on to handle that: it is idle (no
    # turn's end was seen), or done (one was seen) for {DONE_GRACE} seconds.
    #
    # @param shown [Hash{String=>Object}, nil] the pane's entry in the snapshot
    # @param now [Time]
    # @return [Boolean]
    def self.turn_over?(shown, now)
      return false unless shown
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
    def initialize(config:, bindings:, tmux:, locator:, binder:, snapshot_client:, agent_ensurer:, connector: ->(path) { UNIXSocket.open(path) },
      reply_timeout: REPLY_TIMEOUT, clock: -> { Time.now })
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
      self.class.turn_over?(Array(snapshot["panes"]).find { |each| each["pane_id"] == pane }, @clock.call)
    rescue Workspace::Error
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
    # @return [Hash] :ok; when false, :code (an error code) and :message
    def kick(workspace:, pane:, text:, fresh:)
      ensure_daemon!(workspace)
      fresh ? restart(workspace, pane, text) : type(workspace, pane, text)
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

    # Whether the daemon shows the pane's agent working or waiting at a prompt; false when it can't say.
    def busy?(workspace, pane)
      shown = Array(@snapshot_client.fetch(workspace, timeout: IDLE_TIMEOUT)["panes"]).find { |each| each["pane_id"] == pane }
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
      delivery = @tmux.deliver(session, pane, text)
      return {ok: true} if delivery.landed?
      {ok: false, code: "not_delivered", message: delivery.message}
    end

    def restart(workspace, pane, text)
      reply = request(workspace, "type" => "restart_agent", "workspace" => workspace, "pane" => pane, "prompt" => text,
        "force" => false, "wait" => true)
      return {ok: true} if reply["ok"]
      {ok: false, code: reply["error"].to_s, message: [reply["message"], reply["fix"]].compact.join(" ")}
    end

    def request(workspace, message)
      socket = @connector.call(@config.agent_socket_path(workspace))
      begin
        socket.puts(JSON.generate(message))
        # The run's own lock is held while this waits, so it never waits for good.
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
