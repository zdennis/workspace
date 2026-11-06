require "fileutils"
require "securerandom"
require "time"

module Workspace
  # Moves a workflow run from step to step. A run is a copy of its
  # definition plus where it stands, kept by {WorkflowRunStore}; every
  # method here makes one transition under the run's lock and returns.
  #
  # A step is done when the agent's turn ends in the bound pane
  # ({#turn_ended}), every file the step `produces:` exists, and its
  # `status:` check passes. `workspace step done` only adds the agent's own
  # report ({#report}); a report of `fail` fails the step at the turn's end.
  # A failed step follows its `on_fail: {goto, max}` while loops and the
  # run's `max_attempts` last; after that the run waits for a person.
  #
  # A run that is not moving has a `reason` that says why, one of
  # `waiting_lock`, `waiting_you`, `turn_ended_incomplete`,
  # `turn_ended_background` (a turn that ended with background tasks listed;
  # {WorkflowStatus} hides it) and `failed_check`. {WorkflowStatus} adds
  # `pane_gone`, which is read from tmux rather than stored. The one case
  # with no reason is a turn that ended without the daemon seeing it (an
  # interrupted turn, a daemon that was down): the step still reads
  # `running`, {WorkflowStatus} flags it `idle`, and {#resume} looks at it.
  #
  # Resources a step `uses:` are held by the run, taken before the step's
  # prompt is typed and given up at a gate, on a failure that stops the run,
  # and at the end.
  #
  # A resume that can't be carried out yet is parked ({#park}): a request
  # stored on the run as `parked`, not an attempt. No attempt is made and no
  # new resource taken until {#release_park}. Until then a turn's end, a tick
  # and a check's result decide nothing.
  class WorkflowEngine
    # The one line typed into the pane; the instructions themselves are in the file.
    KICK = "Read %s and follow it."

    # The run id {#preflight} and {#render} compose a first step under, for a run that does not exist.
    PREVIEW_RUN_ID = "wr_preview".freeze

    # Restart errors that mean there is no pane to type into.
    # The words in `details.code` the engine sets itself; `step done --code` refuses them, so `code_source: agent` never carries one.
    ENGINE_CODES = (WorkflowGuard::CODES + [WorkflowGuard::CONFIG_CHANGED] + WorkflowRequire::PROOFS.map { |name| "require_#{name}" } + %w[require_remote_unreachable require_unknown check_failed check_timed_out check_error reported step_timed_out]).freeze

    PANE_GONE_CODES = %w[no_such_pane pane_gone no_session wrong_session].freeze

    # Seconds after an attempt starts during which its line may still be on its
    # way: the daemon's answer to `restart_agent`, plus a minute to start it.
    DELIVERY_WINDOW = WorkflowPanes::REPLY_TIMEOUT + 60

    # Seconds a parked resume waits for the turn to end.
    PARK_SECONDS = 3600

    # How many times a released resume that could not be typed is parked again.
    # Each failed delivery is an attempt, and attempts count against `max_attempts`.
    PARK_RETRIES = 3

    # Delivery failures that a later try can get past.
    PARK_AGAIN_CODES = %w[pane_busy restart_in_progress].freeze

    # Seconds the sweep waits after an undelivered attempt ended before retrying it; retry n uses entry n
    # (the last entry again past the end).
    REDELIVER_BACKOFF = [60, 300, 900].freeze

    # Delivery failures that prove the line never reached the pane, so typing it again cannot type it twice: the
    # pane was busy or the screen refused before anything was typed, a restart was already under way, or no daemon
    # socket could be opened. Not among them: `not_delivered` (a paste may have landed slowly), `connection_failed`
    # and `unreadable_reply` (the daemon may have typed it), a gone pane, a missing checkout or an unreadable pack.
    REDELIVER_CODES = %w[pane_busy restart_in_progress no_daemon].freeze

    # The daemon's `reason` for a failure that may have left the line in the input box; retrying could type it twice.
    REDELIVER_NEVER_REASONS = %w[prompt_unconfirmed].freeze

    # @param run [Hash{String=>Object}] a stored run
    # @return [Integer] the attempts that count against the allowance: all but those the sweep typed again
    def self.attempts_made(run)
      run["steps"].values.sum { |each| each["attempts"].count { |earlier| !earlier["redelivered"] } }
    end

    # Whether the run has made all the attempts it is allowed, read from the stored run (the definition's
    # `max_attempts` plus `extra_attempts`); false for a run that does not say.
    #
    # @param run [Hash{String=>Object}] a stored run
    # @return [Boolean]
    def self.attempts_spent?(run)
      return false unless run.dig("definition", "max_attempts").is_a?(Integer)
      attempts_made(run) >= attempt_allowance(run)
    end

    # @param run [Hash{String=>Object}] a stored run with a definition
    # @return [Integer] the definition's `max_attempts` plus the run's `extra_attempts`
    def self.attempt_allowance(run)
      run["definition"]["max_attempts"] + run["extra_attempts"].to_i
    end

    # The least `--extra-attempts` that lets the attempt about to start fit.
    #
    # @param run [Hash{String=>Object}] a stored run with a definition
    # @return [Integer] attempts made minus the allowance, plus one (1 for a run exactly spent)
    def self.extra_attempts_needed(run)
      attempts_made(run) - attempt_allowance(run) + 1
    end

    # Whether a resume would start a new attempt: `--from`, a run held for its token budget, a retry's wait, a step that failed or never
    # got its line, or a running step given a pane. Not a check or a turn left to decide (a failure there goes
    # through the `on_fail` budget), a passed step moving on, or a lock wait (the attempt was allowed when the
    # step was reached).
    #
    # @param run [Hash{String=>Object}] a stored run
    # @param from [String, nil] the step a resume would start again at
    # @param pane [String, nil] the pane the resume would name
    # @return [Boolean]
    def self.starts_attempt?(run, from:, pane:)
      return true if from
      return true if run["budget_hold"].is_a?(Hash)
      return true if run["backoff"].is_a?(Hash) && run["backoff"]["to"].is_a?(String)
      return false if run.dig("reason", "code") == "waiting_lock"
      case run["steps"].fetch(run["current"])["state"]
      when "running" then !pane.nil?
      when "checking", "passed" then false
      else true
      end
    end

    # Where the line that starts an attempt stands. An attempt is stored as
    # `delivering` before its line is typed, outside the run's lock, and the
    # mark is cleared once the daemon answers or a turn's end shows the agent
    # had it. A mark older than {DELIVERY_WINDOW} was left by a process that
    # died while it waited: the line may or may not have reached the agent.
    #
    # @param attempt [Hash{String=>Object}, nil] a step's last attempt
    # @param now [Time]
    # @return [Symbol, nil] :delivering, :unknown, or nil when the line was delivered or never sent
    def self.delivery(attempt, now)
      return nil unless attempt && attempt["delivery"] == "delivering"
      (now - Time.iso8601(attempt["started_at"]) > DELIVERY_WINDOW) ? :unknown : :delivering
    rescue ArgumentError, TypeError
      :unknown
    end

    # Where the sweep's retry of an undelivered line stands. The step must wait on a failed delivery (reason
    # `waiting_you`, kind `dispatch`, a code in {REDELIVER_CODES}), with no park, its last attempt ended
    # `not_delivered`, and the definition's `redeliver` above 0. Attempts the sweep already retried carry
    # `redelivered: true`, and do not count against `max_attempts`.
    #
    # @param run [Hash{String=>Object}] a stored run
    # @param now [Time]
    # @return [Hash, nil] nil when no retry applies; else :state (`:due`, `:waiting` for the backoff, `:exhausted`),
    #   :retries (done), :limit, :wait (seconds left), :code
    def self.redelivery(run, now)
      limit = WorkflowDefinition.redeliver(run["definition"])
      return nil if limit.zero? || run["parked"] || run["state"] != "waiting"
      reason = run["reason"]
      details = reason.is_a?(Hash) ? reason["details"] : nil
      return nil unless reason.is_a?(Hash) && reason["code"] == "waiting_you" && details.is_a?(Hash) && details["kind"] == "dispatch"
      return nil unless REDELIVER_CODES.include?(details["error"]) && !REDELIVER_NEVER_REASONS.include?(details["reason"])
      state = run.dig("steps", run["current"])
      attempts = state.is_a?(Hash) ? state["attempts"] : nil
      last = attempts.is_a?(Array) ? attempts.last : nil
      return nil unless state["state"] == "waiting" && last.is_a?(Hash) && last["outcome"] == "not_delivered" && !last["redelivered"]
      # `redelivery` is set on an attempt the sweep started: a person's resume starts the count again.
      retries = last["redelivery"].is_a?(Integer) ? last["redelivery"] : 0
      info = {retries: retries, limit: limit, code: details["error"]}
      return info.merge(state: :exhausted, wait: 0) if retries >= limit
      wait = Time.iso8601(last["ended_at"].to_s) + REDELIVER_BACKOFF[[retries, REDELIVER_BACKOFF.size - 1].min] - now
      (wait > 0) ? info.merge(state: :waiting, wait: wait.ceil) : info.merge(state: :due, wait: 0)
    rescue ArgumentError, TypeError, NoMethodError
      nil
    end

    # Where an `on_fail` retry's wait stands. A step that failed with `on_fail: {backoff: ...}` stores `backoff` on
    # the run (`until`, `to`, `text`, `context`) and reads `waiting` with the reason `retry_backoff`; nothing is
    # held meanwhile (no attempt, binding or lock). The retry starts when the time has come: by {#tick}, by
    # `workflow sweep` ({#retry_backoff}), or at once by a person's resume.
    #
    # @param run [Hash{String=>Object}] a stored run
    # @param now [Time]
    # @return [Hash, nil] nil when the run waits out no backoff (an old run too); else :state (`:waiting` or
    #   `:due`), :wait (seconds left, 0 when due), :until (ISO time), :to (the step the retry goes back to)
    def self.backoff(run, now)
      stored = run["backoff"]
      return nil unless stored.is_a?(Hash) && run["state"] == "waiting" && stored["to"].is_a?(String) && !stored["blocked"]
      # A time that can't be read is taken as over: a wait must not outlast what could be measured.
      wait = begin
        Time.iso8601(stored["until"].to_s) - now
      rescue ArgumentError
        0
      end
      {state: (wait > 0) ? :waiting : :due, wait: [wait.ceil, 0].max, until: stored["until"], to: stored["to"]}
    end

    # Where a run's parked resume stands.
    #
    # @param run [Hash{String=>Object}] a stored run
    # @param now [Time]
    # @return [Symbol, nil] :waiting, :expired (an unreadable time too), or nil with no park
    def self.parked(run, now)
      parked = run["parked"]
      return nil unless parked
      (now > Time.iso8601(parked["expires_at"])) ? :expired : :waiting
    rescue ArgumentError, TypeError
      :expired
    end

    # The one wording of a parked resume that ran out of time.
    #
    # @param pane [String] the pane the resume waited on
    # @param checking [Boolean] the step reads `checking`, so a check's result may have been thrown away
    # @return [String]
    def self.park_timeout_message(pane, checking: false)
      text = "the turn in pane #{pane} did not end within 1 hour, so nothing was typed. Any --from or --pane on that resume was not applied, " \
        "and a note is kept for the next attempt. Resume the run again. A step still running is decided as usual when its turn ends."
      return text unless checking
      "#{text} A check that finished while this was parked was not recorded; resume the run to run it again."
    end

    # @param store [Workspace::WorkflowRunStore]
    # @param resources [Workspace::RunResources] holds each step's `uses:` for the run
    # @param composer [Workspace::InstructionComposer] builds a step's instructions
    # @param panes [Workspace::WorkflowPanes] binds, finds and types into the run's pane
    # @param checker [Workspace::WorkflowCheck] runs a step's `status:` command
    # @param commands_config [Workspace::CommandsConfig] the project's `commands.test`/`commands.lint`
    # @param lineage [Workspace::WorkspaceLineage] names a checkout's parent project
    # @param git [Workspace::Git] reads the checkout's branch
    # @param guard [Workspace::WorkflowGuard] records a run's base commit and checks a guarded step against it
    # @param excludes [Workspace::GitExclude] keeps `.workflow/` out of `git status`
    # @param env_stopper [#call, nil] stops the dev environment a run left running under a lock it
    #   gave up (`run_id:`, `worktree:`), so nobody queues behind an environment no step uses
    # @param event_log [Workspace::EventLog, nil] gets `workflow_changed` and the run's lock events
    # @param gate_note [Workspace::WorkflowGateNote] finds and hashes the note a gate names
    # @param task_store [Workspace::TaskStore, nil] names the workspace's task in the run
    # @param attempt_record [Workspace::WorkflowAttemptRecord, nil] records what each attempt started from and ended with
    #   (default: one reading HEAD through `guard`)
    # @param require_check [Workspace::WorkflowRequire, nil] checks a step's `require:` proofs
    #   (default: one over `guard` and `gate_note`)
    # @param log_tail [Workspace::WorkflowLogTail, nil] reads the end of a failed check's log for `on_fail`'s `log_tail`
    #   (default: a new one)
    # @param alerts [Workspace::WorkflowAlerts, nil] tells a person of a gate, a failure, a stall or a finish through `alerts.notify`
    #   (default: none)
    # @param inbox_for [#call, nil] given a workspace name, its inbox store, for a guard's warning (default: no item)
    # @param workspace_known [#call, nil] given a project name, true when a workspace of that name exists (for `workflow check`'s `--name` hint); nil means none does
    # @param clock [#call] returns the current Time
    def initialize(store:, resources:, composer:, panes:, checker:, commands_config:, lineage:, git:, guard:, excludes:, gate_note:,
      env_stopper: nil, workspace_known: nil, event_log: nil, task_store: nil, attempt_record: nil, require_check: nil, log_tail: nil, alerts: nil, inbox_for: nil, clock: -> { Time.now })
      @store = store
      @resources = resources
      @composer = composer
      @panes = panes
      @checker = checker
      @commands_config = commands_config
      @lineage = lineage
      @git = git
      @guard = guard
      @excludes = excludes
      @gate_note = gate_note
      @env_stopper = env_stopper
      @workspace_known = workspace_known
      @event_log = event_log
      @task_store = task_store
      @attempt_record = attempt_record || WorkflowAttemptRecord.new(guard: guard, clock: clock)
      @require_check = require_check || WorkflowRequire.new(guard: guard, notes_dir_of: ->(workspace) { gate_note.notes_dir_of(workspace) },
        commands_config: commands_config, checker: checker)
      @log_tail = log_tail || WorkflowLogTail.new
      @alerts = alerts
      @inbox_for = inbox_for
      @clock = clock
      @delivery = nil
    end

    # The background task types that hold a step (the labels Claude Code lists), and the shape of a
    # task id. The Stop hook boundary and `workflow advance --background-task` both check against these.
    BACKGROUND_TASK_TYPES = ["subagent", "workflow", "shell", "monitor", "MCP task", "cloud session"].freeze
    BACKGROUND_TASK_ID = /\A[\w-]{1,64}\z/

    # How long a `turn_ended_background` hold lasts after the last Stop that listed tasks.
    BACKGROUND_HOLD = 90 * 60

    # Whether a run is one only a timer will wake: a resume is parked on it,
    # an `on_fail` retry's backoff is over,
    # it waits for a lock, its check was started and never reported back
    # (the process running it died), judged by the check's time limit plus a
    # minute, or it has been held for background tasks longer than
    # {BACKGROUND_HOLD}.
    #
    # @param run [Hash{String=>Object}] a stored run
    # @param now [Time]
    # @return [Symbol, nil] :parked, :backoff (a retry's wait is over), :lock, :background, :check, or nil
    def self.wakeable?(run, now)
      return :parked if run["parked"]
      return :backoff if backoff(run, now)&.fetch(:state) == :due
      return :lock if run.dig("reason", "code") == "waiting_lock"
      return :background if background_expired?(run["reason"], now)
      # A park that failed left its reason on a checking step: that run waits for a person's resume.
      :check if run["reason"].nil? && lost_check?(run, now)
    end

    # Whether nothing is left to report the current step's check: its process
    # died, or a park threw its result away (a park that ended left a reason
    # on the step, or one past its limit is still stored).
    #
    # @param run [Hash] the run file
    # @param now [Time]
    # @return [Boolean]
    def self.lost_check?(run, now)
      state = run["steps"].fetch(run["current"])
      return false unless state["state"] == "checking"
      return true if run["reason"] || parked(run, now) == :expired
      attempt = state["attempts"].last
      # A `require:` proof outside the run's lock has its own start and limit; a run stored without `proofs` has neither.
      proof = Array(attempt&.dig("proofs")).find { |each| !each.key?("ended_at") }
      return now - Time.iso8601(proof["started_at"]) > WorkflowRequire.lost_after(proof) if proof
      started = attempt&.dig("check", "started_at")
      step = run["definition"]["steps"].find { |each| each["id"] == run["current"] }
      timeout = step.dig("status", "timeout") || WorkflowDefinition::DEFAULT_CHECK_TIMEOUT
      started.nil? || now - Time.iso8601(started) > timeout + 60
    end

    # A hold with no readable `seen_at` has nothing to measure it by, so it counts as expired.
    def self.background_expired?(reason, now)
      return false unless reason && reason["code"] == "turn_ended_background"
      now - Time.iso8601(reason["seen_at"].to_s) > BACKGROUND_HOLD
    rescue ArgumentError
      true
    end
    private_class_method :background_expired?

    # Checks everything `start` would refuse, and changes nothing.
    #
    # @param definition [Workspace::WorkflowDefinition]
    # @param workspace [String] the workspace the run would work in
    # @param worktree [String] that workspace's checkout
    # @param inputs [Hash{String=>String}] values for the definition's inputs
    # @param pane [String, nil] the pane id the steps would run in, when it is known
    # @param tree [String, nil] the checkout a `guard: unchanged` step would run in, which must
    #   be clean (no commit to start from, no git operation stopped, no change to a tracked
    #   file); nil skips the look
    # @param checkout [String, nil] the path of a checkout that does not exist yet (the worktree `workflow start`
    #   will have `start` make), checked for characters unsafe in shell commands like +worktree+ and +tree+
    # @return [Hash{String=>Object}] "workflow", "workspace", "project", "step" (the first
    #   step), "pane", "inputs" and "packs" (the refs the first step's instructions use)
    # @raise [Workspace::Error] code `input_required` for a missing input, `usage` for an
    #   unknown one, `workflow_command_unset` when a step's check names a command the
    #   project has not set, `workflow_test_files_unset` for `{{changed.tests}}` with no `commands.test_files`, `workflow_program_missing` for an `exec` program that can't run (a relative one is judged in +tree+, not at all when it is nil), `dirty_worktree` when +tree+ is not clean for a guarded step, `pane_has_run` when the pane already runs a workflow, and
    #   the composer's errors for a pack that can't be read
    def preflight(definition:, workspace:, worktree:, inputs:, pane: nil, tree: worktree, checkout: nil)
      data = definition.to_h
      inputs = check_inputs(data, inputs)
      check_checkout_path(data, [worktree, tree, checkout].compact.uniq)
      check_notes_path(data, workspace)
      check_tree(data, tree)
      project = @lineage.resolve(cwd: worktree).name
      check_commands(data, project)
      check_test_files(data, workspace)
      check_exec_programs(data, tree)
      check_pane(pane)
      check_checkout(tree)
      first = data["steps"].first
      packs = compose({"definition" => data, "workspace" => workspace, "worktree" => worktree, "inputs" => inputs,
                       "id" => PREVIEW_RUN_ID, "artifacts_dir" => artifacts_dir(worktree, PREVIEW_RUN_ID)}, first, [])["packs"]
      {"workflow" => data["id"], "workspace" => workspace, "project" => project, "step" => first["id"], "pane" => pane,
       "inputs" => inputs, "packs" => packs.map { |pack| pack["ref"] }}
    end

    # The instructions a step's agent would be sent for its first attempt, composed by the
    # code that composes a delivered attempt's prompt, with a run that does not exist: the id
    # is {PREVIEW_RUN_ID} and the artifacts directory lies under it. Writes nothing and
    # touches no run, binding, lock, pane or daemon.
    #
    # @param definition [Workspace::WorkflowDefinition]
    # @param step [String] a step id
    # @param workspace [String]
    # @param worktree [String] the checkout the packs are read from
    # @param inputs [Hash{String=>String}] checked as {#preflight} checks them
    # @return [Hash{String=>Object}] "workflow", "step", "workspace", "worktree", "inputs", "gate",
    #   "text", "packs" (refs), "run", "artifacts_dir", "instructions" (the path a real attempt's file would have)
    #   and "in_checkout" (false when +worktree+ is not in a git checkout)
    # @raise [Workspace::Error] code `unknown_step` (details.workflow, step, steps), `input_required`,
    #   `invalid_input`, and the composer's errors for a pack that can't be read
    # @raise [Workspace::UsageError] for an input the definition doesn't have
    def render(definition:, step:, workspace:, worktree:, inputs:)
      data = definition.to_h
      found = step_of(data, step)
      inputs = check_inputs(data, inputs)
      # A started run stores the definition with the strict marker, which words the produces line.
      run = {"definition" => data.merge(WorkflowProduced::MARKER_KEY => WorkflowProduced::STRICT), "workspace" => workspace, "worktree" => worktree, "inputs" => inputs,
             "id" => PREVIEW_RUN_ID, "artifacts_dir" => artifacts_dir(worktree, PREVIEW_RUN_ID)}
      path = prompt_path(run, found, 1)
      composed = compose(run, found, [], binding: step_binding(run, found, 1, path))
      {"workflow" => data["id"], "step" => found["id"], "workspace" => workspace, "worktree" => worktree, "inputs" => inputs,
       "gate" => found["gate"], "text" => composed["text"], "packs" => composed["packs"].map { |pack| pack["ref"] },
       "run" => PREVIEW_RUN_ID, "artifacts_dir" => run["artifacts_dir"], "instructions" => path,
       "in_checkout" => !@lineage.resolve(cwd: worktree).git_common_dir.nil?}
    end

    # What `workflow check` runs for a step, found as a run finds it: the step's `status:` command
    # (the project's `commands.test`/`lint` for the `command:` form), its time limit, and the checkout's HEAD
    # for `WORKSPACE_RUN_BASE_SHA`. A `status:` command is never rendered, so inputs play no part. Writes nothing.
    #
    # @param definition [Workspace::WorkflowDefinition]
    # @param step [String] a step id
    # @param worktree [String] the checkout the check runs in and the project's commands are read from
    # @return [Hash{String=>Object}] "workflow", "step", "command", "timeout" (whole seconds as an Integer), "base_sha"
    #   (empty when HEAD can't be read), "run" ({PREVIEW_RUN_ID}) and "in_checkout"
    # @raise [Workspace::Error] code `unknown_step`, `step_without_status` (the step has no `status:`) or
    #   `workflow_command_unset` (the project command it names is not set; `details.steps` as for `start`)
    def check_plan(definition:, step:, worktree:)
      data = definition.to_h
      found = step_of(data, step)
      status = found["status"]
      unless status
        raise Workspace::Error.new("Step #{found["id"]} of workflow #{data["id"]} has no status: command to check.",
          code: "step_without_status", details: {"workflow" => data["id"], "step" => found["id"]})
      end
      lineage = @lineage.resolve(cwd: worktree)
      command = status["run"] || @commands_config.for_project(lineage.name)[status["command"].to_sym]
      unless command
        raise Workspace::Error.new("Step #{found["id"]} of workflow #{data["id"]} checks with the project's #{status["command"]} command, and #{lineage.name || "this directory"} has none. " +
          (@workspace_known&.call(lineage.name) ? "Set it: workspace config set commands.#{status["command"]} \"<#{status["command"]} command>\" --name #{lineage.name}" : "Set commands.#{status["command"]} in this project's workspace."),
          code: "workflow_command_unset", details: {"workflow" => data["id"], "project" => lineage.name, "commands" => [status["command"]],
                                                    "steps" => [{"step" => found["id"], "command" => status["command"], "via" => "status"}]})
      end
      timeout = status["timeout"] || WorkflowDefinition::DEFAULT_CHECK_TIMEOUT
      {"workflow" => data["id"], "step" => found["id"], "command" => command,
       "timeout" => (timeout == timeout.to_i) ? timeout.to_i : timeout, "base_sha" => @guard.head(worktree).to_s,
       "run" => PREVIEW_RUN_ID, "in_checkout" => in_checkout?(lineage.git_common_dir, worktree)}
    end

    # Creates a run and starts its first step.
    #
    # @param definition [Workspace::WorkflowDefinition]
    # @param workspace [String]
    # @param worktree [String]
    # @param inputs [Hash{String=>String}]
    # @param pane [String] the pane id the steps run in
    # @param note [String, nil] added to every step's instructions
    # @param dispatch [Boolean] false stores the run waiting with `not_started` and types nothing
    # @return [Hash{String=>Object}] the run after its first transition, or as created
    # @raise [Workspace::Error] see {#preflight}
    def start(definition:, workspace:, worktree:, inputs:, pane:, note: nil, dispatch: true)
      checked = preflight(definition: definition, workspace: workspace, worktree: worktree, inputs: inputs, pane: pane)
      # The marker says this run's `produces` files must be non-empty regular files, not links;
      # a run stored without it keeps the exists-only check (see WorkflowProduced).
      data = definition.to_h.merge(WorkflowProduced::MARKER_KEY => WorkflowProduced::STRICT)
      now = now_iso
      base = @guard.base(worktree)
      # Stored as waiting to be started: a `workflow run` that is interrupted before its
      # first step is under way leaves a run that says so, and that `resume` can start.
      attributes = {
        "schema_version" => 1, "workflow" => data["id"], "title" => data["title"],
        "definition" => data, "definition_source" => definition.source, "definition_path" => definition.path,
        "definition_sha256" => definition.resolved_sha256,
        "workspace" => workspace, "project" => checked["project"], "worktree" => worktree,
        "base_sha" => base["base_sha"], "base_guard" => base["base_guard"],
        "task" => task_id(workspace), "inputs" => checked["inputs"], "note" => note,
        "state" => "waiting", "created_at" => now, "started_at" => now, "ended_at" => nil,
        "current" => data["steps"].first["id"], "pane" => pane, "loops" => {}, "pending_context" => [],
        "reason" => reason("waiting_you", "kind" => "dispatch", "step" => data["steps"].first["id"], "pane" => pane, "workspace" => workspace,
          "error" => "not_started", "message" => "the run was created and its first step never started"),
        "steps" => data["steps"].to_h { |step| [step["id"], {"state" => "pending", "attempts" => []}] }
      }
      run = @store.create(attributes, -> {
        check_pane(pane)
        check_checkout(worktree)
      }) { |created| created["artifacts_dir"] = artifacts_dir(worktree, created["id"]) }
      event(run, "run_started", "workflow" => data["id"], "workspace" => workspace)
      return transition(run["id"]) { |_stored| } unless dispatch
      transition(run["id"]) { |stored| dispatch(stored) }
    end

    # The agent's turn ended in the run's pane: decides whether the current
    # step is done. A step with a `status:` check has it run here, outside
    # the run's lock, so a long check never blocks a `cancel`.
    #
    # @param run_id [String]
    # @param pane [String, nil] the pane the turn ended in; an event from a pane the
    #   run is not bound to changes nothing
    # @param turn_started [Time, nil] when the turn that ended began, when the daemon knows.
    #   A turn that began before the step's attempt did was already under way when the
    #   step's line was typed (a person talking to the agent at a gate), and its end
    #   decides nothing. Without it every end of a turn in the pane counts
    # @param background [Array<Hash>] the background tasks (`"id"`, `"type"`) the agent still listed when
    #   its turn ended. A step the files do not yet complete is then held (`turn_ended_background`) and
    #   not reported as stopped, since each task that ends starts another turn
    # @param stopped_at [Time, nil] when the turn's end was seen. One from before the attempt
    #   began can't be that attempt's own, even with no +turn_started+
    # @return [Hash{String=>Object}] the run afterwards
    # @raise [Workspace::Error] code `unknown_run` or `run_not_active`
    def turn_ended(run_id, pane: nil, turn_started: nil, stopped_at: nil, background: [])
      check = nil
      run = transition(run_id) do |stored|
        next if stored["parked"]
        state = step_state(stored)
        next unless state["state"] == "running"
        next if pane && bound_pane(stored) != pane
        next if turn_started && turn_started < Time.iso8601(state["attempts"].last["started_at"])
        next if stopped_at && stopped_at < Time.iso8601(state["attempts"].last["started_at"])
        check = evaluate(stored, turn_started: turn_started, background: background)
      end
      check ? finish_check(run_id, check) : run
    end

    # Records what the agent says about its current attempt. Nothing moves
    # until the turn ends.
    #
    # @param run_id [String]
    # @param status [String] "pass" or "fail"
    # @param summary [String, nil] one line about the attempt
    # @param code [String, nil] a word the agent chose for why (stored; a failed step's `details.code`)
    # @return [Hash{String=>Object}] "run_id", "step", "attempt" and "reported" (the stored
    #   report: "status", "summary", "code", "at")
    # @raise [Workspace::Error] code `step_not_running` when the run's step is not being worked on
    def report(run_id, status:, summary: nil, code: nil)
      result = nil
      transition(run_id) do |stored|
        state = step_state(stored)
        unless %w[running checking].include?(state["state"])
          raise Workspace::Error.new("Step #{stored["current"]} of run #{run_id} is #{state["state"]}, so there is nothing to report on.",
            code: "step_not_running", details: {"run_id" => run_id, "step" => stored["current"], "state" => state["state"]})
        end
        attempt = state["attempts"].last
        attempt["reported"] = {"status" => status, "summary" => summary, "code" => code, "at" => now_iso}.reject { |key, value| key == "code" && value.nil? }
        event(stored, "step_reported", "step" => stored["current"], "attempt" => attempt["n"], "status" => status)
        result = {"run_id" => run_id, "step" => stored["current"], "attempt" => attempt["n"], "reported" => attempt["reported"]}
      end
      result
    end

    # Passes a gate: the run goes on to the step after the gated one. When the
    # gated step's first file names a note (`note: <file>`), the note's sha256
    # is recorded with the approval and named in the next step's instructions.
    # Every check runs under the run's lock, in this order: the gate is
    # waiting (at +step+ and +attempt+ when given), +guard+, then the note.
    # A refusal leaves the run file as it was.
    #
    # @param run_id [String]
    # @param note [String, nil] added to the next step's instructions
    # @param step [String, nil] the gated step the caller saw; refused when the run is elsewhere
    # @param attempt [Integer, nil] that step's attempt the caller saw (needs +step+)
    # @param note_sha256 [String, nil] the note's sha256 the caller read; refused when it changed
    # @param guard [#call, nil] called with the stored run after the step checks; raises to refuse
    # @return [Hash{String=>Object}] the run afterwards
    # @raise [Workspace::Error] code `gate_not_waiting` when the run is not at a gate (or not at
    #   +step+ and +attempt+), `stale_revision` when the note's sha256 is not +note_sha256+,
    #   `gate_note_unreadable` when the named note can't be read, or when +note_sha256+ is given
    #   and the gate names no note; and what +guard+ raises
    def approve(run_id, note: nil, step: nil, attempt: nil, note_sha256: nil, guard: nil)
      transition(run_id) do |stored|
        gate = waiting_gate(stored, step: step, attempt: attempt)
        guard&.call(stored)
        file = gate_file(stored, note_sha256)
        gate.merge!("state" => "approved", "at" => now_iso, "note" => note)
        gate["file"] = file if file
        event(stored, "gate_approved", with_note({"step" => stored["current"]}, note).merge(file ? {"sha256" => file["sha256"]} : {}))
        stored["pending_context"] << "The #{stored["current"]} step was approved with this note: #{note}" if note
        stored["pending_context"] << "The approved note is #{file["path"]}, sha256 #{file["sha256"]}." if file
        advance(stored)
      end
    end

    # Turns a gate down: the gated step, or an earlier one, runs again with the note.
    #
    # @param run_id [String]
    # @param note [String] why, added to that step's instructions
    # @param to [String, nil] the step to run again; nil for the gated step
    # @param step [String, nil] the gated step the caller saw; refused when the run is elsewhere
    # @param attempt [Integer, nil] that step's attempt the caller saw (needs +step+)
    # @param guard [#call, nil] called with the stored run after the step checks; raises to refuse
    # @param extra_attempts [Integer, nil] added to the run's attempt allowance (see {#resume})
    # @param extra_tokens [Integer, nil] added to the run's token budget (see {#resume})
    # @return [Hash{String=>Object}] the run afterwards
    # @raise [Workspace::Error] code `gate_not_waiting`; `attempts_spent` when the run has made all its
    #   attempts and +extra_attempts+ is not given; `budget_spent` when the token budget is used up and +extra_tokens+ does not cover it; `usage` when `to` is not the gated step or
    #   one before it; and what +guard+ raises
    def reject(run_id, note:, to: nil, step: nil, attempt: nil, guard: nil, extra_attempts: nil, extra_tokens: nil)
      transition(run_id) do |stored|
        gate = waiting_gate(stored, step: step, attempt: attempt)
        guard&.call(stored)
        target = to || stored["current"]
        ids = step_ids(stored)
        unless ids.first(ids.index(stored["current"]) + 1).include?(target)
          raise UsageError, "--to must be #{stored["current"]} or a step before it (#{ids.first(ids.index(stored["current"]) + 1).join(", ")}), got #{target.to_s[0, 60].inspect}."
        end
        # The step runs again, which is a new attempt.
        spend_attempts(stored, extra_attempts)
        spend_tokens(stored, extra_tokens)
        gate.merge!("state" => "rejected", "at" => now_iso, "note" => note, "attempt" => step_state(stored)["attempts"].last&.fetch("n", nil))
        event(stored, "gate_rejected", with_note({"step" => stored["current"], "to" => target}, note))
        stored["pending_context"] << "The #{stored["current"]} step was rejected at its gate: #{note}"
        stored["current"] = target
        dispatch(stored)
      end
    end

    # Gets a run that is not moving going again: asks for its lock again,
    # runs a failed or undelivered step again, looks again at a step whose
    # turn ended without its files or without the daemon seeing it, and
    # moves the run to another pane when its own is gone. A step an agent is
    # working on, and a check that is still running, are left alone. A resume
    # that acts takes over from a parked one; one that does nothing leaves it.
    #
    # @param run_id [String]
    # @param from [String, nil] start again at this step instead
    # @param note [String, nil] added to the next attempt's instructions
    # @param pane [String, nil] the pane to use from now on (when the old one is gone)
    # @param turn_over [Hash{String=>Object}, nil] "step" and "attempt": the pane's agent was
    #   seen to have ended its turn on that attempt, so the step, if the run is still on that
    #   attempt and it reads `running`, is decided now
    # @param extra_attempts [Integer, nil] raises the run's attempt allowance by this much, kept in the run
    #   (`extra_attempts`) and recorded as `attempts_extended`; applied only when the resume starts an attempt,
    #   whether or not the allowance was spent
    # @param extra_tokens [Integer, nil] raises the run's token budget by this much, kept in the run (`extra_tokens`)
    #   and recorded as `budget_extended`; applied only when the resume starts an attempt, whether or not the budget was spent
    # @return [Hash{String=>Object}] the run afterwards; with "unchanged" (why, as a
    #   sentence) when nothing was done
    # @raise [Workspace::Error] see {#refuse_resume}; code `attempts_spent` when the resume would start
    #   an attempt the run has none left for and +extra_attempts+ is not given; `budget_spent` likewise for the token budget and +extra_tokens+
    def resume(run_id, from: nil, note: nil, pane: nil, turn_over: nil, extra_attempts: nil, extra_tokens: nil)
      check = nil
      unchanged = nil
      run = transition(run_id) do |stored|
        check, unchanged = resume_step(stored, from: from, note: note, pane: pane, turn_over: turn_over, extra_attempts: extra_attempts, extra_tokens: extra_tokens)
      end
      run = finish_check(run_id, check) if check
      unchanged ? run.merge("unchanged" => unchanged) : run
    end

    # Stores a resume for later, with the same arguments as {#resume}: no
    # attempt, no binding, no new lock. What the run already has stays, and
    # {#release_park} carries it out. A live park stays as it is, so repeating
    # the call can't extend the wait; one past its limit is replaced.
    #
    # @param run_id [String]
    # @param from [String, nil] see {#resume}
    # @param note [String, nil] see {#resume}; stored in the run, never in an event
    # @param pane [String, nil] see {#resume}
    # @param turn_over [Hash{String=>Object}, nil] see {#resume}
    # @param extra_attempts [Integer, nil] see {#resume}; applied when the park is released
    # @param extra_tokens [Integer, nil] see {#resume}; applied when the park is released
    # @return [Hash{String=>Object}] the run afterwards; with "unchanged" (why, as a
    #   sentence) when nothing was stored
    # @raise [Workspace::Error] see {#refuse_resume}; code `pane_has_run` for a +pane+ another run has;
    #   `attempts_spent` as {#resume}
    def park(run_id, from: nil, note: nil, pane: nil, turn_over: nil, extra_attempts: nil, extra_tokens: nil)
      unchanged = nil
      run = transition(run_id) do |stored|
        refuse_resume(stored, from: from)
        if self.class.parked(stored, @clock.call) == :waiting
          unchanged = "a resume is already parked for pane #{park_target(stored)}"
          next
        end
        unchanged = from ? nil : left_alone(stored, step_state(stored), pane, turn_over)
        next if unchanged
        check_pane(pane, run_id: run_id) if pane && @panes.run_on(pane) != run_id
        if starts_attempt?(stored, from: from, pane: pane)
          refuse_spent(stored, extra_attempts)
          refuse_over_budget(stored, extra_tokens)
        end
        drop_park(stored, "expired")
        store_park(stored, {"from" => from, "note" => note, "pane" => pane, "turn_over" => turn_over}.merge(extra_attempts ? {"extra_attempts" => extra_attempts} : {}).merge(extra_tokens ? {"extra_tokens" => extra_tokens} : {}),
          expires_at: (@clock.call + PARK_SECONDS).utc.iso8601, retries: 0)
      end
      unchanged ? run.merge("unchanged" => unchanged) : run
    end

    # Carries out a parked resume, in one change with taking it off the run.
    #
    # @param run_id [String]
    # @param id [String] the park's id; any other changes nothing
    # @return [Hash{String=>Object}] the run afterwards; with "unchanged" (why, as a
    #   sentence) when the resume did nothing, its note kept for the next attempt
    # @raise [Workspace::Error] see {#resume}; the run stays parked
    def release_park(run_id, id)
      check = nil
      unchanged = nil
      run = transition(run_id) do |stored|
        parked = stored["parked"]
        next unless parked && parked["id"] == id
        stored.delete("parked")
        check, unchanged = resume_step(stored, from: parked["from"], note: parked["note"], pane: parked["pane"], turn_over: parked["turn_over"], extra_attempts: parked["extra_attempts"], extra_tokens: parked["extra_tokens"],
          budget: parked["retries"].to_i.zero?)
        add_resume_note(stored, parked["note"]) if unchanged
        event(stored, "resume_parked_ended", {"step" => stored["current"], "how" => unchanged ? "unchanged" : "released"}
          .merge(unchanged ? {"detail" => unchanged} : {}))
        next unless @delivery
        step_state(stored)["attempts"].last["after_park"] = {"expires_at" => parked["expires_at"], "pane" => @delivery["pane"], "retries" => parked["retries"]}
      end
      run = finish_check(run_id, check) if check
      unchanged ? run.merge("unchanged" => unchanged) : run
    end

    # Ends a park that can't be released, and leaves the run waiting for a
    # person. The step and what it holds stay, so a `running` step keeps its
    # attempt and a later resume decides it. A lock the run queued for is given
    # up, since the run would no longer use it. A run waiting at a gate keeps
    # its gate reason, so approve and reject stay open; the failure is in the
    # `resume_parked_ended` event.
    #
    # @param run_id [String]
    # @param id [String] the park's id; any other changes nothing
    # @param code [String] why, stored as the reason's `error`
    # @param message [String]
    # @return [Hash{String=>Object}] the run afterwards
    # @raise [Workspace::Error] code `unknown_run` or `run_not_active`
    def park_failed(run_id, id, code:, message:)
      transition(run_id) do |stored|
        next unless stored.dig("parked", "id") == id
        if step_state(stored).dig("gate", "state") == "waiting"
          drop_park(stored, "failed", "error" => code, "message" => message)
          next
        end
        target = park_target(stored)
        case stored.dig("reason", "code")
        when "waiting_lock" then release(stored)
        when "failed_check" then stored["pending_context"].unshift(last_failure(stored))
        end
        drop_park(stored, "failed")
        stored["state"] = "waiting"
        stored["reason"] = reason(PANE_GONE_CODES.include?(code) ? "pane_gone" : "waiting_you",
          "kind" => "dispatch", "step" => stored["current"], "pane" => target, "workspace" => stored["workspace"], "error" => code, "message" => message)
      end
    end

    # What {#resume} refuses, checked without changing anything, so a caller
    # can refuse before it starts a daemon or picks a pane.
    #
    # @param run [Hash{String=>Object}] a stored run that has not finished
    # @param from [String, nil] the step a resume would start again at
    # @return [void]
    # @raise [Workspace::Error] code `gate_waiting` for a run at a gate when no step is
    #   named (approve or reject it); `usage` for a step the workflow doesn't have
    def refuse_resume(run, from: nil)
      if from
        return if step_ids(run).include?(from)
        raise UsageError, "No step #{from.to_s[0, 60].inspect} in workflow #{run["workflow"]} (#{step_ids(run).join(", ")})."
      end
      return unless step_state(run).dig("gate", "state") == "waiting"
      raise Workspace::Error.new("Run #{run["id"]} is waiting at the #{run["current"]} gate. Approve or reject it, or pass --from STEP.",
        code: "gate_waiting", details: {"run_id" => run["id"], "step" => run["current"]})
    end

    # Ends a run: gives up its resources and frees its pane.
    #
    # @param run_id [String]
    # @param cause [String] who ended it: "cancel", or "kill" when its workspace was killed
    # @return [Hash{String=>Object}] the run afterwards
    # @raise [Workspace::Error] code `unknown_run` or `run_not_active`
    def cancel(run_id, cause: "cancel")
      transition(run_id) do |stored|
        @attempt_record.abandon(stored)
        finish(stored, "cancelled")
        stored["cancelled_by"] = cause
        event(stored, "run_cancelled", "cause" => cause)
      end
    end

    # Ends every run of a workspace that was killed, so none of them goes on
    # holding a lock for a checkout that is gone. Never raises: a run whose
    # file is malformed is reported, and the others are still ended.
    #
    # @param workspace [String]
    # @return [Hash{String=>Array<String>}] "cancelled", the ids of the runs ended, and
    #   "failed", the ids of the runs that could not be
    def workspace_killed(workspace)
      result = {"cancelled" => [], "failed" => []}
      @store.active.select { |run| run["workspace"] == workspace }.each do |run|
        cancel(run["id"], cause: "kill")
        result["cancelled"] << run["id"]
      rescue
        result["failed"] << run["id"]
      end
      result
    rescue
      result
    end

    # The periodic look at a run nothing else will wake: one whose `on_fail`
    # backoff is over starts its retry, one waiting for a
    # lock asks for it again, a hold for background tasks that passed
    # {BACKGROUND_HOLD} becomes a `turn_ended_incomplete` stop, and a check
    # that never reported back (its process died) is run again. Does nothing
    # while another process is changing the run.
    #
    # @param run_id [String]
    # @return [Hash{String=>Object}, nil] the run afterwards; nil when nothing was done
    def tick(run_id)
      check = nil
      acted = false
      run = transition(run_id, nonblocking: true) do |stored|
        case self.class.wakeable?(stored, @clock.call)
        when :backoff
          acted = true
          start_retry(stored)
        when :lock
          acted = true
          dispatch(stored)
        when :background
          acted = true
          expire_background(stored)
        when :check
          acted = true
          check = evaluate(stored)
        end
      end
      return nil unless run && acted
      check ? finish_check(run_id, check) : run
    end

    # Seconds a pending interrupt claim holds before another sweep may take it over: the process that took it
    # died between the claim and the press.
    INTERRUPT_CLAIM_SECONDS = 60

    # The marks the sweep left on the run's current attempt: "stalled" and "recovered" (cause => time) and
    # "interrupt" (`state` `pending` or `sent`, and `at`). Empty once the run is on another step or attempt.
    #
    # @param run [Hash{String=>Object}] a stored run
    # @return [Hash{String=>Object}]
    def self.sweep_marks(run)
      marks = run["sweep"]
      attempt = run.dig("steps", run["current"], "attempts")&.last&.fetch("n", nil)
      (marks.is_a?(Hash) && marks["step"] == run["current"] && marks["attempt"] == attempt) ? marks : {}
    end

    # Records that the step stands in a stall the sweep found, once for each attempt and cause, and changes
    # nothing else. Does not wait for another process that is changing the run.
    #
    # @param run_id [String]
    # @param step [String] the step the sweep saw the run on
    # @param attempt [Integer, nil] that step's last attempt the sweep saw
    # @param cause [String] `pane_gone`, `agent_gone` or `daemon_down`
    # @param data [Hash{String=>Object}] more for the `step_stalled` event
    # @return [Symbol] :recorded, :repeat (this cause was recorded for the attempt already), :moved_on (the run
    #   is elsewhere now) or :busy (another process is changing the run)
    # @raise [Workspace::Error] code `unknown_run` or `run_not_active`
    def note_stall(run_id, step:, attempt:, cause:, data: {})
      sweep_change(run_id, step: step, attempt: attempt, running: false) { |stored| [mark_stall(stored, cause, data) ? :recorded : :repeat, nil] }
    end

    # Records that the sweep put right a stall it noted, once for each attempt and cause, and only for a cause
    # that was noted. Waits for the run's lock, so the record is not dropped for a busy run.
    #
    # @param run_id [String]
    # @param step [String]
    # @param attempt [Integer, nil]
    # @param cause [String] the cause given to {#note_stall}
    # @param action [String] e.g. `daemon_respawned`
    # @return [Symbol] :recorded, :repeat, :moved_on
    def note_recovery(run_id, step:, attempt:, cause:, action:)
      sweep_change(run_id, step: step, attempt: attempt, running: false, blocking: true) do |stored|
        next [:repeat, nil] unless self.class.sweep_marks(stored).dig("stalled", cause)
        [mark_recovery(stored, cause, action) ? :recorded : :repeat, nil]
      end
    end

    # Decides a step whose agent has ended its turn without anyone seeing it, as {#resume} does when it is given
    # the same proof (+turn_over+). Does nothing unless the run is still on that step and attempt, `running`, with
    # no reason and no park, so a resume that got there first stands.
    #
    # @param run_id [String]
    # @param turn_over [Hash{String=>Object}] "step" and "attempt": the pane's agent was seen to have ended its turn on that attempt
    # @param cause [String] why the sweep acts, e.g. `idle_turn_over`
    # @param data [Hash{String=>Object}] more for the `step_stalled` event
    # @param fail_if_incomplete [Hash, nil] "elapsed" and "timeout" of a step past its `timeout:` with `on_timeout: fail`:
    #   when the decision is a `turn_ended_incomplete` stop, the step is failed with `step_timed_out` instead
    # @return [Symbol] :evaluated, :timed_out, :moved_on or :busy
    def recover(run_id, turn_over:, cause:, data: {}, fail_if_incomplete: nil)
      sweep_change(run_id, step: turn_over["step"], attempt: turn_over["attempt"], running: true) do |stored|
        mark_stall(stored, cause, data)
        mark_recovery(stored, cause, "evaluated")
        check = evaluate(stored)
        next [:evaluated, check] unless fail_if_incomplete && stored.dig("reason", "code") == "turn_ended_incomplete"
        fail_timed_out(stored, fail_if_incomplete["elapsed"], fail_if_incomplete["timeout"])
        [:timed_out, nil]
      end
    end

    # Fails a step that ran past its `timeout:`, by the road a failed check takes (`on_fail`, then a stop for a
    # person), with `details.code` `step_timed_out`. A step held on `turn_ended_incomplete` is failed too. Waits
    # for the run's lock: it follows {#claim_interrupt} and {#interrupt_sent} when keys were pressed.
    #
    # @param run_id [String]
    # @param step [String]
    # @param attempt [Integer, nil]
    # @param elapsed [Numeric] seconds since the attempt began
    # @param timeout [Numeric] the step's `timeout:`
    # @return [Symbol] :timed_out or :moved_on
    def time_out(run_id, step:, attempt:, elapsed:, timeout:)
      sweep_change(run_id, step: step, attempt: attempt, running: :or_incomplete, blocking: true) do |stored|
        fail_timed_out(stored, elapsed, timeout)
        [:timed_out, nil]
      end
    end

    # Types a step's line again after a delivery that failed, as the sweep's retry. Does nothing unless the run is
    # still on that step and attempt and {.redelivery} says a retry is due, so a resume, a park or a cancel that got
    # there first stands. The failed attempt is marked `redelivered` (it no longer counts against `max_attempts`),
    # the cause `undelivered` is recorded once for it, and a new attempt starts exactly as a resume starts one; the
    # typing itself goes through {WorkflowPanes#kick}, which refuses a pane that is not idle.
    #
    # @param run_id [String]
    # @param step [String]
    # @param attempt [Integer, nil] the failed attempt the sweep saw
    # @return [Symbol] :redelivered, :moved_on or :busy
    def redeliver(run_id, step:, attempt:)
      outcome = :moved_on
      info = nil
      run = transition(run_id, nonblocking: true) do |stored|
        next unless sweep_target?(stored, step, attempt, false)
        info = self.class.redelivery(stored, @clock.call)
        next unless info && info[:state] == :due
        mark_stall(stored, "undelivered", {"code" => info[:code], "retry" => info[:retries] + 1, "of" => info[:limit]})
        step_state(stored)["attempts"].last["redelivered"] = true
        # Stamped on the next attempt by {#dispatch}, which may be one `tick` starts after a lock wait.
        step_state(stored)["redelivery_pending"] = info[:retries] + 1
        dispatch(stored, budgeted: false)
        outcome = :started
      end
      return :busy unless run
      return outcome unless outcome == :started
      # The line has been typed (or refused) by now: say what became of it.
      state = run.dig("steps", step)
      last = state["attempts"].last
      return :waiting_lock if run.dig("reason", "code") == "waiting_lock"
      return :not_delivered if last["outcome"] == "not_delivered"
      @store.record_event(run_id, "step_recovered", "step" => step, "attempt" => attempt, "action" => "redelivered")
      :redelivered
    end

    # Starts an `on_fail` retry whose backoff is over, as the sweep's act. Does nothing unless the run is still on
    # that step and attempt and {.backoff} says the wait is over, so a resume, a cancel or a tick that got there
    # first stands.
    #
    # @param run_id [String]
    # @param step [String] the failed step the sweep saw
    # @param attempt [Integer, nil] that step's last attempt the sweep saw
    # @return [Symbol] :retried, :blocked (the pane is no longer the run's; the run waits for a person, nothing is spent), :held (the token budget is used; the run waits for a person), :moved_on or :busy
    def retry_backoff(run_id, step:, attempt:)
      outcome = :moved_on
      run = transition(run_id, nonblocking: true) do |stored|
        next unless sweep_target?(stored, step, attempt, false)
        next unless self.class.backoff(stored, @clock.call)&.fetch(:state) == :due
        start_retry(stored)
        outcome = if stored.dig("backoff", "blocked") then :blocked
        elsif stored["budget_hold"] then :held
        else :retried
        end
      end
      run ? outcome : :busy
    end

    # Takes the right to interrupt a step past its `timeout:`, as a pending mark, so two sweeps at once press the
    # keys once. A pending mark older than {INTERRUPT_CLAIM_SECONDS} can be taken over. Follow it with
    # {#interrupt_sent}, with the lock given up while the keys are pressed.
    #
    # @param run_id [String]
    # @param step [String]
    # @param attempt [Integer, nil]
    # @param elapsed [Numeric] seconds since the attempt began
    # @param timeout [Numeric] the step's `timeout:`
    # @return [Array(Symbol, String), Symbol] [:claimed, the claim's `at`] to hand to {#interrupt_sent}; or :repeat, :moved_on or :busy
    def claim_interrupt(run_id, step:, attempt:, elapsed:, timeout:)
      at = nil
      outcome = sweep_change(run_id, step: step, attempt: attempt, running: true) do |stored|
        marks = sweep_marks_for(stored)
        next [:repeat, nil] if interrupt_held?(marks["interrupt"])
        at = now_iso
        marks["interrupt"] = {"state" => "pending", "at" => at}
        mark_stall(stored, "timed_out", {"elapsed" => elapsed.round, "timeout" => timeout})
        [:claimed, nil]
      end
      (outcome == :claimed) ? [:claimed, at] : outcome
    end

    # Ends a {#claim_interrupt}. Sent: the mark becomes `sent`, and with +record+ the recovery is written. Not
    # sent: the claim is given back, so a later sweep tries again. Waits for the run's lock, so neither is dropped.
    #
    # @param run_id [String]
    # @param step [String]
    # @param attempt [Integer, nil]
    # @param claim_at [String] the `at` {#claim_interrupt} gave; a claim another process took over since is left as it is
    # @param sent [Boolean] whether the keys were pressed
    # @param record [Boolean] write `step_recovered` (false when a {#time_out} follows and writes its own)
    # @return [Symbol] :recorded, :released, :taken_over or :moved_on
    def interrupt_sent(run_id, step:, attempt:, claim_at:, sent:, record: true)
      sweep_change(run_id, step: step, attempt: attempt, running: false, blocking: true) do |stored|
        marks = sweep_marks_for(stored)
        next [:taken_over, nil] unless marks.dig("interrupt", "at") == claim_at
        unless sent
          marks.delete("interrupt")
          next [:released, nil]
        end
        marks["interrupt"] = {"state" => "sent", "at" => now_iso}
        mark_recovery(stored, "timed_out", "interrupted") if record
        [:recorded, nil]
      end
    end

    # The active run on a checkout, matched by realpath. A run with no worktree, or one whose
    # path is gone or can't be resolved, is not that checkout; a finished run is not among the
    # active ones. Reads the store and takes no lock.
    #
    # @param path [String] the checkout's path
    # @return [Hash{String=>Object}, nil] the stored run, or nil
    def run_on_checkout(path)
      target = File.realpath(path)
      @store.active.find do |run|
        run["worktree"].is_a?(String) && File.realpath(run["worktree"]) == target
      rescue SystemCallError
        false
      end
    rescue SystemCallError
      nil
    end

    private

    # One change the sweep makes under the run's lock. The block returns [outcome, check], and is run only for
    # the step and attempt the sweep saw (and, with +running+, only while that step reads `running` with no
    # park and no line still on its way, and no reason: +running+ `:or_incomplete` allows a
    # `turn_ended_incomplete` stop). Without +blocking+ a run another process is changing is :busy.
    def sweep_change(run_id, step:, attempt:, running:, blocking: false)
      outcome = :moved_on
      check = nil
      run = transition(run_id, nonblocking: !blocking) do |stored|
        next unless sweep_target?(stored, step, attempt, running)
        outcome, check = yield stored
      end
      return :busy unless run
      finish_check(run_id, check) if check
      outcome
    end

    def sweep_target?(run, step, attempt, running)
      return false unless run["current"] == step
      state = step_state(run)
      last = state["attempts"].last
      return false unless last&.fetch("n", nil) == attempt
      return true unless running
      return false unless state["state"] == "running" && !run["parked"] && self.class.delivery(last, @clock.call) != :delivering
      run["reason"].nil? || (running == :or_incomplete && run.dig("reason", "code") == "turn_ended_incomplete")
    end

    def sweep_marks_for(run)
      marks = self.class.sweep_marks(run)
      return marks unless marks.empty?
      run["sweep"] = {"step" => run["current"], "attempt" => step_state(run)["attempts"].last&.fetch("n", nil), "stalled" => {}, "recovered" => {}}
    end

    def interrupt_held?(claim)
      return false unless claim
      return true if claim["state"] == "sent"
      @clock.call - Time.iso8601(claim["at"].to_s) < INTERRUPT_CLAIM_SECONDS
    rescue ArgumentError
      false
    end

    # Writes the cause once for each attempt; false when this attempt has it already.
    def mark_stall(run, cause, data)
      stalled = (sweep_marks_for(run)["stalled"] ||= {})
      return false if stalled.key?(cause)
      stalled[cause] = now_iso
      event(run, "step_stalled", sweep_event(run, {"cause" => cause}.merge(data)))
      true
    end

    def mark_recovery(run, cause, action)
      recovered = (sweep_marks_for(run)["recovered"] ||= {})
      return false if recovered.key?(cause)
      recovered[cause] = now_iso
      event(run, "step_recovered", sweep_event(run, "action" => action))
      true
    end

    def fail_timed_out(run, elapsed, timeout)
      mark_stall(run, "timed_out", {"elapsed" => elapsed.round, "timeout" => timeout})
      mark_recovery(run, "timed_out", "failed")
      fail_step(run, {"cause" => "timeout", "timeout" => timeout, "elapsed" => elapsed.round}.merge(code_for("step_timed_out", nil)))
    end

    def sweep_event(run, data)
      {"step" => run["current"], "attempt" => step_state(run)["attempts"].last&.fetch("n", nil)}.merge(data)
    end

    # The body of {#resume}, inside a transition.
    #
    # @return [Array] the check to run, or nil; and why nothing was done, or nil
    def resume_step(stored, from:, note:, pane:, turn_over:, extra_attempts: nil, extra_tokens: nil, budget: true)
      # Refusals come first, so a refused resume leaves the run and its pane as they were.
      refuse_resume(stored, from: from)
      state = step_state(stored)
      # Decided before anything is changed: a resume that does nothing moves no pane and keeps no note.
      unchanged = (from || stored["budget_hold"]) ? nil : left_alone(stored, state, pane, turn_over)
      return [nil, unchanged] if unchanged
      # A wait whose pane would not take the retry is held before anything is written: no rebind, note, event or reset.
      held = held_by_pane(stored, pane, from)
      return [nil, held] if held
      # A pane another run has is refused first, so a refusal after this point logs nothing.
      check_pane(pane, run_id: stored["id"]) if pane && @panes.run_on(pane) != stored["id"]
      # Only a resume that starts an attempt is held to the budget (not a parked one typed again after a
      # busy pane: its attempt was counted then); decided before anything is written.
      starting = budget && starts_attempt?(stored, from: from, pane: pane)
      spend_attempts(stored, extra_attempts, needed: starting)
      spend_tokens(stored, extra_tokens, needed: starting)
      # A person's resume starts the sweep's retry count again, also for a retry waiting on a lock.
      stored["steps"].each_value { |each| each.delete("redelivery_pending") }
      rebind(stored, pane) if pane
      drop_park(stored, "taken_over")
      add_resume_note(stored, note)
      held = stored.delete("budget_hold")
      drop_retry_text(stored, held) if held && from
      if held && !from
        event(stored, "run_resumed", "step" => stored["current"], "budget" => "released")
        stored["reason"] = nil
        dispatch(stored, context: held["context"], budgeted: budget)
        return [nil, nil]
      end
      # A resume skips the wait of a retry; `--from` goes elsewhere and drops it.
      waiting_retry = stored.delete("backoff")
      # A stored wait that names no step to go back to is dropped; the failed step is resumed as it stands.
      waiting_retry = nil unless waiting_retry.is_a?(Hash) && waiting_retry["to"].is_a?(String)
      if waiting_retry && !from
        event(stored, "run_resumed", "step" => stored["current"], "state" => state["state"], "backoff" => "skipped")
        start_retry(stored, waiting_retry, proven: !pane.nil?, budgeted: budget)
        return [nil, held_retry_sentence(stored)]
      end
      if from
        event(stored, "run_resumed", "from" => from)
        stored["current"] = from
        dispatch(stored, budgeted: budget)
        return [nil, nil]
      end
      event(stored, "run_resumed", "step" => stored["current"], "state" => state["state"])
      stored["pending_context"].unshift(last_failure(stored)) if state["state"] == "failed" && stored.dig("reason", "code") == "failed_check"
      check = nil
      case state["state"]
      when "running"
        if pane
          dispatch(stored, budgeted: budget)
        else
          stored["reason"] = nil
          check = evaluate(stored)
        end
      when "checking" then check = evaluate(stored)
      when "passed" then advance(stored)
      else dispatch(stored, budgeted: budget)
      end
      [check, nil]
    end

    # `--from` goes elsewhere: the text that told the held step why it was sent back is not for the step named.
    def drop_retry_text(run, hold)
      index = hold["text"].is_a?(String) ? run["pending_context"].index(hold["text"]) : nil
      run["pending_context"].delete_at(index) if index
    end

    def starts_attempt?(run, from:, pane:) = self.class.starts_attempt?(run, from: from, pane: pane)

    # Attempts that count against the allowance: every one except those the sweep typed again.
    def attempts_made(run) = self.class.attempts_made(run)

    # The definition's `max_attempts` plus what people added with `--extra-attempts`.
    def attempt_allowance(run) = self.class.attempt_allowance(run)

    # Refuses with `attempts_spent` when the allowance is used up and +extra+ does not cover the overrun: the
    # attempt about to start must fit, so +extra+ must be at least made minus allowed plus one.
    def refuse_spent(run, extra)
      made = attempts_made(run)
      allowed = attempt_allowance(run)
      needed = self.class.extra_attempts_needed(run)
      return if made < allowed || (extra && extra >= needed)
      raise Workspace::Error.new("Run #{run["id"]} has spent max_attempts (#{made} of #{allowed}). Pass --extra-attempts #{needed} to continue.",
        code: "attempts_spent", details: {"run_id" => run["id"], "attempts" => made, "max_attempts" => allowed, "step" => run["current"], "needed" => needed})
    end

    # The budget step of a person's resume or reject: refused before anything changes; +extra+ is added to the
    # run and recorded when the action goes on.
    def spend_attempts(run, extra, needed: true)
      return unless needed
      refuse_spent(run, extra)
      return unless extra
      run["extra_attempts"] = run["extra_attempts"].to_i + extra
      event(run, "attempts_extended", "extra" => extra, "extra_attempts" => run["extra_attempts"], "max_attempts" => attempt_allowance(run))
    end

    # Refuses with `budget_spent` when the token budget is used up and +extra+ does not cover the overrun (the least
    # is used minus the allowance plus one). A run without a budget is never refused.
    def refuse_over_budget(run, extra)
      reading = WorkflowBudget.reading(run, live: false)
      return unless reading && reading["spent"]
      return if extra && extra >= reading["needed"]
      raise Workspace::Error.new("Run #{run["id"]} has used its token budget (#{reading["used"]} of #{reading["allowance"]} tokens#{" at least" if reading["uncounted"].positive?}). Pass --extra-tokens #{reading["suggested"]} to continue (#{reading["needed"]} is the least).",
        code: "budget_spent", details: budget_details(run, reading))
    end

    # The token step of a person's resume or reject, as {#spend_attempts} is for attempts.
    def spend_tokens(run, extra, needed: true)
      return unless needed
      refuse_over_budget(run, extra)
      return unless extra && WorkflowBudget.reading(run)
      run["extra_tokens"] = run["extra_tokens"].to_i + extra
      event(run, "budget_extended", "extra" => extra, "extra_tokens" => run["extra_tokens"], "allowance" => WorkflowBudget.reading(run, live: false)["allowance"])
    end

    def budget_details(run, reading)
      {"run_id" => run["id"], "step" => run["current"]}.merge(reading.slice("used", "allowance", "counted", "uncounted", "needed", "suggested"))
        .merge("tokens" => reading["tokens"], "extra_tokens" => reading["extra_tokens"])
    end

    # Whether the attempt about to start is held: the budget is used up. Not for a lock wait that ends (the attempt
    # was allowed when the step was reached). A run none of whose attempts could be counted has a total of 0, which is
    # under any budget, so it is never held.
    def budget_holds?(run)
      return false if run.dig("reason", "code") == "waiting_lock"
      reading = WorkflowBudget.reading(run, live: false)
      !!(reading && reading["spent"])
    end

    # Stops the run before the attempt: nothing is held, the step is left as it was, and the run waits for a
    # person. The resume that ends it starts the attempt, with the context the stop kept.
    def hold_for_budget(run, context, retry_of = nil)
      reading = WorkflowBudget.reading(run, live: false)
      release(run)
      pane = retry_of&.fetch("pane", nil) || bound_pane(run)
      identity = retry_of&.fetch("identity", nil) || @panes.identity(run["id"])
      run["budget_hold"] = {"context" => context, "pane" => pane, "identity" => identity, "text" => retry_of&.fetch("text", nil)}.compact
      run["state"] = "waiting"
      run["reason"] = reason("budget_spent", budget_details(run, reading).merge("kind" => "budget"))
      event(run, "budget_spent", reading.slice("used", "allowance", "counted", "uncounted").merge("step" => run["current"]))
      true
    end

    # A run held by its budget types into the pane it had when the attempt would have started. As for a retry's wait,
    # that pane must still be the run's (a person's +pane+ is the proof); nothing is written, so a refusal costs nothing.
    def held_budget_pane(stored, pane)
      hold = stored["budget_hold"]
      check_pane(pane, run_id: stored["id"]) if pane && @panes.run_on(pane) != stored["id"]
      problem = retry_pane_problem(stored, hold, pane: pane || @panes.pane_of(stored["id"]) || hold["pane"], proven: !pane.nil?)
      problem && problem[:message].sub(/\.\z/, "")
    end

    # The read-only decision of a resume over a retry's wait: the sentence saying why the retry can't start in the
    # pane it would use (an explicit +pane+ counts as proven), after recording the hold once; nil when it can start
    # or the run waits out no (readable) backoff.
    def held_by_pane(stored, pane, from)
      return held_budget_pane(stored, pane) if stored["budget_hold"].is_a?(Hash)
      waiting = stored["backoff"]
      return nil if from || !(waiting.is_a?(Hash) && waiting["to"].is_a?(String))
      check_pane(pane, run_id: stored["id"]) if pane && @panes.run_on(pane) != stored["id"]
      problem = retry_pane_problem(stored, waiting, pane: pane, proven: !pane.nil?)
      return nil unless problem
      hold_retry(stored, waiting, problem, pane: pane || bound_pane(stored))
      held_retry_sentence(stored)
    end

    def add_resume_note(run, note)
      run["pending_context"] << "Note from the person who resumed the run: #{note}" if note
    end

    def last_failure(run)
      "The last attempt of this step failed: #{failure_text(run["reason"]["details"])}."
    end

    def park_target(run)
      run["parked"]["pane"] || bound_pane(run)
    end

    # +request+ is what a resume would be given: "from", "note", "pane", "turn_over".
    def store_park(run, request, expires_at:, retries:, event_data: {})
      run["parked"] = request.merge("id" => SecureRandom.hex(8), "requested_at" => now_iso, "expires_at" => expires_at, "retries" => retries)
      event(run, "resume_parked", {"step" => run["current"], "pane" => park_target(run), "from" => request["from"],
                                   "has_note" => !request["note"].nil?}.merge(event_data))
    end

    # Takes a park off the run however it ended. A note moves to the pending
    # context, so it reaches the next attempt whichever path starts it.
    def drop_park(run, how, extra = {})
      parked = run.delete("parked")
      return unless parked
      add_resume_note(run, parked["note"])
      event(run, "resume_parked_ended", {"step" => run["current"], "how" => how}.merge(extra))
    end

    # After a release's line could not be typed: the failure stands unless a
    # later try can help. The first pass already moved the step and the pane,
    # and {#not_delivered} put the note back, so the new park only waits.
    def park_again(run, after, kick)
      return unless after && PARK_AGAIN_CODES.include?(kick[:code].to_s) && after["retries"] < PARK_RETRIES
      return unless self.class.parked({"parked" => after}, @clock.call) == :waiting
      store_park(run, {"from" => nil, "note" => nil, "pane" => nil, "turn_over" => nil}, expires_at: after["expires_at"], retries: after["retries"] + 1,
        event_data: {"pane" => after["pane"], "retry" => true})
    end

    # Runs one change to a run under its lock and announces it, then types
    # the line of a step the change started, once the lock is given up.
    def transition(run_id, nonblocking: false)
      before = nil
      alert_before = nil
      # The one step line this change started, if any; taken before {#deliver} runs a transition of its own.
      @delivery = nil
      run = @store.update(run_id, nonblocking: nonblocking) do |stored|
        before = fingerprint(stored)
        alert_before = @alerts&.marks(stored)
        was_open = @attempt_record.open_attempt(stored)
        @attempt_record.reasons(run: stored)
        yield stored
        @attempt_record.reasons(run: stored, was_open: was_open)
        stored
      end
      delivery, @delivery = @delivery, nil
      return nil unless run
      changed(run) unless before == fingerprint(run)
      @alerts&.fire(alert_before, run)
      delivery ? deliver(run_id, delivery) : run
    end

    # What `workflow status` shows of a run's progress; a change in it is announced.
    def fingerprint(run)
      state = step_state(run)
      [run["state"], run["current"], shown_reason(run["reason"]), state["state"], state["attempts"].size, state.dig("gate", "state"), run.key?("parked")]
    end

    # A hold shows nothing that moves, so only its code and since count; its seen_at, tasks and missing change nothing a reader sees.
    def shown_reason(reason)
      hold?(reason) ? reason.slice("code", "since") : reason&.except("seen_at")
    end

    def hold?(reason)
      reason && reason["code"] == "turn_ended_background"
    end

    def changed(run)
      @event_log&.record(type: "workflow_changed", project: run["workspace"],
        data: {"run_id" => run["id"], "workflow" => run["workflow"], "workspace" => run["workspace"], "state" => hold?(run["reason"]) ? "running" : run["state"],
               "step" => run["current"], "reason" => run["parked"] ? nil : run.dig("reason", "code")})
    end

    def event(run, type, data = {})
      @store.record_event(run["id"], type, data)
    end

    # A gate event carries the person's note only when one was given.
    def with_note(data, note)
      note.to_s.strip.empty? ? data : data.merge("note" => note)
    end

    def now_iso
      @clock.call.utc.iso8601
    end

    # A checkout, not the inside of its `.git` directory.
    def in_checkout?(common_dir, worktree)
      return false unless common_dir
      path = File.expand_path(worktree)
      common = File.expand_path(common_dir)
      path != common && !path.start_with?(common + File::SEPARATOR)
    end

    def step_of(data, step)
      found = data["steps"].find { |each| each["id"] == step }
      return found if found
      ids = data["steps"].map { |each| each["id"] }
      raise Workspace::Error.new("Workflow #{data["id"]} has no step #{step.to_s[0, 60].inspect} (steps: #{ids.join(", ")}).",
        code: "unknown_step", details: {"workflow" => data["id"], "step" => step.to_s[0, 60], "steps" => ids})
    end

    def artifacts_dir(worktree, run_id)
      File.join(worktree, ".workflow", run_id)
    end

    def step_ids(run)
      run["definition"]["steps"].map { |step| step["id"] }
    end

    def step_def(run, id = run["current"])
      run["definition"]["steps"].find { |step| step["id"] == id }
    end

    def step_state(run)
      run["steps"].fetch(run["current"])
    end

    def bound_pane(run)
      @panes.pane_of(run["id"]) || run["pane"]
    end

    # A task store that can't be read costs the run its task's id, not its start.
    def task_id(workspace)
      @task_store&.active_for(workspace)&.fetch("id", nil)
    rescue Workspace::Error, EncodingError, ArgumentError
      nil
    end

    def check_inputs(data, inputs)
      WorkflowInputs.check(data, inputs)
    end

    # Every step's `status: command:` and every `require: command:` that isn't optional, each unset one listed.
    def check_commands(data, project)
      wanted = WorkflowDefinition.command_needs(data)
      return if wanted.empty?
      set = @commands_config.for_project(project)
      unset = wanted.reject { |each| set[each["command"].to_sym] }
      return if unset.empty?
      roles = unset.map { |each| each["command"] }.uniq
      lines = unset.map { |each| "step #{each["step"]} (#{each["via"]}: command: #{each["command"]}): workspace config set commands.#{each["command"]} \"COMMAND\" --name #{project}" }
      raise Workspace::Error.new(
        "Workflow #{data["id"]} checks steps with the project's #{roles.join(" and ")} command, and #{project} has none. Set each:\n  #{lines.join("\n  ")}",
        code: "workflow_command_unset", details: {"workflow" => data["id"], "project" => project, "commands" => roles, "steps" => unset}
      )
    end

    # Every step with an `exec` proof using `{{changed.tests}}` needs the workspace's `commands.test_files`.
    def check_test_files(data, workspace)
      steps = exec_steps(data).select { |_step, argv| WorkflowArgv.list_names(argv).include?("changed.tests") }.map(&:first).uniq
      return if steps.empty? || @commands_config.test_files(workspace).any?
      raise Workspace::Error.new(
        "Workflow #{data["id"]} uses {{changed.tests}} in step #{steps.join(", ")}, and #{workspace} has no commands.test_files. Set it: workspace config set commands.test_files \"spec/**/*_spec.rb\" --name #{workspace}",
        code: "workflow_test_files_unset", details: {"workflow" => data["id"], "workspace" => workspace, "steps" => steps}
      )
    end

    # Argument 1 of each `exec` proof must be a program {WorkflowExecProgram} accepts. A relative program is
    # judged in +tree+, the checkout that exists; nil (a worktree not made yet) leaves it unjudged, since the branch may add it.
    def check_exec_programs(data, tree)
      missing = exec_steps(data).filter_map do |step, argv|
        reason = WorkflowExecProgram.problem(argv.first, checkout: tree)
        {"step" => step, "program" => argv.first, "problem" => reason} if reason
      end
      return if missing.empty?
      lines = missing.map { |each| "step #{each["step"]}: #{TerminalText.escape(each["program"].to_s.empty? ? "(empty)" : each["program"])} #{TerminalText.escape(each["problem"])}" }
      raise Workspace::Error.new(
        "Workflow #{data["id"]} runs programs that can't run:\n  #{lines.join("\n  ")}\nInstall each, fix its path, or edit the workflow. A bare name is looked up on the PATH of the process that starts the step (the daemon's, for a run), which can differ from your shell's.",
        code: "workflow_program_missing",
        details: {"workflow" => data["id"], "program" => missing.first["program"], "steps" => missing}
      )
    end

    def exec_steps(data)
      data["steps"].flat_map do |step|
        Array(step["require"]).select { |entry| entry.is_a?(Hash) && entry["exec"].is_a?(Array) }.map { |entry| [step["id"], entry["exec"]] }
      end
    end

    # +run_id+ is the run asking, which a park of its own can't refuse.
    def check_pane(pane, run_id: nil)
      return unless pane
      bound = @panes.run_on(pane)
      other = (bound && active?(bound)) ? bound : (parked_on(pane, run_id) || backoff_on(pane, run_id))
      return unless other
      raise Workspace::Error.new("Pane #{pane} is already running workflow run #{other}. Cancel it, or pass --pane for another agent pane.",
        code: "pane_has_run", details: {"pane" => pane, "run_id" => other})
    end

    # Refuses a second run going on one checkout, matched by realpath. A run
    # with no worktree, or one whose path is gone or can't be resolved, is not
    # that checkout; a finished run is not among the active ones. A resume
    # never comes here: it is the run itself.
    def check_checkout(path)
      return unless path
      holder = run_on_checkout(path)
      return unless holder
      target = File.realpath(path)
      raise Workspace::Error.new("Checkout #{target} already has workflow run #{holder["id"]} at step #{holder["current"]}. " \
        "Cancel it with `workspace workflow cancel #{holder["id"]}`, or use another worktree.",
        code: "checkout_has_run", details: {"worktree" => target, "run_id" => holder["id"], "step" => holder["current"],
                                            "state" => holder["state"], "next" => ["workspace workflow cancel #{holder["id"]}"]})
    rescue SystemCallError
      nil
    end

    # Another run waiting to start in +pane+: a run parked by `workflow run` has no binding yet.
    def parked_on(pane, run_id)
      now = @clock.call
      @store.active.find do |run|
        run["id"] != run_id && self.class.parked(run, now) == :waiting && (run["parked"]["pane"] || run["pane"]) == pane
      end&.fetch("id")
    end

    # Another run whose `on_fail` retry waits for +pane+, or that a token budget holds before an attempt in it: the wait unbinds the pane but the retry types into it. The wait
    # holds the pane only while it is still the pane the wait began in (a dead or reused id holds nothing).
    def backoff_on(pane, run_id)
      @store.active.find do |run|
        waiting = run["backoff"] || run["budget_hold"]
        run["id"] != run_id && run["state"] == "waiting" && waiting.is_a?(Hash) && !waiting["blocked"] &&
          (waiting["pane"] || run["pane"]) == pane && @panes.same_pane?(pane, waiting["identity"])
      end&.fetch("id")
    end

    def active?(run_id)
      !WorkflowRunStore::TERMINAL_STATES.include?(@store.find(run_id)["state"])
    rescue Workspace::Error
      false
    end

    # The waiting gate of the run's step; with +step+ (and +attempt+), only when the
    # run is at that step (and attempt), so a stale button can't pass a later gate.
    def waiting_gate(run, step: nil, attempt: nil)
      state = step_state(run)
      gate = state["gate"]
      current = state["attempts"].last&.fetch("n", nil)
      waiting = gate && gate["state"] == "waiting"
      return gate if waiting && (step.nil? || step == run["current"]) && (attempt.nil? || attempt == current)
      message = if step
        "Run #{run["id"]} is not waiting at the gate of step #{step.to_s[0, 60]}#{", attempt #{attempt}," if attempt} " \
          "(step #{run["current"]}, attempt #{current.inspect}, is #{state["state"]}#{" and waits at its gate" if waiting}). " \
          "Read `workspace workflow status #{run["id"]}` again."
      else
        "Run #{run["id"]} is not waiting at a gate (step #{run["current"]} is #{state["state"]})."
      end
      raise Workspace::Error.new(message,
        code: "gate_not_waiting",
        details: {"run_id" => run["id"], "step" => run["current"], "attempt" => current, "state" => state["state"],
                  "expected_step" => step, "expected_attempt" => attempt})
    end

    # The note the approval is of, as {"path", "sha256"}: hashed once here, compared with
    # what the caller read when it says, and recorded as read.
    def gate_file(run, note_sha256)
      found = @gate_note.find(run)
      if note_sha256
        raise @gate_note.missing(run) unless found
        unless found["sha256"] == note_sha256
          raise Workspace::Error.new("The note #{found["path"]} changed since that revision: its sha256 is now #{found["sha256"]}. " \
            "Read it again before you approve.",
            code: "stale_revision",
            details: {"revision" => found["sha256"], "path" => found["path"], "run_id" => run["id"], "step" => run["current"],
                      "attempt" => step_state(run)["attempts"].last&.fetch("n", nil)})
        end
      end
      found&.slice("path", "sha256")
    end

    def rebind(run, pane)
      check_pane(pane, run_id: run["id"]) unless @panes.run_on(pane) == run["id"]
      @panes.unbind(run["id"])
      run["pane"] = pane
    end

    # Why {#resume} does nothing for the step as it stands; nil when it acts.
    def left_alone(run, state, pane, turn_over)
      case state["state"]
      when "running"
        # Another process is still typing this attempt's line; typing it again would start the step twice.
        if !pane && self.class.delivery(state["attempts"].last, @clock.call) == :delivering
          return "step #{run["current"]}'s line is still being delivered to pane #{bound_pane(run)}"
        end
        # The turn's end counts only for the attempt it was seen on: the run may have moved on since.
        over = turn_over && turn_over["step"] == run["current"] && turn_over["attempt"] == state["attempts"].last&.fetch("n", nil)
        "an agent is working on step #{run["current"]}" unless pane || run["reason"] || over
      when "checking"
        "the check of step #{run["current"]} is still running" unless self.class.lost_check?(run, @clock.call)
      end
    end

    # Ends an `on_fail` retry's wait: tells the target step what failed (the text kept when the step failed) and
    # starts it, as the loop would have without a backoff.
    # +proven+ is a pane the person named: that is their proof it is the right pane, so its identity is not compared
    # (it must still exist and not belong to another run).
    def start_retry(run, stored = run.delete("backoff"), proven: false, budgeted: true)
      problem = retry_pane_problem(run, stored, proven: proven)
      return hold_retry(run, stored, problem) if problem
      to = stored["to"]
      run["pending_context"] << stored["text"] if stored["text"].is_a?(String)
      event(run, "step_retry_started", "from" => run["current"], "to" => to)
      run["current"] = to
      run["reason"] = nil
      dispatch(run, context: stored["context"], budgeted: budgeted, retry_of: stored.slice("pane", "identity", "text"))
    end

    # Why the pane a waiting retry would type into is no longer the run's: another run took it, or tmux no longer has it.
    def retry_pane_problem(run, stored, proven: false, pane: nil)
      pane ||= bound_pane(run)
      return nil unless pane
      other = @panes.run_on(pane)
      if other && other != run["id"] && active?(other)
        return {code: "pane_has_run", message: "pane #{pane} is now running workflow run #{other}. Name another agent pane with `workflow resume --pane PANE`"}
      end
      return {code: "pane_gone", message: "pane #{pane} is gone. Name another agent pane with `workflow resume --pane PANE`"} if @panes.pane_gone?(pane)
      # A pane a person named for the resume was checked then; the wait's facts are about the pane it began in.
      return nil if proven || (stored["pane"] && stored["pane"] != pane)
      return nil if @panes.same_pane?(pane, stored["identity"])
      reason = stored["identity"] ? "does not look like the pane the run was in (a tmux restart reuses pane ids, and closing a pane beside it renumbers it; it may be fine)" : "can't be shown to be the pane the run was in (it may be fine)"
      {code: "pane_changed", message: "pane #{pane} #{reason}. Name it with `--pane #{pane}` to resume in it"}
    end

    # The retry is not started and not spent: the wait is kept, marked `blocked` so a tick or the sweep leaves it,
    # and the run waits for a person. A resume (with `--pane` for another pane) starts the retry.
    def hold_retry(run, stored, problem, pane: bound_pane(run))
      # The same hold again (same code, same pane) changes nothing: no new reason, no event.
      held = run["backoff"]
      same = held.is_a?(Hash) && held["blocked"] == problem[:code] && run.dig("reason", "details", "pane") == pane &&
        run.dig("reason", "details", "error") == problem[:code]
      return if same
      run["backoff"] = stored.merge("blocked" => problem[:code])
      run["reason"] = reason((problem[:code] == "pane_gone") ? "pane_gone" : "waiting_you",
        {"kind" => "dispatch", "step" => run["current"], "pane" => pane, "workspace" => run["workspace"], "error" => problem[:code],
         "message" => "the retry of step #{stored["to"]} was not started: #{problem[:message]}. Or cancel the run."})
      event(run, "step_retry_blocked", "from" => run["current"], "to" => stored["to"], "code" => problem[:code])
    end

    # Why a resume that skipped the wait still started nothing; nil when the retry started.
    def held_retry_sentence(run)
      return nil unless run.dig("backoff", "blocked")
      run.dig("reason", "details", "message").to_s.sub(/\.\z/, "")
    end

    # Starts the current step: takes its resources, writes its instructions,
    # binds the pane and stores the attempt as running and `delivering`. The
    # line that points the agent at the instructions is typed by {#deliver}
    # after the run's lock is given up, so a process that dies while the
    # daemon answers leaves an attempt a turn's end can decide.
    def dispatch(run, context: nil, budgeted: true, retry_of: nil)
      drop_park(run, "moved_on")
      step = step_def(run)
      state = step_state(run)
      return hold_for_budget(run, context, retry_of) if budgeted && budget_holds?(run)
      # A rejected gate stays marked for the first run of the step again, and no longer.
      gate = state["gate"]
      state.delete("gate") unless gate && gate["state"] == "rejected" && gate["attempt"] == state["attempts"].last&.fetch("n", nil)
      run["artifacts_dir"] ||= artifacts_dir(run["worktree"], run["id"])
      # Before anything is written: a removed checkout must not come back as a directory.
      raise Workspace::Error, "the checkout #{run["worktree"]} is gone" unless File.directory?(run["worktree"])
      pane = bound_pane(run)
      # A binding made for another pane (a tmux restart reuses pane ids) is not typed into.
      if @panes.pane_of(run["id"]) && !@panes.alive?(run["id"])
        return not_delivered(run, state, nil, {code: "pane_gone", message: "pane #{pane} is no longer the pane the run was bound in"})
      end
      waiting = acquire(run, step, pane)
      return wait_for_lock(run, state, waiting) if waiting

      # To the millisecond: the end of a turn is matched to the attempt by when that turn began.
      attempt = {"n" => state["attempts"].size + 1, "started_at" => @clock.call.utc.iso8601(3), "context" => run["pending_context"],
                 "delivery" => "delivering"}
      pending = state.delete("redelivery_pending")
      attempt["redelivery"] = pending if pending
      run["pending_context"] = []
      attempt["prompt_file"], composed = write_prompt(run, step, attempt)
      @attempt_record.start(run: run, attempt: attempt, composed: composed)
      state["attempts"] << attempt
      @panes.bind(workspace: run["workspace"], pane: pane, run_id: run["id"], step: step["id"], attempt: attempt["n"],
        instructions: attempt["prompt_file"], artifacts: run["artifacts_dir"])
      run["pane"] = pane
      state["state"] = "running"
      run["state"] = "running"
      run["reason"] = nil
      event(run, "step_dispatching", "step" => step["id"], "attempt" => attempt["n"], "pane" => pane)
      @delivery = {"step" => step["id"], "attempt" => attempt["n"], "workspace" => run["workspace"], "pane" => pane,
                   "text" => format(KICK, attempt["prompt_file"]), "fresh" => (context || step["context"]) == "fresh",
                   "remote_baseline" => WorkflowRequire.remote_baseline?(step), "worktree" => run["worktree"]}
    rescue Workspace::Error, SystemCallError, EncodingError => e
      # The step could not be started (no pane, an unreadable pack, a checkout that is gone, text that can't be written as UTF-8).
      not_delivered(run, state, attempt, {code: e.respond_to?(:code) ? e.code : "error", message: e.message.lines.first.to_s.strip})
    end

    # Types the line of an attempt {#dispatch} stored, then records the
    # daemon's answer under the run's lock, if the run is still on that
    # attempt and nothing else (a turn's end, a cancel, a resume) has
    # settled it meanwhile. A line that could not be typed makes the run wait
    # as before; a late answer for an attempt already settled changes nothing.
    def deliver(run_id, delivery)
      record_remote(run_id, delivery) if delivery["remote_baseline"]
      kick = begin
        @panes.kick(workspace: delivery["workspace"], pane: delivery["pane"], text: delivery["text"], fresh: delivery["fresh"], run_id: run_id)
      rescue => e
        # Whatever went wrong, the mark is settled here: left set, it would hold off `resume` for nothing.
        {ok: false, code: e.respond_to?(:code) ? e.code : "error", message: e.message.lines.first.to_s.scrub.strip}
      end
      @store.record_event(run_id, "step_dispatched", "step" => delivery["step"], "attempt" => delivery["attempt"],
        "pane" => delivery["pane"], "delivered" => kick[:ok], **kick.slice(:warning, :proof_missing).transform_keys(&:to_s))
      transition(run_id) do |stored|
        state = stored["steps"].fetch(delivery["step"])
        attempt = state["attempts"].last
        after = (attempt["n"] == delivery["attempt"]) ? attempt.delete("after_park") : nil
        next unless stored["current"] == delivery["step"] && attempt["n"] == delivery["attempt"] && attempt["delivery"] == "delivering"
        attempt.delete("delivery")
        next if kick[:ok]
        not_delivered(stored, state, attempt, kick)
        park_again(stored, after, kick)
      end
    rescue Workspace::Error => e
      # Cancelled while the line was on its way: the cancel stands.
      raise unless e.code == "run_not_active"
      @store.find(run_id)
    end

    # The reading `remote_unchanged` compares with. It is taken here, the one place every attempt passes with the
    # lock given up and the agent not yet told: `dispatch` runs inside a transition, from many callers. It may take
    # {WorkflowGuard::REMOTE_READ_LIMIT} seconds, which {DELIVERY_WINDOW} has room for. A process that dies here
    # leaves an attempt with no reading, which that proof fails as unproven.
    def record_remote(run_id, delivery)
      reading = @guard.remote_head(delivery["worktree"])
      transition(run_id) do |stored|
        attempt = stored["steps"].fetch(delivery["step"])["attempts"].last
        attempt["remote"] = reading if stored["current"] == delivery["step"] && attempt["n"] == delivery["attempt"]
      end
    rescue Workspace::Error => e
      # Only a cancel stops the line; otherwise the attempt goes on with no reading, which that proof fails as unproven.
      raise if e.code == "run_not_active"
    end

    def not_delivered(run, state, attempt, kick)
      attempt&.delete("delivery")
      attempt&.merge!("ended_at" => now_iso, "outcome" => "not_delivered")
      attempt["code"] = kick[:code].to_s if attempt && kick[:code]
      # The next attempt is told what this one would have been.
      run["pending_context"] = attempt["context"] + run["pending_context"] if attempt
      release(run)
      state["state"] = "waiting"
      run["state"] = "waiting"
      gone = PANE_GONE_CODES.include?(kick[:code].to_s)
      run["reason"] = reason(gone ? "pane_gone" : "waiting_you",
        {"kind" => "dispatch", "step" => run["current"], "pane" => run["pane"], "workspace" => run["workspace"],
         "error" => kick[:code].to_s, "message" => kick[:message]&.to_s&.scrub, "reason" => kick[:reason]&.to_s,
         "proof_missing" => kick[:proof_missing]&.to_s}.compact)
    end

    # @return [Hash, nil] the lock the run has to wait for; nil when it holds everything the step uses
    def acquire(run, step, pane)
      result = @resources.acquire(run_id: run["id"], step: step["id"], uses: step["uses"], worktree: run["worktree"],
        workflow: run["workflow"], workspace: run["workspace"], pane: pane)
      raise Workspace::Error, "run #{run["id"]} has no run file, so it can hold no lock" if result[:status] == :not_alive
      waited = (run.dig("reason", "code") == "waiting_lock") ? run["reason"] : nil
      result[:released].each { |name| lock_event(run, "lock_released", name) }
      result[:acquired].each do |name|
        was_waiting = waited && waited.dig("details", "resource") == name
        lock_event(run, "lock_acquired", name, was_waiting ? {"waited_seconds" => (@clock.call - Time.iso8601(waited["since"])).round} : {})
      end
      stop_environment(run) if result[:handed_over].include?(DevRunner::LOCK_NAME)
      waiting = result[:waiting]
      return nil unless waiting
      unless waited && waited.dig("details", "resource") == waiting[:name]
        lock_event(run, "lock_wait_started", waiting[:name], "position" => waiting[:position],
          "holder" => waiting[:holder]&.slice("pane", "pid", "worktree", "task", "run_id", "step")&.compact)
      end
      waiting
    end

    # An environment that can't be stopped keeps the lock, as `dev down`
    # leaves it; the step goes on with the locks it has.
    def stop_environment(run)
      @env_stopper&.call(run_id: run["id"], worktree: run["worktree"])
    rescue Workspace::Error, SystemCallError
      nil
    end

    def wait_for_lock(run, state, waiting)
      holder = waiting[:holder] || {}
      details = {"resource" => waiting[:name], "step" => run["current"], "position" => waiting[:position], "total" => waiting[:total],
                 "holder" => {"run_id" => holder["run_id"], "step" => holder["step"], "workspace" => holder["workspace"],
                              "worktree" => holder["worktree"], "pid" => holder["pid"], "kind" => holder["kind"]}.compact}
      since = (run.dig("reason", "code") == "waiting_lock" && run.dig("reason", "details", "resource") == waiting[:name]) ? run["reason"]["since"] : now_iso
      state["state"] = "waiting"
      run["state"] = "waiting"
      run["reason"] = {"code" => "waiting_lock", "since" => since, "details" => details}
    end

    def lock_event(run, type, name, data = {})
      @event_log&.record(type: type, project: run["project"],
        data: {"lock" => name, "run_id" => run["id"], "step" => run["current"], "workspace" => run["workspace"]}.merge(data))
    end

    # Gives up everything the run holds. A checkout that is gone can't name
    # its lock store; the store drops a finished run's holds by itself.
    def release(run)
      @resources.release(run_id: run["id"], worktree: run["worktree"]).each { |name| lock_event(run, "lock_released", name) }
    rescue Workspace::Error, SystemCallError
      nil
    end

    def reason(code, details)
      {"code" => code, "since" => now_iso, "details" => details}
    end

    # No turn ended, so the step is neither passed nor checked: the hold only
    # becomes the stop it was hiding, with a `since` of its own.
    def expire_background(run)
      held = run["reason"]["details"]
      run["reason"] = reason("turn_ended_incomplete", held.slice("step", "attempt", "missing", "stale", "invalid").merge("background_tasks" => held["tasks"]))
    end

    def stop_reason(stored, turn_started, code, details)
      fresh = reason(code, details)
      return fresh unless stored && stored["code"] == code && stored["since"]
      return fresh unless %w[step attempt].all? { |key| stored.dig("details", key) == details[key] }
      return fresh if turn_started && turn_started.to_i > Time.iso8601(stored["since"]).to_i
      fresh.merge("since" => stored["since"])
    end

    def values(run)
      branch = begin
        @git.worktree_branch(run["worktree"])
      rescue Workspace::Error, SystemCallError
        nil
      end
      {"workspace" => run["workspace"], "branch" => branch.to_s, "artifacts" => run["artifacts_dir"], "run" => run["id"]}
        .merge(run["inputs"].transform_keys { |name| "inputs.#{name}" })
    end

    def compose(run, step, context, binding: nil)
      data = run["definition"]
      filled = values(run)
      context = context.dup
      context.unshift("Note for this run: #{run["note"]}") if run["note"]
      @composer.compose(
        packs: nil, cwd: run["worktree"], binding: binding, skip: step["uses"].to_a.include?("devenv") ? ["dev"] : [],
        workflow: {"name" => data["id"], "include" => data["include"],
                   "text" => data["instructions"] && WorkflowDefinition.render(data["instructions"], filled)},
        step: {"name" => step["id"], "include" => step["include"], "text" => step_text(run, step, filled)},
        attempt: context
      )
    rescue EncodingError, ArgumentError => e
      # Text that is not UTF-8 met text that is (a pack read with no UTF-8 locale, a checkout under
      # such a path): an encoding error, or the "invalid byte sequence" a string method raises.
      raise unless e.is_a?(EncodingError) || e.message.include?("invalid byte sequence")
      raise Workspace::Error, "the step's instructions could not be put together: a pack, a prompt or a path is not UTF-8 text (#{e.class})"
    end

    # The prompt, then what the runner looks at when the turn ends.
    def step_text(run, step, filled)
      text = WorkflowDefinition.render(step["prompt"], filled).strip
      files = step["produces"].map { |file| File.join(run["artifacts_dir"], file) }
      if files.any?
        what = WorkflowProduced.strict?(run["definition"]) ? "exist as non-empty regular files (not links), written during this attempt" : "exist, written during this attempt"
        text += "\n\nThis step is finished when your turn ends and these files #{what}: #{files.join(", ")}."
      end
      text += "\n\nWhen your turn ends, the runner checks the step with the project's own command; work until it would pass." if step["status"]
      text
    end

    # Where an attempt's instructions file goes, and the binding its pane gets; {#render} asks the same two.
    def prompt_path(run, step, attempt_number)
      File.join(run["artifacts_dir"], "steps", "#{step["id"]}.#{attempt_number}.prompt.md")
    end

    def step_binding(run, step, attempt_number, path)
      {"kind" => "run", "id" => run["id"], "workspace" => run["workspace"], "step" => step["id"], "attempt" => attempt_number,
       "instructions" => path, "artifacts" => run["artifacts_dir"]}
    end

    def write_prompt(run, step, attempt)
      FileUtils.mkdir_p(File.join(run["artifacts_dir"], "steps"))
      @excludes.add(run["worktree"], "/.workflow/")
      path = prompt_path(run, step, attempt["n"])
      composed = compose(run, step, attempt["context"], binding: step_binding(run, step, attempt["n"], path))
      File.write(path, composed["text"], encoding: Encoding::UTF_8)
      [path, composed]
    end

    # Decides a step whose turn ended. Returns the check to run, when the
    # step has one and nothing else already decided it.
    # A stop the daemon sees again (the same code, step and attempt) keeps its `since`, so a
    # repeat raises no second notice; a turn that began after the stop was recorded is a new stop.
    # The stored `since` is whole seconds, so a turn that began in the same second is the same stop.
    def evaluate(run, turn_started: nil, background: [])
      step = step_def(run)
      state = step_state(run)
      attempt = state["attempts"].last
      # A turn that ended on the attempt shows its line reached the agent.
      attempt.delete("delivery")
      attempt.delete("proofs")
      reported = attempt["reported"]
      if reported && reported["status"] == "fail"
        fail_step(run, {"cause" => "reported", "summary" => reported["summary"]}.merge(code_for("reported", reported["code"])))
        return nil
      end
      if step["guard"]
        found = guard_check(run, step)
        if found
          fail_step(run, found)
          return nil
        end
      end
      files = step["produces"].map { |file| File.join(run["artifacts_dir"], file) }
      strict = WorkflowProduced.strict?(run["definition"])
      found = files.to_h { |file| [file, WorkflowProduced.inspect_file(file, strict: strict)] }
      missing = files.reject { |file| found[file].exists }
      invalid = files.select { |file| found[file].exists && found[file].rule }.map { |file| {"file" => file, "rule" => found[file].rule} }
      # A file an earlier attempt left does not count: the step has to write it again.
      started = Time.iso8601(attempt["started_at"])
      stale = files.select { |file| found[file].exists && found[file].rule.nil? && found[file].mtime < started }
      if missing.any? || invalid.any? || stale.any?
        state["state"] = "running"
        run["state"] = "waiting"
        details = {"step" => step["id"], "attempt" => attempt["n"], "missing" => missing, "stale" => stale}
        details["invalid"] = invalid if invalid.any?
        run["reason"] = if background.any?
          # Every notification starts a new turn and a hold is hidden, so its `since` stays.
          stop_reason(run["reason"], nil, "turn_ended_background", details.merge("tasks" => background)).merge("seen_at" => now_iso)
        else
          stop_reason(run["reason"], turn_started, "turn_ended_incomplete", details)
        end
        return nil
      end
      require_and_status(run, step, state, attempt)
    end

    # What comes after the step's files: its `require:` entries from +from+ in order, then its `status:`
    # check. Returns the next thing to run outside the lock (a proof or the check); nil once the step is decided.
    def require_and_status(run, step, state, attempt, from: 0)
      if step["require"].to_a.any?
        unmet = @require_check.check(run: run, step: step, attempt: attempt, from: from)
        while unmet&.key?("skipped")
          skipped = unmet["skipped"]
          (attempt["proofs"] ||= []).reject! { |each| each["skipped"] && each["index"] == skipped["index"] }
          attempt["proofs"] << skipped.merge("started_at" => now_iso, "ended_at" => now_iso)
          unmet = @require_check.check(run: run, step: step, attempt: attempt, from: skipped["index"] + 1)
        end
        return start_proof(run, step, state, attempt, unmet["outside"]) if unmet&.key?("outside")
        if unmet
          fail_step(run, require_failure(unmet))
          return nil
        end
      end
      unless step["status"]
        pass_step(run)
        return nil
      end

      command = step["status"]["run"] || @commands_config.for_project(run["project"])[step["status"]["command"].to_sym]
      log = File.join(run["artifacts_dir"], "steps", "#{step["id"]}.#{attempt["n"]}.check.log")
      attempt["check"] = {"started_at" => now_iso, "log" => log}
      attempt["check"]["command"] = command if command
      state["state"] = "checking"
      run["state"] = "running"
      run["reason"] = nil
      {"step" => step["id"], "attempt" => attempt["n"], "command" => command, "timeout" => step["status"]["timeout"], "log" => log,
       "cwd" => run["worktree"], "role" => step["status"]["command"]}
    end

    # A proof takes the step to `checking` like a `status:` check, so a resume, a cancel, a tick and {#wanted?}
    # treat it as one. Its record stays open (no `ended_at`) until it is applied, or a next {#evaluate} starts over.
    # A proof's {WorkflowRequire::FACTS_KEY} (what an `exec` proof read of the run under the lock) goes to {WorkflowRequire#run_outside} only.
    def start_proof(run, step, state, attempt, pending)
      (attempt["proofs"] ||= []) << pending.except(WorkflowRequire::FACTS_KEY).merge("started_at" => now_iso)
      state["state"] = "checking"
      run["state"] = "running"
      run["reason"] = nil
      {"step" => step["id"], "attempt" => attempt["n"], "cwd" => run["worktree"], "proof" => pending}
    end

    # Runs what {#evaluate} handed back with the run's lock given up, and whatever comes after it: a proof can be
    # followed by another proof or the `status:` check.
    def finish_check(run_id, check)
      run = nil
      run, check = apply_check(run_id, check, run_check(run_id, check)) while check
      run
    rescue Workspace::Error => e
      # Cancelled while the check ran: there is nothing left to decide.
      raise unless e.code == "run_not_active"
      @store.find(run_id)
    end

    def run_check(run_id, check)
      stop_when = -> { !wanted?(run_id, check) }
      return @require_check.run_outside(check["proof"], cwd: check["cwd"], env: check_env(run_id), stop_when: stop_when) if check["proof"]
      return {exit_code: nil, timed_out: false, error: "the project's #{check["role"]} command is not set"} unless check["command"]
      @checker.call(command: check["command"], cwd: check["cwd"], timeout: check["timeout"], log: check["log"], stop_when: stop_when, env: check_env(run_id))
    end

    # What a `status:` check is told about its run. `WORKSPACE_RUN_BASE_SHA` is
    # empty for a run with no recorded commit (an unborn branch, or a run made before it was kept).
    # Every inherited `GIT_*` variable is removed, so a caller's `GIT_DIR`, `GIT_INDEX_FILE` or
    # `GIT_CONFIG_*` can't steer the check.
    def check_env(run_id)
      WorkflowCheck.env_for(@store.find(run_id))
    end

    # The steps' prompts hand the agent shell commands that hold the run's artifacts path
    # (under the checkout) and the gate note's path (under the notes directory), so a path that
    # can end a quote or start a substitution is refused. Only the names of the characters are
    # reported, never the path. +what+ says which path it is.
    def check_checkout_path(data, paths, what: "checkout")
      paths.each do |path|
        found = ShellSafePath.unsafe_characters(path)
        next if found.empty?
        raise Workspace::Error.new(
          "Workflow #{data["id"]} can't run with a #{what} whose path holds #{found.join(", ")}: its instructions put the path in shell commands. " \
          "Use a #{what} whose path has none of them.",
          code: "unsafe_checkout_path", details: {"workflow" => data["id"], "characters" => found, "path_kind" => what}
        )
      end
    end

    # The notes directory is read only for a workflow with a gate, whose note the fix step is
    # handed the path of; one that can't be found yet (a worktree not made) is left to the gate.
    def check_notes_path(data, workspace)
      return unless data["steps"].any? { |step| step["gate"] }
      dir = @gate_note.notes_dir_of(workspace)
      check_checkout_path(data, [dir].compact, what: "notes directory")
    end

    # A definition with a `guard: unchanged` step starts from a clean checkout: a commit to
    # start from, no stopped git operation, no change to a tracked file.
    def check_tree(data, tree)
      return unless tree && data["steps"].any? { |step| step["guard"] == "unchanged" }
      found = @guard.check(tree, @guard.base(tree), "unchanged")
      return unless found
      raise Workspace::Error.new(
        "Workflow #{data["id"]} needs a clean checkout, and #{tree} is not (#{GUARD_TEXT[found["code"]] || "tracked files changed: #{found["paths"].join(", ")}"}). " \
        "Commit or stash the changes, or finish the git operation, first.",
        code: "dirty_worktree", details: {"path" => tree, "guard" => found["code"], "files" => found["paths"]}
      )
    end

    # Whether the run still waits for this check: it is still on that step and
    # attempt, checking. A cancel, a kill or a `resume --from` ends that, and
    # the check is stopped instead of running on beside the lock's next holder.
    # So does a park: only a `--from` parks over a check, and that restarts the step. So does a proof run again.
    def wanted?(run_id, check)
      run = @store.find(run_id)
      state = run["steps"].fetch(check["step"])
      !run["parked"] && !WorkflowRunStore::TERMINAL_STATES.include?(run["state"]) && run["current"] == check["step"] &&
        state["state"] == "checking" && state["attempts"].last["n"] == check["attempt"] &&
        (!check["proof"] || !open_proof(state["attempts"].last, check).nil?)
    rescue Workspace::Error, SystemCallError
      true
    end

    # @return [Array] the run afterwards, and what to run next outside the lock, or nil
    def apply_check(run_id, check, result)
      following = nil
      run = transition(run_id) do |stored|
        next if stored["parked"]
        state = step_state(stored)
        attempt = state["attempts"].last
        # The run moved on while the check ran (a resume, a reject): its result decides nothing.
        next unless stored["current"] == check["step"] && state["state"] == "checking" && attempt["n"] == check["attempt"]
        if check["proof"]
          following = apply_proof(stored, attempt, check, result)
          next
        end
        attempt["check"].merge!("ended_at" => now_iso, "exit_code" => result[:exit_code], "timed_out" => result[:timed_out],
          "error" => result[:error]).compact!
        event(stored, "check_finished", "step" => check["step"], "attempt" => check["attempt"], "exit_code" => result[:exit_code])
        if result[:exit_code] == 0
          pass_step(stored)
        else
          code = if result[:timed_out]
            "check_timed_out"
          else
            result[:error] ? "check_error" : "check_failed"
          end
          fail_step(stored, {"cause" => "check", "exit_code" => result[:exit_code], "timed_out" => result[:timed_out],
                             "error" => result[:error], "log" => check["log"]}.compact.merge(code_for(code, nil)))
        end
      end
      [run, following]
    end

    # Records a proof's result; a passed one goes on to the next `require:` entry. A proof run again (a tick or a
    # resume took it for lost) has a new token, so a late result of the old run matches nothing and is dropped.
    def apply_proof(run, attempt, check, result)
      record = open_proof(attempt, check)
      return nil unless record
      record.merge!(result["record"].merge("ended_at" => now_iso))
      unmet = result["unmet"]
      event(run, "proof_finished", "step" => check["step"], "attempt" => check["attempt"], "proof" => record["proof"], "passed" => unmet.nil?)
      if unmet
        fail_step(run, require_failure(unmet))
        return nil
      end
      require_and_status(run, step_def(run), step_state(run), attempt, from: check["proof"]["index"] + 1)
    end

    def open_proof(attempt, check)
      Array(attempt["proofs"]).find { |each| each["token"] == check["proof"]["token"] && !each.key?("ended_at") }
    end

    def pass_step(run)
      state = step_state(run)
      state["attempts"].last.merge!("ended_at" => now_iso, "outcome" => "passed")
      @attempt_record.finish(run: run, step: step_def(run), attempt: state["attempts"].last)
      state["state"] = "passed"
      event(run, "step_passed", "step" => run["current"], "attempt" => state["attempts"].last["n"])
      return advance(run) unless step_def(run)["gate"]

      release(run)
      state["gate"] = {"state" => "waiting", "since" => now_iso}
      run["state"] = "waiting"
      run["reason"] = reason("waiting_you", "kind" => "gate", "step" => run["current"],
        "artifacts" => step_def(run)["produces"].map { |file| File.join(run["artifacts_dir"], file) })
      event(run, "gate_waiting", "step" => run["current"])
      true
    end

    def advance(run)
      ids = step_ids(run)
      following = ids[ids.index(run["current"]) + 1]
      return complete(run) unless following
      run["current"] = following
      dispatch(run)
      true
    end

    def complete(run)
      finish(run, "completed")
      event(run, "run_completed")
      true
    end

    def finish(run, state)
      drop_park(run, "ended")
      run.delete("backoff")
      run.delete("budget_hold")
      release(run)
      @panes.unbind(run["id"])
      run["state"] = state
      run["reason"] = nil
      run["ended_at"] = now_iso
    end

    # A failed step goes back along its `on_fail` while it has loops left and
    # the run has attempts left; otherwise the run stops and waits for a person.
    def fail_step(run, failure)
      step = step_def(run)
      state = step_state(run)
      attempt = state["attempts"].last
      attempt["ended_at"] = now_iso
      attempt["outcome"] = "failed"
      attempt["code"] = failure["code"] if failure["code"].is_a?(String)
      @attempt_record.finish(run: run, step: step, attempt: attempt)
      state["state"] = "failed"
      event(run, "step_failed", {"step" => step["id"], "attempt" => attempt["n"]}.merge(failure.slice("cause", "exit_code")))
      on_fail = step["on_fail"]
      edge = on_fail && "#{step["id"]}->#{on_fail["goto"]}"
      attempts = attempts_made(run)
      spent = attempts >= attempt_allowance(run)
      if on_fail && run["loops"].fetch(edge, 0) < on_fail["max"] && !spent
        run["loops"][edge] = run["loops"].fetch(edge, 0) + 1
        text = loop_context(run, step, on_fail, failure, run["loops"][edge])
        wait = WorkflowDefinition.backoff(on_fail)
        event(run, "step_looped", {"from" => step["id"], "to" => on_fail["goto"], "count" => run["loops"][edge]}.merge(wait ? {"backoff" => wait} : {}))
        return wait_to_retry(run, step, on_fail, text, wait, attempt) if wait
        run["pending_context"] << text
        run["current"] = on_fail["goto"]
        return dispatch(run, context: on_fail["context"], retry_of: {"text" => text})
      end
      release(run)
      run["state"] = "waiting"
      run["reason"] = reason("failed_check", {"step" => step["id"], "attempt" => attempt["n"], "loops" => run["loops"],
                                              "attempts" => attempts, "max_attempts" => attempt_allowance(run)}.merge(failure))
    end

    # No attempt, pane binding or lock is held while the retry waits: the run reads `waiting` with the reason
    # `retry_backoff`, and the step stays `failed` until {#start_retry}.
    def wait_to_retry(run, step, on_fail, text, wait, attempt)
      release(run)
      pane = bound_pane(run)
      identity = @panes.identity(run["id"])
      @panes.unbind(run["id"])
      time = (@clock.call + wait).utc.iso8601
      run["backoff"] = {"until" => time, "to" => on_fail["goto"], "context" => on_fail["context"], "text" => text, "pane" => pane, "identity" => identity}.compact
      run["state"] = "waiting"
      run["reason"] = reason("retry_backoff", {"step" => step["id"], "attempt" => attempt["n"], "to" => on_fail["goto"], "until" => time,
                                               "seconds" => wait, "loops" => run["loops"]})
    end

    def loop_context(run, step, on_fail, failure, count)
      text = "The #{step["id"]} step failed and sent the run back to this step (time #{count} of #{on_fail["max"]}): #{failure_text(failure)}. " \
        "Its files are in #{run["artifacts_dir"]}. Fix what it found."
      lines = WorkflowDefinition.log_tail(on_fail)
      tail = (lines && failure["log"].is_a?(String)) ? @log_tail.block(failure["log"], lines: lines) : nil
      tail ? "#{text}\n\n#{tail}" : text
    end

    def require_failure(unmet)
      {"cause" => "require", "require" => unmet["proof"], "detail" => unmet["detail"], "unproven" => unmet["unproven"],
       "required" => unmet["required"], "found" => unmet["found"], "base" => unmet["base"], "paths" => unmet["paths"],
       "reason" => unmet["reason"], "error" => unmet["error"], "exit_code" => unmet["exit_code"], "log" => unmet["log"], "program" => unmet["program"],
       "before" => unmet["before"], "after" => unmet["after"]}
        .compact.merge(code_for(unmet["code"], nil))
    end

    def guard_check(run, step)
      found = @guard.check(run["worktree"], run, step["guard"])
      note_config_change(run, step)
      return nil unless found
      {"cause" => "guard", "guard" => found["code"], "paths" => found["paths"], "base_sha" => found["base_sha"], "head" => found["head"]}
        .compact.merge(code_for(found["code"], nil))
    rescue => e
      {"cause" => "check", "error" => "the guard could not run (#{e.class})"}.merge(code_for("check_error", nil))
    end

    # A changed repository config is a warning and the step goes on. `guard_config_seen` holds the reading last
    # warned of, so each distinct change warns once, on the attempt that first saw it, whatever steps follow; a
    # config back at the base's reading clears it. It is set only once the attempt holds the warning, so one that
    # could not be recorded is tried again at the next guarded step. A warning that can't be recorded must not stop the step.
    def note_config_change(run, step)
      found = @guard.config_change(run["worktree"], run, seen: run["guard_config_seen"])
      return unless found
      return run.delete("guard_config_seen") unless found["code"]
      attempt = step_state(run)["attempts"].last
      (attempt["warnings"] ||= []) << {"code" => found["code"], "at" => now_iso, "message" => config_warning(found)}
      run["guard_config_seen"] = found["reading"]
      event(run, "guard_warning", "step" => step["id"], "attempt" => attempt["n"], "code" => found["code"], "inbox" => post_config_warning(run, step, attempt, found))
    rescue
      nil
    end

    def config_warning(found)
      return "this run started before the config was read this way, so the difference may be no change at all; the run went on" if found["old_format"]
      "#{GUARD_TEXT.fetch(found["code"])}; the run went on"
    end

    # One item per run, whatever the number of changes; a later change opens it again if it was closed. Under the run's lock, as `inbox_item` reads.
    #
    # @return [Boolean] whether the item was written
    def post_config_warning(run, step, attempt, found)
      return false unless @inbox_for
      workspace = run["workspace"]
      @inbox_for.call(workspace).upsert({
        "type" => "alert", "scope" => {"kind" => "workspace", "key" => workspace, "name" => workspace},
        "title" => "Workflow run #{run["id"]}: the repository's config changed",
        "body" => "At step #{step["id"]} (attempt #{attempt["n"]}): #{config_warning(found)}. Check `git -C #{run["worktree"]} config --list` if you did not expect it; `workspace workflow status #{run["id"]}` lists every warning.",
        "source" => {"kind" => "workflow", "ref" => run["id"], "url" => nil},
        "dedupe_key" => "workflow-guard:#{run["id"]}:#{found["code"]}",
        "created_by" => {"kind" => "cli", "pane" => nil, "session_id" => nil, "tmux_server" => nil},
        "links" => {"run_id" => run["id"], "step" => step["id"], "attempt" => attempt["n"]}, "expires_at" => nil, "note" => nil
      }, reopen: true)
      true
    rescue Workspace::Error, SystemCallError
      false
    end

    # The one code key of a failed step: an agent's word when it gave one, else the engine's.
    def code_for(engine_code, agent_code)
      agent_code ? {"code" => agent_code, "code_source" => "agent"} : {"code" => engine_code, "code_source" => "engine"}
    end

    GUARD_TEXT = {
      "no_commit" => "the checkout had no commit to start from",
      "operation_in_progress" => "a git operation (merge, rebase, cherry-pick, revert or bisect) is in progress",
      "config_changed" => "the repository's config, attributes or replace refs changed",
      "hooks_changed" => "the repository's hooks changed since the run started",
      "hidden_changed" => "tracked files were hidden from git (assume-unchanged or skip-worktree) since the run started"
    }.freeze

    def failure_text(failure)
      if failure["cause"] == "timeout"
        "the step ran past its #{failure["timeout"]} second time limit (#{failure["elapsed"]} seconds in)"
      elsif failure["cause"] == "guard"
        case failure["guard"]
        when "head_moved" then "HEAD moved from #{failure["base_sha"].to_s[0, 12]} to #{failure["head"].to_s[0, 12]} since the run started"
        when "tracked_changed" then "tracked files changed since the run started (#{Array(failure["paths"]).join(", ")})"
        else GUARD_TEXT.fetch(failure["guard"], "the guard failed (#{failure["guard"]})")
        end
      elsif failure["cause"] == "require"
        "a required proof failed (#{failure["require"]}): #{failure["detail"]}"
      elsif failure["cause"] == "reported"
        "its agent reported failure#{": #{failure["summary"]}" if failure["summary"]}"
      elsif failure["timed_out"]
        "its check ran past its time limit (log: #{failure["log"]})"
      elsif failure["error"]
        "its check could not be run (#{failure["error"]})"
      else
        "its check exited #{failure["exit_code"].inspect} (log: #{failure["log"]})"
      end
    end
  end
end
