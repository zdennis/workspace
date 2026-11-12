require "optparse"
require "time"

module Workspace
  class CLI
    # The `workflow` and `step` verbs: parses their arguments, refuses a flag a verb has no use for
    # with the same usage text the CLI always printed, and hands the parsed values to
    # {Commands::Workflow} or {Commands::WorkflowStart}. It writes and exits only through the
    # {Invocation} it is given, so `--help --json` captures what it prints.
    class Workflow
      # The verbs of `workflow`, in the order `workflow --help` lists them.
      SUBCOMMANDS = %w[list show validate add update remove install uninstall run start render check simulate status events files attempts audit stats compare sweep resume cancel approve reject advance].freeze

      # @param workflow_command [Workspace::Commands::Workflow, nil] the `workflow` and `step` command; nil refuses both verbs
      # @param workflow_start_command [Workspace::Commands::WorkflowStart, nil] the `workflow start` command; nil refuses that verb
      # @param workflow_project [Workspace::WorkflowProject, nil] the one resolver for the project whose workflow definitions are read first;
      #   nil reads none and finds the workspace through the project detector
      # @param status_scope [Workspace::StatusScope, nil] resolves --name, --project and --all for `status`, `stats` and `compare`
      # @param config [Workspace::Config] names the definition directories in the help page
      # @param project_config [Workspace::ProjectConfig] the checkout root of a detected workspace
      # @param project_detector [Workspace::ProjectDetector] finds the workspace of the working directory when there is no workflow_project
      # @param git [Workspace::Git] the repository root `workflow check` runs in outside a workspace
      # @param launch_mode [Workspace::LaunchMode] whether `workflow start` runs headless when no --[no-]headless is given
      # @param common [CLI::Common] the output, exit and help helpers
      # @param names [CLI::Names] the working directory of a named workspace
      # @param input [IO] the input stream `workflow remove` asks on (refused under --no-input)
      # @param working_dir [String] the directory the CLI runs from
      def initialize(workflow_command:, workflow_start_command:, workflow_project:, status_scope:, config:, project_config:, project_detector:, git:, launch_mode:, common:, names:, input:, working_dir:)
        @workflow_command = workflow_command
        @workflow_start_command = workflow_start_command
        @workflow_project = workflow_project
        @status_scope = status_scope
        @config = config
        @project_config = project_config
        @project_detector = project_detector
        @git = git
        @launch_mode = launch_mode
        @common = common
        @names = names
        @input = input
        @working_dir = working_dir
      end

      # Runs one `workflow` or `step` command line.
      #
      # @param verb [String] "workflow" or "step"
      # @param args [Array<String>] the arguments after the verb (changed in place)
      # @param invocation [Invocation] the run's streams, exit handler and flags
      # @return [void]
      # @raise [Workspace::UsageError, Workspace::Error] without `--json`, for the CLI's rescue funnel to report
      def call(verb, args, invocation)
        (verb == "step") ? step(args, invocation) : workflow(args, invocation)
      end

      # The `--input KEY=VALUE` pairs of a workflow run as a Hash, the first `=` splitting each.
      #
      # @param pairs [Array<String>]
      # @return [Hash{String=>String}]
      # @raise [Workspace::UsageError] for a pair with no `=` or an empty key
      def self.inputs(pairs)
        pairs.to_h do |pair|
          key, value = pair.split("=", 2)
          raise UsageError, "--input takes KEY=VALUE, got #{pair[0, 60].inspect}." if value.nil? || key.empty?
          [key, value]
        end
      end

      private

      def workflow_parser(options)
        OptionParser.new do |opts|
          opts.banner = HelpPages.overview_usage(HelpPages::WORKFLOW)
          opts.separator ""
          opts.separator "Run a workflow in a workspace: an ordered list of steps, each done by the agent in the"
          opts.separator "workspace's Claude pane. A step gets its instructions in a file under .workflow/ in the"
          opts.separator "checkout and one typed line pointing at it, in a fresh conversation unless the step says"
          opts.separator "context: continue. A step is done when the agent's turn ends, every file it produces:"
          opts.separator "is there (a non-empty regular file, not a link), and its status: check passes; the agent daemon (agentd) sees the turn end and"
          opts.separator "moves the run on. A failed step goes back along its on_fail: {goto, max}; a step with"
          opts.separator "gate: approve waits for `workflow approve`. Resources a step uses: are locks the run"
          opts.separator "holds, in the same queue as `lock acquire` and `dev up`."
          opts.separator ""
          opts.separator "Definitions are YAML files: #{@config.workflows_dir}/ID.yml (a project's own, in #{File.join(@config.workspace_projects_dir, "NAME", "workflows")}/ID.yml, are found first; never read from a repository), then the directories of the workflows.sources config key in list order (source:1, source:2, ...), then the presets that"
          opts.separator "ship with workspace (rpiv: research, plan, implement, verify; rpiv-auto-approve: rpiv with reviewer agents in place of the plan gate; pr-feedback: triage review feedback, then fix; investigate: reproduce, diagnose, fix; explore: read-only research, a gate, then a report note). See docs/README.workflow.md."
          opts.separator ""
          HelpPages.overview_verbs(HelpPages::WORKFLOW).each { |line| opts.separator line }
          opts.separator "Run `workspace workflow VERB --help` for a verb's options."
          opts.separator ""
          opts.separator "approve and reject with --step (and --attempt) are refused with gate_not_waiting unless the run"
          opts.separator "waits at that step's gate (on that attempt), so a stale button can't pass a later gate. These"
          opts.separator "checks guard against mistakes; they are not a security boundary (docs/README.workflow.md)."
          opts.separator ""
          opts.separator "`workflow advance RUN [--turn-ended --pane ID [--turn-started AT] [--stopped-at AT] [--background-task TYPE:ID]...]` is what the agent daemon runs to move a run"
          opts.separator "on when a turn ends; it is not meant to be typed."
          opts.separator ""
          opts.separator "`run` and `start` really start a run (start also makes a worktree); --dry-run checks and starts nothing."
          opts.separator "`start` may leave out the ID: config names it (workflows.by_ref.<kind>, else workflows.default)."
          opts.separator "RUN is a workflow run id (see `workspace workflow status`)."
          opts.separator ""
          opts.on("--name WORKSPACE", "run: the workspace to run in; render, check: the workspace whose packs and commands are read; show, validate, render, check, simulate, add, update, remove: the workspace whose project's definitions are read first (default: the current workspace); status: that workspace's runs still going (default: the current workspace); sweep: only that workspace's runs (default: every run going)") { |v| options[:name] = v }
          opts.on("--input KEY=VALUE", "run, start, render, simulate: a value for one of the workflow's inputs (repeatable)") { |v| options[:inputs] << v }
          opts.on("--artifacts DIR", "check: an existing directory standing for the run's artifacts (WORKSPACE_RUN_ARTIFACTS); default an empty temporary one") { |v| options[:artifacts] = v }
          opts.on("--note TEXT", "run, start: added to every step's instructions; resume, approve, reject: to the next attempt's") { |v| options[:note] = v }
          opts.on("--pane PANE", "run, resume: the pane to run in (%19 or 0.1) instead of the workspace's Claude pane") { |v| options[:pane] = v }
          opts.on("--from STEP", "resume: start again at this step") { |v| options[:from] = v }
          opts.on("--extra-attempts N", "resume, reject: add N to the run's attempt allowance when it has spent max_attempts (ignored by a resume that starts no attempt)") { |v| options[:extra_attempts] = v }
          opts.on("--extra-tokens N", "resume, reject: add N to the run's token budget when it has used budget.tokens (ignored by a resume that starts no attempt)") { |v| options[:extra_tokens] = v }
          opts.on("--to STEP", "reject: the step to run again (the gated step, or one before it)") { |v| options[:to] = v }
          opts.on("--step STEP", "approve, reject: the gated step you saw (current.step in status --json); refused unless the run waits there") { |v| options[:step] = v }
          opts.on("--attempt N", "approve, reject: that step's attempt you saw (current.attempt); needs --step") { |v| options[:attempt] = v }
          opts.on("--note-sha256 HEX", "approve: the sha256 of the gate's note you read (gate_file.sha256); refused with stale_revision when it changed") { |v| options[:note_sha256] = v }
          opts.on("--script FILE", "simulate: the YAML script of what the fake agent does on each attempt and how each check comes out") { |v| options[:script] = v }
          opts.on("--source", "show ID: the file's text, sha256 of its bytes and problems, valid or not; install: only the source at position N of workflows.sources (a whole number from 1, written after the flag)") { options[:source] = true }
          opts.on("--attempt-of STEP", "attempts, audit: only this step's attempts") { |v| options[:attempt_of] = v }
          opts.on("--by GROUP", "compare: group the runs by definition (default) or pack:NAME, the text of that pack their agent was sent") { |v| options[:compare_by] = v }
          opts.on("--last DURATION", "stats, compare: only runs started in the last DURATION (30d, 2w, 12h, 90m; a run that started exactly then counts)") { |v| options[:last] = v }
          opts.on("--since N", "events: only events after line N of the history (default 0)") { |v| options[:since] = v }
          opts.on("--id ID", "validate: check the text as this workflow id") { |v| options[:id] = v }
          opts.on("--project [NAME]", "status: all runs of a project, finished too (NAME, or the project of the current workspace)") { |v| options[:project] = v || true }
          opts.on("--all", "status: every workspace's runs, finished too") { options[:all] = true }
          opts.on("--needs-me", "status: the runs still going, in every workspace, that wait for you (a gate, question, prompt, failed check, gone pane, stall), each with the next command; --name or --project narrows it") { options[:needs_me] = true }
          opts.on("--table", "status: one row per run with its workspace's status and whether its config, tmux session, worktree and state directory exist; finished runs show at every scope") { options[:table] = true }
          opts.on("--ref REF", "start: run the workflow that fits REF's kind (workflows.by_ref.<kind>, then workflows.default, else the one that fits) instead of naming an ID") { |v| options[:ref] = v }
          opts.on("--force", "start: start although the workflow's applies_to: does not list the REF's kind") { options[:force] = true }
          opts.on("--dry-run", "run, start: report what would start and start nothing; sweep: report what would be done and do nothing (also --install and --uninstall); add, update: check and write no definition (the lock file may be created); remove: check and delete nothing") { options[:dry_run] = true }
          opts.on("--install", "sweep: install the launchd entry that runs the sweep every 5 minutes (a per-user LaunchAgent; opt-in)") { options[:schedule_flags] << :install }
          opts.on("--uninstall", "sweep: unload and remove that launchd entry") { options[:schedule_flags] << :uninstall }
          opts.on("--installed", "sweep: say whether that launchd entry is installed and loaded") { options[:schedule_flags] << :status }
          opts.on("--yes", "remove, uninstall: do not ask before deleting") { options[:yes] = true }
          opts.on("--if-sha256 SHA", "update: the sha256 of the file's raw bytes you read; refuse with stale_workflow unless it still matches") { |v| options[:if_sha256] = v }
          opts.on("--prompt TEXT", "start: the task as free text (the workflow's task input, and the branch's name when there is no REF)") { |v| options[:prompt] = v }
          opts.on("--branch BRANCH", "start: the branch for a --prompt (default: the prompt's words); refused with a REF") { |v| options[:branch] = v }
          opts.on("--slug", "start: add the ticket title's words to a JIRA or issue branch, as `workspace start --slug`") { options[:slug] = true }
          opts.on("--base REF", "start: the branch or ref a new branch starts from") { |v| options[:base] = v }
          opts.on("--[no-]headless", "start: start the session in plain tmux, as `workspace start --headless`") { |v| options[:headless] = v }
          opts.on("--agent-kind KIND", "start: the coding agent the main agent pane runs: #{AgentProvider.all.map(&:key).join(", ")}") { |v| options[:agent_kind] = v }
          opts.on("--prompt-timeout DURATION", "start: how long to wait for the coding agent to be ready (default #{AgentReadiness::DEFAULT_TIMEOUT}s)") do |v|
            options[:prompt_timeout] = @common.parse_duration_option("--prompt-timeout", v, positive: true)
          end
          opts.on("--turn-ended", "advance: a turn ended in the run's pane") { options[:turn_ended] = true }
          opts.on("--turn-started AT", "advance: when that turn began (ISO 8601)") { |v| options[:turn_started] = v }
          opts.on("--stopped-at AT", "advance: when the daemon saw that turn end (ISO 8601)") { |v| options[:stopped_at] = v }
          opts.on("--background-task TYPE:ID", "advance: a background task still going when the turn ended (repeatable)") { |v| options[:background] << workflow_background_task(v) }
          opts.on("--json", "Print one JSON document (see docs/README.workflow.md)") { options[:json] = true }
          opts.on("-h", "--help", "Show this help") { options[:help] = true }
          opts.separator ""
          opts.separator "Examples:"
          opts.separator "  workspace workflow show    # list the workflows you can run"
          opts.separator "  workspace workflow show rpiv    # see the inputs and steps of one before running it"
          opts.separator "  workspace workflow run rpiv --input task=\"PROJ-101 invoice PDF export\" --dry-run    # check a run in this workspace and start nothing"
          opts.separator "  workspace workflow run rpiv --input task=\"PROJ-101 invoice PDF export\"    # start it for real: step one is typed into the Claude pane"
          opts.separator "  workspace workflow start rpiv --prompt \"add a hello script\"    # make a worktree workspace from a sentence and run rpiv in it"
          opts.separator "  workspace workflow status    # which runs are going, and why one is stuck"
          opts.separator "  workspace workflow approve RUN --note \"Skip the migration.\"    # pass the gate a run waits at"
          opts.separator "  workspace workflow reject RUN --note \"Too big; split it.\"    # send the gated step back with a reason"
          opts.separator "  workspace workflow resume RUN --from implement    # start a stuck run again at one step"
          opts.separator "  workspace workflow cancel RUN    # end a run and release its locks"
        end
      end

      def workflow(args, invocation)
        return if @common.verb_help_shown?(invocation, HelpPages::WORKFLOW, args)

        options = {json: false, inputs: [], background: [], all: false, dry_run: false, turn_ended: false, source: false, schedule_flags: []}
        given = args.dup
        parser = workflow_parser(options)
        @common.refuse_bad_bytes!(args)
        subcommand = args.shift if SUBCOMMANDS.include?(args.first)
        parser.parse!(args)
        subcommand ||= args.shift if SUBCOMMANDS.include?(args.first)
        return invocation.output.puts(parser.help) if options[:help]

        unless subcommand
          raise UsageError, args.empty? ? "Missing subcommand: list, show, validate, add, update, remove, install, uninstall, run, start, render, check, simulate, status, events, files, attempts, audit, stats, compare, sweep, resume, cancel, approve or reject.\n\n#{parser.help}" : "Unknown workflow subcommand: #{args.first}. Run 'workspace workflow --help'."
        end
        raise Error, "workflow is not available: no workflow command was wired" unless @workflow_command
        subject = args.shift
        source_path = args.shift if %w[add update].include?(subcommand)
        start_ref = args.shift if subcommand == "start"
        render_step = args.shift if %w[render check].include?(subcommand)
        raise UsageError, "Unexpected argument: #{args.first}. Run 'workspace workflow --help'." if args.any?
        needs = {"validate" => "a PATH, or - for stdin", "add" => "an ID and a PATH (or - for stdin)", "update" => "an ID and a PATH (or - for stdin)", "remove" => "an ID (see `workspace workflow show`)", "run" => "an ID (see `workspace workflow show`)", "render" => "an ID and a STEP (see `workspace workflow show ID`)", "simulate" => "an ID (see `workspace workflow show`)", "check" => "an ID and a STEP (see `workspace workflow show ID`)", "events" => "a RUN id", "files" => "a RUN id", "attempts" => "a RUN id", "audit" => "a RUN id", "stats" => "a workflow ID (see `workspace workflow show`)", "compare" => "a workflow ID (see `workspace workflow show`)", "resume" => "a RUN id", "cancel" => "a RUN id", "approve" => "a RUN id",
                 "reject" => "a RUN id", "advance" => "a RUN id"}[subcommand]
        raise UsageError, "workflow #{subcommand} needs #{needs}." if needs && (subject.nil? || (%w[add update].include?(subcommand) && source_path.nil?) || (%w[render check].include?(subcommand) && render_step.nil?))

        raise UsageError, "--script is for `workflow simulate ID`." if options[:script] && subcommand != "simulate"
        raise UsageError, "workflow simulate needs --script FILE (what the fake agent does; see `workspace workflow simulate --help`)." if subcommand == "simulate" && options[:script].nil?
        raise UsageError, "--since is for `workflow events RUN`." if options[:since] && subcommand != "events"
        raise UsageError, "--attempt-of is for `workflow attempts RUN` and `workflow audit RUN`." if options[:attempt_of] && !%w[attempts audit].include?(subcommand)
        raise UsageError, "--id is for `workflow validate PATH`." if options[:id] && subcommand != "validate"
        raise UsageError, "--last is for `workflow stats ID` and `workflow compare ID`." if options[:last] && !%w[stats compare].include?(subcommand)
        raise UsageError, "--by is for `workflow compare ID`." if options[:compare_by] && subcommand != "compare"
        raise UsageError, "--project is for `workflow status`, `workflow stats` and `workflow compare`." if options[:project] && !%w[status stats compare].include?(subcommand)
        raise UsageError, "workflow #{subcommand} covers every workspace unless --name or --project narrows it; --all is not needed." if %w[stats compare].include?(subcommand) && options[:all]
        raise UsageError, "workflow sweep takes a RUN or --name WORKSPACE, not both." if subcommand == "sweep" && subject && options[:name]
        schedule = options[:schedule_flags].first
        raise UsageError, "--install, --uninstall and --installed are for `workflow sweep`." if schedule && subcommand != "sweep"
        raise UsageError, "workflow sweep takes one of --install, --uninstall and --installed, and no RUN or --name with it." if schedule && (options[:schedule_flags].size > 1 || subject || options[:name])
        raise UsageError, "--dry-run does not apply to `workflow sweep --installed`: it changes nothing." if schedule == :status && options[:dry_run]
        raise UsageError, "--table is for `workflow status`." if options[:table] && subcommand != "status"
        raise UsageError, "--needs-me is for `workflow status`." if options[:needs_me] && subcommand != "status"
        raise UsageError, "--needs-me lists runs still going and takes no RUN or --table." if options[:needs_me] && (subject || options[:table])
        raise UsageError, "workflow check runs a status: command, which takes no inputs: --input is for run, start and render." if subcommand == "check" && options[:inputs].any?
        raise UsageError, "--artifacts is for `workflow check ID STEP`." if options[:artifacts] && subcommand != "check"
        raise UsageError, "--source is for `workflow show ID` and `workflow install`." if options[:source] && !%w[show install].include?(subcommand)
        raise UsageError, "workflow show --source needs an ID (see `workspace workflow show`)." if options[:source] && subcommand == "show" && subject.nil?
        raise UsageError, "workflow install --source needs N, the position in workflows.sources (1 is the first)." if subcommand == "install" && options[:source] && subject.nil?
        raise UsageError, "workflow install takes no argument; --source N installs only the Nth source." if subcommand == "install" && subject && !options[:source]
        raise UsageError, "--source N is not a position: use a whole number from 1." if subcommand == "install" && subject && !subject.match?(/\A[1-9][0-9]{0,5}\z/)
        raise UsageError, "--dry-run does not apply to `workflow install`." if subcommand == "install" && options[:dry_run]
        raise UsageError, "workflow uninstall takes no argument." if subcommand == "uninstall" && subject
        gate_options = workflow_gate_options(subcommand, options)
        extra_attempts = workflow_extra_attempts(subcommand, options[:extra_attempts])
        extra_tokens = workflow_extra_tokens(subcommand, options[:extra_tokens])

        start_flags = {"--prompt" => :prompt, "--branch" => :branch, "--slug" => :slug, "--base" => :base, "--[no-]headless" => :headless, "--agent-kind" => :agent_kind, "--prompt-timeout" => :prompt_timeout, "--force" => :force, "--ref" => :ref}
        if subcommand != "start" && (flag = start_flags.find { |_, key| !options[key].nil? })
          raise UsageError, "#{flag.first} is for `workflow start [ID] [REF]`."
        end
        if subcommand == "start"
          raise UsageError, "workflow start makes its own workspace: --name is for `workflow run`." if options[:name]
          raise UsageError, "workflow start runs in the new workspace's pane: --pane is for `workflow run`." if options[:pane]
          if options[:ref]
            raise UsageError, "--ref takes the place of the workflow ID and the REF: use `workflow start --ref REF`, or `workflow start ID REF`." if subject || start_ref
            raise UsageError, "--ref is a REF to route; --prompt has no kind to route by. Name a workflow: `workflow start ID --prompt TEXT`." unless options[:prompt].nil?
            raise UsageError, "--ref needs a REF." if options[:ref].strip.empty?
          end
          raise UsageError, "workflow start needs a REF (a ticket, pull request, issue or branch) or --prompt TEXT." if subject.nil? && options[:ref].nil? && options[:prompt].to_s.strip.empty?
          raise Error, "workflow start is not available: no workflow start command was wired" unless @workflow_start_command
        end

        case subcommand
        when "list" then @workflow_command.list(json: options[:json], project: workflow_project(options))
        when "show" then @workflow_command.show(id: subject, json: options[:json], source: options[:source], project: workflow_project(options))
        when "uninstall" then workflow_action(invocation, "workflow uninstall", options) { @workflow_command.uninstall(yes: options[:yes], dry_run: options[:dry_run], json: options[:json]) }
        when "validate" then @workflow_command.validate(path: subject, id: options[:id], json: options[:json], project: workflow_project(options))
        when "render"
          name = workflow_workspace(options)
          project = workflow_project(options)
          root = name && (options[:name] ? @names.working_dir_for(name) : @project_config.project_root_for(name))
          @workflow_command.render(id: subject, step: render_step, workspace: name, worktree: root ? File.expand_path(root) : @working_dir, inputs: Workflow.inputs(options[:inputs]), json: options[:json], project: project)
        when "check"
          name = workflow_workspace(options)
          project = workflow_project(options)
          root = if name
            options[:name] ? @names.working_dir_for(name) : @project_config.project_root_for(name)
          else
            @git.root
          end
          artifacts = options[:artifacts]
          artifacts = File.expand_path(artifacts, @working_dir) unless artifacts.to_s.empty?
          result = @workflow_command.check(id: subject, step: render_step, worktree: root ? File.expand_path(root) : @working_dir,
            artifacts: artifacts, json: options[:json], project: project)
          invocation.exit_handler.exit(result[:exit_code]) unless result[:exit_code].zero?
        when "simulate" then @workflow_command.simulate(id: subject, script: options[:script], inputs: Workflow.inputs(options[:inputs]), json: options[:json], project: workflow_project(options))
        when "add" then workflow_action(invocation, "workflow add", options) { @workflow_command.add(id: subject, path: source_path, dry_run: options[:dry_run], project: workflow_project(options)) }
        when "update"
          raise UsageError, "workflow update needs --if-sha256 SHA (the sha256 from `workflow show ID --source`)." if options[:if_sha256].to_s.empty?
          workflow_action(invocation, "workflow update", options) { @workflow_command.update(id: subject, path: source_path, if_sha256: options[:if_sha256], dry_run: options[:dry_run], project: workflow_project(options)) }
        when "install" then workflow_action(invocation, "workflow install", options) { @workflow_command.install(source: subject && Integer(subject, 10)) }
        when "remove"
          project = workflow_project(options)
          @workflow_command.check_removable(id: subject, project: project)
          unless options[:yes] || options[:dry_run]
            Prompt.refuse_if_no_input!(@input, "Remove workflow #{subject}?", retry_flags: ["--yes"], destructive: true)
            raise UsageError, "workflow remove --json never prompts: pass --yes to remove, or --dry-run to preview." if options[:json]
          end
          workflow_action(invocation, "workflow remove", options) { @workflow_command.remove(id: subject, yes: options[:yes], dry_run: options[:dry_run], project: project) }
        when "files"
          @workflow_command.files(run: subject, json: options[:json])
        when "attempts"
          @workflow_command.attempts(run: subject, step: options[:attempt_of], json: options[:json])
        when "stats"
          last = workflow_last(options[:last])
          scope = @status_scope.resolve(name: options[:name], project: options[:project], all: nil, working_dir: @working_dir) if options[:name] || options[:project]
          result = @workflow_command.stats(workflow: subject, last: last, last_text: options[:last], scope: scope, json: options[:json])
          invocation.exit_handler.exit(result[:exit_code]) unless result[:exit_code].zero?
        when "compare"
          last = workflow_last(options[:last])
          scope = @status_scope.resolve(name: options[:name], project: options[:project], all: nil, working_dir: @working_dir) if options[:name] || options[:project]
          result = @workflow_command.compare(workflow: subject, by: options[:compare_by] || "definition", last: last, last_text: options[:last], scope: scope, json: options[:json])
          invocation.exit_handler.exit(result[:exit_code]) unless result[:exit_code].zero?
        when "audit"
          result = @workflow_command.audit(run: subject, step: options[:attempt_of], json: options[:json])
          invocation.exit_handler.exit(result[:exit_code]) unless result[:exit_code].zero?
        when "sweep"
          if schedule
            action = "workflow sweep --#{(schedule == :status) ? "installed" : schedule}"
            workflow_action_rows(invocation, action, options) { @workflow_command.schedule(schedule, dry_run: options[:dry_run]) }
            return
          end
          workflow_action_rows(invocation, "workflow sweep", options) { @workflow_command.sweep(run: subject, name: options[:name], dry_run: options[:dry_run], json: options[:json], caller_pane: ENV["TMUX_PANE"]) }
        when "events"
          @workflow_command.events(run: subject, since: workflow_since(options[:since]), json: options[:json])
        when "status"
          if subject && (options[:name] || options[:project] || options[:all])
            raise UsageError, "workflow status RUN takes no --name, --project or --all: the run names its own workspace."
          end
          scope = if options[:needs_me]
            @status_scope.resolve_needs_me(name: options[:name], project: options[:project], all: options[:all], working_dir: @working_dir)
          elsif !subject
            @status_scope.resolve(name: options[:name], project: options[:project], all: options[:all], working_dir: @working_dir)
          end
          outcome = @workflow_command.status(run: subject, scope: scope, json: options[:json], hint: !options[:name], table: options[:table] || false)
          code = outcome[:exit_code] if outcome.is_a?(Hash)
          invocation.exit_handler.exit(code) if code && !code.zero?
        when "advance"
          @workflow_command.advance(run: subject, turn_ended: options[:turn_ended], pane: options[:pane], turn_started: workflow_time(options[:turn_started], "--turn-started"),
            stopped_at: workflow_time(options[:stopped_at], "--stopped-at"), background: options[:background], caller_pane: ENV["TMUX_PANE"])
        when "run"
          name = workflow_workspace(options)
          raise UsageError, "workflow run needs a workspace: pass --name, or run from inside a project." unless name
          inputs = Workflow.inputs(options[:inputs])
          workflow_action(invocation, "workflow run", options) do
            project = workflow_project(options)
            # The checkout's root, where the run's files go: the named workspace's, or the detected one's.
            root = options[:name] ? @names.working_dir_for(name) : @project_config.project_root_for(name)
            @workflow_command.run(id: subject, workspace: name, worktree: root ? File.expand_path(root) : @working_dir, inputs: inputs,
              pane: options[:pane], note: options[:note], dry_run: options[:dry_run], caller_pane: ENV["TMUX_PANE"], project: project,
              fill_from_branch: !root.nil?)
          end
        when "start"
          inputs = Workflow.inputs(options[:inputs])
          workflow_action(invocation, "workflow start", options) do
            begin
              row = @workflow_start_command.call(id: start_ref && subject, ref: options[:ref] || start_ref, positional: (start_ref || options[:ref]) ? nil : subject, route: !options[:ref].nil?, prompt: options[:prompt], branch: options[:branch], slug: options[:slug] == true, inputs: inputs,
                note: options[:note], base: options[:base], headless: @launch_mode.resolve(options[:headless]).headless?, agent_kind: options[:agent_kind],
                prompt_timeout: options[:prompt_timeout], dry_run: options[:dry_run], force: options[:force] == true)
            rescue Workspace::Error => e
              print_start_warnings(invocation, e.details["warnings"], options)
              raise
            end
            print_start_warnings(invocation, row && row["warnings"], options)
            row
          end
        when "resume"
          workflow_action(invocation, "workflow resume", options) { @workflow_command.resume(run: subject, from: options[:from], note: options[:note], pane: options[:pane], extra_attempts: extra_attempts, extra_tokens: extra_tokens, caller_pane: ENV["TMUX_PANE"]) }
        when "cancel" then workflow_action(invocation, "workflow cancel", options) { @workflow_command.cancel(run: subject) }
        when "approve"
          workflow_action(invocation, "workflow approve", options) do
            @workflow_command.approve(run: subject, note: options[:note], **gate_options, note_sha256: options[:note_sha256], caller_pane: ENV["TMUX_PANE"])
          end
        when "reject"
          raise UsageError, "workflow reject needs --note TEXT: the step runs again with it." if options[:note].to_s.strip.empty?
          workflow_action(invocation, "workflow reject", options) do
            @workflow_command.reject(run: subject, note: options[:note], to: options[:to], **gate_options, extra_attempts: extra_attempts, extra_tokens: extra_tokens, caller_pane: ENV["TMUX_PANE"])
          end
        end
      rescue OptionParser::ParseError, UsageError => e
        raise unless @common.json_requested?(options[:json], given)
        @common.emit_json_error(invocation, JsonEnvelope::SCHEMA_VERSION, e, message: e.message.lines.first.strip)
      end

      # The project whose workflow definitions every `workflow` reader looks in first, from {WorkflowProject}: the parent
      # project of `--name`'s workspace (an unknown one is refused), else of the current directory; nil outside any
      # project, or when a repository's marker is not tied to this checkout (the user directory and presets alone).
      def workflow_workspace(options)
        return options[:name] if options[:name]
        @workflow_project ? @workflow_project.workspace(@working_dir) : @project_detector.detect(@working_dir)
      end

      def workflow_project(options)
        return nil unless @workflow_project
        resolved = options[:name] ? @workflow_project.for_workspace(options[:name]) : @workflow_project.for_directory(@working_dir)
        resolved&.project
      end

      # `--extra-attempts` of resume and reject, checked: a whole number from 1 up.
      def workflow_extra_attempts(subcommand, text)
        return nil if text.nil?
        raise UsageError, "--extra-attempts is for `workflow resume` and `workflow reject`." unless %w[resume reject].include?(subcommand)
        raise UsageError, "--extra-attempts must be a whole number from 1 up, got #{text.to_s[0, 20].inspect}." unless text.match?(/\A[1-9]\d{0,5}\z/)
        text.to_i
      end

      # `--extra-tokens` of resume and reject, checked: a whole number from 1 up.
      def workflow_extra_tokens(subcommand, text)
        return nil if text.nil?
        raise UsageError, "--extra-tokens is for `workflow resume` and `workflow reject`." unless %w[resume reject].include?(subcommand)
        raise UsageError, "--extra-tokens must be a whole number from 1 up, got #{text.to_s[0, 20].inspect}." unless text.match?(/\A[1-9]\d{0,11}\z/)
        text.to_i
      end

      # The `--step`/`--attempt` pair of approve and reject, checked; `--note-sha256` is approve's.
      def workflow_gate_options(subcommand, options)
        gated = %w[approve reject].include?(subcommand)
        raise UsageError, "--step and --attempt are for `workflow approve` and `workflow reject`." if !gated && (options[:step] || options[:attempt])
        raise UsageError, "--note-sha256 is for `workflow approve`." if options[:note_sha256] && subcommand != "approve"
        raise UsageError, "--attempt needs --step: the attempt is of the gated step." if options[:attempt] && !options[:step]
        if options[:note_sha256] && !options[:note_sha256].match?(/\A[0-9a-f]{64}\z/)
          raise UsageError, "--note-sha256 must be 64 lowercase hex digits (gate_file.sha256 in `workflow status --json`)."
        end
        attempt = options[:attempt]
        raise UsageError, "--attempt must be a whole number from 1 up, got #{attempt.to_s[0, 20].inspect}." if attempt && !attempt.match?(/\A[1-9]\d{0,8}\z/)
        gated ? {step: options[:step], attempt: attempt&.to_i} : {}
      end

      # `--last` of stats, in seconds: a Duration (`90m`, `12h`) or whole days or weeks (`30d`, `2w`).
      def workflow_last(text)
        return nil if text.nil?
        Workspace::Duration.parse_window(text)
      rescue ArgumentError => e
        detail = e.message.start_with?("must be") ? e.message.sub(/, got .*/, "") : "needs a duration like 30d, 2w, 12h or 90m"
        raise UsageError, "--last #{detail}, got #{text.to_s[0, 40].inspect}."
      end

      def workflow_since(text)
        return 0 if text.nil?
        raise UsageError, "--since needs a whole number of 0 or more, got #{text.to_s[0, 40].inspect}." unless text.match?(/\A\d+\z/)
        text.to_i
      end

      def workflow_time(text, flag)
        text && Time.iso8601(text)
      rescue ArgumentError
        raise UsageError, "#{flag} takes an ISO 8601 time, got #{text[0, 40].inspect}."
      end

      def workflow_background_task(text)
        type, id = text.split(":", 2)
        unless IdPatterns::BACKGROUND_TASK_TYPES.include?(type) && id.to_s.match?(IdPatterns::BACKGROUND_TASK_ID)
          raise UsageError, "--background-task takes TYPE:ID with a type of #{IdPatterns::BACKGROUND_TASK_TYPES.join(", ")}, got #{text[0, 60].inspect}."
        end
        {"id" => id, "type" => type}
      end

      def step_parser(options)
        OptionParser.new do |opts|
          opts.banner = HelpPages.overview_usage(HelpPages::STEP)
          opts.separator ""
          opts.separator "For the agent working on a workflow step, run from the pane the run is bound to."
          opts.separator "Neither is required: a step is decided when the agent's turn ends, from the files it"
          opts.separator "was told to leave and the step's check (see `workspace workflow --help`)."
          opts.separator ""
          HelpPages.overview_verbs(HelpPages::STEP).each { |line| opts.separator line }
          opts.separator "Run `workspace step VERB --help` for a verb's options."
          opts.separator ""
          opts.on("--status STATUS", "done: pass (default) or fail") { |v| options[:status] = v }
          opts.on("--summary TEXT", "done: one line about what was done, or what is left") { |v| options[:summary] = v }
          opts.on("--code WORD", "done: a word for why, kept with a failed step: starts with a lowercase letter, then lowercase letters, digits, _ (at most 40); not one the engine uses (e.g. check_failed, head_moved)") { |v| options[:code] = v }
          opts.on("--json", "Print one JSON document (see docs/README.workflow.md)") { options[:json] = true }
          opts.on("-h", "--help", "Show this help") { options[:help] = true }
          opts.separator ""
          opts.separator "Examples:"
          opts.separator "  workspace step status    # which run, step and attempt this pane is on"
          opts.separator "  workspace step done --summary \"Plan written; three commits.\"    # record a pass, then end your turn"
          opts.separator "  workspace step done --status fail --summary \"Two specs still fail in billing.\"    # fail the step at the turn's end"
          opts.separator "  workspace step done --status fail --code not_reproduced --summary \"The failure did not happen locally.\"    # fail it with a word for why"
        end
      end

      def step(args, invocation)
        return if @common.verb_help_shown?(invocation, HelpPages::STEP, args)

        options = {json: false, status: "pass"}
        given = args.dup
        parser = step_parser(options)
        @common.refuse_bad_bytes!(args)
        subcommand = args.shift if %w[done status].include?(args.first)
        parser.parse!(args)
        subcommand ||= args.shift if %w[done status].include?(args.first)
        return invocation.output.puts(parser.help) if options[:help]

        unless subcommand
          raise UsageError, args.empty? ? "Missing subcommand: done or status.\n\n#{parser.help}" : "Unknown step subcommand: #{args.first}. Run 'workspace step --help'."
        end
        raise UsageError, "Unexpected argument: #{args.first}. Run 'workspace step --help'." if args.any?
        raise Error, "step is not available: no workflow command was wired" unless @workflow_command

        if subcommand == "status"
          @workflow_command.step_status(pane: ENV["TMUX_PANE"], json: options[:json])
        else
          workflow_action(invocation, "step done", options) { @workflow_command.step_done(pane: ENV["TMUX_PANE"], status: options[:status], summary: options[:summary], code: options[:code]) }
        end
      rescue OptionParser::ParseError, UsageError => e
        raise unless @common.json_requested?(options[:json], given)
        @common.emit_json_error(invocation, JsonEnvelope::SCHEMA_VERSION, e, message: e.message.lines.first.strip)
      end

      # `workflow start`'s warnings, on success or above its refusal; `--json` carries them in the document.
      def print_start_warnings(invocation, warnings, options)
        return if options[:json]
        Array(warnings).each { |warning| invocation.error_output.puts "Warning: #{TerminalText.escape(warning.to_s)}" }
      end

      # Runs a workflow or step mutation under {Common#run_row_action}, with the command's row as the one result.
      def workflow_action(invocation, action, options, &block)
        @common.run_row_action(invocation, action, json: options[:json], &block)
      end

      # Like {#workflow_action}, for a command that answers many rows and its own exit code.
      def workflow_action_rows(invocation, action, options)
        @common.run_action(invocation, action, json: options[:json]) do
          outcome = yield
          {exit_code: outcome[:exit_code], results: outcome[:results], status: outcome[:status]}
        end
      end
    end
  end
end
