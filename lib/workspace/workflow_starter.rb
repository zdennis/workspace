require "time"

module Workspace
  # What starts a workflow run: the checks `start` would refuse ({#preflight}), the preview of a step's first
  # instructions ({#render}), what `workflow check` runs for a step ({#check_plan}), and {#start}, which stores
  # the run and starts its first step through +dispatch+. Reads a pane's and a checkout's occupancy as store
  # queries, the pane's through {WorkflowDispatch#check_pane}.
  class WorkflowStarter
    # The run id {#preflight} and {#render} compose a first step under, for a run that does not exist.
    PREVIEW_RUN_ID = "wr_preview".freeze

    # @param change [Workspace::WorkflowRunChange] makes the run's first change and writes its history
    # @param store [Workspace::WorkflowRunStore] creates the run and says which run is on a checkout
    # @param prompt [Workspace::WorkflowPrompt] composes a step's instructions
    # @param dispatch [Workspace::WorkflowDispatch] starts the run's first step, and refuses a pane another run holds
    # @param lineage [Workspace::WorkspaceLineage] names a checkout's parent project
    # @param commands_config [Workspace::CommandsConfig] the project's `commands.test`/`commands.lint`
    # @param guard [Workspace::WorkflowGuard] records a run's base commit and checks a checkout is clean
    # @param gate_note [Workspace::WorkflowGateNote] names a workspace's notes directory
    # @param task_store [Workspace::TaskStore, nil] names the workspace's task in the run
    # @param workspace_known [#call, nil] given a project name, true when a workspace of that name exists (for `workflow check`'s `--name` hint); nil means none does
    # @param clock [#call] returns the current Time
    def initialize(change:, store:, prompt:, dispatch:, lineage:, commands_config:, guard:, gate_note:,
      task_store: nil, workspace_known: nil, clock: -> { Time.now })
      @change = change
      @store = store
      @prompt = prompt
      @dispatch = dispatch
      @lineage = lineage
      @commands_config = commands_config
      @guard = guard
      @gate_note = gate_note
      @task_store = task_store
      @workspace_known = workspace_known
      @clock = clock
    end

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
      @dispatch.check_pane(pane)
      check_checkout(tree)
      first = data["steps"].first
      packs = @prompt.compose({"definition" => data, "workspace" => workspace, "worktree" => worktree, "inputs" => inputs,
                               "id" => PREVIEW_RUN_ID, "artifacts_dir" => @prompt.artifacts_dir(worktree, PREVIEW_RUN_ID)}, first, [])["packs"]
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
             "id" => PREVIEW_RUN_ID, "artifacts_dir" => @prompt.artifacts_dir(worktree, PREVIEW_RUN_ID)}
      path = @prompt.prompt_path(run, found, 1)
      composed = @prompt.compose(run, found, [], binding: @prompt.step_binding(run, found, 1, path))
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
    # @return [WorkflowRun] the run after its first transition, or as created
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
      run = WorkflowRun.from_h(@store.create(attributes, -> {
        @dispatch.check_pane(pane)
        check_checkout(worktree)
      }) { |created| created["artifacts_dir"] = @prompt.artifacts_dir(worktree, created["id"]) })
      @change.event(run, "run_started", "workflow" => data["id"], "workspace" => workspace)
      return @change.call(run.id) { |_run| } unless dispatch
      @change.call(run.id) { |read, ctx| @dispatch.dispatch(read, ctx: ctx) }
    end

    private

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

    # Refuses a second run going on one checkout, matched by realpath. A run
    # with no worktree, or one whose path is gone or can't be resolved, is not
    # that checkout; a finished run is not among the active ones. A resume
    # never comes here: it is the run itself.
    def check_checkout(path)
      return unless path
      holder = @store.on_checkout(path)
      return unless holder
      target = File.realpath(path)
      raise Workspace::Error.new("Checkout #{target} already has workflow run #{holder.id} at step #{holder.current}. " \
        "Cancel it with `workspace workflow cancel #{holder.id}`, or use another worktree.",
        code: "checkout_has_run", details: {"worktree" => target, "run_id" => holder.id, "step" => holder.current,
                                            "state" => holder.state, "next" => ["workspace workflow cancel #{holder.id}"]})
    rescue SystemCallError
      nil
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
        "Workflow #{data["id"]} needs a clean checkout, and #{tree} is not (#{WorkflowTransitions::GUARD_TEXT[found["code"]] || "tracked files changed: #{found["paths"].join(", ")}"}). " \
        "Commit or stash the changes, or finish the git operation, first.",
        code: "dirty_worktree", details: {"path" => tree, "guard" => found["code"], "files" => found["paths"]}
      )
    end

    def now_iso
      @clock.call.utc.iso8601
    end

    def reason(code, details)
      {"code" => code, "since" => now_iso, "details" => details}
    end
  end
end
