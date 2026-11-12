require "optparse"
require "json"

module Workspace
  class CLI
    # The `plan`, `spine` (and its other name `journey`) and `goal` verbs: parses their arguments
    # with the same usage text the CLI always printed and hands the parsed values to their commands
    # ({Commands::Plan}, {Commands::PlanDispatch}, {Commands::PlanTask}, {Commands::Spine},
    # {Commands::SpineInit}, {Commands::SpineStart}, {Commands::Goal}). `plan start` and
    # `spine start` launch a workspace with no session through {CLI::Launcher}. It writes and
    # exits only through the {Invocation} it is given, so `--help --json` captures what it prints.
    class PlanSpine
      # The flags each `plan` verb takes (`task` lists every flag of its verbs, which {PLAN_TASK_FLAGS} narrows).
      PLAN_FLAGS = {
        "status" => %i[name project all file group json],
        "path" => %i[name json],
        "show" => %i[name],
        "init" => %i[name title from force json],
        "start" => %i[name task pane spawn json],
        "pause" => %i[name interrupt json],
        "delete" => %i[name yes json],
        "task" => %i[name task id title state reason phase after before if_revision json]
      }.freeze

      # The flags each `plan task` verb takes (on top of --name and --json).
      PLAN_TASK_FLAGS = {
        "add" => %i[id title state reason phase after if_revision],
        "set-state" => %i[task state reason if_revision],
        "set-title" => %i[task title if_revision],
        "move" => %i[task after before phase if_revision]
      }.freeze

      # @param plan_command [Workspace::Commands::Plan, nil] `plan status|path|show|init|pause|delete`; nil refuses `plan`
      # @param plan_dispatch_command [Workspace::Commands::PlanDispatch, nil] `plan start`; nil refuses `plan`
      # @param plan_task_command [Workspace::Commands::PlanTask, nil] `plan task`; nil refuses `plan`
      # @param spine_command [Workspace::Commands::Spine, nil] `spine show|set|check|verify|goal`; nil refuses them
      # @param spine_init_command [Workspace::Commands::SpineInit, nil] `spine init`; nil refuses it
      # @param spine_start_command [Workspace::Commands::SpineStart, nil] `spine start`; nil refuses it
      # @param goal_command [Workspace::Commands::Goal, nil] `goal show|list`; nil refuses them
      # @param status_scope [Workspace::StatusScope, nil] resolves `plan status`'s --name, --project and --all
      # @param project_detector [Workspace::ProjectDetector] finds the workspace of the working directory
      # @param launcher [CLI::Launcher] launches a workspace with no session for `plan start` and `spine start`
      # @param common [CLI::Common] the output, exit and help helpers
      # @param names [CLI::Names] settles the workspace names given
      # @param working_dir [String] the directory the CLI runs from
      def initialize(plan_command:, plan_dispatch_command:, plan_task_command:, spine_command:, spine_init_command:, spine_start_command:,
        goal_command:, status_scope:, project_detector:, launcher:, common:, names:, working_dir:)
        @plan_command = plan_command
        @plan_dispatch_command = plan_dispatch_command
        @plan_task_command = plan_task_command
        @spine_command = spine_command
        @spine_init_command = spine_init_command
        @spine_start_command = spine_start_command
        @goal_command = goal_command
        @status_scope = status_scope
        @project_detector = project_detector
        @launcher = launcher
        @common = common
        @names = names
        @working_dir = working_dir
      end

      # Runs one `plan`, `spine`, `journey` or `goal` command line.
      #
      # @param verb [String] the verb {CLI::ROUTES} sent here
      # @param args [Array<String>] the arguments after the verb (changed in place)
      # @param invocation [Invocation] the run's streams, exit handler and flags
      # @return [void]
      # @raise [Workspace::UsageError, Workspace::Error] without `--json`, for the CLI's rescue funnel to report
      def call(verb, args, invocation)
        case verb
        when "plan" then plan(args, invocation)
        when "spine", "journey" then spine(args, invocation)
        when "goal" then goal(args, invocation)
        end
      end

      private

      def plan_parser(options)
        OptionParser.new do |opts|
          opts.banner = HelpPages.overview_usage(HelpPages::PLAN)
          opts.separator ""
          opts.separator "A plan is IMPLEMENTATION_PLAN.md in the workspace's notes directory: one checklist"
          opts.separator "line per task under '## Tasks'. workspace counts it, and works out one state from the"
          opts.separator "plan, the session and the pane that owns the plan."
          opts.separator ""
          opts.separator "Subcommands:"
          HelpPages.overview_verbs(HelpPages::PLAN).each { |line| opts.separator line }
          opts.separator "Run `workspace plan VERB --help` for a verb's options. Task states: #{IdPatterns::TASK_STATES.join(", ")}."
          opts.separator ""
          opts.separator "A verb that writes (init, start, pause, delete, task) changes the plan or the workspace for real."
          opts.separator ""
          opts.on("--name NAME", "Workspace to act on instead of the one detected from the current directory") { |v| take_plan_flag(options, :name, v) }
          opts.on("--project [NAME]", "status: every workspace of a project (NAME, or the project of the current workspace)") { |v| take_plan_flag(options, :project, v || true) }
          opts.on("--all", "status: every workspace") { take_plan_flag(options, :all, true) }
          opts.on("--group GROUP", "status: every workspace of every repository in a group (group:billing, billing or Billing; see projects group list)") { |v| take_plan_flag(options, :group, v) }
          opts.on("--file PATH", "status: read any file, with no workspace and a state from the file alone") { |v| take_plan_flag(options, :file, v) }
          opts.on("--title TITLE", "init: the plan's title (default: the workspace task's title); task add: the task's title; task set-title: the new title") { |v| take_plan_flag(options, :title, v) }
          opts.on("--from FILE", "init: import this document as the plan") { |v| take_plan_flag(options, :from, v) }
          opts.on("--force", "init: replace a plan that is already there") { take_plan_flag(options, :force, true) }
          opts.on("--yes", "delete: confirm the delete") { take_plan_flag(options, :yes, true) }
          opts.on("--task ID", "start: send only this task; task set-state, set-title and move: the task (its id, such as T3)") { |v| take_plan_flag(options, :task, v) }
          opts.on("--id ID", "task add: the new task's id (default: the next number after the plan's last id)") { |v| take_plan_flag(options, :id, v) }
          opts.on("--state STATE", "task add and set-state: #{IdPatterns::TASK_STATES.join(", ")}") { |v| take_plan_flag(options, :state, v) }
          opts.on("--reason TEXT", "task add and set-state: why a task is blocked or skipped") { |v| take_plan_flag(options, :reason, v) }
          opts.on("--phase NAME", "task add: the ### heading to add under; task move: move to the end of this phase") { |v| take_plan_flag(options, :phase, v) }
          opts.on("--after ID", "task add and move: place the task after this task") { |v| take_plan_flag(options, :after, v) }
          opts.on("--before ID", "task move: place the task before this task") { |v| take_plan_flag(options, :before, v) }
          opts.on("--if-revision REV", "task: refuse with stale_revision unless the plan's revision is REV") { |v| take_plan_flag(options, :if_revision, v) }
          opts.on("--pane PANE", "start --task: the pane to send it to, a pane id (%19) or window.pane (0.1)") { |v| take_plan_flag(options, :pane, v) }
          opts.on("--spawn KIND", "start --task: start a new agent pane for it (#{Commands::PlanDispatch::AGENT_KINDS.join(", ")})") { |v| take_plan_flag(options, :spawn, v) }
          opts.on("--interrupt", "pause: interrupt the owner panes that are working") { take_plan_flag(options, :interrupt, true) }
          opts.on("--json", "Print one JSON document (see docs/README.plan.md)") { take_plan_flag(options, :json, true) }
          opts.on("-h", "--help", "Show this help") { options[:help] = true }
          opts.separator ""
          opts.separator "Examples:"
          opts.separator "  workspace plan status    # the plan of the workspace you are in, e.g. api.worktree-x  working  7/20 (40%)  T9 Add the token store"
          opts.separator "  workspace plan status --all --json    # every workspace, as one JSON document"
          opts.separator "  workspace plan path    # where the plan file is, e.g. /src/api/tmp/workspace-notes/IMPLEMENTATION_PLAN.md"
          opts.separator "  workspace plan init --title \"Auth rewrite\"    # write a new plan"
          opts.separator "  workspace plan start    # set it active, then launch the workspace or type the play into its agent pane"
          opts.separator "  workspace plan start --task T4 --pane %23    # type one task into pane %23"
          opts.separator "  workspace plan pause --interrupt    # stop after the current task and interrupt the working owner panes"
          opts.separator "  workspace plan task add --title \"Write the docs\" --phase Docs    # add a task under the ### Docs heading"
          opts.separator "  workspace plan task set-state --task T3 --state blocked --reason \"needs the dev database\"    # block a task"
          opts.separator "  workspace plan delete --yes    # rename the plan file to IMPLEMENTATION_PLAN.md.deleted-<time>"
        end
      end

      def take_plan_flag(options, key, value)
        options[key] = value
        options[:given] << key
      end

      def plan(args, invocation)
        return if @common.verb_help_shown?(invocation, HelpPages::PLAN, args)

        options = {given: [], json: false, force: false, yes: false}
        parser = plan_parser(options)
        parser.parse!(args)
        return invocation.output.puts(parser.help) if options[:help]

        subcommand = args.shift
        raise UsageError, "Missing subcommand: one of #{PLAN_FLAGS.keys.join(", ")}.\n\n#{parser.help}" unless subcommand
        raise UsageError, "Unknown plan subcommand: #{subcommand}. Run 'workspace plan --help'." unless PLAN_FLAGS.key?(subcommand)
        verb = args.shift if subcommand == "task"
        raise UsageError, "Unexpected argument: #{args.first}. Run 'workspace plan --help'." if args.any?
        options[:given].uniq.each do |key|
          raise UsageError, "--#{key} does not apply to 'plan #{subcommand}'. Run 'workspace plan --help'." unless PLAN_FLAGS[subcommand].include?(key)
        end
        if subcommand == "task"
          raise UsageError, "Missing task verb: one of #{PLAN_TASK_FLAGS.keys.join(", ")}. Run 'workspace plan --help'." unless verb
          raise UsageError, "Unknown plan task verb: #{verb}. One of #{PLAN_TASK_FLAGS.keys.join(", ")}." unless PLAN_TASK_FLAGS.key?(verb)
          options[:given].uniq.each do |key|
            next if %i[name json].include?(key) || PLAN_TASK_FLAGS[verb].include?(key)
            raise UsageError, "--#{key.to_s.tr("_", "-")} does not apply to 'plan task #{verb}'. Run 'workspace plan --help'."
          end
          plan_task_usage(verb, options)
        end
        if subcommand == "status" && options[:given].count { |key| %i[name project all file group].include?(key) } > 1
          raise UsageError, "Give only one of --name, --project, --all, --file and --group."
        end
        raise UsageError, "Give only one of --pane and --spawn." if options[:pane] && options[:spawn]
        raise UsageError, "--pane and --spawn need --task. Run 'workspace plan --help'." if (options[:pane] || options[:spawn]) && !options[:task]
        if options[:spawn] && !Commands::PlanDispatch::AGENT_KINDS.include?(options[:spawn])
          raise UsageError, "Unknown agent kind for --spawn: #{options[:spawn]}. One of #{Commands::PlanDispatch::AGENT_KINDS.join(", ")}."
        end
        raise Error, "plan is not available: no plan command was wired" unless @plan_command && @plan_dispatch_command && @plan_task_command

        return @plan_command.status_group(group: options[:group], json: options[:json]) if options[:group]
        return @plan_command.status(file: options[:file], json: options[:json]) if options[:file]

        if subcommand == "status"
          scope = @status_scope.resolve(name: options[:name], project: options[:project], all: options[:all], working_dir: @working_dir)
          case scope.kind
          when :all then return @plan_command.status(all: true, json: options[:json])
          when :project then return @plan_command.status(project: scope.project, json: options[:json])
          else return @plan_command.status(names: [scope.workspace], json: options[:json])
          end
        end

        name = options[:name] || @project_detector.detect(@working_dir)
        raise Error.new("No workspace found for #{@working_dir}. Run from inside a workspace or pass --name.", code: "not_in_workspace", details: {"path" => @working_dir}) unless name

        case subcommand
        when "path" then @plan_command.path(name: name, json: options[:json])
        when "show" then @plan_command.show(name: name)
        when "init"
          @common.run_action(invocation, "plan init", json: options[:json]) do
            created = @plan_command.init(name: name, title: options[:title], from: options[:from], force: options[:force])
            {exit_code: 0, results: [@common.action_row(name, "created", message: created["message"], path: created["path"])]}
          end
        when "start"
          @common.run_action(invocation, "plan start", json: options[:json]) do
            row = if options[:task]
              @plan_dispatch_command.start_task(name: name, task_id: options[:task], pane: options[:pane], spawn: options[:spawn], launch: plan_launcher(invocation))
            else
              @plan_dispatch_command.start(name: name, launch: plan_launcher(invocation))
            end
            plan_verb_outcome(name, row, options[:json], invocation)
          end
        when "pause"
          @common.run_action(invocation, "plan pause", json: options[:json]) do
            plan_verb_outcome(name, @plan_command.pause(name: name, interrupt: options.fetch(:interrupt, false)), options[:json], invocation)
          end
        when "delete"
          @common.run_action(invocation, "plan delete", json: options[:json]) { plan_verb_outcome(name, @plan_command.delete(name: name, yes: options[:yes]), options[:json], invocation) }
        when "task"
          @common.run_action(invocation, "plan task #{verb}", json: options[:json]) { plan_verb_outcome(name, plan_task_row(verb, name, options), options[:json], invocation) }
        end
      end

      # Checks what a `plan task` verb needs before anything is read, so a missing flag is a usage error.
      def plan_task_usage(verb, options)
        case verb
        when "add"
          raise UsageError, "plan task add needs --title." if options[:title].to_s.strip.empty?
          raise UsageError, "Give only one of --phase and --after." if options[:phase] && options[:after]
        when "set-state"
          raise UsageError, "plan task set-state needs --task." unless options[:task]
          raise UsageError, "plan task set-state needs --state." unless options[:state]
        when "set-title"
          raise UsageError, "plan task set-title needs --task." unless options[:task]
          raise UsageError, "plan task set-title needs --title." if options[:title].nil?
        when "move"
          raise UsageError, "plan task move needs --task." unless options[:task]
          raise UsageError, "Give exactly one of --after, --before and --phase." unless [options[:after], options[:before], options[:phase]].compact.size == 1
        end
        if options[:state] && !IdPatterns::TASK_STATES.include?(options[:state])
          raise UsageError, "Unknown task state: #{options[:state]}. One of #{IdPatterns::TASK_STATES.join(", ")}."
        end
      end

      def plan_task_row(verb, name, options)
        case verb
        when "add"
          @plan_task_command.add(name: name, title: options[:title], id: options[:id], state: options.fetch(:state, "todo"), reason: options[:reason],
            phase: options[:phase], after: options[:after], if_revision: options[:if_revision])
        when "set-state"
          @plan_task_command.set_state(name: name, id: options[:task], state: options[:state], reason: options[:reason], if_revision: options[:if_revision])
        when "set-title"
          @plan_task_command.set_title(name: name, id: options[:task], title: options[:title], if_revision: options[:if_revision])
        when "move"
          @plan_task_command.move(name: name, id: options[:task], after: options[:after], before: options[:before], phase: options[:phase],
            if_revision: options[:if_revision])
        end
      end

      # The action result for a plan verb's row; a failed one also says why on stderr when there is no document.
      # A row's `task` and `interrupts` ride along in the result, and its `warnings` go to the document's.
      def plan_verb_outcome(name, row, json, invocation)
        failed = row["outcome"] == "failed"
        invocation.error_output.puts "Error: could not start the plan for #{name}: #{row["message"]}" if failed && !json
        extra = row.slice("task", "interrupts", "state", "title", "previous_state", "line", "phase", "revision", "counts", "percent").transform_keys(&:to_sym)
        {exit_code: failed ? 1 : 0, warnings: row["warnings"] || [],
         results: [@common.action_row(name, row["outcome"], reason: row["reason"], message: row["message"], path: row["path"], pane: row["pane"], **extra)]}
      end

      # What `plan start` uses to launch a workspace that has no session: `launch --play implementation-plan
      # --prompt "Continue the plan."` (or a task's prompt), with the packs a launch sends. Returns `{ok:, reason:, message:, pane:}`.
      def plan_launcher(invocation)
        lambda do |workspace, prompt = Commands::PlanDispatch::CONTINUE_PROMPT|
          launched_pane(@launcher.launch(invocation, [workspace], plays: [Commands::PlanDispatch::PLAY], prompt: prompt, with_packs: true))
        end
      end

      # The one launched workspace's row from {Launcher#launch}, as `{ok:, reason:, message:, pane:}`.
      def launched_pane(launched)
        row = @launcher.rows(launched[:projects], launched[:result], plays: launched[:plays], packs: launched[:packs], skipped_packs: launched[:skipped_packs], prompts: launched[:prompts]).first
        pane = row.dig("play", "pane") || row["pane"]
        {ok: row["outcome"] != "failed", reason: row["reason"], message: row["message"], pane: pane}
      end

      def goal(args, invocation)
        return if @common.verb_help_shown?(invocation, HelpPages::GOAL, args)

        options = {json: false, all: false}
        parser = goal_parser(options)
        parser.parse!(args)
        return invocation.output.puts(parser.help) if options[:help]

        subcommand = args.shift
        raise UsageError, "Missing subcommand: show or list.\n\n#{parser.help}" unless subcommand
        raise UsageError, "Unknown goal subcommand: #{subcommand}. Run 'workspace goal --help'." unless %w[show list].include?(subcommand)
        raise Error, "goal is not available: no goal command was wired" unless @goal_command

        if subcommand == "list"
          raise UsageError, "Unexpected argument: #{args.first}. Run 'workspace goal --help'." if args.any?

          return @goal_command.list(all: options[:all], json: options[:json])
        end
        raise UsageError, "--all applies to 'goal list' only." if options[:all]
        raise UsageError, "Unexpected argument: #{args[1]}. Run 'workspace goal --help'." if args.size > 1

        @goal_command.show(args.first || @names.current_workspace!(nil), json: options[:json])
      end

      def goal_parser(options)
        OptionParser.new do |opts|
          opts.banner = HelpPages.overview_usage(HelpPages::GOAL)
          opts.separator ""
          opts.separator "show: where a goal is at each level (the goal, its journey stage, its workflow step, the agent's"
          opts.separator "turn, the tool call), what it waits for and on whom, and the next expected event. A goal is a"
          opts.separator "workspace. REF is a workspace name, a workflow run id, a task id, a ticket key or URL, or a branch;"
          opts.separator "with none, the workspace of the current directory. Reads only: nothing is written and 'gh' is not run."
          opts.separator ""
          opts.separator "list: one line per goal: workspace, state, stage, step, agent state."
          opts.separator ""
          opts.on("--all", "list: include workspaces with no plan, run or spine (state none)") { options[:all] = true }
          opts.on("--json", "Print one JSON document (see docs/README.goal.md)") { options[:json] = true }
          opts.on("-h", "--help", "Show this help") { options[:help] = true }
          opts.separator ""
          opts.separator "Examples:"
          opts.separator "  workspace goal show    # the goal of the workspace you are in"
          opts.separator "  workspace goal show LAB-1 --json    # the goal for a ticket key, as JSON"
          opts.separator "  workspace goal list    # one line per goal"
        end
      end

      def spine_parser(options)
        OptionParser.new do |opts|
          opts.banner = HelpPages.overview_usage(HelpPages::SPINE)
          opts.separator ""
          opts.separator "A spine is the stage files in spine/ of a workspace's notes directory, one Markdown file"
          opts.separator "per stage. Writers of a workspace take turns."
          opts.separator ""
          opts.separator "Verbs:"
          HelpPages.overview_verbs(HelpPages::SPINE).each { |line| opts.separator line }
          opts.separator "Run `workspace spine VERB --help` for a verb's options."
          opts.separator ""
          opts.on("--name NAME", "The workspace (default: the one detected from the current directory)") { |v| options[:name] = v }
          opts.on("--stage STAGE-PATH", "show: only that stage (with its sub-stages); unknown_stage when there is none") { |v| options[:stage] = v }
          opts.on("--body", "show: add the text after the frontmatter (16 KB at most) to the stage, or to the goal without --stage") { options[:body] = true }
          opts.on("--evaluate", "show: judge each stage against the plan, git, the pull request, the review agent and the panes (reads gh and the agent daemon, up to about 5s; an unreadable source leaves its gates unchecked; a completed stage with a check: line reads checking or check_failed until the check passes)") { options[:evaluate] = true }
          opts.on("--status VALUE", "set: not_started, in_progress, blocked, completed or skipped (or an alias such as done)") { |v| options[:status] = v }
          opts.on("--note TEXT", "set: one line of at most 300 characters; alone it changes only the note (empty clears it). With a new status and no --note the note is cleared. verify: the verdict's note, required, 300 characters at most") { |v| options[:note] = v }
          opts.on("--pass", "verify: the stage passed its check") { options[:pass] = true }
          opts.on("--fail", "verify: the stage failed its check") { options[:fail] = true }
          opts.on("--owner VALUE", "set: who works the stage: a pane id such as %6, you, or an agent label; one line of at most 64 characters (empty clears it). Not with --recursive") { |v| options[:owner] = v }
          opts.on("--if-revision REV", "set, verify, goal set, start: refuse with stale_revision unless the stage file's (goal.md's for goal set) revision (from show) is REV") { |v| options[:if_revision] = v }
          opts.on("--item N", Integer, "check: the checklist item, 1-based; repeat for several") { |v| (options[:items] ||= []) << v }
          opts.on("--done", "check: tick the items") { options[:check_done] = true }
          opts.on("--undone", "check: untick the items") { options[:check_undone] = true }
          opts.on("--pane PANE", "start: the pane to send the stage to, a pane id (%21) or window.pane (0.1) of the workspace's session") { |v| options[:pane] = v }
          opts.on("--spawn KIND", "start: split a new pane and start that agent in it (#{Commands::SpineStart::AGENT_KINDS.join(", ")})") { |v| options[:spawn] = v }
          opts.on("--fan-out", "start: start every startable sub-stage of STAGE-PATH, each in a new pane") { options[:fan_out] = true }
          opts.on("--max N", Integer, "start --fan-out: spawn at most N panes (default #{Commands::SpineStart::DEFAULT_FAN_OUT})") { |v| options[:max] = v }
          opts.on("--play REF", "start: the play to send (default: the stage's play:, else research, implementation-plan or review by its kind)") { |v| options[:play] = v }
          opts.on("--recursive", "set: also set every sub-stage that is not completed or skipped") { options[:recursive] = true }
          opts.on("--by LABEL", "set: the updated_by label; verify: the checked_by label (default: the agent and pane id of $TMUX_PANE, else person)") { |v| options[:by] = v }
          opts.on("--json", "Print one JSON document (see docs/README.spine.md)") { options[:json] = true }
          opts.on("-h", "--help", "Show this help") { options[:help] = true }
          opts.separator ""
          opts.separator "Examples:"
          opts.separator "  workspace spine show    # the stages of the workspace you are in"
          opts.separator "  workspace spine show --evaluate --json    # judge every stage against the plan, git, the pull request and the panes (up to about 5s)"
          opts.separator "  workspace spine init --dry-run    # preview the spine/ files; nothing is written"
          opts.separator "  workspace spine set verify --status in_progress    # mark a stage started"
          opts.separator "  workspace spine set verify --owner %6 --note \"waiting on CI\"    # record who works it and a note"
          opts.separator "  workspace spine check verify --item 2 --done    # tick item 2 of the stage's Done when list"
          opts.separator "  workspace spine verify implement --pass --note \"CI green, all 4 items met\"    # a checker records a pass (not the agent that did the stage)"
          opts.separator "  workspace spine goal set \"Fix the OAuth refresh race\"    # write the goal's title"
          opts.separator "  workspace spine start verify    # type the stage's brief into its owner pane, else the main agent pane"
          opts.separator "  workspace spine start implement --fan-out --max 2    # one new agent pane per ready sub-stage, at most two"
        end
      end

      def spine_init_parser(options)
        OptionParser.new do |opts|
          opts.banner = "Usage: workspace spine init [WORKSPACE] [--name WORKSPACE] [--template NAME] [--dry-run] [--json]"
          opts.separator ""
          opts.separator "Create the spine/ folder in a workspace's notes directory from a spine template (a library"
          opts.separator "entry of kind spine; the built-in 'default' has the stages research to ship, and a main"
          opts.separator "checkout gets no ship stage). {{WORKSPACE}}, {{BRANCH}} and {{TITLE}} in the template are"
          opts.separator "filled in. Nothing is overwritten: when spine/ exists the answer is 'exists' and nothing is"
          opts.separator "written. The notes directory is made if needed, as 'notes dir --create' does."
          opts.separator ""
          opts.on("--name NAME", "The workspace (default: the one detected from the current directory)") { |v| options[:name] = v }
          opts.on("--template NAME", "The spine template (default: the spine.template config, else default). See: workspace library list --kind spine") { |v| options[:template] = v }
          opts.on("--dry-run", "Say what would be written and write nothing") { options[:dry_run] = true }
          opts.on("--json", "Print one JSON document (see docs/README.spine.md)") { options[:json] = true }
          opts.on("-h", "--help", "Show this help") { options[:help] = true }
          opts.separator ""
          opts.separator "Examples:"
          opts.separator "  workspace spine init --dry-run    # preview the files for the workspace you are in"
          opts.separator "  workspace spine init api.worktree-login --template=team --json"
        end
      end

      # `spine init`: kept apart from the other spine verbs; `args` no longer holds the verb.
      def spine_init(args, invocation)
        options = {json: false, name: nil, template: nil, dry_run: false}
        parser = spine_init_parser(options)
        parser.parse!(args)
        return invocation.output.puts(parser.help) if options[:help]

        positional = @names.settle_name(invocation, args.shift)
        raise UsageError, "Unexpected argument: #{args.first}. Run 'workspace spine init --help'." if args.any?
        if positional && options[:name] && positional != options[:name]
          raise UsageError, "Give the workspace once: '#{positional}' and --name #{options[:name]} differ."
        end
        raise Error, "spine init is not available: no spine init command was wired" unless @spine_init_command

        name = options[:name] || positional || @project_detector.detect(@working_dir)
        raise Error.new("No workspace found for #{@working_dir}. Run from inside a workspace or pass --name.", code: "not_in_workspace", details: {"path" => @working_dir}) unless name

        @spine_init_command.call(name: name, template: options[:template], dry_run: options[:dry_run], json: options[:json])
      end

      # The verb of a spine command line: the first word that is not an option or the value of --name,
      # so options may come before it (`spine --name X init`).
      def spine_verb_index(args)
        skip = false
        args.each_with_index do |arg, i|
          if skip
            skip = false
          elsif %w[--name --template --stage --status --note --owner --if-revision --by --pane --spawn --play].include?(arg)
            skip = true
          elsif arg == "--"
            return nil
          elsif !arg.start_with?("-")
            return i
          end
        end
        nil
      end

      def spine(args, invocation)
        return if @common.verb_help_shown?(invocation, HelpPages::SPINE, args)

        index = spine_verb_index(args)
        if index && args[index] == "init"
          args.delete_at(index)
          return spine_init(args, invocation)
        end

        options = {json: false, name: nil}
        parser = spine_parser(options)
        parser.parse!(args)
        return invocation.output.puts(parser.help) if options[:help]

        subcommand = args.shift
        raise UsageError, "Missing subcommand: show, set, check, verify, goal, start or init.\n\n#{parser.help}" unless subcommand
        raise UsageError, "Unknown spine subcommand: #{subcommand}. Run 'workspace spine --help'." unless %w[show set check start goal verify].include?(subcommand)
        if options[:pass] || options[:fail]
          raise UsageError, "--pass and --fail are for 'spine verify'. Run 'workspace spine --help'." unless subcommand == "verify"
        end
        return spine_verify(args, options, parser, invocation) if subcommand == "verify"
        return spine_goal(args, options, parser, invocation) if subcommand == "goal"
        return spine_check(args, options, parser, invocation) if subcommand == "check"
        if options[:items] || options[:check_done] || options[:check_undone]
          raise UsageError, "--item, --done and --undone are for 'spine check'. Run 'workspace spine --help'."
        end
        return spine_start(args, options, parser, invocation) if subcommand == "start"
        if options[:pane] || options[:spawn] || options[:play] || options[:fan_out] || options[:max]
          raise UsageError, "--pane, --spawn, --play, --fan-out and --max are for 'spine start'. Run 'workspace spine --help'."
        end
        return spine_set(args, options, parser, invocation) if subcommand == "set"

        positional = @names.settle_name(invocation, args.shift)
        raise UsageError, "Unexpected argument: #{args.first}. Run 'workspace spine --help'." if args.any?
        if positional && options[:name] && positional != options[:name]
          raise UsageError, "Give the workspace once: '#{positional}' and --name #{options[:name]} differ."
        end
        raise Error, "spine is not available: no spine command was wired" unless @spine_command

        name = options[:name] || positional || @project_detector.detect(@working_dir)
        raise Error.new("No workspace found for #{@working_dir}. Run from inside a workspace or pass --name.", code: "not_in_workspace", details: {"path" => @working_dir}) unless name

        @spine_command.show(name: name, json: options[:json], stage: options[:stage], body: options[:body] || false, evaluate: options[:evaluate] || false)
      end

      def spine_set(args, options, parser, invocation)
        raise UsageError, "--stage, --body and --evaluate are for 'spine show'; 'spine set' takes the stage path as an argument." if options[:stage] || options[:body] || options[:evaluate]
        raise UsageError, "Give at least one of --status, --note and --owner.\n\n#{parser.help}" unless options[:status] || options[:note] || options[:owner]
        positional = (args.size > 1 && !options[:name]) ? @names.settle_name(invocation, args.shift) : nil
        path = args.shift
        raise UsageError, "Missing STAGE-PATH, the stage's ids joined with / (as 'spine show' reports path).\n\n#{parser.help}" unless path
        raise UsageError, "Unexpected argument: #{args.first}. Run 'workspace spine --help'." if args.any?
        raise Error, "spine is not available: no spine command was wired" unless @spine_command

        name = options[:name] || positional || @project_detector.detect(@working_dir)
        raise Error.new("No workspace found for #{@working_dir}. Run from inside a workspace or pass --name.", code: "not_in_workspace", details: {"path" => @working_dir}) unless name

        @spine_command.set(name: name, path: path, status: options[:status], note: options[:note], owner: options[:owner], if_revision: options[:if_revision],
          recursive: options[:recursive] || false, by: options[:by], json: options[:json])
      end

      def spine_verify(args, options, parser, invocation)
        if options[:stage] || options[:body] || options[:evaluate] || options[:status] || options[:owner] || options[:recursive] || options[:pane] || options[:spawn] || options[:play] || options[:items] || options[:check_done] || options[:check_undone]
          raise UsageError, "spine verify takes --pass, --fail, --note, --by, --if-revision, --name and --json; the other options are for show, set, check and start."
        end
        raise UsageError, "Give only one of --pass and --fail." if options[:pass] && options[:fail]
        raise UsageError, "Give --pass or --fail." unless options[:pass] || options[:fail]
        raise UsageError, "Give --note TEXT: what was checked and what was found." if options[:note].to_s.strip.empty?
        positional = (args.size > 1 && !options[:name]) ? @names.settle_name(invocation, args.shift) : nil
        path = args.shift
        raise UsageError, "Missing STAGE-PATH, the stage's ids joined with / (as 'spine show' reports path).\n\n#{parser.help}" unless path
        raise UsageError, "Unexpected argument: #{args.first}. Run 'workspace spine --help'." if args.any?
        raise Error, "spine is not available: no spine command was wired" unless @spine_command

        name = options[:name] || positional || @project_detector.detect(@working_dir)
        raise Error.new("No workspace found for #{@working_dir}. Run from inside a workspace or pass --name.", code: "not_in_workspace", details: {"path" => @working_dir}) unless name

        @spine_command.verify(name: name, path: path, verdict: options[:pass] ? "passed" : "failed", note: options[:note],
          by: options[:by], if_revision: options[:if_revision], json: options[:json])
      end

      def spine_goal(args, options, parser, invocation)
        if options[:stage] || options[:body] || options[:evaluate] || options[:status] || options[:note] || options[:owner] || options[:recursive] || options[:pane] || options[:spawn] || options[:play] || options[:items] || options[:check_done] || options[:check_undone]
          raise UsageError, "spine goal set takes --if-revision, --by, --name and --json; the other options are for show, set, check and start."
        end
        verb = args.shift
        raise UsageError, "Missing goal subcommand. Use 'workspace spine goal set TEXT'." unless verb
        raise UsageError, "Unknown spine goal subcommand: #{verb}. Use 'workspace spine goal set TEXT'." unless verb == "set"
        positional = (args.size > 1 && !options[:name]) ? @names.settle_name(invocation, args.shift) : nil
        text = args.shift
        raise UsageError, "Missing TEXT, the goal as one line.\n\n#{parser.help}" unless text
        raise UsageError, "Unexpected argument: #{args.first}. Quote TEXT if it has spaces, and put -- before text that starts with a dash. Run 'workspace spine --help'." if args.any?
        raise Error, "spine is not available: no spine command was wired" unless @spine_command

        name = options[:name] || positional || @project_detector.detect(@working_dir)
        raise Error.new("No workspace found for #{@working_dir}. Run from inside a workspace or pass --name.", code: "not_in_workspace", details: {"path" => @working_dir}) unless name

        @spine_command.goal_set(name: name, text: text, if_revision: options[:if_revision], by: options[:by], json: options[:json])
      end

      def spine_check(args, options, parser, invocation)
        if options[:stage] || options[:body] || options[:evaluate] || options[:status] || options[:note] || options[:owner] || options[:recursive] || options[:pane] || options[:spawn] || options[:play]
          raise UsageError, "spine check takes --item, --done, --undone, --if-revision, --by and --json; the other options are for show, set and start."
        end
        raise UsageError, "Give at least one --item N." if options[:items].to_a.empty?
        raise UsageError, "--item takes a positive number." unless options[:items].all?(&:positive?)
        raise UsageError, "Give only one of --done and --undone." if options[:check_done] && options[:check_undone]
        raise UsageError, "Give --done or --undone." unless options[:check_done] || options[:check_undone]
        positional = (args.size > 1 && !options[:name]) ? @names.settle_name(invocation, args.shift) : nil
        path = args.shift
        raise UsageError, "Missing STAGE-PATH, the stage's ids joined with / (as 'spine show' reports path).\n\n#{parser.help}" unless path
        raise UsageError, "Unexpected argument: #{args.first}. Run 'workspace spine --help'." if args.any?
        raise Error, "spine is not available: no spine command was wired" unless @spine_command

        name = options[:name] || positional || @project_detector.detect(@working_dir)
        raise Error.new("No workspace found for #{@working_dir}. Run from inside a workspace or pass --name.", code: "not_in_workspace", details: {"path" => @working_dir}) unless name

        @spine_command.check(name: name, path: path, items: options[:items], done: options[:check_done] ? true : false,
          if_revision: options[:if_revision], by: options[:by], json: options[:json])
      end

      def spine_start(args, options, parser, invocation)
        if options[:stage] || options[:body] || options[:evaluate] || options[:status] || options[:note] || options[:owner] || options[:recursive] || options[:by]
          raise UsageError, "spine start takes --pane, --spawn, --play, --if-revision and --json; the other options are for show and set."
        end
        raise UsageError, "Give only one of --pane and --spawn." if options[:pane] && options[:spawn]
        raise UsageError, "--max is for 'spine start --fan-out'." if options[:max] && !options[:fan_out]
        if options[:fan_out]
          raise UsageError, "--fan-out starts new panes (--spawn); it cannot be combined with --pane." if options[:pane]
          raise UsageError, "--fan-out cannot be combined with --if-revision: it starts several stage files." if options[:if_revision]
          raise UsageError, "--play is not used by --fan-out: each sub-stage gets its own play." if options[:play]
          raise UsageError, "--max must be at least 1." if options[:max] && options[:max] < 1
        end
        if options[:spawn] && !Commands::SpineStart::AGENT_KINDS.include?(options[:spawn])
          raise UsageError, "Unknown agent kind for --spawn: #{options[:spawn]}. One of #{Commands::SpineStart::AGENT_KINDS.join(", ")}."
        end
        positional = (args.size > 1 && !options[:name]) ? @names.settle_name(invocation, args.shift) : nil
        path = args.shift
        raise UsageError, "Missing STAGE-PATH, the stage's ids joined with / (as 'spine show' reports path).\n\n#{parser.help}" unless path
        raise UsageError, "Unexpected argument: #{args.first}. Run 'workspace spine --help'." if args.any?
        raise Error, "spine start is not available: no spine start command was wired" unless @spine_start_command

        name = options[:name] || positional || @project_detector.detect(@working_dir)
        raise Error.new("No workspace found for #{@working_dir}. Run from inside a workspace or pass --name.", code: "not_in_workspace", details: {"path" => @working_dir}) unless name

        start = -> {
          next @spine_start_command.fan_out(name: name, path: path, spawn: options[:spawn], max: options[:max] || Commands::SpineStart::DEFAULT_FAN_OUT) if options[:fan_out]
          @spine_start_command.start(name: name, path: path, pane: options[:pane], spawn: options[:spawn], play: options[:play],
            if_revision: options[:if_revision], launch: spine_launcher(invocation))
        }
        doc = options[:json] ? @common.divert_output(invocation, &start) : start.call
        if options[:json]
          invocation.output.puts JSON.generate(doc)
        elsif !doc["ok"] && doc["results"]
          invocation.error_output.puts "Error: nothing was spawned for the sub-stages of #{doc["path"]} of #{name}; every startable sub-stage was refused (#{doc["results"].filter_map { |entry| entry["code"] if entry["result"] == "refused" }.uniq.join(", ")})."
        elsif !doc["ok"]
          invocation.error_output.puts "Error: could not start stage #{doc["path"]} of #{name}: #{doc["message"]}"
        end
        invocation.exit_handler.exit(1) unless doc["ok"]
      end

      # What `spine start` uses to launch a workspace that has no session: `launch --play REF --prompt BRIEF`, with the
      # packs a launch sends (the spine pack among them). Returns `{ok:, reason:, message:, pane:}`.
      def spine_launcher(invocation)
        lambda do |workspace, play, prompt|
          launched = @launcher.launch(invocation, [workspace], plays: Array(play), prompt: prompt, with_packs: true)
          launched_pane(launched)
        end
      end
    end
  end
end
