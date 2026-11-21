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
    REPLY_TIMEOUT = AgentProtocol::RESTART_REPLY_TIMEOUT

    # Seconds to wait for the daemon's answer to a snapshot that asks it to rescan its unnamed panes.
    RESCAN_TIMEOUT = 15

    # Seconds to wait for the daemon when asking whether a pane is idle.
    IDLE_TIMEOUT = 1.0

    # Seconds each tmux read of a review window (its pane state, listing, closing) may take, so a wedged tmux server
    # does not hang the sweep, `doctor` or a round's delivery.
    TMUX_READ_TIMEOUT = 5

    # Seconds since a pane's turn ended before that end counts as unhandled:
    # the `workflow advance` the daemon starts on it has taken the run's lock
    # long before.
    DONE_GRACE = 10

    # Seconds `type` gives a refused screen to clear: a Stop's `advance` can read
    # the pane before Claude Code has redrawn it.
    SCREEN_SETTLE = 5

    # Seconds between looks at a refused screen.
    SCREEN_POLL = 0.5

    # Least seconds `type` waits, in a pane the caller just opened, for the daemon to name its agent: the SessionStart
    # hook gives the pane a row at once, but its kind comes from the next scan. The wait is two scans
    # (`agentd.poll_interval`, 10s by default) when that is longer.
    ROW_WAIT = 30

    # Seconds between reads of the daemon while waiting {ROW_WAIT}.
    ROW_POLL = 1.0

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

    # Seconds a pane must have been idle before its turn is taken as over for a stall or a line typed again.
    IDLE_FLOOR = 5

    # Whether a pane's row shows its turn over ({.turn_over?}) and idle for at least {IDLE_FLOOR} seconds: the one
    # test before an undelivered step line is typed again, by the sweep or the tick.
    #
    # @param shown [Hash{String=>Object}, nil] the pane's entry in the snapshot
    # @param now [Time]
    # @return [Boolean]
    def self.settled?(shown, now)
      turn_over?(shown, now) && shown["idle_seconds"].to_i >= IDLE_FLOOR
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
    # @param error_output [IO] where a warning about a path left out of a binding is written
    # @param spawner [#spawn, nil] splits a new pane and waits for its agent, as {PaneDispatch#spawn} does, for the
    #   author pane of each fan_out sibling after the first ({#spawn_author}); nil makes none
    def initialize(config:, bindings:, tmux:, locator:, binder:, snapshot_client:, agent_ensurer:, connector: ->(path) { UNIXSocket.open(path) },
      reply_timeout: REPLY_TIMEOUT, clock: -> { Time.now }, idle_check: IdlePromptCheck.new, transcript: TranscriptSummary.new,
      sleeper: ->(seconds) { sleep(seconds) }, error_output: $stderr, spawner: nil, poll_interval_for: ->(_workspace) {})
      @poll_interval_for = poll_interval_for
      @spawner = spawner
      @error_output = error_output
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
    # A review window's pane (a row with a `review` mark, or a pane bound as the reviewer) is never the answer.
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
      pane = claude_pane_row(@snapshot_client.fetch(workspace))
      pane ||= rescanned_claude_pane_row(workspace)
      return pane["pane_id"] if pane
      raise Workspace::Error.new("No pane of '#{workspace}' is running Claude Code. Start it, or name the pane with --pane.",
        code: "no_agent_pane", details: {"workspace" => workspace})
    rescue AgentSnapshotClient::Unavailable => e
      raise Workspace::Error.new(e.message, code: "no_daemon", details: {"workspace" => workspace})
    end

    # The pane a restart of a run's step uses, picked from one daemon snapshot, with what the run's own pane is
    # like. Nothing is changed.
    #
    # The target is, in order: the pane the caller named (a Claude Code agent whose turn is over or failed); the
    # run's bound pane when it is idle, failed or busy (the engine refuses a busy one); the one Claude Code pane
    # that is no review pane, bound to no run, not the caller's and whose turn is over.
    #
    # @param workspace [String]
    # @param run_id [String]
    # @param bound [String, nil] the run's bound pane id
    # @param named [String, nil] a pane the caller named, already located
    # @param caller [String, nil] the caller's own pane, never picked on its own
    # @return [Hash{String=>String}] `"pane"` (a pane id) and `"bound"` (the bound pane's fact: `idle`, `failed`,
    #   `busy`, `shell` or `gone`)
    # @raise [Workspace::Error] code `no_daemon`; `no_agent_pane` or `pane_busy` for a named pane, or when none
    #   qualifies; `pane_ambiguous` (`details.panes`) when several do
    def restart_target(workspace, run_id, bound:, named: nil, caller: nil)
      ensure_daemon!(workspace)
      snapshot = @snapshot_client.fetch(workspace)
      fact = bound_fact(run_id, bound, row_of(snapshot, bound))
      return {"pane" => named_target(workspace, run_id, snapshot, named, caller), "bound" => fact} if named
      return {"pane" => bound, "bound" => fact} if %w[idle failed busy].include?(fact)
      {"pane" => sole_free_pane(workspace, run_id, snapshot, caller), "bound" => fact}
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
    # @return [String, nil] the run the pane is bound to as its author now; nil for an unbound
    #   pane, a review pane, or a binding made for another pane (see {PaneBindings#stale?})
    def run_on(pane)
      bound = bound_on(pane)
      (bound && bound[:role] == "author") ? bound[:run_id] : nil
    end

    # @param pane [String] a pane id
    # @return [Hash{Symbol=>Object}, nil] `:run_id` and `:role` ("author" or "reviewer") of the run the pane is
    #   bound to now; nil for an unbound pane, a binding of another kind, or one made for another pane
    def bound_on(pane)
      entry = @bindings.binding_for(pane)
      return nil unless entry && entry["kind"] == "run"
      return nil if stale?(pane, entry)
      {run_id: entry["id"], role: (entry["role"] == "reviewer") ? "reviewer" : "author"}
    end

    # @param pane [String] a pane id
    # @return [String, nil] the step the pane's author binding was made for ({#bound_on}'s rules: a live binding of a
    #   run); nil for an unbound pane, a review pane, or a binding that records no step
    def step_on(pane)
      bound = bound_on(pane)
      return nil unless bound && bound[:role] == "author"
      step = @bindings.binding_for(pane)["step"]
      (step.is_a?(String) && !step.empty?) ? step : nil
    end

    # The fan_out group the pane's run binding names, when it is bound to a group whole (its subagent siblings run
    # as the pane agent's own sub-agents); nil for a pane bound to one step.
    def group_on(pane)
      bound = bound_on(pane)
      return nil unless bound && bound[:role] == "author"
      group = @bindings.binding_for(pane)["group"]
      (group.is_a?(String) && !group.empty?) ? group : nil
    end

    # @param run_id [String]
    # @param step [String, nil] only the pane bound for that step; nil is the first author pane the run has
    # @return [String, nil] the pane bound to the run as its author, wherever `restore` moved the
    #   binding; never the run's review pane
    def pane_of(run_id, step: nil)
      step ? @bindings.pane_for("run", run_id, step: step) : @bindings.pane_for("run", run_id)
    end

    # @param run_id [String]
    # @return [String, nil] the run's review pane; nil when none is bound
    def review_pane_of(run_id)
      @bindings.pane_for("run", run_id, role: "reviewer")
    end

    # @param run_id [String]
    # @param step [String, nil] the pane bound for that step; nil is the first author pane the run has
    # @return [Boolean] whether the run's bound pane is still the pane it was bound in
    def alive?(run_id, step: nil)
      pane = pane_of(run_id, step: step)
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
    # idle with no hook event for {AgentProvider::DEFAULT_IDLE_AFTER} seconds: an
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
    # Code. A pane the daemon has no row for yet counts only in window 0; a pane
    # elsewhere gets a row only in a marked review window.
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
      self.class.agent_gone_row?(row_of(@snapshot_client.fetch(workspace, timeout: IDLE_TIMEOUT), pane))
    rescue Workspace::Error
      false
    end

    # @param row [Hash{String=>Object}, nil] a pane's entry in the daemon's snapshot
    # @return [Boolean] whether the pane has shown a shell for {AGENT_GONE_AFTER} seconds
    def self.agent_gone_row?(row)
      !row.nil? && row["kind"] == "shell" && row["idle_seconds"].to_i >= AGENT_GONE_AFTER
    end

    # @param workspace [String]
    # @param pane [String] a pane id
    # @return [Hash{String=>Object}, nil] the pane's entry in the daemon's snapshot; nil when the daemon does
    #   not answer or does not list the pane
    def pane_row(workspace, pane)
      row_of(@snapshot_client.fetch(workspace, timeout: IDLE_TIMEOUT), pane)
    rescue Workspace::Error
      nil
    end

    # The one reading of a pane's pid: the process tmux started in it, as the workspace's own session lists it.
    # `approve` and `reject` look for it among this process's ancestors; `pause --interrupt` records it, and
    # `unpause` and the tick compare it to tell a pane replaced under the same id.
    #
    # @param workspace [String] the workspace whose tmux session lists the pane
    # @param pane [String] a pane id
    # @return [Integer, nil] nil when the session does not list the pane or tmux can't be read
    def pane_pid(workspace, pane)
      detail = @tmux.pane_details(@tmux.session_name_for(workspace), window: nil).find { |each| each[:id] == pane }
      (detail && detail[:pid].to_i.positive?) ? detail[:pid] : nil
    rescue SystemCallError
      nil
    end

    # @param workspace [String]
    # @return [Boolean] whether the workspace has a tmux session
    def session_live?(workspace)
      @tmux.session_exists?(@tmux.session_name_for(workspace))
    end

    # Starts the workspace's agent daemon when none runs (it answers at once when one does).
    #
    # @param workspace [String]
    # @return [Hash] `:ok`, and `:detail` (why it could not be started) when not
    def respawn_daemon(workspace)
      result = @agent_ensurer.call(name: workspace)
      {ok: result.ok?, detail: result.detail}
    rescue Workspace::Error => e
      {ok: false, detail: e.message.lines.first.to_s.strip}
    end

    # @param pane [String] a pane id
    # @param workspace [String, nil] the run's workspace, whose tmux socket is asked (its config's `socket_name`); nil asks the default one
    # @return [Boolean] whether tmux no longer has the pane; false when tmux can't be read or does not answer in time
    #   (a wedged server is not a gone pane)
    def pane_gone?(pane, workspace: nil)
      @tmux.session_name_for_pane(pane, project: workspace, strict: true).nil?
    rescue Workspace::Error, SystemCallError
      false
    end

    # What identifies the pane a run is bound to: the session and window slot the binding recorded, the facts
    # {#same_pane?} compares later, once the binding is gone.
    #
    # @param run_id [String]
    # @param step [String, nil] the pane bound for that step (a fan_out sibling's own); nil is the first author pane the run has
    # @return [Hash{String=>String}, nil] nil when the run has no binding or the binding recorded no session
    def identity(run_id, step: nil)
      pane = pane_of(run_id, step: step)
      entry = pane && @bindings.binding_for(pane)
      return nil unless entry && entry["session"].is_a?(String)
      entry.slice("session", "pane_slot")
    end

    # @param pane [String] a pane id
    # @param identity [Hash, nil] from {#identity}
    # @return [Boolean] whether +pane+ is still in the session (and slot) the identity names, by the rule of a
    #   binding's stale check; false for no identity, a pane tmux does not have, or a pane id reused elsewhere
    def same_pane?(pane, identity)
      return false unless identity.is_a?(Hash) && identity["session"].is_a?(String)
      !@bindings.stale?(identity, session: @tmux.session_name_for_pane(pane), pane_slot: @tmux.pane_slot(pane),
        server_pid: -> { @tmux.server_pid_for_pane(pane) })
    rescue SystemCallError
      false
    end

    # The agent kind a fan_out sibling's own author pane starts: a step's line may be typed after `/clear`, which only
    # Claude Code reads.
    AUTHOR_KIND = "claude"

    # Splits a new pane off the workspace's session for a fan_out sibling's author agent, and waits until that agent is
    # ready for text. The pane is not bound; the dispatch that types the sibling's line binds it. As a pane made for an
    # infra retry ({WorkflowInfraRetry}), a pane whose agent never got ready is closed again by the spawner, and one
    # waiting at a sign-in, trust or approval screen is kept for the person.
    #
    # @param workspace [String]
    # @return [Hash{Symbol=>String}] :pane, the new pane's id; or, when there is no pane to type into, :error
    #   (`spawn_failed` when none was made, no spawner given included; `agent_not_ready`; `agent_waiting_<screen>`),
    #   :message, and :pane when one was made
    def spawn_author(workspace)
      return {error: "spawn_failed", message: "no pane can be split for '#{workspace}' here"} unless @spawner
      spawned = @spawner.spawn(workspace, AUTHOR_KIND)
      return {pane: spawned.pane} if spawned.ready?
      {error: spawned.waiting ? "agent_waiting_#{spawned.waiting}" : "agent_not_ready", pane: spawned.pane,
       message: "the agent in new pane #{spawned.pane} of '#{workspace}' was not ready for its step's line"}
    rescue Workspace::Error => e
      {error: e.details.key?("pane_id") ? "agent_not_ready" : "spawn_failed", pane: e.details["pane_id"], message: e.message.lines.first.to_s.strip}.compact
    rescue SystemCallError => e
      {error: "spawn_failed", message: e.message.lines.first.to_s.strip}
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
    # @param role [String, nil] "reviewer" for a review pane; nil binds the step's own agent
    # @param round [Integer, nil] the review round, for a reviewer
    # @param relative_to [String, nil] the checkout; a reviewer's paths too long for a field are tried relative to it
    # @return [Hash{String=>Object}] the stored binding
    # @raise [Workspace::Error] when the pane is not one of the workspace's
    def bind(workspace:, pane:, run_id:, step:, attempt:, instructions:, artifacts:, role: nil, round: nil, relative_to: nil)
      fields = {kind: "run", id: run_id, step: step, attempt: attempt, instructions: instructions, artifacts: artifacts}
      if role
        fields[:role] = role
        fields[:round] = round if round
        %i[instructions artifacts].each { |key| fields[key] = relative_path(fields[key], relative_to) }
      end
      fields.delete_if do |key, value|
        next false unless %i[instructions artifacts].include?(key)
        next true if value.nil?
        too_long = value.length > PaneBindings::MAX_FIELD_LENGTH
        @error_output.puts "Warning: the #{key} path of run #{run_id} is longer than #{PaneBindings::MAX_FIELD_LENGTH} characters, so it is not stored in the pane's binding." if too_long
        too_long
      end
      @binder.bind(workspace: workspace, pane: pane, **fields)
    end

    # Binds the pane to a fan_out group of a run, replacing its earlier binding: the pane works on the group whole
    # (its subagent siblings run as the pane agent's own sub-agents), so no one sibling's step id is on it. The
    # pane's next normal step binds it back to that step.
    #
    # @param workspace [String]
    # @param pane [String] a pane id
    # @param run_id [String]
    # @param group [String] the group's id
    # @param artifacts [String, nil] the run's artifacts directory
    # @return [Hash{String=>Object}] the stored binding
    # @raise [Workspace::Error] when the pane is not one of the workspace's
    def bind_group(workspace:, pane:, run_id:, group:, artifacts: nil)
      fields = {kind: "run", id: run_id, group: group}
      fields[:artifacts] = artifacts if artifacts && artifacts.length <= PaneBindings::MAX_FIELD_LENGTH
      @binder.bind(workspace: workspace, pane: pane, **fields)
    end

    # Removes the run's binding, one `restore` has not carried to a pane yet included.
    #
    # @param run_id [String]
    # @param role [String, nil] "reviewer" or "author" removes only that role's binding; nil removes both
    # @param pane [String, nil] removes only that pane's binding to the run; nil removes the run's every binding
    # @param step [String, nil] removes only the bindings made for that step; nil removes them whatever their step
    # @return [void]
    def unbind(run_id, role: nil, pane: nil, step: nil)
      if step
        @bindings.unbind_all("run", run_id, role: role, pane: pane, step: step)
      else
        @bindings.unbind_all("run", run_id, role: role, pane: pane)
      end
    rescue SystemCallError
      nil
    end

    # Starts the workspace's agent daemon when none runs, and refuses when it can't be: a review round's verdicts are
    # proved from the daemon's hook log, so no round is delivered without one.
    #
    # @param workspace [String]
    # @return [void]
    # @raise [Workspace::Error] code `no_daemon`
    def require_daemon(workspace)
      ensure_daemon!(workspace)
    end

    # The `@workspace-review` mark of a run's review window: `RUN:STEP:ROUND`. Run and step ids hold no `:`.
    #
    # @param run_id [String]
    # @param step [String]
    # @param round [Integer]
    # @return [String]
    def self.review_mark(run_id, step, round) = "#{run_id}:#{step}:#{round}"

    # @param mark [String, nil] a window's `@workspace-review` value
    # @return [Array(String, String, Integer), nil] its run id, step and round; nil for a value not shaped as {.review_mark} makes it
    def self.parse_review_mark(mark)
      found = mark.to_s.match(/\A([^:\s]+):([^:\s]+):(\d+)\z/)
      found && [found[1], found[2], found[3].to_i]
    end

    # Closes the review windows of a run, found by their `@workspace-review` mark (so a window whose pane was never
    # recorded, or that a person renamed, is found too), and removes the reviewer binding of each pane it closed. A
    # workspace on its own tmux socket has none (no round opens one there), and its session name is not looked up on
    # the default server. Never raises.
    #
    # @param workspace [String] the run's workspace
    # @param run_id [String]
    # @param step [String, nil] only that step's windows; nil closes every window of the run
    # @param round [Integer, nil] only windows marked for that round or an earlier one, so a late close of round K
    #   leaves round K+1's window; nil closes every round's
    # @return [Array<String>] the window ids closed
    def close_review(workspace, run_id, step: nil, round: nil)
      return [] if @tmux.custom_socket_option(workspace)
      @tmux.review_windows(@tmux.session_name_for(workspace), timeout: TMUX_READ_TIMEOUT).filter_map do |window|
        run, marked_step, marked_round = self.class.parse_review_mark(window[:review])
        next if run != run_id || (step && marked_step != step) || (round.is_a?(Integer) && marked_round > round)
        next unless @tmux.kill_window(window[:window], timeout: TMUX_READ_TIMEOUT)
        unbind(run_id, role: "reviewer", pane: window[:pane]) if window[:pane]
        window[:window]
      end
    rescue Workspace::Error, SystemCallError, Timeout::Error
      []
    end

    # What became of a round's review pane, for the sweep, answered only on positive evidence: there on the tmux
    # server the round recorded (`:live`); missing from the session's pane list while the session's server answers
    # with that same pid (`:gone`); or the session's server, or the server that has the pane id now, answers with another pid
    # (`:server_restarted`: a pane id the new server reused is not the review pane). Anything else is nil and the
    # sweep leaves the round alone: no server recorded (nothing can tell a restarted server's reused pane id from
    # the review pane), or tmux that can't be reached or read.
    #
    # @param workspace [String] the run's workspace
    # @param pane [String] the round's review pane
    # @param server_pid [String, nil] the tmux server's pid the round recorded
    # @return [Symbol, nil] :live, :gone, :server_restarted, or nil when it can't be told
    def review_pane_state(workspace, pane, server_pid)
      return nil if server_pid.nil? || server_pid.to_s.empty?
      now = @tmux.server_pid_for_pane(pane, timeout: TMUX_READ_TIMEOUT)
      return (now.to_s == server_pid.to_s) ? :live : :server_restarted if now
      session = @tmux.session_name_for(workspace)
      current = @tmux.server_pid_for_session(session, timeout: TMUX_READ_TIMEOUT)
      return nil unless current
      return :server_restarted unless current.to_s == server_pid.to_s
      # The same server: gone only when it lists the session's panes and this one is not among them.
      listed = @tmux.pane_details(session, window: nil, timeout: TMUX_READ_TIMEOUT)
      (listed.any? && listed.none? { |detail| detail[:id] == pane }) ? :gone : nil
    rescue SystemCallError, Workspace::Error, Timeout::Error
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
    # @param opened [Boolean] the caller has just opened the pane for this line (a new review window): a `working`
    #   row there is judged by the turn the hooks report, not by the screen the agent's start-up drew
    # @return [Hash] :ok, :warning when the daemon gave one, and for a fresh line :cleared_at (when the daemon confirmed
    #   the new conversation, ISO 8601, when it says); when false, :code
    #   (an error code) and :message, with :reason and :proof_missing when the daemon gave them
    def kick(workspace:, pane:, text:, fresh:, run_id: nil, opened: false)
      ensure_daemon!(workspace)
      fresh ? restart(workspace, pane, text, run_id) : type(workspace, pane, text, opened: opened)
    rescue Workspace::Error => e
      {ok: false, code: e.code, message: e.message.lines.first.to_s.strip}
    end

    private

    # A path too long for a binding field, made relative to the checkout when it lies inside it.
    def relative_path(path, root)
      return path if path.nil? || path.length <= PaneBindings::MAX_FIELD_LENGTH || root.nil?
      prefix = "#{root.to_s.chomp("/")}/"
      path.start_with?(prefix) ? path.delete_prefix(prefix) : path
    end

    # A pane whose agent started since the daemon's last scan has no kind yet, and that scan may be waiting for a
    # slot: the daemon reads the unnamed panes again. A rescan that fails leaves the first read's answer standing.
    def rescanned_claude_pane_row(workspace)
      claude_pane_row(@snapshot_client.fetch(workspace, rescan: true, timeout: RESCAN_TIMEOUT))
    rescue AgentSnapshotClient::Unavailable, Workspace::Error
      nil
    end

    def claude_pane_row(snapshot)
      Array(snapshot["panes"]).find { |each| each["kind"] == "claude" && !review_pane?(each) }
    end

    def review_pane?(row)
      row["review"] || @bindings.binding_for(row["pane_id"])&.dig("role") == "reviewer"
    end

    def stale?(pane, entry)
      @bindings.stale?(entry, session: @tmux.session_name_for_pane(pane), pane_slot: @tmux.pane_slot(pane),
        server_pid: -> { @tmux.server_pid_for_pane(pane) })
    end

    def bound_fact(run_id, bound, row)
      return "gone" if bound.nil? || !alive?(run_id) || row.nil?
      return "shell" if row["kind"] == "shell"
      return "failed" if row["turn_failed"]
      self.class.turn_over?(row, @clock.call) ? "idle" : "busy"
    end

    def named_target(workspace, run_id, snapshot, named, caller)
      row = row_of(snapshot, named)
      unless row && row["kind"] == "claude"
        raise Workspace::Error.new("Pane #{named} of '#{workspace}' is not running Claude Code. Nothing was changed.",
          code: "no_agent_pane", details: {"workspace" => workspace, "pane" => named})
      end
      refuse_named(workspace, named, "caller") if named == caller
      refuse_named(workspace, named, "review") if review_pane?(row)
      refuse_named(workspace, named, "bound") if live_binding?(named) && run_on(named) != run_id
      return named if row["turn_failed"] || self.class.turn_over?(row, @clock.call)
      raise Workspace::Error.new("The agent in pane #{named} is in the middle of a turn. Wait for its turn to end, then run the command again. Nothing was changed.",
        code: "pane_busy", details: {"workspace" => workspace, "pane" => named, "reason" => row["state"]}.compact)
    end

    def refuse_named(workspace, named, reason)
      why = {"caller" => "is the pane this command was run from. Run the command from another pane.",
             "review" => "is a review pane. Name a different pane with --pane.",
             "bound" => "is bound to something else. Name a pane no run uses with --pane."}.fetch(reason)
      raise Workspace::Error.new("Pane #{named} of '#{workspace}' #{why} Nothing was changed.",
        code: "pane_busy", details: {"workspace" => workspace, "pane" => named, "reason" => reason})
    end

    def live_binding?(pane)
      entry = @bindings.binding_for(pane)
      !entry.nil? && !stale?(pane, entry)
    end

    def sole_free_pane(workspace, run_id, snapshot, caller)
      found = Array(snapshot["panes"]).select do |row|
        id = row["pane_id"]
        row["kind"] == "claude" && !review_pane?(row) && !live_binding?(id) && id != caller && self.class.turn_over?(row, @clock.call)
      end.map { |row| row["pane_id"] }
      return found.first if found.size == 1
      if found.empty?
        raise Workspace::Error.new("No idle Claude Code pane of '#{workspace}' is free to restart the step in. Nothing was changed. " \
          "Start Claude Code in a pane of #{workspace}, or name one with --pane.", code: "no_agent_pane", details: {"workspace" => workspace})
      end
      raise Workspace::Error.new("Several idle Claude Code panes of '#{workspace}' could restart the step: #{found.join(", ")}. " \
        "Nothing was changed. Name one with --pane.", code: "pane_ambiguous", details: {"workspace" => workspace, "run_id" => run_id, "panes" => found})
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
        (last_event.nil? || @clock.call - Time.iso8601(last_event) >= AgentProvider::DEFAULT_IDLE_AFTER)
    end

    # The refusal still standing after {SCREEN_SETTLE} seconds, reading the
    # daemon again each time, with the row it was read from; nil when the line can
    # be typed.
    #
    # @return [Array(Hash, Hash, nil), nil] the refusal and the row, nil when the line can be typed
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
      refusal = screen_refusal(pane, row)
      refusal && [refusal, row]
    rescue Workspace::Error
      unknown
    end

    # The daemon's row for the pane when it shows the agent working or waiting at a prompt, or a
    # shell where an agent's turn failed (nothing to type a step's line to); nil when it isn't, or the daemon can't say.
    #
    # In a pane the caller just opened, `working` from the screen alone (the agent drawing its start-up, which the
    # monitor counts as working for {AgentProvider::DEFAULT_IDLE_AFTER} seconds) is no turn: such a row is busy only
    # while the hooks show one under way, or can't say.
    def busy_row(workspace, pane, opened: false)
      shown = opened ? named_row(workspace, pane) : row_of(@snapshot_client.fetch(workspace, timeout: IDLE_TIMEOUT), pane)
      return {"pane_id" => pane, "kind" => "unknown", "state" => "unknown"} if opened && shown.nil?
      return shown if shown && shown["turn_failed"] && shown["kind"] == "shell"
      return nil unless %w[working waiting].include?(shown && shown["state"])
      return nil if opened && shown["state"] == "working" && !hooked_turn?(shown)
      shown
    rescue Workspace::Error
      nil
    end

    # The daemon's row for a pane just opened once it names the agent, read every {ROW_POLL} seconds for up to
    # {#row_wait}; the last row read (nil when there was none) when it never does.
    def named_row(workspace, pane)
      deadline = @clock.call + row_wait(workspace)
      loop do
        row = row_of(@snapshot_client.fetch(workspace, timeout: IDLE_TIMEOUT), pane)
        return row if row_named?(row) || @clock.call >= deadline
        @sleeper.call(ROW_POLL)
      end
    end

    def row_wait(workspace)
      [ROW_WAIT, 2 * (@poll_interval_for.call(workspace) || 0)].max
    end

    # A kind, and for Claude Code its hooks or a screen past its start-up (a Claude Code without hooks has none to wait for).
    def row_named?(row)
      return false unless row && row["kind"] != "unknown"
      row["kind"] != "claude" || row["hook_mode"] == "hooks" || row["state"] != "working"
    end

    # Whether the hooks show the main agent's turn under way, or can't say: a prompt with no Stop after it, a tool or a
    # sub-agent running; a row without hooks, or from a daemon before `user_prompt_at`, can't say.
    def hooked_turn?(row)
      return true unless row["hook_mode"] == "hooks" && row.key?("user_prompt_at")
      (row["user_prompt_at"] && row["main_turn_over_since"].nil?) || Array(row["open_tools"]).any? || Array(row["subagents"]).any?
    end

    # What a refusal saw, from the row it was read from.
    def seen_of(row, reason: nil, changed_by: nil, read_after: false)
      return nil unless row
      {
        "state" => row["state"],
        "state_since" => row["state_since"],
        "changed_by" => changed_by || row["state_changed_by"],
        "turn_failed" => row["turn_failed"],
        "turn_failed_since" => row["turn_failed_since"],
        "turn_failed_kind" => row["turn_failed_kind"],
        "kind" => row["kind"],
        "last_event_at" => row["last_event_at"],
        "refusal_reason" => reason && TerminalText.escape(reason),
        "seen_at" => @clock.call.utc.iso8601,
        "read_after" => (true if read_after)
      }.compact
    end

    def type(workspace, pane, text, opened: false)
      session = @tmux.session_name_for_pane(pane)
      unless session
        # The non-strict lookup can miss a pane tmux still lists, so the strict one decides.
        return {ok: false, code: "pane_gone", message: "pane #{pane} of '#{workspace}' is gone"} if pane_gone?(pane, workspace: workspace)
        return {ok: false, code: "no_such_pane", message: "pane #{pane} of '#{workspace}' could not be read, but tmux still lists it"}
      end
      # A line typed into a turn that is under way is queued into that turn, whose end would
      # then be taken for an earlier one's; so is one typed at a permission prompt.
      busy = busy_row(workspace, pane, opened: opened)
      if busy
        changed_by = "turn_failed" if busy["turn_failed"] && busy["kind"] == "shell"
        return {ok: false, code: "pane_busy", message: "the agent in pane #{pane} is in the middle of a turn; resume the run when it is done",
                seen: seen_of(busy, changed_by: changed_by)}.compact
      end
      refused, row = settled_refusal(workspace, pane)
      if refused
        return {ok: false, code: "pane_busy", reason: refused[:reason],
                message: TerminalText.escape("pane #{pane} can't take the step's line: #{refused[:message]}"),
                seen: seen_of(row, reason: refused[:reason].to_s)}.compact
      end
      delivery = @tmux.deliver(session, pane, text)
      return {ok: true} if delivery.landed?
      {ok: false, code: "not_delivered", message: delivery.message}
    end

    def restart(workspace, pane, text, run_id)
      message = AgentProtocol.restart_agent(workspace: workspace, pane: pane, prompt: text, force: false, wait: true, run_id: run_id)
      reply = request(workspace, message)
      return {ok: true, warning: reply["warning"], cleared_at: reply["cleared_at"]}.compact if reply["ok"]
      {ok: false, code: reply["error"].to_s, message: [reply["message"], reply["fix"]].compact.join(" "), reason: reply["reason"],
       proof_missing: reply.dig("details", "proof_missing"), warning: reply["warning"],
       seen: (read_after(workspace, pane, reply["reason"]) if reply["error"] == "pane_busy")}.compact
    end

    # The pane's row read once after the daemon refused it; the pane may have moved on by then.
    def read_after(workspace, pane, reason)
      row = row_of(@snapshot_client.fetch(workspace, timeout: IDLE_TIMEOUT), pane)
      seen_of(row, reason: reason&.to_s, read_after: true)
    rescue Workspace::Error
      nil
    end

    # `no_daemon` means nothing was sent (no socket to open); once the request is on the wire, a failure is
    # `connection_failed`, which does not say whether the daemon typed the line.
    def request(workspace, message)
      socket = begin
        @connector.call(@config.agent_socket_path(workspace))
      rescue SystemCallError, IOError
        raise Workspace::Error.new("No agent daemon answered for '#{workspace}'.", code: "no_daemon")
      end
      begin
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
      rescue SystemCallError, IOError
        raise Workspace::Error.new("The connection to the agent daemon for '#{workspace}' failed after the request was sent.", code: "connection_failed")
      end
      reply = line && JSON.parse(line)
      return reply if reply.is_a?(Hash)
      raise Workspace::Error.new("The agent daemon for '#{workspace}' closed the connection without replying.", code: "connection_failed")
    rescue JSON::ParserError
      raise Workspace::Error.new("Unreadable reply from the agent daemon for '#{workspace}'.", code: "unreadable_reply")
    end
  end
end
