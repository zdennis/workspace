require "optparse"
require "socket"
require "securerandom"
require "shellwords"
require "time"
require "json"

module Workspace
  # Command-line interface for the workspace CLI.
  # Receives all collaborators via constructor injection and dispatches
  # subcommands via a case statement.
  class CLI
    # Known subcommand names, matching the `case subcommand` branches in
    # {#run}. Used to pick out the intended subcommand when a leading flag
    # is mistaken for one (see the "Unknown option before the subcommand"
    # hint).
    SUBCOMMANDS = %w[
      init doctor launch start stop add add-project kill finish relaunch restore
      focus deactivate reactivate tile resize capture agent agentd lock dev parent notes plan ticket spine pr rebase push promote projects
      capabilities daemon sessions review snapshot ask inbox hooks session-event agent-run handoff pipeline run library lib instructions workflow step
      run-and-report report-run-status layout config tmux statusline current
      list-projects list status repair cleanup prune set-command event-log events
      whereis lookup dir alfred version help
    ].freeze

    # @param workspace_name [Workspace::WorkspaceName, nil] settles a given workspace name to its on-disk spelling (nil leaves names as given)
    # @param config [Workspace::Config] configuration for path lookups
    # @param state [Workspace::State] state persistence
    # @param project_config [Workspace::ProjectConfig] project config management
    # @param window_manager [Workspace::WindowManager] iTerm window operations
    # @param doctor [Workspace::Doctor] dependency checking
    # @param project_settings [Workspace::ProjectSettings] per-project settings
    # @param hook_runner [Workspace::HookRunner] lifecycle hook execution
    # @param launch_command [Workspace::Commands::Launch] pre-built launch command
    # @param kill_command [Workspace::Commands::Kill] pre-built kill command
    # @param finish_command [Workspace::Commands::Finish] pre-built finish command
    # @param start_command [Workspace::Commands::Start] pre-built start command
    # @param stop_command [Workspace::Commands::Stop] pre-built stop command (session-only teardown)
    # @param focus_command [Workspace::Commands::Focus] pre-built focus command
    # @param tile_command [Workspace::Commands::Tile] pre-built tile command
    # @param layout_command [Workspace::Commands::Layout] pre-built layout command
    # @param resize_command [Workspace::Commands::Resize] pre-built resize command
    # @param init_command [Workspace::Commands::Init] pre-built init command
    # @param repair_command [Workspace::Commands::Repair] pre-built repair command
    # @param cleanup_command [Workspace::Commands::Cleanup] pre-built cleanup command
    # @param prune_command [Workspace::Commands::Prune] pre-built prune command
    # @param claude_command [Workspace::Commands::Claude] pre-built claude command
    # @param lookup_command [Workspace::Commands::Lookup] pre-built lookup command
    # @param update_pane_command [Workspace::Commands::UpdatePaneCommand] pre-built set-command command
    # @param capture_command [Workspace::Commands::Capture] pre-built capture command
    # @param wait_until_content_command [Workspace::Commands::WaitUntilContent] pre-built wait-until-content command
    # @param agent_command [Workspace::Commands::Agent] pre-built agent command
    # @param ensure_agent_command [Workspace::Commands::EnsureAgent, nil] pre-built
    #   `agentd --ensure` command
    # @param name_migration [Workspace::NameMigration, nil] renames a mixed-case workspace
    #   to lowercase before `launch` starts it; nil renames nothing
    # @param restart_agent_command [Workspace::Commands::RestartAgent, nil] pre-built
    #   `agent-run restart` command; optional so test builders need not wire it
    # @param agent_status_command [Workspace::Commands::AgentStatus, nil] pre-built
    #   `agent status` command; optional so test builders need not wire it
    # @param send_command [Workspace::Commands::Send, nil] pre-built
    #   `agent-run send` command; optional so test builders need not wire it
    # @param handoff_command [Workspace::Commands::Handoff, nil] pre-built
    #   `handoff check`/`handoff new` command; optional so test builders need not wire it
    # @param logger [Workspace::Logger] debug logger
    # @param output [IO] output stream for user-facing messages
    # @param error_output [IO] error output stream for warnings and errors
    # @param input [IO] input stream for interactive prompts
    # @param exit_handler [#exit] callable for process exit (Kernel in production, FakeExitHandler in tests)
    # @param parent_command [Workspace::Commands::Parent] pre-built parent command
    # @param dev_command [Workspace::Commands::Dev] pre-built dev command
    # @param notes_command [Workspace::Commands::Notes, nil] pre-built notes command
    # @param notes_setup [Workspace::NotesSetup, nil] fixes the notes directory of a worktree config `add` creates; nil skips it
    # @param plan_command [Workspace::Commands::Plan, nil] pre-built plan command
    # @param plan_dispatch_command [Workspace::Commands::PlanDispatch, nil] pre-built plan start command
    # @param plan_task_command [Workspace::Commands::PlanTask, nil] pre-built plan task command
    # @param ticket_command [Workspace::Commands::Ticket, nil] pre-built ticket command
    # @param spine_command [Workspace::Commands::Spine, nil] pre-built spine command
    # @param spine_init_command [Workspace::Commands::SpineInit, nil] pre-built spine init command
    # @param spine_start_command [Workspace::Commands::SpineStart, nil] pre-built spine start command
    # @param pull_request_command [Workspace::Commands::PullRequest, nil] pre-built pr command
    # @param rebase_command [Workspace::Commands::Rebase, nil] pre-built rebase command
    # @param push_command [Workspace::Commands::Push, nil] pre-built push command
    # @param promote_command [Workspace::Commands::Promote, nil] pre-built promote command
    # @param projects_command [Workspace::Commands::Projects, nil] pre-built projects command
    # @param capabilities_command [Workspace::Commands::Capabilities, nil] pre-built capabilities command
    # @param daemon_command [Workspace::Commands::Daemon, nil] pre-built daemon command
    # @param ui_command [Workspace::Commands::Ui, nil] pre-built ui command
    # @param binding_command [Workspace::Commands::Binding, nil] pre-built binding command
    # @param library_command [Workspace::Commands::Library, nil] pre-built library command
    # @param library [Workspace::Library, nil] resolves `launch --play` per project
    # @param instructions_command [Workspace::Commands::Instructions, nil] pre-built instructions command
    # @param instruction_composer [Workspace::InstructionComposer, nil] composes the packs `launch` sends with the first prompt
    # @param workflow_command [Workspace::Commands::Workflow, nil] pre-built `workflow` and `step` command
    # @param review_command [Workspace::Commands::Review, nil] pre-built review command
    # @param restore_command [Workspace::Commands::Restore, nil] pre-built restore command
    # @param events_command [Workspace::Commands::Events, nil] pre-built events command
    # @param snapshot_command [Workspace::Commands::Snapshot, nil] pre-built snapshot command
    # @param inbox_command [Workspace::Commands::Inbox, nil] pre-built inbox command
    # @param config_report [Workspace::ConfigReport, nil] builds the `config show/validate --json` documents
    # @param tmuxinator_report [Workspace::TmuxinatorReport, nil] builds the `tmux show --json` document
    # @param groups_command [Workspace::Commands::Groups, nil] pre-built `projects group` command
    # @param project_actions_command [Workspace::Commands::ProjectActions, nil] pre-built project-wide actions command
    # @param clock [#call] returns the current Time, for relative deadline display
    # @param liveness [#call, nil] maps project names to true, false, or nil
    # @param env [#[]] the environment `config edit` reads $VISUAL and $EDITOR from
    # @param editor_launcher [#call, nil] runs an editor given its argv array (no shell) and returns
    #   true when it exited 0; defaults to `system`
    # @param interactive [#call, nil] says whether stdin and stdout are both terminals (`config edit` opens
    #   no editor otherwise); defaults to a check of $stdin and $stdout
    #   (alive, dead, can't tell) for `list --liveness` and `status`; nil
    #   reports every project as unknown
    # @param window_liveness [#call, nil] maps project names to true, false, or
    #   nil (window open, gone, can't tell) for the `window_alive` field of
    #   `list --liveness --json` and `status --json`; takes name => state entry
    # @param launch_mode [Workspace::LaunchMode, nil] decides whether launch/start
    #   run headless when no --[no-]headless flag is given; nil builds one
    def initialize(config:, state:, project_config:, git:, window_manager:, doctor:, project_settings:, hook_runner:, project_detector:, launch_command:, kill_command:, finish_command:, start_command:, stop_command:, focus_command:, tile_command:, layout_command:, resize_command:, init_command:, repair_command:, cleanup_command:, prune_command:, claude_command:, lookup_command:, update_pane_command:, run_command:, run_result_store:, run_and_report_command:, capture_command:, wait_until_content_command:, lock_command:, dev_command:, parent_command:, agent_command:, sessions_command:, session_event_command:, config_command:, statusline_command:, ask_command:, hooks_command: nil, restart_agent_command: nil, agent_status_command: nil, send_command: nil, ensure_agent_command: nil, name_migration: nil, spine_command: nil, spine_init_command: nil, spine_start_command: nil, handoff_command: nil, notes_command: nil, notes_setup: nil, plan_command: nil, plan_dispatch_command: nil, plan_task_command: nil, ticket_command: nil, pull_request_command: nil, rebase_command: nil, push_command: nil, promote_command: nil, projects_command: nil, groups_command: nil, capabilities_command: nil, daemon_command: nil, ui_command: nil, binding_command: nil, library_command: nil, library: nil, instructions_command: nil, instruction_composer: nil, workflow_command: nil, review_command: nil, restore_command: nil, snapshot_command: nil, events_command: nil, project_actions_command: nil, remove_command: nil, inbox_command: nil, config_report: nil, tmuxinator_report: nil, exit_handler: Kernel, logger: Workspace::Logger.new, output: $stdout, error_output: $stderr, input: $stdin, working_dir: Dir.pwd, clock: -> { Time.now }, launch_mode: nil, liveness: nil, window_liveness: nil, env: ENV, editor_launcher: nil, interactive: nil, workspace_name: nil)
      @config = config
      @state = state
      @project_config = project_config
      @git = git
      @window_manager = window_manager
      @doctor = doctor
      @project_settings = project_settings
      @hook_runner = hook_runner
      @project_detector = project_detector
      @workspace_name = workspace_name
      @sessions_command = sessions_command
      @session_event_command = session_event_command
      @hooks_command = hooks_command
      @launch_command = launch_command
      @kill_command = kill_command
      @finish_command = finish_command
      @start_command = start_command
      @stop_command = stop_command
      @focus_command = focus_command
      @tile_command = tile_command
      @layout_command = layout_command
      @resize_command = resize_command
      @init_command = init_command
      @repair_command = repair_command
      @cleanup_command = cleanup_command
      @prune_command = prune_command
      @remove_command = remove_command
      @claude_command = claude_command
      @lookup_command = lookup_command
      @update_pane_command = update_pane_command
      @run_command = run_command
      @run_result_store = run_result_store
      @run_and_report_command = run_and_report_command
      @capture_command = capture_command
      @wait_until_content_command = wait_until_content_command
      @lock_command = lock_command
      @dev_command = dev_command
      @parent_command = parent_command
      @notes_command = notes_command
      @plan_command = plan_command
      @plan_dispatch_command = plan_dispatch_command
      @plan_task_command = plan_task_command
      @ticket_command = ticket_command
      @spine_command = spine_command
      @spine_init_command = spine_init_command
      @spine_start_command = spine_start_command
      @pull_request_command = pull_request_command
      @rebase_command = rebase_command
      @push_command = push_command
      @promote_command = promote_command
      @notes_setup = notes_setup
      @agent_command = agent_command
      @config_command = config_command
      @statusline_command = statusline_command
      @ask_command = ask_command
      @inbox_command = inbox_command
      @restart_agent_command = restart_agent_command
      @agent_status_command = agent_status_command
      @send_command = send_command
      @ensure_agent_command = ensure_agent_command
      @name_migration = name_migration
      @handoff_command = handoff_command
      @projects_command = projects_command
      @groups_command = groups_command
      @capabilities_command = capabilities_command
      @daemon_command = daemon_command
      @ui_command = ui_command
      @binding_command = binding_command
      @library_command = library_command
      @workflow_command = workflow_command
      @library = library
      @instructions_command = instructions_command
      @instruction_composer = instruction_composer
      @review_command = review_command
      @restore_command = restore_command
      @snapshot_command = snapshot_command
      @events_command = events_command
      @config_report = config_report
      @tmuxinator_report = tmuxinator_report
      @project_actions_command = project_actions_command
      @exit_handler = exit_handler
      @logger = logger
      @output = output
      @error_output = error_output
      @input = input
      @working_dir = working_dir
      @clock = clock
      @launch_mode = launch_mode || LaunchMode.new(project_settings: project_settings)
      @window_liveness = window_liveness || ->(entries) { entries.to_h { |name, _| [name, nil] } }
      @liveness = liveness || ->(names) { names.to_h { |name| [name, nil] } }
      @env = env
      @editor_launcher = editor_launcher || ->(argv) { system(*argv) }
      @interactive = interactive || -> { $stdin.tty? && $stdout.tty? }
    end

    # Parses the subcommand from argv and dispatches to the appropriate method.
    #
    # @param argv [Array<String>] command-line arguments
    # @return [void]
    def run(argv)
      args = argv.dup
      @logger.enable! if args.delete("--debug")
      @input.no_input! if take_no_input_flag!(args) && @input.respond_to?(:no_input!)
      settle_name_flags!(args)
      subcommand = args.shift
      @logger.debug { "subcommand=#{subcommand} args=#{args.inspect}" }

      case subcommand
      when "init"
        cmd_init(args)
      when "doctor"
        cmd_doctor(args)
      when "launch"
        cmd_launch(args)
      when "start"
        cmd_start(args)
      when "stop"
        cmd_stop(args)
      when "add", "add-project"
        cmd_add(args)
      when "kill"
        cmd_kill(args)
      when "finish"
        cmd_finish(args)
      when "relaunch"
        cmd_relaunch(args)
      when "restore"
        cmd_restore(args)
      when "focus"
        cmd_focus(args)
      when "deactivate"
        cmd_deactivate(args)
      when "reactivate"
        cmd_reactivate(args)
      when "tile"
        cmd_tile(args)
      when "resize"
        cmd_resize(args)
      when "capture"
        cmd_capture(args)
      when "wait-until-content"
        cmd_wait_until_content(args)
      when "agent"
        cmd_agent(args)
      when "agentd"
        cmd_agentd(args)
      when "lock"
        cmd_lock(args)
      when "dev"
        cmd_dev(args)
      when "parent"
        cmd_parent(args)
      when "notes"
        cmd_notes(args)
      when "plan"
        cmd_plan(args)
      when "ticket"
        cmd_ticket(args)
      when "spine"
        cmd_spine(args)
      when "pr"
        cmd_pr(args)
      when "rebase"
        cmd_rebase(args)
      when "push"
        cmd_push(args)
      when "promote"
        cmd_promote(args)
      when "projects"
        cmd_projects(args)
      when "capabilities"
        cmd_capabilities(args)
      when "sessions"
        cmd_sessions(args)
      when "daemon"
        cmd_daemon(args)
      when "ui"
        cmd_ui(args)
      when "binding"
        cmd_binding(args)
      when "library", "lib"
        cmd_library(args)
      when "instructions"
        cmd_instructions(args)
      when "workflow"
        cmd_workflow(args)
      when "step"
        cmd_step(args)
      when "review"
        cmd_review(args)
      when "snapshot"
        cmd_snapshot(args)
      when "ask"
        cmd_ask(args)
      when "inbox"
        cmd_inbox(args)
      when "hooks"
        cmd_hooks(args)
      when "session-event"
        cmd_session_event(args)
      when "agent-run"
        cmd_agent_run(args)
      when "handoff"
        cmd_handoff(args)
      when "pipeline"
        cmd_pipeline(args)
      when "run"
        cmd_run(args)
      when "run-and-report"
        cmd_run_and_report(args)
      when "report-run-status"
        cmd_report_run_status(args)
      when "layout"
        cmd_layout(args)
      when "config"
        cmd_config(args)
      when "tmux"
        cmd_tmux(args)
      when "statusline"
        cmd_statusline(args)
      when "current"
        cmd_current(args)
      when "list-projects"
        cmd_list(["--all"] + args)
      when "list"
        cmd_list(args)
      when "status"
        cmd_status(args)
      when "repair"
        cmd_repair(args)
      when "cleanup"
        cmd_cleanup(args)
      when "prune"
        cmd_prune(args)
      when "remove"
        cmd_remove(args)
      when "set-command"
        cmd_set_pane_command(args)
      when "event-log"
        cmd_event_log(args)
      when "events"
        cmd_events(args)
      when "whereis"
        cmd_whereis(args)
      when "lookup"
        cmd_lookup(args)
      when "dir"
        cmd_dir(args)
      when "alfred"
        cmd_alfred(args)
      when "version", "--version", "-v"
        if args.include?("--help") || args.include?("-h")
          @output.puts <<~HELP
            Usage: workspace version

            Print the workspace version.

            Example:
              workspace version
          HELP
        else
          @output.puts "workspace #{Workspace::VERSION}"
        end
      when "help", "--help", "-h", nil
        main_help
      else
        if subcommand&.start_with?("-")
          known = args.find { |a| SUBCOMMANDS.include?(a) }
          hint = known ? ", e.g. \"workspace #{known} #{subcommand}\"." : "."
          message = "Unknown option before the subcommand: #{subcommand}. Put options after the subcommand#{hint}"
          raise UsageError, message if json_flag?(argv)
          @error_output.puts message
        else
          raise UsageError, "Unknown subcommand: #{subcommand}" if json_flag?(argv)
          @error_output.puts "Unknown subcommand: #{subcommand}"
          @error_output.puts
          main_help
        end
        @exit_handler.exit(1)
      end
    rescue UsageError, OptionParser::ParseError => e
      report_failure(e, argv, e.message, json_message: e.message.lines.first.to_s.strip)
    rescue Workspace::Commands::Run::NotSubmittedError => e
      report_failure(e, argv, "Error: #{e.message}", exit_code: Workspace::Commands::Run::NotSubmittedError::EXIT_CODE)
    rescue Error => e
      report_failure(e, argv, "Error: #{e.message}")
    end

    private

    # The rescue funnel's output: with `--json` among the arguments, the
    # failure goes to stdout as one {JsonEnvelope} error document and stderr
    # stays empty; otherwise `human` goes to stderr. Exits either way.
    #
    # @param error [Exception] the failure
    # @param argv [Array<String>] the original arguments, to look for `--json`
    # @param human [String] the stderr text without `--json`
    # @param json_message [String, nil] the envelope's `error`, when not the exception's message
    # @param exit_code [Integer]
    def report_failure(error, argv, human, json_message: nil, exit_code: 1)
      if json_flag?(argv)
        @output.puts JSON.generate(JsonEnvelope.from_exception(JsonEnvelope::SCHEMA_VERSION, error, message: json_message))
      else
        @error_output.puts human
      end
      @exit_handler.exit(exit_code)
    end

    # Removes `--no-input` from `args` wherever it appears before a bare `--`,
    # so every subcommand accepts it without declaring it.
    #
    # @param args [Array<String>] arguments, modified in place
    # @return [Boolean] whether the flag was present
    def take_no_input_flag!(args)
      stop = args.index("--") || args.size
      found = args.first(stop).include?("--no-input")
      args.replace(args.first(stop).reject { |arg| arg == "--no-input" } + args.drop(stop)) if found
      found
    end

    # Rewrites the value of each `--name` (or `--name=VALUE`) that matches an
    # existing workspace ignoring case to that workspace's on-disk name, so
    # every command sees one spelling. A name that matches nothing is left as
    # given: whether it is new or a mistake is the command's call.
    #
    # @param args [Array<String>] arguments, modified in place
    def settle_name_flags!(args)
      return unless @workspace_name

      stop = args.index("--") || args.size
      stop.times do |i|
        if args[i] == "--name" && i + 1 < stop
          args[i + 1] = @workspace_name.match(args[i + 1]) || args[i + 1]
        elsif args[i].start_with?("--name=")
          value = args[i].delete_prefix("--name=")
          args[i] = "--name=#{@workspace_name.match(value) || value}"
        end
      end
    end

    # @param name [String, nil] a workspace or project name as given
    # @return [String, nil] the on-disk name of the config it matches ignoring case, else the name as given
    def settle_name(name)
      (@workspace_name && name) ? (@workspace_name.match(name) || name) : name
    end

    # @raise [Workspace::Error] code `unknown_workspace` when no config exists for +name+ (ignoring case)
    def require_known_workspace!(name)
      return if @project_config.existing_name(name)

      raise Error.new("Unknown workspace '#{name}': it has no config. See `workspace list`, or create one with `workspace add PATH` (`workspace add .` for this directory).",
        code: "unknown_workspace", details: {"name" => name})
    end

    # The directory a per-workspace command acts from: the named workspace's
    # root for `--name`, else the detected working directory.
    #
    # @param name [String, nil] value of `--name`
    # @return [String]
    # @raise [Workspace::Error] code `unknown_workspace` when no such workspace exists
    def working_dir_for(name)
      return @working_dir unless name

      root = @project_config.project_root_for(name)
      raise Error.new("Unknown workspace '#{name}'", code: "unknown_workspace", details: {"name" => name}) unless root

      File.expand_path(root)
    end

    # Whether `--json` or `--json-envelope` appears as its own argument before a bare `--`.
    #
    # @param argv [Array<String>]
    def json_flag?(argv)
      argv.take_while { |arg| arg != "--" }.any? { |arg| arg == "--json" || arg == "--json-envelope" }
    end

    def resolve_claude_targets(args, all, parser)
      if all
        @state.load
        @state.keys
      else
        project = settle_name(args.first) || @project_detector.detect(@working_dir)
        raise UsageError, parser.help unless project
        [project]
      end
    end

    def main_help
      @output.puts <<~HELP
        Usage: workspace <subcommand> [options]

        Subcommands:
          add             Add a tmuxinator config for a project directory
          agent           Drive a workspace agent: agent run "prompt", agent status request|post
          agentd          Run the long-lived workspace agent daemon for a project, or replace it (agentd restart)
          agent-run       Send a message to a running agent, or type into a pane (command, inject, restart, send)
          alfred          Manage the Alfred workflow for workspace focus
          ask             Record a question an unattended agent hit, with its default
          binding         Bind a pane to a workflow run, a PR review or a play, so it survives /clear and compaction
          capabilities    Print what this CLI supports, as feature revisions (for scripts and the UI)
          capture         Print a tmux pane's scrollback buffer to stdout
          cleanup         Detect and remove zombie sessions from state (--dry-run reports only)
          config          Show, validate, set, get, unset, edit or describe (keys) project or global configuration
          current         Print the workspace project name for the current directory
          daemon          List, show, restart (one or all) or read the log of agent daemons
          dev             Start, stop, or inspect this repo's dev environment (devenv lock)
          deactivate      Deactivate Claude in a project's tmux pane (sends Ctrl-C)
          dir             Print the root directory of a workspace project
          doctor          Check that all required dependencies are installed
          event-log       Show or compact the event log (state changes and agent activity)
          events          Read or follow the event log and every agent's hook events as one stream
          finish          Verify a worktree is clean and pushed, then remove it (optionally opens a PR)
          focus           Bring a project's iTerm window to the front (not for headless projects)
          handoff         Check context usage and hand off to a fresh conversation
          help            Show this help message
          init            Install tmuxinator templates and create config directory
          inbox           Keep a durable list of things that need a person: add, list, show, edit, done, dismiss, reopen
          instructions    Print the instructions built from library packs (binding, orchestrator, commits, review, notes, handoff, dev, implementation-plan, research, spine, promote)
          kill            Kill a worktree project and remove its worktree (auto-detects from cwd)
          launch          Launch tmuxinator projects in iTerm windows, or headless in plain tmux
          layout          Save/restore tmux pane layouts (auto-saved before resize)
          library         Store named plays, prompts, agents and skills, beside the built-in packs (alias: lib)
          list            List currently active (launched) projects (--all for all available)
          lock            Acquire, release, inspect, or clear a shared repo-wide lock
          lookup          Find a workspace project by worktree path, branch, or project name
          notes           Print where a workspace's notes are kept (dir)
          parent          Print the parent workspace of the current (or given) workspace
          plan            Show and run a workspace's plan (IMPLEMENTATION_PLAN.md): status, path, show, init, start, pause, delete
          pipeline        Deprecated (use workflow): inspect and drive a project's agent pipeline
          pr              Open a pull request for a workspace's branch without finishing it (create)
          projects        Group workspaces by repository (main checkout + worktrees); name several repositories as a group
          promote         Move the work in a main checkout (changes and branch commits) into a new worktree workspace
          prune           Remove worktree projects whose PR is closed or merged
          push            Push a workspace's branch to origin, forcing with a lease only after a rebase
          reactivate      Reactivate Claude in a project's tmux pane
          rebase          Rebase a workspace's branch onto the default branch (--onto local|update|remote|upstream)
          relaunch        Stop and relaunch all active workspace projects
          remove          Forget a stopped project: delete its generated config and state (your files stay)
          repair          Rebuild state from live iTerm windows
          resize          Resize tmux panes for a running project
          restore         Bring back agent panes after a reboot: recreate them and resume their sessions
          run             Send a shell command to a pane in a running project's tmux session
          run-and-report  Run a command as a subprocess, capture stdout/stderr/exit status
          report-run-status  Internal: write run result for --wait (called by shell wrapper)
          hooks           Remove workspace's hooks from a coding agent's settings (hooks uninstall)
          session-event   Forward one agent hook event to its daemon (installed by init)
          review          Show a workspace's finished work for review, or list the ones ready
          sessions        Show coding-agent sessions and sub-agents in a workspace
          snapshot        Print everything a UI polls (projects, panes, git, asks, locks, dev) as one JSON document
          step            For the agent on a workflow step: report on it (done), or see what it is (status)
          spine           Read and set a workspace's stages (stage files in spine/ in its notes directory): show, init, set a stage's status, tick its checklist, record a check verdict (verify), start an agent on a stage
          start           Create a worktree and launch it (from JIRA key, PR URL or #n, or branch)
          status          Show detailed state of tracked launcher sessions
          set-command     Set the shell command for a pane in a project config (--pane <N>)
          statusline      Render Claude Code's status line (install as its statusLine command)
          stop            Stop active workspace projects and their tmux sessions
          ticket          Look up a ticket (JIRA key, pull request, issue or branch) the way start reads it (show), or list yours (list)
          tile            Tile all windows for a project across the screen
          tmux            Show a workspace's tmuxinator file as windows and panes (tmux show --json)
          ui              Open a workspace-ui:// link: a task, a review, notes or the inbox
          wait-until-content  Block until a pane shows content, then exec a command
          whereis         Print the workspace installation directory
          workflow        Run a workflow (ordered steps, e.g. rpiv) in a workspace's agent pane, and see where it stands

        Global options:
          --debug         Print detailed debug output to stderr
          --no-input      Never wait for an answer: a prompt fails with code confirmation_required
                          (with --json, an error document naming the prompt and the flag that
                          answers it). Same as WORKSPACE_NO_INPUT=1.

        Run 'workspace <subcommand> --help' for subcommand-specific help.

        Environment variables:
          WORKSPACE_DEBUG   Enable debug output (same as --debug)
          WORKSPACE_NO_INPUT  Fail prompts instead of asking (same as --no-input; empty, 0 and false mean off)
      HELP
    end

    def cmd_launch(args)
      reattach = false
      headless = nil
      prompt = nil
      prompt_timeout = nil
      play = nil
      packs = []
      no_packs = false
      handoff = nil
      arrange = false
      json = false
      parser = OptionParser.new do |opts|
        opts.banner = "Usage: workspace launch [options] <project1> [project2] ..."
        opts.separator ""
        opts.separator "Launch tmuxinator projects in iTerm2, each in its own window."
        opts.separator "Reuses existing launcher panes when available."
        opts.separator "Windows are arranged left-to-right with slight overlap."
        opts.separator ""
        opts.separator "Options:"
        opts.on("--reattach", "Reuse a launcher pane's existing tmux session instead of relaunching",
          "into it (see docs/README.launch.md).") do
          reattach = true
        end
        opts.on("--[no-]headless", "Start each session in the background with plain tmux: no iTerm2,",
          "AppleScript or window-tool. Default: the launch.headless config key if set,",
          "else headless when not on macOS, when osascript is missing, or when CI is set") do |v|
          headless = v
        end
        opts.on("--prompt PROMPT", "Send an initial prompt to the coding agent in each project, once it is",
          "ready (up to #{AgentReadiness::DEFAULT_TIMEOUT}s); exits 1 if it can't be sent") do |p|
          prompt = p
        end
        opts.on("--prompt-timeout DURATION", "How long to wait for the coding agent to be ready for --prompt",
          "(e.g. \"90s\", or a plain number of seconds); default #{AgentReadiness::DEFAULT_TIMEOUT}s") do |v|
          prompt_timeout = parse_duration_option("--prompt-timeout", v, positive: true)
        end
        opts.on("--play NAME", "Send each project's agent 'Read \"<path>\" and follow it.' for a library play,",
          "then any --prompt text. Looked up per project (its library, then global);",
          "an unknown or unreadable play fails before anything launches") do |v|
          play = v
        end
        opts.on("--pack NAME", "Also send the agent a library pack's text with the first prompt (repeatable; see",
          "'workspace instructions compose --help'). An unknown pack fails before anything launches") do |v|
          packs << v
        end
        opts.on("--no-packs", "Send no automatic packs (the notes pack, unless notes.instructions is false;",
          "the spine pack, when spine/ exists; the dev pack, when dev.up is set; the handoff pack, when handoff.auto is true);",
          "cannot be combined with --pack") do
          no_packs = true
        end
        opts.on("--[no-]handoff", "Send (or never send) the handoff pack, whatever handoff.auto says. It makes a Claude",
          "Code or Codex agent run 'workspace handoff check' after every task. --handoff for a project",
          "whose main agent is neither fails before anything launches (handoff_unsupported_agent)") do |v|
          handoff = v
        end
        opts.on("--arrange", "Tile the new windows, ignoring the window positions saved when they were",
          "stopped (launch.restore_window_position false does the same on every launch)") do
          arrange = true
        end
        opts.on("--json", "Print one action document (see docs/README.json.md) instead of progress text;",
          "the text goes to stderr. Exit 0, 3 when some projects failed, 1 when all did") do
          json = true
        end
        opts.separator ""
        opts.separator "Headless: a session already running is reused as it is; attach with"
        opts.separator "'tmux attach -t <session>'. --reattach has no effect headless."
        opts.separator ""
        opts.separator "Note: --reattach uses tmux -CC attach which may trigger an iTerm dialog."
        opts.separator "To suppress it, set iTerm > Settings > General > tmux >"
        opts.separator "  'When attaching, restore windows' to 'Always'."
        opts.separator ""
        opts.separator "A directory path creates a config named in lowercase. A name that differs only"
        opts.separator "in case from another workspace's is refused (workspace_name_case_conflict); the"
        opts.separator "same directory's mixed-case config is reused."
        opts.separator ""
        opts.separator "Examples:"
        opts.separator "  workspace launch my-project    # launch one project by name"
        opts.separator "  workspace launch my-notes work-notes billing    # launch several projects"
        opts.separator "  workspace launch ~/Code/my-project    # launch from a directory path (creates a config)"
        opts.separator "  workspace launch --reattach my-project    # reuse the pane's existing tmux session"
        opts.separator "  workspace launch --arrange my-project    # tile the window, ignoring its saved position"
        opts.separator "  workspace launch --prompt \"Review the README\" my-project    # send the agent an initial prompt"
        opts.separator "  workspace launch --play kickoff my-project    # point the agent at a library play"
      end
      parser.parse!(args)

      raise UsageError, parser.help if args.empty?
      raise UsageError, "--no-packs cannot be combined with --pack." if no_packs && packs.any?
      raise UsageError, "--no-packs cannot be combined with --handoff." if no_packs && handoff == true

      run_action("launch", json: json) do
        launched = launch_projects(args, reattach: reattach, headless: headless, prompt: prompt, prompt_timeout: prompt_timeout, play: play,
          packs: packs, no_packs: no_packs, handoff: handoff, with_packs: true, arrange: arrange)
        {exit_code: launched[:exit_code], results: json ? launch_rows(launched[:projects], launched[:result], plays: launched[:plays], packs: launched[:packs], skipped_packs: launched[:skipped_packs], prompts: launched[:prompts]) : [],
         warnings: launched[:skipped_packs].values.flatten.map { |pack| pack["message"] } + (launched[:result]&.dig(:skipped_prompts) || {}).values + (launched[:result]&.dig(:warnings) || [])}
      end
    end

    # Launches the given project args (already parsed, no leading flags) and
    # returns `{exit_code:, projects:, result:, plays:, packs:}` (the project names,
    # Launch's own result, each project's resolved play, and each project's
    # composed packs) without exiting -- so callers with multiple batches to run
    # (e.g. cmd_relaunch) can attempt every batch before deciding whether to exit.
    # A play and the packs are resolved for every project before any config is
    # created. Packs are sent only when +with_packs+ is true (`launch` itself), so
    # `relaunch` and `restore` do not type them into an agent again.
    def launch_projects(args, reattach: false, headless: nil, prompt: nil, prompt_timeout: nil, play: nil, packs: [], no_packs: false, handoff: nil, with_packs: false, arrange: false)
      # A mixed-case workspace is renamed to lowercase before anything is keyed on its name
      # (see NameMigration), as its agent daemon would rename it once started.
      resolved = args.map { |arg| @project_config.resolve_project_arg(arg) }
        .map { |name, root| [settle_launch_name(name), root] }
      plays = play ? resolved.to_h { |name, root| [name, resolve_play(play, root || @project_config.project_root_for(name))] } : {}
      composed = with_packs ? compose_launch_packs(resolved, packs, no_packs, handoff) : {}
      skipped_packs = composed.transform_values { |c| c["skipped"] || [] }.reject { |_, skipped| skipped.empty? }
      composed = composed.reject { |_, c| c["packs"].empty? }
      skipped_packs.each_value { |skipped| skipped.each { |pack| @error_output.puts "Warning: #{pack["message"]}" } }
      projects = resolved.map { |name, root| root ? @project_config.create(name, root) : name }

      prompts = projects.each_with_object({}) do |p, h|
        text = (plays[p] || composed[p]) ? @library.play_prompt(plays[p], prompt, packs: composed[p]&.fetch("text")) : prompt
        h[p] = text if text
      end

      call_options = {reattach: reattach, prompts: prompts}
      pane_bindings = projects.to_h do |name|
        names = composed[name] ? InstructionComposer.pack_names(composed[name]["packs"]) : []
        [name, plays[name] ? @library.play_binding(plays[name], packs: names) : (@library.packs_binding(names) if names.any?)]
      end.compact
      call_options[:bindings] = pane_bindings if pane_bindings.any?
      call_options[:report_panes] = true if composed.any? || prompts.any?
      optional = composed.select { |name, c| InstructionComposer.optional_prompt?(c, prompt: prompt, play: plays[name]) }
      call_options[:optional] = optional.transform_values { |c| InstructionComposer.pack_names(c["packs"]) } if optional.any?
      call_options[:prompt_timeout] = prompt_timeout if prompt_timeout
      call_options[:headless] = true if @launch_mode.resolve(headless).headless?
      call_options[:arrange] = true if arrange
      result = @launch_command.call(projects, **call_options)

      projects.each do |p|
        @project_settings.ensure_exists(p)
        @hook_runner.run(p, "post_launch")
      end
      {exit_code: result && result[:exit_code], projects: projects, result: result, plays: plays, packs: composed, skipped_packs: skipped_packs, prompts: prompts}
    end

    # The lowercase name once a mixed-case workspace is renamed; the name as
    # given when nothing was renamed, or its agent daemon is running.
    def settle_launch_name(name)
      result = @name_migration&.call_locked(name)
      return name unless result

      result.warnings.each { |warning| @error_output.puts "Warning: #{warning}" }
      result.from ? result.name : name
    end

    # The packs `launch` sends each project, from its root's library and config; a
    # project with none has no entry. An unknown pack fails before any config is created.
    def compose_launch_packs(resolved, packs, no_packs, handoff = nil)
      resolved.each_with_object({}) do |(name, root), composed|
        cwd = root || @project_config.project_root_for(name)
        next if cwd.nil? && packs.empty? && handoff != true
        if @instruction_composer.nil?
          raise Error, "--pack is not available: no library was wired." if packs.any?
          raise Error, "--handoff is not available: no library was wired." if handoff == true
          next
        end
        result = @instruction_composer.compose_start(cwd: cwd || @working_dir, packs: packs, none: no_packs, handoff: handoff)
        composed[name] = result unless result["packs"].empty? && result["skipped"].to_a.empty?
      end
    end

    # The play `launch --play` sends one project, from its root's library, then global.
    def resolve_play(play, root)
      raise Error, "--play is not available: no library was wired." unless @library
      @library.play(play, cwd: root)
    end

    # One `results` row per launched project, from the state Launch wrote.
    def launch_rows(projects, result, ok_outcome: "launched", plays: {}, packs: nil, skipped_packs: {}, prompts: {})
      @state.load
      reused = result&.dig(:reused) || []
      prompt_failures = result&.dig(:prompt_failures) || {}
      start_failures = result&.dig(:start_failures) || {}
      projects.map do |project|
        entry = @state[project]
        sent = !result.nil? && !entry.nil? && !prompt_failures.key?(project) && !start_failures.key?(project)
        skipped = result&.dig(:skipped_prompts)&.key?(project)
        details = {iterm_window_id: entry.is_a?(Hash) ? entry["iterm_window_id"] : nil, headless: entry.is_a?(Hash) && entry["headless"] == true}
        prompt_sent = prompts[project] ? (sent && !skipped) : nil
        details[:position] = result&.dig(:positions, project)
        details[:prompt_sent] = prompt_sent
        details[:pane] = prompt_sent ? result&.dig(:delivered_panes, project) : nil
        if plays[project]
          details[:play] = plays[project].merge("delivered" => sent,
            "pane" => result&.dig(:bound_panes, project))
        end
        if packs
          details[:packs] = InstructionComposer.delivery_rows(packs[project] ? packs[project]["packs"] : [], delivered: sent && !skipped,
            pane: result&.dig(:delivered_panes, project), skipped: skipped_packs[project] || [])
        end
        if start_failures[project]
          action_row(project, "failed", reason: "session_not_started", message: start_failures[project].to_s, **details)
        elsif entry.nil?
          action_row(project, "failed", reason: "not_launched", message: "No state was recorded for '#{project}'.", **details)
        elsif prompt_failures[project]
          action_row(project, "failed", reason: "prompt_not_sent", message: prompt_failures[project].to_s, **details)
        else
          action_row(project, reused.include?(project) ? "reused" : ok_outcome, **details)
        end
      end
    end

    def cmd_start(args)
      prompt = nil
      prompt_timeout = nil
      base = nil
      yes = false
      headless = nil
      json = false
      title = nil
      play = nil
      packs = []
      no_packs = false
      handoff = nil
      agents = []
      skills = []
      no_launch = false
      spine = nil
      no_spine = false
      plan = nil
      agent_kind = nil
      title_from_ticket = false
      slug = false
      parser = OptionParser.new do |opts|
        opts.banner = "Usage: workspace start [options] <jira-key|jira-url|pr-url|pr-ref|branch>"
        opts.separator ""
        opts.separator "Create a git worktree and launch it as a workspace project."
        opts.separator ""
        opts.separator "Accepts:"
        opts.separator "  PROJ-123                                  JIRA issue key (used as branch name)"
        opts.separator "  https://mycompany.atlassian.net/.../123   JIRA URL (extracts issue key)"
        opts.separator "  https://github.com/.../pull/471           GitHub PR URL (works for PRs from forks)"
        opts.separator "  '#471', owner/repo#471                    GitHub PR ref ('#n' is a PR of the current repo; quote it,"
        opts.separator "                                            or your shell treats # as a comment)"
        opts.separator "  https://github.com/.../issues/123         GitHub issue URL (branch: issue-123)"
        opts.separator "  user/PROJ-123                             Branch name (used as-is)"
        opts.separator ""
        opts.separator "Options:"
        opts.on("--prompt PROMPT", "Send an initial prompt to the coding agent once it is ready",
          "(up to #{AgentReadiness::DEFAULT_TIMEOUT}s); exits 1 if it can't be sent") do |p|
          prompt = p
        end
        opts.on("--prompt-timeout DURATION", "How long to wait for the coding agent to be ready for --prompt",
          "(e.g. \"90s\", or a plain number of seconds); default #{AgentReadiness::DEFAULT_TIMEOUT}s") do |v|
          prompt_timeout = parse_duration_option("--prompt-timeout", v, positive: true)
        end
        opts.on("--play NAME", "Send the agent 'Read \"<path>\" and follow it.' for a library play,",
          "then any --prompt text. Looked up in the project's library, then global;",
          "an unknown or unreadable play fails before the worktree is created") do |v|
          play = v
        end
        opts.on("--pack NAME", "Also send the agent a library pack's text with the first prompt (repeatable; see",
          "'workspace instructions compose --help'). An unknown pack fails before the worktree is created") do |v|
          packs << v
        end
        opts.on("--no-packs", "Send no automatic packs (the notes pack, unless notes.instructions is false;",
          "the spine pack, when spine/ exists; the dev pack, when dev.up is set; the handoff pack, when handoff.auto is true);",
          "cannot be combined with --pack") do
          no_packs = true
        end
        opts.on("--[no-]handoff", "Send (or never send) the handoff pack, whatever handoff.auto says. It makes a Claude",
          "Code or Codex agent run 'workspace handoff check' after every task. --handoff for a project",
          "whose main agent is neither fails before the worktree is created (handoff_unsupported_agent)") do |v|
          handoff = v
        end
        opts.on("--agent NAME", "Copy a library agent into the worktree's .claude/agents/ (repeatable).",
          "Listed in the repo's info/exclude; a file the repo tracks there is kept") do |v|
          agents << v
        end
        opts.on("--skill NAME", "Copy a library skill directory into the worktree's .claude/skills/",
          "(repeatable), the same way. Unknown names fail before the worktree is created") do |v|
          skills << v
        end
        opts.on("--agent-kind KIND", "The coding agent the main agent pane runs: #{AgentProvider.all.map(&:key).join(", ")}.",
          "Named -kind because --agent copies a library agent. Applies to a config this run",
          "writes (default claude); an unknown kind fails before anything is created") do |v|
          agent_kind = v
        end
        opts.on("--no-launch", "Create the worktree, config and task and start nothing; run",
          "`workspace launch` later. Cannot be combined with --prompt, --prompt-timeout, --play,",
          "or --pack or --handoff; the automatic packs are not sent") do
          no_launch = true
        end
        opts.on("--spine=[NAME]", "Run 'workspace spine init' once the worktree exists, before the first prompt, so the agent",
          "gets the spine pack. NAME is the template (default: the spine.template config, else default).",
          "Overrides spine.auto; a failed init is a warning, not an error. Give the name with an '=':",
          "write --spine=team ('--spine team' would take 'team' as the ref)") do |v|
          spine = v || true
        end
        opts.on("--no-spine", "Do not run 'workspace spine init', even when spine.auto is true") do
          no_spine = true
        end
        opts.on("--plan=[TITLE]", "Run 'workspace plan init' in the new worktree (TITLE, else the task title) and send the",
          "implementation-plan play with the first prompt, so the agent drafts the plan's tasks. --prompt becomes",
          "the goal (without it, the plan's title). A plan already there is kept. With --no-launch the plan is made and nothing is sent.",
          "Cannot be combined with --play. Give the title with an '=': write --plan=\"Add SSO\"") do |v|
          plan = v || true
        end
        opts.on("--base REF", "Branch/ref to create a new branch from, instead of prompting") do |v|
          base = v
        end
        opts.on("--title TITLE", "A human title for the workspace's task; it labels the agent panes in",
          "`workspace sessions --json`. The panes also get WORKSPACE_TASK=<task id>") do |v|
          title = v
        end
        opts.on("--title-from-ticket", "Use the ticket's title (gh or jira) as the task title when --title is not given.",
          "A ticket that cannot be read is a warning, not an error") do
          title_from_ticket = true
        end
        opts.on("--slug", "Add the title's words to the branch of a JIRA or issue ref (PROJ-123-fix-login,",
          "issue-42-fix-login). Takes the words from --title, else from the ticket (implies --title-from-ticket).",
          "A worktree already made for the plain branch is reused") do
          slug = true
        end
        opts.on("--yes", "Accept every default instead of prompting (e.g. the default base branch)") do
          yes = true
        end
        opts.on("--[no-]headless", "Start the session in the background with plain tmux: no iTerm2,",
          "AppleScript or window-tool (see 'workspace launch --help' for the default)") do |v|
          headless = v
        end
        opts.on("--json", "Emit the documented JSON schema instead of plain text (see docs/README.start.md);",
          "never prompts (see --base/--yes). Only the JSON goes to stdout; progress/warnings",
          "go to stderr or the warnings field (docs/README.start.md)") do
          json = true
        end
        opts.separator ""
        opts.separator "The worktree is created in .worktrees/ under the project root (when run from"
        opts.separator "inside a linked worktree, the parent repo's root is used)."
        opts.separator "A pull request is checked out with `gh pr checkout --worktree` as branch pr-<n>"
        opts.separator "in .worktrees/pr-<n>, so PRs from forks work (needs a recent `gh`)."
        opts.separator "Never blocks on stdin when stdin isn't a TTY: pass --base/--yes, or it exits with"
        opts.separator "a usage error naming the flag it needed."
        opts.separator ""
        opts.separator "Examples:"
        opts.separator "  workspace start PROJ-123    # from a JIRA issue key (used as the branch name)"
        opts.separator "  workspace start feature/my-feature    # from an existing branch name"
        opts.separator "  workspace start '#471'    # check out PR 471 of the current repo, fork or not"
        opts.separator "  workspace start PROJ-123 --prompt \"Fix the login bug\"    # with an initial agent prompt"
        opts.separator "  workspace start PROJ-123 --play kickoff --prompt \"Start at step 2.\"    # point the agent at a library play"
        opts.separator "  workspace start PROJ-123 --agent reviewer --skill write-tests    # copy library entries into the worktree"
        opts.separator "  workspace start PROJ-123 --agent-kind codex    # the main agent pane runs Codex"
        opts.separator "  workspace start PROJ-123 --no-launch    # create the worktree and config, launch nothing"
        opts.separator "  workspace start PROJ-123 --spine=team    # also make the stages from the 'team' template"
        opts.separator "  workspace start PROJ-123 --plan --prompt \"Add SSO login\"    # the agent drafts a plan for that goal first"
        opts.separator "  workspace start PROJ-123 --title \"Fix the login bug\"    # name the task shown in `workspace sessions`"
        opts.separator "  workspace start PROJ-123 --slug    # branch and task title from the ticket: PROJ-123-fix-the-login-bug"
        opts.separator "  workspace start PROJ-123 --headless --yes --json    # non-interactive, e.g. from CI"
        opts.separator "  workspace start PROJ-123 --base main --yes --json    # non-interactive, branch from main, not the default base"
      end
      parser.parse!(args)

      if args.empty?
        raise UsageError, parser.help unless json
        return emit_json_usage_error(Workspace::Commands::Start::JSON_SCHEMA_VERSION, parser.help.lines.first.strip)
      end

      start_options = {prompt: prompt, prompt_timeout: prompt_timeout, base: base, yes: yes, json: json}
      start_options[:title] = title if title
      start_options[:play] = play if play
      raise UsageError, "--no-packs cannot be combined with --pack." if no_packs && packs.any?
      start_options[:packs] = packs if packs.any?
      start_options[:no_packs] = true if no_packs
      raise UsageError, "--no-packs cannot be combined with --handoff." if no_packs && handoff == true
      start_options[:handoff] = handoff unless handoff.nil?
      start_options[:agents] = agents if agents.any?
      start_options[:skills] = skills if skills.any?
      start_options[:no_launch] = true if no_launch
      raise UsageError, "--spine cannot be combined with --no-spine." if spine && no_spine
      start_options[:spine] = false if no_spine
      start_options[:spine] = spine if spine
      start_options[:plan] = plan if plan
      start_options[:agent_kind] = agent_kind if agent_kind
      start_options[:title_from_ticket] = true if title_from_ticket
      start_options[:slug] = true if slug
      start_options[:headless] = true if @launch_mode.resolve(headless).headless?
      result = @start_command.call(args.first, **start_options)
      @exit_handler.exit(result[:exit_code]) if result && !result[:exit_code].zero?
      # post_start hook — project name not easily available here,
      # so hooks for start should use post_launch (which fires from Launch)
    rescue OptionParser::ParseError, UsageError => e
      raise unless json_requested?(json, args)
      emit_json_error(Workspace::Commands::Start::JSON_SCHEMA_VERSION, e, message: e.message.lines.first.strip)
    end

    def cmd_stop(args)
      json = false
      parser = OptionParser.new do |opts|
        opts.banner = "Usage: workspace stop [--json] [project1] [project2] ..."
        opts.separator ""
        opts.separator "Stop workspace projects and their tmux sessions."
        opts.separator "If no projects are specified, stops all active workspace projects."
        opts.separator "Projects can be restarted with 'workspace launch'."
        opts.separator ""
        opts.on("--json", "Print one action document (see docs/README.json.md) instead of text, which goes",
          "to stderr; a named project that isn't active gets a not_running row, not a warning") { json = true }
        opts.separator ""
        opts.separator "Examples:"
        opts.separator "  workspace stop    # stop all active projects"
        opts.separator "  workspace stop my-notes    # stop one project"
        opts.separator "  workspace stop my-notes billing    # stop several projects"
      end
      parser.parse!(args)

      run_action("stop", json: json) do
        stopped = json ? @stop_command.call(args, warn_inactive: false) : @stop_command.call(args)
        stopped.each { |p| @hook_runner.run(p, "post_stop") }
        rows = json ? stopped.map { |p| action_row(p, "stopped") } + (args - stopped).map { |p| action_row(p, "not_running", reason: "not_active", message: "'#{p}' is not an active workspace project") } : []
        {results: rows, warnings: @stop_command.warnings}
      end
    end

    def cmd_kill(args)
      force = false
      json = false
      parser = OptionParser.new do |opts|
        opts.banner = "Usage: workspace kill [--json] [project]"
        opts.separator ""
        opts.separator "Kill a worktree project's session and remove its git worktree."
        opts.separator "The inverse of 'workspace start'."
        opts.separator ""
        opts.separator "If no project is specified, detects the current worktree project"
        opts.separator "from a .workspace-project marker file in the working directory."
        opts.separator ""
        opts.separator "Refuses to remove a worktree with uncommitted changes to tracked files"
        opts.separator "or commits that haven't been pushed anywhere (untracked files don't"
        opts.separator "count). --force skips this check along with the confirmation prompt."
        opts.separator ""
        opts.separator "Options:"
        opts.on("-f", "--force", "Skip confirmation, and skip the uncommitted/unpushed-work check") do
          force = true
        end
        opts.on("--json", "Print one action document (see docs/README.json.md) instead of text, which goes",
          "to stderr; a refusal is the error envelope with a retry hint") { json = true }
        opts.separator ""
        opts.separator "Examples:"
        opts.separator "  workspace kill    # kill the current worktree project (auto-detected from cwd)"
        opts.separator "  workspace kill myproject.worktree-PROJ-123    # kill a specific worktree project"
        opts.separator "  workspace kill -f myproject.worktree-PROJ-123    # skip confirmation and the unsaved-work check"
      end
      parser.parse!(args)

      # The hook runs from inside Kill, before the session is killed: kill may
      # be running inside that session, and nothing after the kill would run.
      run_action("kill", json: json) do
        killed = @kill_command.call(args.first, force: force, working_dir: @working_dir) do |project|
          @hook_runner.run(project, "post_kill")
        end
        if !json
          {}
        elsif killed
          extra = @kill_command.dev_stopped ? {dev_stopped: true} : {}
          held = @kill_command.notes_inside_worktree
          if held
            {results: [action_row(killed, "killed", notes_inside_worktree: held, **extra)], warnings: [Workspace::Commands::Kill.notes_sentence(held)]}
          else
            {results: [action_row(killed, "killed", **extra)]}
          end
        else
          {results: [action_row(args.first, "cancelled", reason: "declined", message: "Not confirmed; nothing was removed.")], status: "cancelled"}
        end
      end
    end

    def cmd_finish(args)
      pr = false
      json = false
      parser = OptionParser.new do |opts|
        opts.banner = "Usage: workspace finish [project]"
        opts.separator ""
        opts.separator "Verify a worktree project is clean and fully pushed, then remove it"
        opts.separator "the same way 'workspace kill' does (session, worktree, config, state)."
        opts.separator ""
        opts.separator "If no project is specified, detects the current worktree project"
        opts.separator "from a .workspace-project marker file in the working directory."
        opts.separator ""
        opts.separator "Refuses when the branch has uncommitted changes to tracked files"
        opts.separator "(untracked files don't count), has no upstream, or is ahead of its"
        opts.separator "upstream. There is no override; push or commit first."
        opts.separator ""
        opts.separator "Options:"
        opts.on("--pr", "Open a PR with `gh pr create --fill` (or reuse an existing one) first;",
          "skipped with a note if `gh` isn't installed") do
          pr = true
        end
        opts.on("--json", "Emit the documented JSON schema instead of plain text (see docs/README.finish.md)") do
          json = true
        end
        opts.separator ""
        opts.separator "Examples:"
        opts.separator "  workspace finish    # finish the current worktree project (auto-detected from cwd)"
        opts.separator "  workspace finish --pr    # open (or reuse) a PR first"
        opts.separator "  workspace finish myproject.worktree-PROJ-123 --json    # scripted; JSON on stdout"
      end
      parser.parse!(args)

      if json
        # No post_kill hook here: its output would land on stdout next to the JSON.
        result = @finish_command.call(args.first, pr: pr, json: true, working_dir: @working_dir)
        @exit_handler.exit(result[:exit_code]) unless result[:exit_code].zero?
        return
      end
      @finish_command.call(args.first, pr: pr, json: false, working_dir: @working_dir) do |project|
        @hook_runner.run(project, "post_kill")
      end
    rescue OptionParser::ParseError, UsageError => e
      raise unless json_requested?(json, args)
      emit_json_error(Workspace::Commands::Finish::JSON_SCHEMA_VERSION, e, message: e.message.lines.first.strip)
    end

    def cmd_focus(args)
      shake = false
      highlight = false
      highlight_color = "green"
      json = false
      pane = nil
      cycle = false
      reverse = false
      parser = OptionParser.new do |opts|
        opts.banner = "Usage: workspace focus [options] [project]"
        opts.separator ""
        opts.separator "Bring the project's iTerm window to the front."
        opts.separator "Auto-detects the project from the current directory if not specified."
        opts.separator ""
        opts.separator "Options:"
        opts.on("--shake", "Shake the window after focusing") do
          shake = true
        end
        opts.on("--highlight", "Highlight the window after focusing") do
          highlight = true
        end
        opts.on("--color COLOR", "Color for highlight (default: green)",
          "Colors: red, green, blue, yellow, orange, purple, white, cyan, magenta, random") do |c|
          highlight_color = c
        end
        opts.on("--pane PANE", "Also select this pane once the window is up front: a pane id (%19) or",
          "window.pane (0.1). Must belong to the project's tmux session") { |v| pane = v }
        opts.on("--cycle", "Focus the next tracked project with a live window, by name, after the one in front") { cycle = true }
        opts.on("--reverse", "With --cycle, go to the previous one") { reverse = true }
        opts.on("--json", "Print one action document (see docs/README.json.md) instead of text, which goes to stderr") { json = true }
        opts.separator ""
        opts.separator "Examples:"
        opts.separator "  workspace focus    # focus the current directory's project"
        opts.separator "  workspace focus my-notes --pane %19    # focus the window and select pane %19"
        opts.separator "  workspace focus my-notes    # focus a specific project"
        opts.separator "  workspace focus --shake my-notes    # shake the window after focusing"
        opts.separator "  workspace focus --highlight my-notes    # highlight the window green (default)"
        opts.separator "  workspace focus --highlight --color blue my-notes    # highlight in another color"
        opts.separator "  workspace focus --cycle    # focus the next workspace window; repeat to keep going"
        opts.separator "  workspace focus --cycle --reverse    # go the other way"
      end
      parser.parse!(args)

      raise UsageError, "--reverse needs --cycle\n\n#{parser.help}" if reverse && !cycle
      if cycle
        raise UsageError, "--cycle takes no project; it picks one\n\n#{parser.help}" if args.any?
        raise UsageError, "--cycle can't be combined with --pane\n\n#{parser.help}" if pane
        return run_action("focus", json: json) do
          project = @focus_command.cycle(reverse: reverse, shake: shake, highlight: highlight ? highlight_color : nil)
          @hook_runner.run(project, "post_focus")
          if json
            @state.load
            {results: [action_row(project, "focused", iterm_window_id: @state.dig(project, "iterm_window_id"))]}
          else
            {}
          end
        end
      end

      project = settle_name(args.first) || @project_detector.detect(@working_dir)
      raise UsageError, parser.help unless project

      run_action("focus", json: json) do
        focused_pane = @focus_command.call(project, shake: shake, highlight: highlight ? highlight_color : nil, pane: pane)
        @hook_runner.run(project, "post_focus")
        if json
          @state.load
          row = action_row(project, "focused", iterm_window_id: @state.dig(project, "iterm_window_id"))
          row["pane"] = focused_pane if pane
          {results: [row]}
        else
          {}
        end
      end
    end

    def cmd_tile(args)
      all = false
      parser = OptionParser.new do |opts|
        opts.banner = "Usage: workspace tile [options] [project]"
        opts.separator ""
        opts.separator "Tile all active windows for a project across the screen."
        opts.separator "Auto-detects the project from the current directory if not specified."
        opts.separator "Matches the base project and all its worktree sessions."
        opts.separator ""
        opts.separator "Options:"
        opts.on("--all", "Tile all active workspace projects") { all = true }
        opts.separator ""
        opts.separator "Example:"
        opts.separator "  workspace tile window-tool    # tiles window-tool + all window-tool.worktree-* windows"
        opts.separator "  workspace tile --all          # tiles all active workspace windows"
      end
      parser.parse!(args)

      if all
        @tile_command.call_all
      else
        project = settle_name(args.first) || @project_detector.detect(@working_dir)
        raise UsageError, parser.help unless project
        @tile_command.call(project)
      end
    end

    def cmd_resize(args)
      parser = OptionParser.new do |opts|
        opts.banner = "Usage: workspace resize [project] <pane-spec>"
        opts.separator ""
        opts.separator "Resize tmux panes for a running workspace project."
        opts.separator ""
        opts.separator "Pane spec is a comma-separated list of sizes, one per pane:"
        opts.separator "  Rows:       10 or 10h     (absolute row count)"
        opts.separator "  Percentage: 50%           (percentage of window height)"
        opts.separator "  Skip:       (empty)       (leave pane as-is)"
        opts.separator ""
        opts.separator "Examples:"
        opts.separator "  workspace resize myproject 15%,,35%      # pane 0=15%, skip 1, pane 2=35%"
        opts.separator "  workspace resize myproject 10h,80%,20%   # pane 0=10 rows, 1=80%, 2=20%"
        opts.separator "  workspace resize myproject 33%,33%,33%   # equal thirds"
      end
      parser.parse!(args)

      if args.size == 1
        # Could be just a pane spec if we can detect the project
        project = @project_detector.detect(@working_dir)
        if project
          spec = args[0]
        else
          raise UsageError, parser.help
        end
      elsif args.size >= 2
        project = args[0]
        spec = args[1]
      else
        raise UsageError, parser.help
      end

      @resize_command.call(project, spec)

      @hook_runner.run(project, "post_resize")
    end

    def cmd_run(args)
      pane_opt = nil
      bottom = false
      split = false
      vertical = false
      no_enter = false
      focus = false
      dry_run = false
      wait = false
      close = false
      json = false
      pipe_commands = []
      timeout_secs = Workspace::RunResultStore::DEFAULT_TIMEOUT

      parser = OptionParser.new do |opts|
        opts.banner = "Usage: workspace run [project] <command> [options]"
        opts.separator ""
        opts.separator "Send a shell command to a pane in a running project's tmux session."
        opts.separator "Defaults to the bottommost pane. Auto-detects project from cwd if omitted."
        opts.separator ""
        opts.separator "Options:"
        opts.on("--pane N", String,
          "Target pane: zero-based index, 'window.pane' (e.g. '0.1', as shown by 'workspace sessions'), a tmux pane id (e.g. '%19', from 'workspace sessions --json'), 'bottom', or a title substring (e.g. 'Claude Code')") do |n|
          pane_opt = n
        end
        # --bottom is intentionally equivalent to the default. It exists so scripts can
        # state the target pane explicitly rather than relying on an implicit default.
        opts.on("--bottom", "Target the bottommost pane (default behavior)") do
          bottom = true
        end
        opts.on("--split", "Create a new pane below the bottommost and run command there") do
          split = true
        end
        opts.on("--vertical",
          "With --split, split side-by-side (vertical divider) instead of horizontal") do
          vertical = true
        end
        opts.on("--no-enter", "Send command text without pressing Enter") do
          no_enter = true
        end
        opts.on("--focus", "Bring the project's iTerm window to the front after sending") do
          focus = true
        end
        opts.on("--dry-run", "Print the tmux command without executing it") do
          dry_run = true
        end
        opts.on("--wait", "Wait for the command to finish and report exit status, stdout, stderr") do
          wait = true
        end
        opts.on("--timeout N", Integer, "Seconds to wait (default: #{Workspace::RunResultStore::DEFAULT_TIMEOUT}, requires --wait)") do |n|
          timeout_secs = n
        end
        opts.on("--close", "Send 'exit' to the pane after the command runs (closes the shell/pane)") do
          close = true
        end
        opts.on("--pipe CMD", String,
          "Pipe command output into CMD (repeatable for multi-stage pipelines)") do |cmd|
          pipe_commands << cmd
        end
        opts.on("--json", "Print one action document (see docs/README.json.md) naming the pane",
          "(the new pane's id with --split, else null); not with --wait or --dry-run") do
          json = true
        end
        opts.separator ""
        opts.separator "Exit codes: 0 delivered; 1 not delivered, safe to run again; 2 text"
        opts.separator "  landed but wasn't confirmed submitted — do not resend, check the pane first."
        opts.separator ""
        opts.separator "Examples:"
        opts.separator "  workspace run 'rake spec'    # bottommost pane, project auto-detected from cwd"
        opts.separator "  workspace run scooter 'rake spec' --pane 1    # explicit project and pane"
        opts.separator "  workspace run scooter 'tail -f log/development.log' --split    # run in a new pane below"
        opts.separator "  workspace run scooter 'bundle exec rails console' --no-enter    # pre-fill without pressing Enter"
        opts.separator "  workspace run scooter 'rake spec' --wait    # wait for the command and report its result"
      end
      parser.parse!(args)

      if vertical && !split
        raise UsageError, "--vertical requires --split.\n\n#{parser.help}"
      end

      if json && (wait || dry_run)
        raise UsageError, "--json cannot be combined with --wait or --dry-run.\n\n#{parser.help}"
      end

      if wait && no_enter
        raise UsageError,
          "--wait requires the command to be sent with Enter (incompatible with --no-enter).\n\n#{parser.help}"
      end

      if close && no_enter
        raise UsageError,
          "--close sends 'exit' after the command runs, which requires Enter (incompatible with --no-enter).\n\n#{parser.help}"
      end

      if pipe_commands.any? && no_enter
        raise UsageError,
          "--pipe runs a shell pipeline, which requires Enter (incompatible with --no-enter).\n\n#{parser.help}"
      end

      pane = pane_opt || :bottom

      if args.size == 1
        project = @project_detector.detect(@working_dir)
        raise UsageError, parser.help unless project
        command = args[0]
      elsif args.size >= 2
        project = args[0]
        # Join trailing args so `workspace run proj echo hello world` sends the whole
        # command rather than silently dropping everything after the first word.
        command = args[1..].join(" ")
      else
        raise UsageError, parser.help
      end

      if pipe_commands.any?
        # Validate each stage individually — joining first would let unbalanced quotes
        # in one stage cancel out unbalanced quotes in another, masking the error.
        ([command] + pipe_commands).each { |stage| validate_shell_quoting!(stage) }
        command = ([command] + pipe_commands).join(" | ")
      end

      if wait && dry_run
        # Show what --wait would write and send, without writing anything.
        escaped_dir = @config.run_results_dir.gsub("'", "'\\''")
        @output.puts "# <uuid>.cmd contents:"
        @output.puts command
        @output.puts "# <uuid>.sh contents:"
        @output.puts "bash '#{escaped_dir}/<uuid>.cmd' > '#{escaped_dir}/<uuid>.stdout' 2>'#{escaped_dir}/<uuid>.stderr'"
        @output.puts "workspace report-run-status <uuid> $?"
        @output.puts "# pane command: . '#{escaped_dir}/<uuid>.sh'"
        if close
          @output.puts "tmux send-keys -l -t <session>:<pane> exit"
          @output.puts "tmux send-keys -t <session>:<pane> Enter"
        end
        return
      elsif wait
        uuid = SecureRandom.uuid
        @run_result_store.ensure_dir

        @run_command.call(
          project, write_run_script(command, uuid),
          pane: pane,
          split: split,
          vertical: vertical,
          enter: true,
          focus: focus,
          dry_run: false,
          close: close
        )

        result = @run_result_store.wait(uuid, timeout: timeout_secs)

        @output.puts "Exit status: #{result.status}"
        unless result.stdout.empty?
          @output.puts "--- stdout ---"
          @output.print result.stdout
        end
        unless result.stderr.empty?
          @output.puts "--- stderr ---"
          @output.print result.stderr
        end

        @hook_runner.run(project, "post_run")
        @exit_handler.exit(result.status) unless result.status == 0
        return
      end

      run_action("run", json: json) do
        new_pane_id = @run_command.call(
          project, command,
          pane: pane,
          split: split,
          vertical: vertical,
          enter: !no_enter,
          focus: focus,
          dry_run: dry_run,
          close: close
        )

        # --dry-run performs no real work, so post_run hooks must not observe it as a run.
        @hook_runner.run(project, "post_run") unless dry_run
        {exit_code: 0, results: json ? [action_row(project, "started", pane: new_pane_id)] : []}
      end
    end

    # Writes two files and returns the pane command string for --wait:
    #   <uuid>.cmd  — the raw command text (executed via `bash <uuid>.cmd`)
    #   <uuid>.sh   — the wrapper: runs cmd with redirected I/O, then reports status
    #
    # Separating the command from the wrapper means the command is never
    # interpolated inside shell syntax, so single quotes, backslashes, and
    # other shell metacharacters in the command work correctly.
    #
    # Raises UsageError early if the command has unbalanced shell quotes, so the
    # user gets a clear message before anything is written or sent to tmux.
    def write_run_script(command, uuid)
      validate_shell_quoting!(command)

      dir = @config.run_results_dir
      FileUtils.mkdir_p(dir)
      cmd_path = File.join(dir, "#{uuid}.cmd")
      script_path = File.join(dir, "#{uuid}.sh")
      escaped_dir = dir.gsub("'", "'\\''")
      File.write(cmd_path, command)
      File.write(script_path, <<~SH)
        bash '#{escaped_dir}/#{uuid}.cmd' > '#{escaped_dir}/#{uuid}.stdout' 2>'#{escaped_dir}/#{uuid}.stderr'
        workspace report-run-status #{uuid} $?
      SH
      ". '#{escaped_dir}/#{uuid}.sh'"
    end

    def validate_shell_quoting!(command)
      Shellwords.split(command)
    rescue ArgumentError => e
      raise UsageError,
        "Command has invalid shell quoting (#{e.message}).\n" \
        "Hint: if your argument contains single quotes (e.g. \"what's\"), " \
        "wrap it in double quotes instead: echo \"what's up\". " \
        "For unbalanced double quotes, escape the inner ones with backslash: echo \"he said \\\"hello\\\"\"."
    end

    def cmd_capture(args)
      pane_opt = nil
      lines_opt = 100
      all = false

      parser = OptionParser.new do |opts|
        opts.banner = "Usage: workspace capture <project> [options]"
        opts.separator ""
        opts.separator "Read a tmux pane's scrollback buffer and print it to stdout."
        opts.separator "Defaults to the bottommost pane and last 100 lines."
        opts.separator ""
        opts.separator "Options:"
        opts.on("--pane N", String,
          "Target pane: zero-based index, 'window.pane' (e.g. '0.1', from 'workspace sessions'), a tmux pane id (e.g. '%19', from 'workspace sessions --json'), 'bottom', or a title substring (e.g. 'Claude Code')") do |n|
          pane_opt = n
        end
        opts.on("--lines N", Integer,
          "Number of lines from the bottom to capture (default: 100)") do |n|
          lines_opt = n
        end
        opts.on("--all", "Capture full pane history up to tmux history-limit") do
          all = true
        end
        opts.separator ""
        opts.separator "Examples:"
        opts.separator "  workspace capture    # last 100 lines of the bottommost pane, project auto-detected"
        opts.separator "  workspace capture scooter --lines 200    # last 200 lines of an explicit project"
        opts.separator "  workspace capture scooter --all    # full pane history"
        opts.separator "  workspace capture scooter --pane 1    # specific pane by index"
        opts.separator "  workspace capture scooter | grep ERROR    # composable — pipe to other tools"
      end
      parser.parse!(args)

      if lines_opt <= 0
        raise UsageError, "--lines must be a positive integer.\n\n#{parser.help}"
      end

      if all && lines_opt != 100
        raise UsageError, "--all and --lines are mutually exclusive.\n\n#{parser.help}"
      end

      if args.empty?
        project = @project_detector.detect(@working_dir)
        raise UsageError, parser.help unless project
      else
        project = args.first
      end

      pane = pane_opt || :bottom

      @capture_command.call(project, pane: pane, lines: lines_opt, all: all)
    end

    def cmd_wait_until_content(args)
      # Split the command after "--" before optparse sees it: parse! permutes,
      # so option-looking words in the command would be swallowed as options.
      exec_args = []
      if (sep = args.index("--"))
        exec_args = args[(sep + 1)..] || []
        args = args[0...sep]
      end

      pane_opt = nil
      lines_opt = 100
      interval_opt = 0.5
      max_wait_time = nil
      since_start = false
      exec_str = nil

      parser = OptionParser.new do |opts|
        opts.banner = "Usage: workspace wait-until-content [project] \"content\" [options] [-- command...]"
        opts.separator ""
        opts.separator "Poll a tmux pane's scrollback until it contains CONTENT,"
        opts.separator "then exec COMMAND in this process (it takes over the terminal:"
        opts.separator "direct Ctrl-C, untouched STDIN/STDOUT/STDERR)."
        opts.separator ""
        opts.separator "Options:"
        opts.on("--pane N", String,
          "Target pane: zero-based index, 'window.pane' (e.g. '0.1', as shown by 'workspace sessions'), a tmux pane id (e.g. '%19', from 'workspace sessions --json'), 'bottom', or a title substring (e.g. 'Claude Code') (default: bottom)") do |n|
          pane_opt = n
        end
        opts.on("--lines N", Integer,
          "Match against the last N lines of scrollback (default: 100)") do |n|
          lines_opt = n
        end
        opts.on("--interval SECONDS", Float,
          "Seconds between polls (default: 0.5)") do |s|
          interval_opt = s
        end
        opts.on("--max-wait-time SECONDS", Float,
          "Give up after this many seconds (default: wait forever)") do |s|
          max_wait_time = s
        end
        opts.on("--since-start",
          "Only match content written after this command starts") do
          since_start = true
        end
        opts.on("-e CMD", "--exec CMD", String,
          "Shell command to exec on match (a command after -- takes precedence)") do |c|
          exec_str = c
        end
        opts.separator ""
        opts.separator "Examples:"
        opts.separator "  workspace wait-until-content \"Listening on\" -- open http://localhost:3000"
        opts.separator "  workspace wait-until-content scooter \"Ready to accept\" --pane 0 -- bin/console"
        opts.separator "  workspace wait-until-content scooter \"WORKSPACE_DONE\" --pane \"Claude Code\" -- irb"
        opts.separator "  workspace wait-until-content scooter \"namespace is running\" --since-start --max-wait-time 60 -- ./scripts/attach.sh"
        opts.separator "  workspace wait-until-content scooter \"READY\" -e 'echo matched'"
      end
      parser.parse!(args)

      if lines_opt <= 0
        raise UsageError, "--lines must be a positive integer.\n\n#{parser.help}"
      end
      if interval_opt <= 0
        raise UsageError, "--interval must be a positive number.\n\n#{parser.help}"
      end
      if max_wait_time && max_wait_time <= 0
        raise UsageError, "--max-wait-time must be a positive number.\n\n#{parser.help}"
      end

      if args.length == 1
        content = args.first
        project = @project_detector.detect(@working_dir)
        unless project
          raise UsageError,
            "no workspace project detected from the current directory — pass the project name explicitly.\n\n#{parser.help}"
        end
      elsif args.length == 2
        project, content = args
      else
        raise UsageError, parser.help
      end
      if content.nil? || content.empty?
        raise UsageError, "content to match is required.\n\n#{parser.help}"
      end

      # -- args are passed straight through as an argv array (no shell
      # re-quoting); -e/--exec stays a shell string so metacharacters work,
      # but is validated for balanced quoting at parse time.
      exec_command = if exec_args.any?
        exec_args
      elsif exec_str
        validate_shell_quoting!(exec_str)
        exec_str
      end
      if exec_command.nil? || (exec_command.respond_to?(:empty?) && exec_command.empty?)
        raise UsageError, "a command is required — pass one after -- or use -e/--exec.\n\n#{parser.help}"
      end

      status = @wait_until_content_command.call(project, content,
        pane: pane_opt || :bottom,
        lines: lines_opt,
        interval: interval_opt,
        max_wait_time: max_wait_time,
        since_start: since_start,
        exec_command: exec_command)
      @exit_handler.exit(status) unless status == 0
    end

    # Umbrella for driving a workspace's agent. `agent run PROMPT` sends a
    # command message to the agent's pipeline; anything the daemon used to
    # accept falls back to it with a deprecation warning pointing at
    # `workspace agentd`.
    def cmd_agent(args)
      # Help only counts in subcommand position, so a prompt containing the
      # word "help" still sends; `agent --help` (no subcommand) still helps.
      index = agent_subcommand_index(args)
      subcommand = index && args[index]
      rest = index ? args[0...index] + args[(index + 1)..] : args
      # A `--` in subcommand position can only be a terminator, never a
      # value; drop it or run's parser treats every flag after it as
      # prompt text (swallowing safety flags like --dry-run).
      rest.shift if rest.first == "--"

      case subcommand
      when "run" then cmd_agent_run_prompt(rest)
      when "status" then cmd_agent_status(rest)
      when "help" then @output.puts agent_help
      when nil
        if args.include?("--help") || args.include?("-h")
          @output.puts agent_help
        else
          # Daemon-era usage was all-flag (`agent --name myapp`), so a bare
          # all-flag invocation still starts the daemon, with a warning.
          @error_output.puts "`workspace agent` for the daemon is deprecated; use `workspace agentd`"
          cmd_agentd(args)
        end
      else
        raise UsageError, "Unknown agent subcommand: #{subcommand}.\n" \
          "For the daemon, use `workspace agentd`.\n\n#{agent_help}"
      end
    end

    # Finds the index of the `agent` subcommand: the first argument that is
    # neither a flag nor a value-taking flag's value (`--name` and
    # `--wc-socket` take a value; `-f`/`--force` do not).
    def agent_subcommand_index(args)
      i = 0
      while i < args.length
        arg = args[i]
        return i unless arg.start_with?("-")
        i += (arg == "--name" || arg == "--wc-socket") ? 2 : 1
      end
      nil
    end

    def agent_help
      <<~HELP
        Usage: workspace agent <subcommand> [options]

        Subcommands:
          run PROMPT    Send a prompt to the workspace's pipeline (a "command" message)
          status        Ask an agent pane for a status line, or post one (see `agent status --help`)

        The long-lived agent daemon now runs as `workspace agentd`
        (see docs/README.agentd.md). During the deprecation window, daemon-era
        invocations like `workspace agent --name myproject --force` still start
        the daemon, with a warning.

        Options (run):
          --name NAME         Workspace name (default: detected from cwd)
          --work-item REF     Work item reference (default: random UUID)
          --dry-run           Print the message without sending it
          --json              Print one JSON document with the agent's reply; text goes to stderr

        Examples:
          workspace agent run "Add OAuth support"
          workspace agent run --name myapp --work-item WC-42 "Add OAuth support" --dry-run
          workspace agentd myapp    # start the daemon for myapp
      HELP
    end

    def agent_status_help
      <<~HELP
        Usage: workspace agent status request --pane PANE [--name NAME] [--json]
               workspace agent status post --summary TEXT [--task ID] [--progress N/M] [--reply-to ID] [--json]

        Ask an agent pane for a status line, and answer one (see docs/README.agent.md).

        request  Types a fixed line carrying a request id into the pane, asking its agent to run
                 `agent status post --reply-to ID`. Refused (pane_not_ready, nothing typed) unless
                 Claude Code runs there, no permission prompt or question is open, no AskUserQuestion
                 or ExitPlanMode is running, and its input prompt is on screen with no draft in it.
                 Enter is pressed only if the prompt is still there once the line is pasted.
                 One request is open per pane at a time (status_request_open); it expires after
                 #{AgentStatusRequests::DEFAULT_TTL / 60} minutes.
        post     Run by an agent in its own pane ($TMUX_PANE). Logs an agent_status line, shown by
                 `workspace events --follow --types agent_status`. With --reply-to, accepted only from
                 the pane that was asked, while the request is open. The summary is cut to
                 #{AgentStatusDesk::MAX_SUMMARY} characters and never typed anywhere.

        Exit codes: 0 done; 1 refused or failed; 2 (request) the line landed but wasn't confirmed
          submitted: the request stays open, so check the pane before asking again.

        Examples:
          workspace agent status request --name api --pane %19 --json
          workspace agent status post --summary "Writing specs for the parser" --progress 3/7
          workspace agent status post --reply-to sr-0a1b2c3d4e5f --summary "Waiting on CI" --json
      HELP
    end

    def cmd_agent_status(args)
      verb = args.first&.start_with?("-") ? nil : args.shift
      case verb
      when "request" then cmd_agent_status_request(args)
      when "post" then cmd_agent_status_post(args)
      when "help", nil
        unless verb == "help" || args.include?("--help") || args.include?("-h")
          raise UsageError, "Missing agent status verb (request or post).\n\n#{agent_status_help}"
        end
        @output.puts agent_status_help
      else
        raise UsageError, "Unknown agent status verb: #{verb}.\n\n#{agent_status_help}"
      end
    end

    def cmd_agent_status_request(args)
      name = nil
      pane = nil
      json = false
      parser = OptionParser.new do |opts|
        opts.banner = "Usage: workspace agent status request --pane PANE [--name NAME] [--json]"
        opts.separator ""
        opts.separator "Ask the agent in one pane for a status line. The agent daemon types a fixed line"
        opts.separator "carrying a request id; the agent answers with `workspace agent status post --reply-to ID`."
        opts.separator "Nothing is typed unless the pane can take text safely (see `agent status --help`)."
        opts.separator ""
        opts.separator "Options:"
        opts.on("--name NAME", "Workspace name (default: detected from cwd)") { |v| name = v }
        opts.on("--pane PANE", "Pane id (%19) or window.pane (0.1)  (required)") { |v| pane = v }
        opts.on("--json", "Print one JSON document: request_id, pane, pane_id, expires_at, delivery") { json = true }
        opts.separator ""
        opts.separator "Exit codes: 0 typed and submitted; 1 refused or failed; 2 landed but not confirmed submitted."
        opts.separator ""
        opts.separator "Examples:"
        opts.separator "  workspace agent status request --name api --pane %19"
        opts.separator "  workspace agent status request --pane=0.1 --json"
      end
      parser.parse!(args)
      raise UsageError, "Unexpected argument: #{args.first}\n\n#{parser.help}" if args.any?
      name ||= @project_detector.detect(@working_dir)
      raise UsageError, "Missing workspace name (pass --name).\n\n#{parser.help}" if name.nil?
      raise UsageError, "Missing --pane.\n\n#{parser.help}" if pane.nil? || pane.strip.empty?
      raise Error, "workspace agent status is not available in this build" unless @agent_status_command

      @agent_status_command.request(name: name, pane: pane, json: json)
    end

    def cmd_agent_status_post(args)
      summary = nil
      task = nil
      progress = nil
      reply_to = nil
      json = false
      parser = OptionParser.new do |opts|
        opts.banner = "Usage: workspace agent status post --summary TEXT [--task ID] [--progress N/M] [--reply-to ID] [--json]"
        opts.separator ""
        opts.separator "Post this pane's status as an agent_status event line. Run by an agent in its own"
        opts.separator "tmux pane: the pane is $TMUX_PANE and the workspace is the one whose tmux session it is in."
        opts.separator ""
        opts.separator "Options:"
        opts.on("--summary TEXT", "One line on what the agent is doing (required; cut to #{AgentStatusDesk::MAX_SUMMARY} characters)") { |v| summary = v }
        opts.on("--task ID", "The task being worked on") { |v| task = v }
        opts.on("--progress N/M", "Steps done out of the total, e.g. 3/7") { |v| progress = v }
        opts.on("--reply-to ID", "The status request this answers (from the typed line)") { |v| reply_to = v }
        opts.on("--json", "Print one JSON document: the line as logged, plus truncated") { json = true }
        opts.separator ""
        opts.separator "Examples:"
        opts.separator "  workspace agent status post --summary \"Writing specs for the parser\" --task T3 --progress 3/7"
        opts.separator "  workspace agent status post --reply-to=sr-0a1b2c3d4e5f --summary \"Waiting on CI\" --json"
      end
      parser.parse!(args)
      raise UsageError, "Unexpected argument: #{args.first}\n\n#{parser.help}" if args.any?
      raise UsageError, "Missing --summary.\n\n#{parser.help}" if summary.nil? || summary.strip.empty?
      raise UsageError, "--reply-to can't be empty.\n\n#{parser.help}" if reply_to && reply_to.strip.empty?
      raise Error, "workspace agent status is not available in this build" unless @agent_status_command

      @agent_status_command.post(summary: summary, task: task, progress: progress && Commands::AgentStatus.parse_progress(progress),
        reply_to: reply_to&.strip, json: json)
    end

    AGENTD_RUN_FLAGS = %w[-f --force --ensure].freeze

    # `restart` is a subcommand only as the first word that isn't a flag or a
    # flag's value, so `--name restart` still names a workspace. With --force
    # or --ensure, which restart doesn't take, it is the workspace's name, as
    # it was before the subcommand existed (`agentd --ensure restart`).
    def cmd_agentd(args)
      index = agent_subcommand_index(args)
      if index && args[index] == "restart" && (args & AGENTD_RUN_FLAGS).empty?
        return cmd_agentd_restart(args[0...index] + args[(index + 1)..])
      end

      name = nil
      wc_socket = nil
      force = false
      ensure_running = false

      parser = OptionParser.new do |opts|
        opts.banner = "Usage: workspace agentd [PROJECT] [options]\n" \
          "       workspace agentd restart [PROJECT] [--wc-socket PATH] [--json]"
        opts.separator ""
        opts.separator "Run the long-lived workspace agent daemon for a project."
        opts.separator "Registers with the work-coordinator and serves commands until terminated."
        opts.separator ""
        opts.separator "The workspace must already have a config; an unknown name is refused (unknown_workspace)."
        opts.separator "A workspace with a mixed-case name is renamed to lowercase before the agent starts"
        opts.separator "(see docs/README.agentd.md); a step that fails is a warning in the daemon log."
        opts.separator ""
        opts.separator "Subcommands:"
        opts.separator "  restart    Stop the agent running for the workspace and start a new one in the background;"
        opts.separator "             see `workspace agentd restart --help`. A workspace named restart needs --name,"
        opts.separator "             except with --force or --ensure, where restart is the workspace"
        opts.separator ""
        opts.separator "Options:"
        opts.on("--name NAME", "Workspace name (defaults to the detected project or PROJECT)") { |v| name = v }
        opts.on("--wc-socket PATH", "Path to the work-coordinator socket") { |v| wc_socket = v }
        opts.on("-f", "--force", "Kill any running agent for this workspace before starting") { force = true }
        opts.on("--ensure", "Start the agent in the background unless one is already running (safe to repeat)") { ensure_running = true }
        opts.separator ""
        opts.separator "Examples:"
        opts.separator "  workspace agentd    # run for the project detected from the current directory"
        opts.separator "  workspace agentd scooter --wc-socket /tmp/wc-dev.sock    # named project, non-default coordinator"
        opts.separator "  workspace agentd --force    # replace the agent already running for this workspace"
        opts.separator "  workspace agentd --ensure   # make sure one is running; exits 0 if it already was"
        opts.separator "  workspace agentd restart    # stop the running agent and start a new one in the background"
      end
      parser.parse!(args)

      name = settle_name(name || args.shift)
      raise UsageError, "Unexpected argument: #{args.first}.\n\n#{parser.help}" if args.any?
      name ||= @project_detector.detect(@working_dir)
      raise UsageError, parser.help if name.nil?
      require_known_workspace!(name)

      if ensure_running
        raise UsageError, "--ensure and --force can't be combined: --ensure never replaces a running agent.\n\n#{parser.help}" if force
        return ensure_agent(name, wc_socket)
      end

      @exit_handler.exit(1) unless @agent_command.call(name: name, wc_socket: wc_socket, force: force)
    end

    def agentd_restart_parser(options)
      OptionParser.new do |opts|
        opts.banner = "Usage: workspace agentd restart [PROJECT] [--wc-socket PATH] [--json]"
        opts.separator ""
        opts.separator "Stop the agent daemon running for the workspace (SIGTERM, even one that no longer answers) and"
        opts.separator "start a new one in the background, the way --ensure does: the terminal is not held, and the"
        opts.separator "new agent's output goes to the daemon log (`workspace daemon log`). An agent run in a terminal"
        opts.separator "is replaced by a background one. With none running, just start one. The same as"
        opts.separator "`workspace daemon restart`."
        opts.separator ""
        opts.separator "The new agent keeps the work-coordinator socket the old one was started with, unless"
        opts.separator "--wc-socket names another."
        opts.separator ""
        opts.on("--name NAME", "Workspace name (defaults to PROJECT or the project detected from the current directory)") { |v| options[:name] = v }
        opts.on("--wc-socket PATH", "Work-coordinator socket for the new agent (default: the old agent's)") { |v| options[:wc_socket] = v }
        opts.on("--json", "Print one JSON action document (see docs/README.daemon.md)") { options[:json] = true }
        opts.on("-h", "--help", "Show this help") { options[:help] = true }
        opts.separator ""
        opts.separator "restart takes neither --force nor --ensure: with either one, `agentd restart` runs the agent"
        opts.separator "for a workspace named restart."
        opts.separator ""
        opts.separator "Examples:"
        opts.separator "  workspace agentd restart    # the project detected from the current directory"
        opts.separator "  workspace agentd restart scooter --json"
        opts.separator "  workspace agentd restart --name restart    # a workspace that is itself named restart"
      end
    end

    def cmd_agentd_restart(args)
      options = {json: false}
      given = args.dup
      parser = agentd_restart_parser(options)
      parser.parse!(args)
      return @output.puts(parser.help) if options[:help]

      raise Error, "agentd restart is not available: no daemon command was wired" unless @daemon_command

      name = settle_name(options[:name] || args.shift)
      raise UsageError, "Unexpected argument: #{args.first}. Run 'workspace agentd restart --help'." if args.any?
      name ||= @project_detector.detect(@working_dir)
      raise UsageError, "Missing workspace name.\n\n#{parser.help}" unless name
      require_known_workspace!(name)

      daemon_restart(name, options)
    rescue OptionParser::ParseError, UsageError => e
      raise unless json_requested?(options[:json], given)
      emit_json_error(Commands::Daemon::JSON_SCHEMA_VERSION, e, message: e.message.lines.first.strip)
    end

    def ensure_agent(name, wc_socket)
      raise Error, "workspace agentd --ensure is not available in this build" unless @ensure_agent_command

      result = @ensure_agent_command.call(name: name, wc_socket: wc_socket)
      case result.status
      when :running then @output.puts "agentd for #{name} is already running"
      when :started then @output.puts "Started agentd for #{name}"
      when :invalid_config then @exit_handler.exit(1)
      else
        @error_output.puts "Error: Could not start the agent daemon for #{name}: #{result.detail}"
        @exit_handler.exit(1)
      end
    end

    def cmd_ask(args)
      # Recording always takes --default, so with it a first word like
      # "list" or "help" is the question text, not a subcommand.
      return cmd_ask_record(args) if args.any? { |a| a == "--default" || a.start_with?("--default=") }

      # The subcommand is the first non-option argument, so a leading flag
      # (e.g. `ask --json list`) doesn't get mistaken for the question text.
      index = args.each_index.find { |i| !args[i].start_with?("-") && !(i.positive? && args[i - 1] == "--name") }
      subcommand = index && args[index]
      rest = index ? args[0...index] + args[(index + 1)..] : args

      case subcommand
      when "list" then cmd_ask_list(rest)
      when "answer", "resolve" then cmd_ask_answer(rest)
      when "withdraw" then cmd_ask_withdraw(rest)
      when "help", "--help", "-h", nil then @output.puts ask_help
      else cmd_ask_record(args)
      end
    end

    def ask_help
      <<~HELP
        Usage: workspace ask "<question>" --default "<default taken>" [options]
               workspace ask list [--all] [--json]
               workspace ask answer <id> "<answer>" [--deliver] [--json]
               workspace ask withdraw <id> [--json]

        Records a question an unattended agent hit, with the default it took,
        so the agent can keep going instead of blocking on a person. Never
        reads stdin; returns once the question is recorded and any notify
        command has finished (it is stopped after 10 seconds).

        Subcommands:
          list                    Show open questions for this workspace (--all: also answered
                                  and withdrawn ones, with their status)
          answer <id> <answer>    Resolve an open question (alias: resolve); with --deliver,
                                  also type the answer and Enter into the pane that asked
          withdraw <id>           Close an open question nobody needs answered any more; it
                                  leaves `ask list` and the inbox, and can't be answered

        A first word of list, answer, resolve, withdraw or help is a subcommand only
        without --default; `workspace ask list --default x` records "list".

        Options (every subcommand):
          --name WS         Act on workspace WS instead of the one detected from the
                            current directory

        Options (answer):
          --deliver         Type the answer, then Enter, into the pane that asked, which must
                            belong to the workspace's tmux session. The pane is checked before the
                            question is answered; if typing then fails, the question stays
                            answered and the error says so. Needs a question asked from tmux.
          --                Ends options, so an answer starting with "-" works

        Options (recording a question):
          --default TEXT    The default the agent took (required)
          --context TEXT    Free-text pointer to the code in question, e.g. "file.rb:42"
          --json             Emit the documented JSON schema instead of a message

        When the project has `alerts.notify` configured (see
        `workspace config set alerts.notify <command>`), it runs with
        WORKSPACE_ALERT=question and the question/default in
        WORKSPACE_ALERT_* env vars. Without it, the question is just recorded.

        Examples:
          workspace ask "Use pg or sqlite for the cache?" --default "sqlite" --context "lib/cache.rb:12"
          workspace ask list
          workspace ask answer a1b2c3 "Use postgres instead"
          workspace ask withdraw a1b2c3             # the asker no longer needs an answer
          workspace ask answer --deliver a1b2c3 -- yes    # also types it into the asking pane
      HELP
    end

    def cmd_ask_record(args)
      workspace = nil
      default = nil
      context = nil
      json = false
      parser = OptionParser.new do |opts|
        opts.banner = "Usage: workspace ask \"<question>\" --default \"<default taken>\" [options]"
        opts.on("--name NAME", "Workspace to act on instead of the one detected from cwd") { |v| workspace = v }
        opts.on("--default TEXT", "The default the agent took (required)") { |v| default = v }
        opts.on("--context TEXT", "Free-text pointer to the code in question, e.g. \"file.rb:42\"") { |v| context = v }
        opts.on("--json", "Emit the documented JSON schema instead of a message") { json = true }
      end
      parser.parse!(args)

      question = args.shift
      if question.nil? || args.any? || default.nil?
        raise UsageError, parser.help unless json_requested?(json, args)
        return emit_json_usage_error(Commands::Ask::JSON_SCHEMA_VERSION, "workspace ask: a question and --default are required.")
      end

      result = @ask_command.call(question: question, default: default, context: context, working_dir: working_dir_for(workspace), json: json)
      @exit_handler.exit(result[:exit_code]) unless result[:exit_code].zero?
    rescue OptionParser::ParseError => e
      raise unless json_requested?(json, args)
      emit_json_error(Commands::Ask::JSON_SCHEMA_VERSION, e)
    end

    def cmd_ask_list(args)
      workspace = nil
      all = false
      json = false
      parser = OptionParser.new do |opts|
        opts.banner = "Usage: workspace ask list [--all] [--json]"
        opts.on("--name NAME", "Workspace to act on instead of the one detected from cwd") { |v| workspace = v }
        opts.on("--all", "Also list answered and withdrawn questions, with their status") { all = true }
        opts.on("--json", "Emit the documented JSON schema instead of a table") { json = true }
      end
      parser.parse!(args)
      raise UsageError, parser.help if args.any?

      result = @ask_command.list(working_dir: working_dir_for(workspace), json: json, all: all)
      @exit_handler.exit(result[:exit_code]) unless result[:exit_code].zero?
    rescue OptionParser::ParseError => e
      raise unless json_requested?(json, args)
      emit_json_error(Commands::Ask::JSON_SCHEMA_VERSION, e)
    end

    def cmd_ask_answer(args)
      workspace = nil
      json = false
      deliver = false
      parser = OptionParser.new do |opts|
        opts.banner = "Usage: workspace ask answer <id> \"<answer>\" [--deliver] [--json]"
        opts.on("--name NAME", "Workspace to act on instead of the one detected from cwd") { |v| workspace = v }
        opts.on("--deliver", "Also type the answer and Enter into the pane that asked") { deliver = true }
        opts.on("--json", "Emit the documented JSON schema instead of a message") { json = true }
      end
      parser.parse!(args)

      id = args.shift
      answer = args.shift
      if id.nil? || answer.nil? || args.any?
        raise UsageError, parser.help unless json_requested?(json, args)
        return emit_json_usage_error(Commands::Ask::JSON_SCHEMA_VERSION, "workspace ask answer: an id and an answer are required.")
      end

      result = @ask_command.answer(id, answer, working_dir: working_dir_for(workspace), json: json, deliver: deliver)
      @exit_handler.exit(result[:exit_code]) unless result[:exit_code].zero?
    rescue OptionParser::ParseError => e
      raise unless json_requested?(json, args)
      emit_json_error(Commands::Ask::JSON_SCHEMA_VERSION, e)
    end

    def cmd_ask_withdraw(args)
      workspace = nil
      json = false
      parser = OptionParser.new do |opts|
        opts.banner = "Usage: workspace ask withdraw <id> [--json]"
        opts.on("--name NAME", "Workspace to act on instead of the one detected from cwd") { |v| workspace = v }
        opts.on("--json", "Emit the documented JSON schema instead of a message") { json = true }
      end
      parser.parse!(args)

      id = args.shift
      if id.nil? || args.any?
        raise UsageError, parser.help unless json_requested?(json, args)
        return emit_json_usage_error(Commands::Ask::JSON_SCHEMA_VERSION, "workspace ask withdraw: an id is required.")
      end

      result = @ask_command.withdraw(id, working_dir: working_dir_for(workspace), json: json)
      @exit_handler.exit(result[:exit_code]) unless result[:exit_code].zero?
    rescue OptionParser::ParseError => e
      raise unless json_requested?(json, args)
      emit_json_error(Commands::Ask::JSON_SCHEMA_VERSION, e)
    end

    def cmd_inbox(args)
      subcommand = args.shift
      case subcommand
      when "add" then cmd_inbox_add(args)
      when "list" then cmd_inbox_list(args)
      when "show" then cmd_inbox_show(args)
      when "edit" then cmd_inbox_edit(args)
      when "snooze" then cmd_inbox_snooze(args)
      when "ack" then cmd_inbox_resolve(args, "ack", :ack)
      when "done" then cmd_inbox_resolve(args, "done", :done)
      when "dismiss" then cmd_inbox_resolve(args, "dismiss", :dismiss)
      when "reopen" then cmd_inbox_resolve(args, "reopen", :reopen)
      when "help", "--help", "-h", nil then @output.puts inbox_help
      else raise UsageError, "Unknown inbox subcommand: #{subcommand}. Run 'workspace inbox help'."
      end
    end

    def inbox_help
      <<~HELP
        Usage: workspace inbox add TITLE [options] [scope]
               workspace inbox add --from-json PATH|- [--json]
               workspace inbox done|dismiss --dedupe-key KEY [scope] [--json]
               workspace inbox list [--state S[,S]] [--type T] [--all] [--include-derived] [scope] [--json]
               workspace inbox show ID [scope] [--json]
               workspace inbox edit ID [options] [scope] [--json]
               workspace inbox done|dismiss|reopen ID... [scope] [--json]
               workspace inbox snooze ID... (--until ISO | --for DURATION) [scope] [--json]
               workspace inbox ack DERIVED_ID... [scope] [--json]

        A durable list of things that need a person, kept per workspace, per
        project (all worktrees of one repository) or globally. Agents, scripts
        and outside tools post to it; titles and bodies are data, never run.

        Subcommands:
          add TITLE     Add an item (type todo unless --type says otherwise)
          list          Open items of this workspace, its project and the global list
          show ID       One item, in any state
          edit ID       Change an item's title, body, expiry or links (any state; it stays as it is)
          done ID...    Mark items done; one already done is reported unchanged
          dismiss ID... Mark items dismissed (nobody will act on them)
          reopen ID...  Move done, dismissed or snoozed items back to open
          snooze ID...  Hide open items until a time; they read open again after it. A derived id
                        (from list --include-derived) is hidden until then, or until it changes
          ack ID...     Hide derived rows (list --include-derived) until they change (a new wait,
                        plan state or lock holder shows again) or 30 days pass. A question is answered, not acked

        Scope (every subcommand; at most one):
          --name WS         The workspace WS instead of the one detected from the current directory
          --project NAME    The project NAME (or a path in it)
          --global          The global list
        Without one, add uses the workspace of the current directory, and fails with
        not_in_workspace outside any; list reads the workspace, its project and global.

        Options (add):
          --type TYPE            todo, alert, note or review_request
          --body TEXT            Longer text, up to 8192 characters
          --body-file PATH|-     Read the body from a file or stdin (64 KB at most)
          --source-kind KIND     jira, github_pr, github_check, session, agent, cli or user
          --source-ref REF       Free text up to 200 characters
          --source-url URL       An https:// URL
          --dedupe-key KEY       Add once: an open or snoozed item with this key in the scope is
                                 updated, a resolved one is left alone (A-Z a-z 0-9 . _ : / # @ -, 200 at most)
          --reopen               With --dedupe-key, reopen a resolved item instead of leaving it
          --expires DURATION|ISO After this time the item counts as dismissed and leaves the
                                 default list (2h, 2026-10-20T09:00:00Z)
          --link-pane PANE       A tmux pane the item is about
          --link-plan-task ID    A plan task id
          --link-pr N            A pull request number
          --link-run ID          A workflow run id
          --as-user              Record the item as made by a person
          --from-json PATH|-     Take the whole item from one JSON object (64 KB at most) with the keys
                                 type, title, body, source, dedupe_key, expires_at, links and scope; use it
                                 alone (only --json goes with it)
        Options (edit; at least one):
          --title TEXT           A new title
          --body TEXT            A new body ("" clears it); or --body-file PATH|-
          --expires DURATION|ISO A new expiry; --no-expires drops it
          --link-pane PANE, --link-plan-task ID, --link-pr N, --link-run ID
                                 Change a link ("" clears it)
        Options (done, dismiss):
          --dedupe-key KEY       Resolve the item holding KEY in the scope (no ids); none is unchanged
        Options (ack, snooze of derived ids): without a scope flag every workspace and project is read
        to find the row.
        Options (snooze; one of):
          --until ISO            Wake at this time (2026-10-20T09:00:00Z); it must be in the future
          --for DURATION         Wake after this long from now (30m, 2h)
        Options (list):
          --state S[,S]          open (default), snoozed, done, dismissed
          --type TYPE            Only this type
          --all                  Every scope that has items
          --include-derived      Add what needs you now, worked out from workspace state: open
                                 questions, waiting agent panes, blocked or stalled plans, workflow
                                 gates and stuck locks (open alerts, never stored)
        Options (every subcommand):
          --json                 Print the documented JSON (see docs/README.inbox.md)

        A title or body with a control character (an escape sequence, NUL) is refused.

        Examples:
          workspace inbox add "Check the deploy" --type todo
          workspace inbox add "CI failed" --type alert --source-kind github_check --global --json
          echo '{"title":"Check the deploy","type":"alert","scope":{"kind":"global"}}' | workspace inbox add --from-json -
          workspace inbox list --all --state open,snoozed
          workspace inbox list --all --include-derived --json
          workspace inbox show a1b2c3d4e5
          workspace inbox done a1b2c3d4e5 f6a7b8c9d0
          workspace inbox dismiss a1b2c3d4e5 --json
          workspace inbox edit a1b2c3d4e5 --title "Check the deploy again" --expires 2h
          workspace inbox snooze a1b2c3d4e5 --for 2h
          workspace inbox snooze a1b2c3d4e5 --until 2026-10-20T09:00:00Z --json
          workspace inbox ack plan:blocked:api.fix
          workspace inbox snooze 'pane:waiting:api.fix:%5' --for 1h
          workspace inbox add "CI failed" --type alert --dedupe-key github_check:org/api:rspec:9f3c2e1 --global
          workspace inbox done --dedupe-key github_check:org/api:rspec:9f3c2e1 --global
      HELP
    end

    def inbox_scope_options(opts, target)
      opts.on("--name NAME", "Workspace to act on instead of the one detected from cwd") { |v| target[:name] = v }
      opts.on("--project NAME", "Project (a name, or a path in it) to act on") { |v| target[:project] = v }
      opts.on("--global", "Act on the global list") { target[:global] = true }
    end

    def inbox_working_dir(target)
      working_dir_for(target[:name])
    end

    def cmd_inbox_add(args)
      target = {}
      json = false
      from_json = nil
      options = {type: "todo", source: {}, links: {}}
      parser = OptionParser.new do |opts|
        opts.banner = "Usage: workspace inbox add TITLE [options]"
        inbox_scope_options(opts, target)
        opts.on("--type TYPE", "todo, alert, note or review_request") { |v| options[:type] = v }
        opts.on("--body TEXT", "Longer text, up to 8192 characters") { |v| options[:body] = v }
        opts.on("--body-file PATH", "Read the body from PATH, or - for stdin (64 KB at most)") { |v| options[:body_file] = v }
        opts.on("--source-kind KIND", "Where the item came from") { |v| options[:source][:kind] = v }
        opts.on("--source-ref REF", "A reference in that source") { |v| options[:source][:ref] = v }
        opts.on("--source-url URL", "An https:// URL") { |v| options[:source][:url] = v }
        opts.on("--expires WHEN", "A duration (2h) or an ISO 8601 time") { |v| options[:expires] = v }
        opts.on("--dedupe-key KEY", "Add once per key: update the open item with it, leave a resolved one") { |v| options[:dedupe_key] = v }
        opts.on("--reopen", "With --dedupe-key, reopen a resolved item") { options[:reopen] = true }
        opts.on("--link-pane PANE", "A pane the item concerns") { |v| options[:links][:pane] = v }
        opts.on("--link-plan-task ID", "A plan task id") { |v| options[:links][:plan_task] = v }
        opts.on("--link-pr N", Integer, "A pull request number") { |v| options[:links][:pr] = v }
        opts.on("--link-run ID", "A workflow run id") { |v| options[:links][:run_id] = v }
        opts.on("--as-user", "Record the item as made by a person") { options[:as_user] = true }
        opts.on("--from-json PATH", "Read the whole item from one JSON object in PATH, or - for stdin (64 KB at most)") { |v| from_json = v }
        opts.on("--json", "Print one action document (see docs/README.json.md) instead of text, which goes to stderr") { json = true }
      end
      flags = args.select { |arg| arg.start_with?("-") && arg != "-" }
      parser.parse!(args)
      if from_json
        mixed = args.any? || (flags - ["--json"]).any? { |flag| !flag.start_with?("--from-json") }
        raise UsageError, "--from-json takes the whole item from the JSON object; pass no title, scope or item flags with it (only --json)." if mixed
        raise Error, "inbox is not available: no inbox command was wired" unless @inbox_command

        return run_action("inbox add", json: json) do
          @inbox_command.add_from_json(from_json, working_dir: inbox_working_dir(target))
        end
      end
      title = args.shift
      raise UsageError, "An inbox item needs a title.\n\n#{parser.help}" if title.nil?
      raise UsageError, "Unexpected argument: #{args.first}. Run 'workspace inbox help'." if args.any?
      raise Error, "inbox is not available: no inbox command was wired" unless @inbox_command

      run_action("inbox add", json: json) do
        @inbox_command.add(title: title, target: target, working_dir: inbox_working_dir(target), **options)
      end
    end

    def cmd_inbox_list(args)
      target = {}
      json = false
      all = false
      include_derived = false
      states = []
      type = nil
      parser = OptionParser.new do |opts|
        opts.banner = "Usage: workspace inbox list [--state S[,S]] [--type T] [--all] [--include-derived] [--json]"
        inbox_scope_options(opts, target)
        opts.on("--state STATES", Array, "open (default), snoozed, done or dismissed; comma-separated") { |v| states = v }
        opts.on("--type TYPE", "Only items of this type") { |v| type = v }
        opts.on("--all", "Every scope that has items") { all = true }
        opts.on("--include-derived", "Add what needs you now: open questions, waiting agents, blocked plans, workflow gates, stuck locks") { include_derived = true }
        opts.on("--json", "Emit the documented JSON schema instead of a table") { json = true }
      end
      parser.parse!(args)
      raise UsageError, "Unexpected argument: #{args.first}. Run 'workspace inbox help'." if args.any?
      raise Error, "inbox is not available: no inbox command was wired" unless @inbox_command

      result = @inbox_command.list(target: target, working_dir: inbox_working_dir(target), states: states, type: type, all: all,
        include_derived: include_derived, json: json)
      @exit_handler.exit(result[:exit_code]) unless result[:exit_code].zero?
    end

    def cmd_inbox_show(args)
      target = {}
      json = false
      parser = OptionParser.new do |opts|
        opts.banner = "Usage: workspace inbox show ID [--json]"
        inbox_scope_options(opts, target)
        opts.on("--json", "Emit the documented JSON schema instead of text") { json = true }
      end
      parser.parse!(args)
      id = args.shift
      raise UsageError, "inbox show needs an id.\n\n#{parser.help}" if id.nil?
      raise UsageError, "Unexpected argument: #{args.first}. Run 'workspace inbox help'." if args.any?
      raise Error, "inbox is not available: no inbox command was wired" unless @inbox_command

      result = @inbox_command.show(id, target: target, working_dir: inbox_working_dir(target), json: json)
      @exit_handler.exit(result[:exit_code]) unless result[:exit_code].zero?
    end

    def cmd_inbox_edit(args)
      target = {}
      json = false
      options = {links: {}}
      parser = OptionParser.new do |opts|
        opts.banner = "Usage: workspace inbox edit ID [options]"
        inbox_scope_options(opts, target)
        opts.on("--title TEXT", "A new title") { |v| options[:title] = v }
        opts.on("--body TEXT", "A new body; an empty one clears it") { |v| options[:body] = v }
        opts.on("--body-file PATH", "Read the body from PATH, or - for stdin (64 KB at most)") { |v| options[:body_file] = v }
        opts.on("--expires WHEN", "A duration (2h) or an ISO 8601 time") { |v| options[:expires] = v }
        opts.on("--no-expires", "Drop the expiry") { options[:no_expires] = true }
        opts.on("--link-pane PANE", "A pane the item concerns; an empty one clears it") { |v| options[:links][:pane] = v }
        opts.on("--link-plan-task ID", "A plan task id; an empty one clears it") { |v| options[:links][:plan_task] = v }
        opts.on("--link-pr N", "A pull request number; an empty one clears it") { |v| options[:links][:pr] = v.match?(/\A\d+\z/) ? v.to_i : v }
        opts.on("--link-run ID", "A workflow run id; an empty one clears it") { |v| options[:links][:run_id] = v }
        opts.on("--json", "Print one action document (see docs/README.json.md) instead of text, which goes to stderr") { json = true }
      end
      parser.parse!(args)
      id = args.shift
      raise UsageError, "inbox edit needs an id.\n\n#{parser.help}" if id.nil?
      raise UsageError, "Unexpected argument: #{args.first}. Run 'workspace inbox help'." if args.any?
      raise Error, "inbox is not available: no inbox command was wired" unless @inbox_command

      run_action("inbox edit", json: json) do
        @inbox_command.edit(id, target: target, working_dir: inbox_working_dir(target), **options)
      end
    end

    def cmd_inbox_snooze(args)
      target = {}
      json = false
      options = {}
      parser = OptionParser.new do |opts|
        opts.banner = "Usage: workspace inbox snooze ID... (--until ISO | --for DURATION) [--json]"
        inbox_scope_options(opts, target)
        opts.on("--until ISO", "Wake at this ISO 8601 time") { |v| options[:until_time] = v }
        opts.on("--for DURATION", "Wake after this long (30m, 2h)") { |v| options[:for_duration] = v }
        opts.on("--json", "Print one action document (see docs/README.json.md) instead of text, which goes to stderr") { json = true }
      end
      parser.parse!(args)
      raise UsageError, "inbox snooze needs at least one id.\n\n#{parser.help}" if args.empty?
      raise Error, "inbox is not available: no inbox command was wired" unless @inbox_command

      run_action("inbox snooze", json: json) do
        @inbox_command.snooze(args.dup, target: target, working_dir: inbox_working_dir(target), **options)
      end
    end

    def cmd_inbox_resolve(args, verb, method)
      target = {}
      json = false
      dedupe_key = nil
      parser = OptionParser.new do |opts|
        opts.banner = "Usage: workspace inbox #{verb} ID... [--json]"
        inbox_scope_options(opts, target)
        opts.on("--dedupe-key KEY", "Resolve the item holding KEY in the scope instead of ids") { |v| dedupe_key = v } unless %i[reopen ack].include?(method)
        opts.on("--json", "Print one action document (see docs/README.json.md) instead of text, which goes to stderr") { json = true }
      end
      parser.parse!(args)
      raise UsageError, "inbox #{verb} needs at least one id.\n\n#{parser.help}" if args.empty? && dedupe_key.nil?
      raise Error, "inbox is not available: no inbox command was wired" unless @inbox_command

      extra = dedupe_key ? {dedupe_key: dedupe_key} : {}
      run_action("inbox #{verb}", json: json) do
        @inbox_command.public_send(method, args.dup, target: target, working_dir: inbox_working_dir(target), **extra)
      end
    end

    def cmd_lock(args)
      case args.shift
      when "acquire" then cmd_lock_acquire(args)
      when "release" then cmd_lock_release(args)
      when "status" then cmd_lock_status(args)
      when "clear" then cmd_lock_clear(args)
      when "instructions" then cmd_lock_instructions(args)
      when "help", "--help", "-h", nil then @output.puts lock_help
      else
        raise UsageError, lock_help
      end
    end

    def lock_help
      <<~HELP
        Usage: workspace lock <subcommand> [options]

        Coordinates agents sharing a resource through one flock-guarded lock
        store per repository. Locks are shared across every worktree of a
        repository, keyed by its git common directory.

        Subcommands:
          acquire <name> [options]   Acquire a lock, or wait for it
          release [<name>|--all]     Release a lock this agent holds
          status  [<name>]           Show holders and queues
          clear   [<name>|--all]     Force-remove a lock's holder and queue
                                     (devenv: also stops the dev env's process group).
                                     Ordinary waiters are removed once the lock is
                                     actually cleared, but stay queued if a kept
                                     devenv holder can't be stopped; a queued
                                     `dev up --force` is kept either way, not
                                     removed.
          instructions [<name>]      Print the prompt block that tells a coding
                                     agent how to use the lock (default: edit)

        Options (every subcommand):
          --name WS         Act on workspace WS instead of the one detected from the
                            current directory (the lock namespace is WS's repository)

        Options (acquire):
          --task TEXT       Free-text description shown to other waiters
          --wait            Enqueue and poll instead of refusing when busy
          --poll DURATION   Time between polls while waiting, e.g. "5s" (a plain
                            number is seconds; default: #{Commands::Lock::DEFAULT_POLL_SECONDS})
          --max-wait DUR    Stop waiting after DUR, e.g. "9m" (a plain number is
                            seconds; exit 75; re-run to keep
                            waiting; implies --wait). This is when to give up
                            polling, not a hard deadline: if promoted to holder
                            at the instant DUR elapses, acquire still exits 0
                            holding the lock. Run `acquire --max-wait` in the
                            background and treat the process's exit code as
                            the signal, not the printed message.

        Exit codes (acquire):
          0   acquired
          1   held by someone else (no --wait)
          3   this agent's hold was taken over while it was idle (see below);
              re-run to queue again
          4   cleared by someone else while waiting
          5   this agent already holds or waits for a different lock
              (release it first)
          75  still queued after --max-wait

        Idle takeover: when a holding agent finishes its turn, the
        session-event hook marks its lock idle; any prompt or tool use marks
        it active again. Once idle for locks.idle_grace (default 5m; set with
        `workspace config set locks.idle_grace 10m`), the first waiter in the
        queue takes the lock over. The displaced agent is told once, on its
        next acquire or release; acquire then carries on as usual, while
        release exits 3. The dev environment lock is never taken over this way.

        Workflow runs: a run can hold locks for a step. `status` shows such a
        holder as `run <id> (step <name>)`. It is not tied to an agent's
        session, is never idle and is never taken over; it is released when
        the run moves on or ends. `acquire` from the pane bound to that run
        reports the lock as already held for it (exit 0) instead of waiting.

        Note: `lock release`/`lock clear` exit 0 even when nothing was
        held/cleared, except that `release` exits 3 when it reports an idle
        takeover, and `clear` exits 1 when it keeps the devenv lock because
        the dev environment's process group could not be stopped (owned by
        another user, or still running after SIGKILL), or because it is
        already being cleared by another `lock clear` (check the result with
        `workspace lock status <name>`). `acquire` has its own exit codes above.

        Enforcement: once hooks are installed (see `workspace init`/`doctor`),
        Edit/Write/MultiEdit/NotebookEdit are denied (exit 2) for any agent
        that isn't the edit lock's holder. Bash-based edits (sed, git apply,
        codegen) aren't covered and stay advisory. The edit lock is released
        automatically on SessionEnd and on a `/clear`'d SessionStart.

        Examples:
          workspace lock acquire edit --wait --task "PROJ-12 fix login"
          workspace lock release edit
          workspace lock status
          workspace lock clear edit
          workspace lock instructions edit
      HELP
    end

    def cmd_lock_instructions(args)
      parser = OptionParser.new do |opts|
        opts.banner = "Usage: workspace lock instructions [<name>]"
        opts.separator ""
        opts.separator "Prints the prompt block that tells a coding agent how to use"
        opts.separator "lock <name> (default: edit), for pasting into its instructions."
      end
      parser.parse!(args)

      name = args.shift || "edit"
      raise UsageError, parser.help if args.any?

      @lock_command.instructions(name)
    end

    def cmd_lock_acquire(args)
      workspace = nil
      task = nil
      wait = false
      poll = Commands::Lock::DEFAULT_POLL_SECONDS
      max_wait = nil
      parser = OptionParser.new do |opts|
        opts.banner = "Usage: workspace lock acquire <name> [options]"
        opts.on("--name NAME", "Workspace to act on instead of the one detected from cwd") { |v| workspace = v }
        opts.on("--task TEXT", "Free-text description shown to other waiters") { |v| task = v }
        opts.on("--wait", "Enqueue and poll instead of refusing when busy") { wait = true }
        opts.on("--poll DURATION", "Time between polls while waiting (e.g. \"5s\", or a plain number of seconds)") { |v| poll = parse_duration_option("--poll", v) }
        opts.on("--max-wait DURATION", "Give up after DURATION (e.g. \"9m\", or a plain number of seconds); exits 75; implies --wait") { |v| max_wait = parse_duration_option("--max-wait", v) }
      end
      parser.parse!(args)

      name = args.shift
      raise UsageError, parser.help if name.nil? || args.any?

      result = @lock_command.acquire(name, task: task, wait: wait, poll: poll, max_wait: max_wait, working_dir: working_dir_for(workspace))
      @exit_handler.exit(result[:exit_code]) unless result[:exit_code].zero?
    end

    # Parses a duration option such as `--poll` or `--max-wait` (e.g. "9m", "5s", or
    # a plain number of seconds), raising a usage error instead of a
    # backtrace on unparsable input.
    #
    # @param flag [String] option name, for the error message
    # @param value [String] raw option value
    # @param positive [Boolean] require the duration be greater than 0
    # @return [Numeric] seconds
    def parse_duration_option(flag, value, positive: false)
      positive ? Workspace::Duration.parse_positive(value) : Workspace::Duration.parse(value)
    rescue ArgumentError => e
      raise UsageError, "#{flag}: #{e.message}"
    end

    # Schema version of the action documents the mutating commands print with `--json`.
    ACTION_JSON_SCHEMA_VERSION = 1

    # Runs a mutating command's work and reports it. Without `--json` the
    # command's text is untouched and a non-zero `exit_code` from the block
    # exits. With it, the text goes to stderr, stdout gets one action document
    # ({JsonEnvelope.action}), and the exit code follows its `status`: 0, 3 for
    # partial, and for failed the block's own non-zero code (else 1). A raised
    # {Workspace::Error} still becomes the error envelope in the rescue funnel.
    #
    # @param action [String] the verb in the document, e.g. "stop"
    # @param json [Boolean] whether `--json` was given
    # @yieldreturn [Hash, nil] `:exit_code`; with `json` also `:results` (rows
    #   with an `"outcome"`), and optionally `:warnings`, `:extra` and `:status`
    #   (else derived from the rows); build rows only when `json`, as text mode ignores them
    # @return [void]
    def run_action(action, json:)
      unless json
        outcome = yield
        code = outcome && outcome[:exit_code]
        @exit_handler.exit(code) if code && !code.zero?
        return
      end

      outcome = divert_output { yield }
      results = outcome.fetch(:results)
      code = outcome[:exit_code]
      status = outcome[:status] || JsonEnvelope.action_status(results)
      status = "failed" if status == "ok" && code && !code.zero?
      @output.puts JSON.generate(JsonEnvelope.action(ACTION_JSON_SCHEMA_VERSION, action,
        results: results, status: status, warnings: outcome[:warnings] || [], extra: outcome[:extra] || {}))
      exit_code = JsonEnvelope::ACTION_EXIT_CODES.fetch(status)
      exit_code = code if exit_code == 1 && code && !code.zero?
      @exit_handler.exit(exit_code) unless exit_code.zero?
    end

    # Sends what collaborators print to stderr while the block runs, so stdout
    # stays free for one JSON document. A plain stream (a test double) is left alone.
    def divert_output(&block)
      return yield unless @output.respond_to?(:divert_to)
      @output.divert_to(@error_output, &block)
    end

    # One row of an action document's `results`.
    #
    # @param workspace [String, nil]
    # @param outcome [String] e.g. "stopped", "failed"
    # @param reason [String, nil] a short machine-readable cause
    # @param message [String, nil] what a person would read
    # @param extra [Hash] more keys for the row
    # @return [Hash]
    def action_row(workspace, outcome, reason: nil, message: nil, **extra)
      {"workspace" => workspace, "outcome" => outcome, "reason" => reason, "message" => message}.merge(extra.transform_keys(&:to_s))
    end

    # Emits a caught failure as the `--json` error envelope (code, details and
    # retry from the exception) to stdout and exits 1.
    #
    # @param schema_version [Integer] the command's JSON schema version
    # @param error [Exception] the failure
    # @param message [String, nil] replaces the exception's message (e.g. its first line)
    def emit_json_error(schema_version, error, message: nil)
      @output.puts JSON.generate(JsonEnvelope.from_exception(schema_version, error, message: message))
      @exit_handler.exit(1)
    end

    # Emits the documented `--json` error contract (see docs/README.lock.md,
    # docs/README.dev.md) to stdout and exits, for usage/validation errors
    # raised before a command's own `status_json` branch is reached (e.g. bad
    # option, extra argument, invalid lock name).
    #
    # @param schema_version [Integer] the command's JSON schema version
    # @param message [String] error message (single line; not the full help text)
    def emit_json_usage_error(schema_version, message)
      @output.puts JSON.generate(JsonEnvelope.error(schema_version, message, code: "usage"))
      @exit_handler.exit(1)
    end

    # Whether --json was requested, even when the parse error happened before
    # OptionParser reached the --json flag (e.g. an unknown option listed
    # first). The JSON error contract must not depend on flag order.
    #
    # @param json [Boolean] the flag as set by OptionParser so far
    # @param args [Array<String>] the raw, unparsed argv for this subcommand
    # @return [Boolean]
    def json_requested?(json, args)
      json || args.include?("--json")
    end

    def cmd_lock_release(args)
      workspace = nil
      all = false
      json = false
      parser = OptionParser.new do |opts|
        opts.banner = "Usage: workspace lock release [<name>|--all] [--json]"
        opts.on("--name NAME", "Workspace to act on instead of the one detected from cwd") { |v| workspace = v }
        opts.on("--all", "Release every lock this agent holds") { all = true }
        opts.on("--json", "Print one action document (see docs/README.json.md) instead of text, which goes to stderr") { json = true }
      end
      parser.parse!(args)

      name = args.shift
      raise UsageError, parser.help if (!all && name.nil?) || (all && name) || args.any?

      run_action("lock release", json: json) do
        result = @lock_command.release(name, all: all, working_dir: working_dir_for(workspace))
        rows = json ? [exit_code_row(workspace || @project_detector.detect(@working_dir), "released", result[:exit_code], lock: name, all: all)] : []
        {exit_code: result[:exit_code], results: rows}
      end
    end

    # One `results` row for a command that reports only an exit code: `ok_outcome`
    # on 0, else `failed` with the code (the details went to stderr).
    def exit_code_row(workspace, ok_outcome, code, **extra)
      return action_row(workspace, ok_outcome, **extra) if code.zero?
      action_row(workspace, "failed", reason: "exit_code", message: "Exited #{code}; the details are on stderr.", exit_code: code, **extra)
    end

    def cmd_lock_status(args)
      workspace = nil
      json = false
      parser = OptionParser.new do |opts|
        opts.banner = "Usage: workspace lock status [<name>] [--json]"
        opts.on("--name NAME", "Workspace to act on instead of the one detected from cwd") { |v| workspace = v }
        opts.on("--json", "Emit the documented JSON schema instead of a table (see docs/README.lock.md)") { json = true }
        opts.separator ""
        opts.separator "Audit trail: locks.jsonl next to locks.json; see docs/README.lock.md."
      end
      parser.parse!(args)

      name = args.shift
      raise UsageError, parser.help if args.any?

      result = @lock_command.status(name, working_dir: working_dir_for(workspace), json: json)
      @exit_handler.exit(result[:exit_code]) unless result[:exit_code].zero?
    rescue OptionParser::ParseError, UsageError => e
      raise unless json_requested?(json, args)
      emit_json_error(Commands::Lock::JSON_SCHEMA_VERSION, e)
    end

    def cmd_lock_clear(args)
      workspace = nil
      all = false
      json = false
      parser = OptionParser.new do |opts|
        opts.banner = "Usage: workspace lock clear [<name>|--all] [--json]"
        opts.on("--name NAME", "Workspace to act on instead of the one detected from cwd") { |v| workspace = v }
        opts.on("--all", "Clear every lock in this namespace") { all = true }
        opts.on("--json", "Emit the documented JSON schema instead of text (see docs/README.lock.md)") { json = true }
      end
      parser.parse!(args)

      name = args.shift
      raise UsageError, parser.help if (!all && name.nil?) || (all && name)
      raise UsageError, "workspace lock clear: too many arguments.\n\n#{parser.help}" if args.any?

      result = @lock_command.clear(name, all: all, working_dir: working_dir_for(workspace), json: json)
      @exit_handler.exit(result[:exit_code]) unless result[:exit_code].zero?
    rescue OptionParser::ParseError, UsageError => e
      raise unless json_requested?(json, args)
      emit_json_error(Commands::Lock::JSON_SCHEMA_VERSION, e, message: e.message.lines.first.strip)
    end

    def cmd_dev(args)
      case args.shift
      when "up" then cmd_dev_up(args)
      when "down" then cmd_dev_down(args)
      when "status" then cmd_dev_status(args)
      when "wait" then cmd_dev_wait(args)
      when "leave" then cmd_dev_leave(args)
      when "__run" then cmd_dev_run(args)
      when "__release" then cmd_dev_release(args)
      when "help", "--help", "-h", nil then @output.puts dev_help
      else
        raise UsageError, dev_help
      end
    end

    def dev_help
      <<~HELP
        Usage: workspace dev <subcommand> [options]

        Runs one dev environment per repository, guarded by the repo-wide
        devenv lock. The command comes from the parent project's config:
          workspace config set dev.up "./start-dev"
          workspace config set dev.ready "port:3000"    (or a shell command)
          workspace config set dev.stop_timeout 20s
          workspace config set dev.startup_timeout 30s  (default: 30s)
          workspace config set dev.ready_timeout 2m      (default: 120s)

        Subcommands:
          up [options]      Start this worktree's dev env in a devenv tmux window
          down [--force]    Stop this repo's dev env, whichever worktree holds it
          status            Show holder, branch, uptime, pane, readiness, and queue
          wait [options]    Block until this worktree holds the dev env and it is ready
          leave             Take this worktree out of the line for the dev env

        Options (every subcommand):
          --name WS         Act on workspace WS instead of the one detected from the
                            current directory

        Options (up):
          --wait            Queue behind another worktree's dev env
          --queue           Queue like --wait but return at once (exit 0), without
                            waiting for the lock or the ready check; follow with
                            `dev wait`. Not with --force or --max-wait.
          --force           Stop another worktree's dev env, then start this one
                            (--takeover, the old flag, still works; unrelated to
                            `down --force`)
          --no-ready        Don't wait for the dev.ready check
          --max-wait DUR    Give up after DUR, e.g. "9m" (a plain number is seconds;
                            exit 75; implies --wait). With --force, it limits
                            the whole switch.

        Options (wait):
          --no-ready        Don't wait for the dev.ready check
          --max-wait DUR    Give up after DUR (exit 75); the worktree stays queued
                            until `dev leave`

        Options (down):
          --force           Also kill a process group left behind by a dead wrapper

        Note: `up` from the worktree that already holds the devenv lock is
        a no-op (exit 0); it doesn't restart the dev command.

        Workflow runs: while a run holds the devenv lock, `up` from the pane
        bound to that run starts the dev env at once, under the run's lock;
        `down` stops it and the lock stays with the run. From anywhere else
        `up` is refused (exit 1): --wait queues behind the run, and --force
        does not take the lock from a run.

        Exit codes (up):
          0   running (or already running for this worktree)
          1   running for another worktree (without --wait/--force), or failed to start;
              also a --force whose target is already being stopped by another
              `lock clear`/`dev down`/`dev up --force`
          4   devenv lock cleared while waiting
          6   ready check failed (the env is stopped and the lock released)
          75  still queued after --max-wait

        Exit codes (wait):
          0   this worktree holds the dev env and it is ready
          1   the queued wrapper exited
          4   the lock was cleared while waiting, or this worktree is not queued
          6   ready check failed
          75  still queued after --max-wait

        Exit codes (leave):
          0   left the line, or this worktree was not in it

        Exit codes (down):
          0   stopped (or nothing was running)
          1   could not stop the process group, or it's already being stopped by
              another `lock clear`/`dev down`/`dev up --force`

        Examples:
          workspace dev up
          workspace dev up --wait --max-wait 10m
          workspace dev up --queue && workspace dev wait --max-wait 10m
          workspace dev leave
          workspace dev up --force
          workspace dev status
          workspace dev down
      HELP
    end

    def cmd_dev_up(args)
      workspace = nil
      wait = false
      force = false
      ready = true
      max_wait = nil
      queue = false
      json = false
      parser = OptionParser.new do |opts|
        opts.banner = "Usage: workspace dev up [--wait | --queue] [--force] [--no-ready] [--max-wait DURATION] [--json]"
        opts.on("--name NAME", "Workspace to act on instead of the one detected from cwd") { |v| workspace = v }
        opts.on("--wait", "Queue behind another worktree's dev env") { wait = true }
        opts.on("--queue", "Queue like --wait but return at once; follow with `dev wait`") { queue = true }
        opts.on("--force", "--takeover", "Stop another worktree's dev env, then start this one") { force = true }
        opts.on("--[no-]ready", "Wait for the dev.ready check (default: on)") { |v| ready = v }
        opts.on("--max-wait DURATION", "Give up after DURATION (e.g. \"9m\", or a plain number of seconds); exits 75; implies --wait") { |v| max_wait = parse_duration_option("--max-wait", v) }
        opts.on("--json", "Print one action document (see docs/README.json.md) instead of text, which goes to stderr") { json = true }
      end
      parser.parse!(args)
      raise UsageError, parser.help if args.any?

      run_action("dev up", json: json) do
        options = {wait: wait, takeover: force, ready: ready, max_wait: max_wait, working_dir: working_dir_for(workspace)}
        options[:queue] = true if queue
        result = @dev_command.up(**options)
        rows = []
        if json
          name = workspace || @project_detector.detect(@working_dir)
          rows = if queue
            [exit_code_row(name, (result[:status] == "queued") ? "queued" : "started", result[:exit_code],
              status: result[:status], position: result[:position])]
          else
            [exit_code_row(name, "started", result[:exit_code])]
          end
        end
        {exit_code: result[:exit_code], results: rows}
      end
    end

    def cmd_dev_wait(args)
      workspace = nil
      ready = true
      max_wait = nil
      json = false
      parser = OptionParser.new do |opts|
        opts.banner = "Usage: workspace dev wait [--no-ready] [--max-wait DURATION] [--json]"
        opts.on("--name NAME", "Workspace to act on instead of the one detected from cwd") { |v| workspace = v }
        opts.on("--[no-]ready", "Wait for the dev.ready check (default: on)") { |v| ready = v }
        opts.on("--max-wait DURATION", "Give up after DURATION (e.g. \"9m\", or a plain number of seconds); exits 75 and stays queued") { |v| max_wait = parse_duration_option("--max-wait", v) }
        opts.on("--json", "Print one action document (see docs/README.json.md) instead of text, which goes to stderr") { json = true }
      end
      parser.parse!(args)
      raise UsageError, parser.help if args.any?

      run_action("dev wait", json: json) do
        result = @dev_command.wait(ready: ready, max_wait: max_wait, working_dir: working_dir_for(workspace))
        rows = json ? [exit_code_row(workspace || @project_detector.detect(@working_dir), "started", result[:exit_code],
          status: result[:status], position: result[:position])] : []
        {exit_code: result[:exit_code], results: rows}
      end
    end

    def cmd_dev_leave(args)
      workspace = nil
      json = false
      parser = OptionParser.new do |opts|
        opts.banner = "Usage: workspace dev leave [--json]"
        opts.on("--name NAME", "Workspace to act on instead of the one detected from cwd") { |v| workspace = v }
        opts.on("--json", "Print one action document (see docs/README.json.md) instead of text, which goes to stderr") { json = true }
      end
      parser.parse!(args)
      raise UsageError, parser.help if args.any?

      run_action("dev leave", json: json) do
        result = @dev_command.leave(working_dir: working_dir_for(workspace))
        rows = json ? [action_row(workspace || @project_detector.detect(@working_dir), result[:outcome])] : []
        {exit_code: result[:exit_code], results: rows}
      end
    end

    def cmd_dev_down(args)
      workspace = nil
      force = false
      json = false
      parser = OptionParser.new do |opts|
        opts.banner = "Usage: workspace dev down [--force] [--json]"
        opts.on("--name NAME", "Workspace to act on instead of the one detected from cwd") { |v| workspace = v }
        opts.on("--force", "Also kill a process group left behind by a dead wrapper") { force = true }
        opts.on("--json", "Print one action document (see docs/README.json.md) instead of text, which goes to stderr") { json = true }
      end
      parser.parse!(args)
      raise UsageError, parser.help if args.any?

      run_action("dev down", json: json) do
        result = @dev_command.down(force: force, working_dir: working_dir_for(workspace))
        rows = json ? [exit_code_row(workspace || @project_detector.detect(@working_dir), "stopped", result[:exit_code])] : []
        {exit_code: result[:exit_code], results: rows}
      end
    end

    def cmd_dev_status(args)
      workspace = nil
      json = false
      parser = OptionParser.new do |opts|
        opts.banner = "Usage: workspace dev status [--json]"
        opts.on("--name NAME", "Workspace to act on instead of the one detected from cwd") { |v| workspace = v }
        opts.on("--json", "Emit the documented JSON schema instead of a table (see docs/README.dev.md)") { json = true }
      end
      parser.parse!(args)
      raise UsageError, parser.help if args.any?

      result = @dev_command.status(working_dir: working_dir_for(workspace), json: json)
      @exit_handler.exit(result[:exit_code]) unless result[:exit_code].zero?
    rescue OptionParser::ParseError, UsageError => e
      raise unless json_requested?(json, args)
      emit_json_error(Commands::Dev::JSON_SCHEMA_VERSION, e)
    end

    # Hidden: the wrapper `dev up` runs in the devenv window.
    def cmd_dev_run(args)
      wait = false
      parser = OptionParser.new do |opts|
        opts.banner = "Usage: workspace dev __run [--wait]"
        opts.on("--wait", "Queue for the devenv lock") { wait = true }
      end
      parser.parse!(args)
      raise UsageError, parser.help if args.any?

      result = @dev_command.run(wait: wait, working_dir: @working_dir)
      @exit_handler.exit(result[:exit_code]) unless result[:exit_code].zero?
    end

    # Hidden: what `session-event` starts when a session that ran `dev up` ends.
    def cmd_dev_release(args)
      session = args.shift
      raise UsageError, "Usage: workspace dev __release SESSION_ID" if session.nil? || args.any?

      result = @dev_command.release_for_session(session_id: session, working_dir: @working_dir)
      @exit_handler.exit(result[:exit_code]) unless result[:exit_code].zero?
    end

    # Sends a raw JSONL message to a running agent socket for manual testing and
    # exploration. Always pretty-prints what is being sent before sending it.
    #
    # Usage with a subcommand (--work-item defaults to a random UUID):
    #   workspace agent-run command --work-item WC-42
    #
    # Usage with raw JSON body (workspace is read from the message):
    #   workspace agent-run --body '{"type":"command","workspace":"myproject",...}'
    def cmd_agent_run(args)
      body = nil
      dry_run = false

      # Peek for --body / --dry-run before deciding whether to dispatch to a
      # subcommand. OptionParser would consume them anyway; doing it here lets
      # us keep a clean subcommand path for the common case.
      parser = OptionParser.new do |opts|
        opts.on("--body JSON", "Full message JSON to send directly (workspace read from message)") { |v| body = v }
        opts.on("--dry-run", "Print without sending") { dry_run = true }
      end
      parser.order!(args)  # stops at the first non-option so subcommand words survive

      if body
        return cmd_agent_run_raw(body, dry_run: dry_run)
      end

      subcommand = args.shift
      case subcommand
      when "command" then cmd_agent_run_command(args)
      when "inject" then cmd_agent_run_inject(args)
      when "restart" then cmd_agent_run_restart(args)
      when "send" then cmd_agent_run_send(args)
      when "examples" then cmd_agent_run_examples
      else
        raise UsageError, agent_run_help
      end
    end

    # Parses +body+ as the full message JSON, compacts it to one line, and
    # sends it directly to the agent socket named in the message's "workspace"
    # field. Useful for copy-pasting an example and firing it immediately.
    def cmd_agent_run_raw(body, dry_run: false)
      message = begin
        JSON.parse(jsonl_body(body))
      rescue JSON::ParserError => e
        raise UsageError, "Invalid JSON in --body: #{e.message}"
      end

      name = message["workspace"]
      raise UsageError, "Message JSON must include a \"workspace\" key" if name.nil? || name.empty?

      agent_run_send(name, message, dry_run: dry_run)
    end

    def agent_run_help
      <<~HELP
        Usage: workspace agent-run <subcommand> [options]
               workspace agent-run --body '<full message JSON>' [--dry-run]

        Send a raw JSONL message to a running agent socket.
        Always prints the message being sent before sending it.

        Subcommands:
          command    Send a "command" message (delivers work to the first pipeline stage)
          inject     Send an "inject" message (steers a running work item)
          restart    Clear the coding agent in one pane and type a fresh prompt into it
          send       Type text or tmux keys into one named pane (straight through tmux; no daemon)
          examples   Print all stock example messages without sending anything

        Raw mode (paste a full message directly):
          --body JSON         Complete message JSON; workspace is read from the message
          --dry-run           Print without sending

        Options (command):
          --name NAME         Workspace name (default: detected from cwd)
          --work-item REF     Work item reference, e.g. WC-42  (default: random UUID)
          --body TEXT         Text to type into the first pipeline pane
                              (default: "Begin work.")
          --dry-run           Print the message without sending it

        Options (inject):
          --name NAME         Workspace name (default: detected from cwd)
          --work-item REF     Work item reference  (required)
          --body TEXT         Text to inject into the pane  (required)
          --interrupt         Interrupt the running stage first (sends Ctrl-C)
          --dry-run           Print the message without sending it

        Options (restart; see `workspace agent-run restart --help`):
          --name NAME         Workspace name (default: detected from cwd)
          --pane PANE         Pane to restart: %12, 0.1, session:0.1, or a pane index  (required)
          --prompt TEXT       Text typed once /clear is confirmed  (required)
          --force             Restart even when a pipeline stage is running on the pane
          --wait              Wait for the restart to finish and report how it went
          --timeout DURATION  Longest wait for context usage to drop after /clear
                              (e.g. "45s", or seconds); default 30s, at most 600s
          --json              Print the result as JSON; errors as {"schema_version":1,"ok":false,"error":...}

        Options (send; see `workspace agent-run send --help`):
          --name NAME         Workspace name (default: detected from cwd)
          --pane PANE         Pane to type into: a pane id (%19) or window.pane (0.1)  (required)
          --body TEXT         Literal text to paste, then Enter  (one of --body/--keys)
          --keys KEYS         Space-separated tmux key names: Escape, Enter, Up, C-c, y  (one of --body/--keys)
          --no-enter          With --body, don't press Enter
          --json              Print the result as JSON

        Examples:
          workspace agent-run command --body "Add OAuth support"
          workspace agent-run command --work-item WC-42 --body "Add OAuth support"
          workspace agent-run command --name myapp --work-item WC-42 --body "Add OAuth support" --dry-run
          workspace agent-run inject --work-item WC-42 --body "Use Postgres, not SQLite"
          workspace agent-run inject --work-item WC-42 --body "Stop and pivot to the auth approach" --interrupt
          workspace agent-run restart --name myapp --pane 0.1 --prompt "Read HANDOFF.md and follow it." --wait
          workspace agent-run restart --pane %18 --prompt "Resume from HANDOFF.md" --json
          workspace agent-run send --pane %19 --body "yes"
          workspace agent-run send --pane %19 --keys Escape --json
          workspace agent-run examples
      HELP
    end

    def cmd_agent_run_command(args)
      name = nil
      work_item = nil
      body = nil
      dry_run = false

      parser = OptionParser.new do |opts|
        opts.banner = "Usage: workspace agent-run command [options]"
        opts.on("--name NAME", "Workspace name") { |v| name = v }
        opts.on("--work-item REF", "Work item reference") { |v| work_item = v }
        opts.on("--body TEXT", "Text to deliver to the pipeline") { |v| body = v }
        opts.on("--dry-run", "Print without sending") { dry_run = true }
      end
      parser.parse!(args)

      name ||= @project_detector.detect(@working_dir)
      raise UsageError, "Missing workspace name.\n\n#{agent_run_help}" if name.nil?
      work_item ||= SecureRandom.uuid

      message = build_command_message(name: name, work_item: work_item, body: body)
      agent_run_send(name, message, dry_run: dry_run)
    end

    # `workspace agent run PROMPT`: the prompt is the positional arguments
    # joined with a space, so a multi-word prompt needs no quoting. Everything
    # else matches `agent-run command` minus the default body — the prompt
    # positional is required.
    def cmd_agent_run_prompt(args)
      name = nil
      work_item = nil
      dry_run = false
      json = false

      parser = OptionParser.new do |opts|
        opts.banner = "Usage: workspace agent run PROMPT [options]"
        opts.separator ""
        opts.separator "Send a prompt to the workspace's pipeline as a \"command\" message."
        opts.separator ""
        opts.separator "Options:"
        opts.on("--name NAME", "Workspace name (default: detected from cwd)") { |v| name = v }
        opts.on("--work-item REF", "Work item reference (default: random UUID)") { |v| work_item = v }
        opts.on("--dry-run", "Print the message without sending it") { dry_run = true }
        opts.on("--json", "Print one JSON document with the agent's reply (see docs/README.json.md) instead of",
          "text; the text goes to stderr. Exit 0 whatever the reply says: read reply.ok") { json = true }
      end
      parser.parse!(args)

      name ||= @project_detector.detect(@working_dir)
      raise UsageError, "Missing workspace name.\n\n#{parser.help}" if name.nil?

      prompt = args.join(" ")
      raise UsageError, "Missing prompt.\n\n#{parser.help}" if prompt.empty?
      work_item ||= SecureRandom.uuid

      unless json
        message = build_command_message(name: name, work_item: work_item, body: prompt, dispatch_prefix: "agent-run-")
        agent_run_send(name, message, dry_run: dry_run)
        return
      end

      # Not an action document (the agent's reply is the result), so it diverts and prints by hand.
      message = reply = nil
      divert_output do
        message = build_command_message(name: name, work_item: work_item, body: prompt, dispatch_prefix: "agent-run-")
        reply = agent_run_send(name, message, dry_run: dry_run)
      end
      doc = {"schema_version" => ACTION_JSON_SCHEMA_VERSION, "ok" => true, "workspace" => name,
             "work_item_ref" => work_item, "dispatch_id" => message["dispatch_id"], "dry_run" => dry_run}
      doc[dry_run ? "message" : "reply"] = dry_run ? message : reply
      @output.puts JSON.generate(doc)
    rescue OptionParser::ParseError => e
      raise UsageError, "#{e.message}\nIf the prompt starts with a dash or looks like a flag, pass it after --.\n\n#{parser.help}"
    end

    # Builds the "command" message shared by `agent run` and
    # `agent-run command`.
    def build_command_message(name:, work_item:, body:, dispatch_prefix: "debug-")
      {
        "type" => "command",
        "workspace" => name,
        "work_item_ref" => work_item,
        "dispatch_id" => "#{dispatch_prefix}#{SecureRandom.hex(4)}",
        "body" => jsonl_body(body || "Begin work.")
      }
    end

    def cmd_agent_run_inject(args)
      name = nil
      work_item = nil
      body = nil
      interrupt = false
      dry_run = false

      parser = OptionParser.new do |opts|
        opts.banner = "Usage: workspace agent-run inject [options]"
        opts.on("--name NAME", "Workspace name") { |v| name = v }
        opts.on("--work-item REF", "Work item reference") { |v| work_item = v }
        opts.on("--body TEXT", "Text to inject into the pane") { |v| body = v }
        opts.on("--interrupt", "Interrupt the running stage first (sends Ctrl-C)") { interrupt = true }
        opts.on("--dry-run", "Print without sending") { dry_run = true }
      end
      parser.parse!(args)

      name ||= @project_detector.detect(@working_dir)
      raise UsageError, "Missing workspace name.\n\n#{agent_run_help}" if name.nil?
      raise UsageError, "Missing --work-item.\n\n#{agent_run_help}" if work_item.nil?
      raise UsageError, "Missing --body.\n\n#{agent_run_help}" if body.nil?

      message = {
        "type" => "inject",
        "workspace" => name,
        "work_item_ref" => work_item,
        "interrupt" => interrupt,
        "body" => jsonl_body(body)
      }
      agent_run_send(name, message, dry_run: dry_run)
    end

    # Asks the agent daemon to /clear the coding agent in one named pane and,
    # once its context usage has dropped, type a prompt into it.
    def cmd_agent_run_restart(args)
      name = nil
      pane = nil
      prompt = nil
      force = false
      wait = false
      timeout = nil
      json = false

      parser = OptionParser.new do |opts|
        opts.banner = "Usage: workspace agent-run restart --pane PANE --prompt TEXT [options]"
        opts.separator ""
        opts.separator "Clear the coding agent in one pane and give it a fresh prompt. The agent daemon"
        opts.separator "first waits up to #{AgentRestart::QUIET_TIMEOUT}s (fixed, not bounded by --timeout) for the pane to go"
        opts.separator "quiet, types /clear, then waits until the new session's first status-line render"
        opts.separator "confirms the clear, then types the prompt. --timeout only bounds that confirm step."
        opts.separator "If the clear can't be confirmed, the prompt is not typed. An agent can run this on"
        opts.separator "its own pane and end its turn: the daemon types from outside the pane. Only Claude"
        opts.separator "panes are accepted (other agents fail with code unsupported_agent). Needs context"
        opts.separator "readings, so `workspace statusline` must be installed as Claude's statusLine."
        opts.separator ""
        opts.separator "Options:"
        opts.on("--name NAME", "Workspace name (default: detected from cwd)") { |v| name = v }
        opts.on("--pane PANE", "Pane to restart: a pane id (%12), window.pane (0.1),",
          "session:window.pane, or a pane index in window 0 (required)") { |v| pane = v }
        opts.on("--prompt TEXT", "Text typed once /clear is confirmed (required)") { |v| prompt = v }
        opts.on("--force", "Restart even when a pipeline stage is running on the pane") { force = true }
        opts.on("--wait", "Wait for the restart to finish and report how it went") { wait = true }
        opts.on("--timeout DURATION", "Longest wait for context usage to drop after /clear",
          "(e.g. \"45s\", or seconds); default #{AgentRestart::CONFIRM_TIMEOUT}s, at most " \
          "#{Commands::Agent::MAX_RESTART_TIMEOUT}s") do |v|
          timeout = parse_duration_option("--timeout", v, positive: true)
        end
        opts.on("--json", "Print the result as JSON; errors as {\"schema_version\":1,\"ok\":false,\"error\":...}") { json = true }
        opts.separator ""
        opts.separator "Examples:"
        opts.separator "  workspace agent-run restart --name myapp --pane 0.1 --prompt \"Read HANDOFF.md and follow it.\" --wait"
        opts.separator "  workspace agent-run restart --pane %18 --prompt \"Resume from HANDOFF.md\" --json"
      end
      parser.parse!(args)
      raise UsageError, "Unexpected argument: #{args.first}\n\n#{parser.help}" if args.any?

      name ||= @project_detector.detect(@working_dir)
      raise UsageError, "Missing workspace name (pass --name).\n\n#{parser.help}" if name.nil?
      raise UsageError, "Missing --pane.\n\n#{parser.help}" if pane.nil? || pane.strip.empty?
      raise UsageError, "Missing --prompt.\n\n#{parser.help}" if prompt.nil? || prompt.strip.empty?
      if timeout && timeout > Commands::Agent::MAX_RESTART_TIMEOUT
        raise UsageError, "--timeout: at most #{Commands::Agent::MAX_RESTART_TIMEOUT}s"
      end
      raise Error, "workspace agent-run restart is not available in this build" unless @restart_agent_command

      result = @restart_agent_command.call(name: name, pane: pane, prompt: prompt, force: force, wait: wait,
        timeout: timeout, json: json)
      @exit_handler.exit(result[:exit_code]) unless result[:exit_code].zero?
    rescue OptionParser::ParseError, UsageError => e
      raise unless json_requested?(json, args)
      emit_json_error(Commands::RestartAgent::JSON_SCHEMA_VERSION, e, message: e.message.lines.first.strip)
    end

    # Types text or tmux key names into one named pane. The pane must be a
    # pane id or window.pane of the workspace's own tmux session; there is
    # no default pane. See {Workspace::Commands::Send}.
    def cmd_agent_run_send(args)
      name = nil
      pane = nil
      body = nil
      keys = nil
      no_enter = false
      json = false

      parser = OptionParser.new do |opts|
        opts.banner = "Usage: workspace agent-run send --pane PANE (--body TEXT | --keys KEYS) [options]"
        opts.separator ""
        opts.separator "Type into one pane of a workspace's tmux session, straight through tmux (no agent daemon)."
        opts.separator "The pane is always named: a pane id (%19, from `workspace sessions --json`) or window.pane"
        opts.separator "(0.1). It is checked against the workspace's own tmux session first, so a wrong or stale"
        opts.separator "pane is an error, never a different pane."
        opts.separator ""
        opts.separator "  --body TEXT  pastes TEXT literally (no key names are interpreted), then presses Enter."
        opts.separator "  --keys KEYS  sends tmux key names, never text and never an implicit Enter: add Enter"
        opts.separator "               yourself (\"Escape\", \"Up Up Enter\", \"C-c\", \"y\"). Anything that isn't a key"
        opts.separator "               name is refused before the first key is sent."
        opts.separator ""
        opts.separator "Options:"
        opts.on("--name NAME", "Workspace name (default: detected from cwd)") { |v| name = v }
        opts.on("--pane PANE", "Pane id (%19) or window.pane (0.1)  (required)") { |v| pane = v }
        opts.on("--body TEXT", "Literal text to paste, then Enter") { |v| body = v }
        opts.on("--keys KEYS", "Space-separated tmux key names") { |v| keys = v }
        opts.on("--no-enter", "With --body, paste the text without pressing Enter") { no_enter = true }
        opts.on("--json", "Print the result as JSON; errors as {\"schema_version\":1,\"ok\":false,\"error\":...}") { json = true }
        opts.separator ""
        opts.separator "Exit codes: 0 delivered; 1 not delivered (safe to resend) or bad input; 2 text landed but wasn't"
        opts.separator "  confirmed submitted (check the pane before resending)."
        opts.separator ""
        opts.separator "Examples:"
        opts.separator "  workspace agent-run send --name api --pane %19 --body \"yes\""
        opts.separator "  workspace agent-run send --name api --pane %19 --keys Escape --json"
        opts.separator "  workspace agent-run send --pane 0.1 --keys \"Up Enter\""
      end
      parser.parse!(args)
      raise UsageError, "Unexpected argument: #{args.first}\n\n#{parser.help}" if args.any?

      name ||= @project_detector.detect(@working_dir)
      raise UsageError, "Missing workspace name (pass --name).\n\n#{parser.help}" if name.nil?
      raise UsageError, "Missing --pane.\n\n#{parser.help}" if pane.nil? || pane.strip.empty?
      raise UsageError, "Pass --body or --keys, not both.\n\n#{parser.help}" if body && keys
      raise UsageError, "Missing --body or --keys.\n\n#{parser.help}" if body.nil? && keys.nil?
      raise UsageError, "--body can't be empty.\n\n#{parser.help}" if body && body.empty?
      raise UsageError, "--no-enter applies to --body; --keys never presses Enter on its own.\n\n#{parser.help}" if no_enter && keys
      raise Error, "workspace agent-run send is not available in this build" unless @send_command

      key_names = keys && Commands::Send.parse_keys(keys)
      @send_command.call(name: name, pane: pane, body: body, keys: key_names, enter: !no_enter, json: json)
    end

    def handoff_help
      <<~HELP
        Usage: workspace handoff check NAME [options]
               workspace handoff new NAME [--handoff-doc PATH|--handoff-prompt TEXT] [options]

        Watches a coding agent's context-window usage and hands off to a fresh
        conversation before it fills up: `check` tells the agent to save its state
        once usage crosses a threshold, `new` clears the conversation and resumes it
        (the same flow as `workspace agent-run restart`).

        NAME defaults to the workspace detected from the current directory.

        With neither --handoff-doc nor --handoff-prompt, both use the workspace's plan
        (IMPLEMENTATION_PLAN.md) when its notes directory has one, else HANDOFF.md there
        (`check` makes the directory first); `new` also binds the pane to the
        implementation-plan play when the plan is the doc. If the notes
        directory can't be worked out, `check` lets the agent pick a path and `new`
        fails with notes_dir_unresolved: pass --handoff-doc then.

        Options (check):
          --pane PANE            tmux pane id ('%19'; "$TMUX_PANE" inside the pane),
                                  window.pane (1.0), or a pane index in window 0
                                  (default: the first Claude Code pane; `workspace
                                  sessions NAME` lists panes). Must be a pane of
                                  NAME's own tmux session
          --threshold PCT        Context usage percent that triggers a handoff, 1-100
                                  (default: handoff.threshold, or 11)
          --context-pct N        Skip detection and use this value (0-100)
          --handoff-doc PATH     Doc the agent updates and resumes from (default: the
                                  plan, else HANDOFF.md, in the notes directory)
          --handoff-prompt TEXT  Prompt sent verbatim instead of a doc
          --json                 Print the result as JSON, with "next"
                                  (continue, handoff or unknown) and "doc"

        Options (new):
          --pane PANE            tmux pane id ('%19'; "$TMUX_PANE" inside the pane),
                                  window.pane (1.0), or a pane index in window 0
                                  (default: the first Claude Code pane; `workspace
                                  sessions NAME` lists panes). Must be a pane of
                                  NAME's own tmux session
          --handoff-doc PATH     Doc the agent reads and resumes from (default: the
                                  plan, else HANDOFF.md, in the notes directory)
          --handoff-prompt TEXT  Prompt sent verbatim instead of a doc
          --wait                 Wait for the restart to finish and report how it
                                  went (don't use this from the agent being restarted)
          --json                 Print the result as JSON

        Exit codes (check): 0 under the threshold, 1 at/over it (a save-state prompt
        was sent), 2 when context usage can't be determined (nothing was sent).

        Examples:
          workspace handoff check myapp                           # the doc is the plan, else HANDOFF.md
          workspace handoff check myapp --handoff-doc HANDOFF.md
          workspace handoff check myapp --pane 2 --threshold 20 --json    # for scripting
          workspace handoff new myapp --pane 1 --handoff-doc HANDOFF.md    # without going through check
          workspace handoff check myapp --pane "$TMUX_PANE" --handoff-doc HANDOFF.md    # an agent, on its own pane
          workspace handoff new myapp --pane "$TMUX_PANE" --handoff-doc HANDOFF.md
      HELP
    end

    # Dispatches `workspace handoff check|new`. Never guesses a pane or a
    # context percentage; see {Workspace::Commands::Handoff}.
    def cmd_handoff(args)
      original_args = args.dup
      subcommand = args.shift
      case subcommand
      when "check" then cmd_handoff_check(args)
      when "new" then cmd_handoff_new(args)
      else
        raise UsageError, handoff_help
      end
    rescue UsageError => e
      raise unless json_requested?(false, original_args)
      emit_json_error(Commands::Handoff::JSON_SCHEMA_VERSION, e, message: e.message.lines.first.strip)
    end

    def cmd_handoff_check(args)
      pane = nil
      threshold = nil
      context_pct = nil
      handoff_doc = nil
      handoff_prompt = nil
      json = false

      parser = OptionParser.new do |opts|
        opts.banner = "Usage: workspace handoff check NAME [options]"
        opts.on("--pane PANE", "tmux pane id ('%19'; \"$TMUX_PANE\" inside the pane), window.pane (1.0), or a pane index in window 0;",
          "must be a pane of NAME's own tmux session; default: the first Claude Code pane") { |v| pane = v }
        opts.on("--threshold PCT", "Context usage percent that triggers a handoff") { |v| threshold = v }
        opts.on("--context-pct N", Integer, "Skip detection and use this value") { |v| context_pct = v }
        opts.on("--handoff-doc PATH", "Doc the agent updates and resumes from (default: the plan, else HANDOFF.md, in the notes directory)") { |v| handoff_doc = v }
        opts.on("--handoff-prompt TEXT", "Prompt sent verbatim instead of a doc") { |v| handoff_prompt = v }
        opts.on("--json", "Print the result as JSON; errors as {\"schema_version\":1,\"ok\":false,\"error\":...}") { json = true }
      end
      parser.parse!(args)
      raise UsageError, "--handoff-doc and --handoff-prompt are mutually exclusive.\n\n#{parser.help}" if handoff_doc && handoff_prompt
      if threshold
        begin
          threshold = HandoffConfig.parse_threshold(threshold)
        rescue ArgumentError => e
          raise UsageError, "--threshold #{e.message}\n\n#{parser.help}"
        end
      end

      name = args.shift
      name ||= @project_detector.detect(@working_dir)
      raise UsageError, "Missing workspace name.\n\n#{parser.help}" if name.nil?
      raise UsageError, "Unexpected argument: #{args.first}\n\n#{parser.help}" if args.any?
      raise Error, "workspace handoff is not available in this build" unless @handoff_command

      result = @handoff_command.check(name: name, pane: pane, threshold: threshold, context_pct: context_pct,
        handoff_doc: handoff_doc, handoff_prompt: handoff_prompt, json: json)
      @exit_handler.exit(result[:exit_code]) unless result[:exit_code].zero?
    rescue OptionParser::ParseError, UsageError, Error => e
      raise unless json_requested?(json, args)
      emit_json_error(Commands::Handoff::JSON_SCHEMA_VERSION, e, message: e.message.lines.first.strip)
    end

    def cmd_handoff_new(args)
      pane = nil
      handoff_doc = nil
      handoff_prompt = nil
      wait = false
      json = false

      parser = OptionParser.new do |opts|
        opts.banner = "Usage: workspace handoff new NAME [options]"
        opts.on("--pane PANE", "tmux pane id ('%19'; \"$TMUX_PANE\" inside the pane), window.pane (1.0), or a pane index in window 0;",
          "must be a pane of NAME's own tmux session; default: the first Claude Code pane") { |v| pane = v }
        opts.on("--handoff-doc PATH", "Doc the agent reads and resumes from (default: the plan, else HANDOFF.md, in the notes directory)") { |v| handoff_doc = v }
        opts.on("--handoff-prompt TEXT", "Prompt sent verbatim instead of a doc") { |v| handoff_prompt = v }
        opts.on("--wait", "Wait for the restart to finish and report how it went") { wait = true }
        opts.on("--json", "Print the result as JSON; errors as {\"schema_version\":1,\"ok\":false,\"error\":...}") { json = true }
      end
      parser.parse!(args)
      raise UsageError, "--handoff-doc and --handoff-prompt are mutually exclusive.\n\n#{parser.help}" if handoff_doc && handoff_prompt

      name = args.shift
      name ||= @project_detector.detect(@working_dir)
      raise UsageError, "Missing workspace name.\n\n#{parser.help}" if name.nil?
      raise UsageError, "Unexpected argument: #{args.first}\n\n#{parser.help}" if args.any?
      raise Error, "workspace handoff is not available in this build" unless @handoff_command

      result = @handoff_command.new(name: name, pane: pane, handoff_doc: handoff_doc, handoff_prompt: handoff_prompt, wait: wait, json: json)
      @exit_handler.exit(result[:exit_code]) unless result[:exit_code].zero?
    rescue OptionParser::ParseError, Error => e
      raise unless json_requested?(json, args)
      emit_json_error(Commands::Handoff::JSON_SCHEMA_VERSION, e, message: e.message.lines.first.strip)
    end

    def cmd_agent_run_examples
      name = @project_detector.detect(@working_dir) || "workspace"

      examples = [
        {
          label: "command — check GitHub CI status (safe, read-only)",
          cli: "workspace agent-run command --work-item WC-42 --body \"What is the current status of GitHub CI for this branch?\"",
          message: {
            "type" => "command",
            "workspace" => name,
            "work_item_ref" => "WC-42",
            "dispatch_id" => "debug-abcd1234",
            "body" => "What is the current status of GitHub CI for this branch?"
          }
        },
        {
          label: "command — run the linter (safe, re-runnable)",
          cli: "workspace agent-run command --work-item WC-42 --body \"Run the linter and report any issues.\"",
          message: {
            "type" => "command",
            "workspace" => name,
            "work_item_ref" => "WC-42",
            "dispatch_id" => "debug-abcd1234",
            "body" => "Run the linter and report any issues."
          }
        },
        {
          label: "inject — queue a steer for the next pipeline stage",
          cli: "workspace agent-run inject --work-item WC-42 --body \"Focus on the failing tests, not the linter warnings.\"",
          message: {
            "type" => "inject",
            "workspace" => name,
            "work_item_ref" => "WC-42",
            "interrupt" => false,
            "body" => "Focus on the failing tests, not the linter warnings."
          }
        },
        {
          label: "inject --interrupt — urgent steer: stop current stage and redirect",
          cli: "workspace agent-run inject --interrupt --work-item WC-42 --body \"Stop. Run bundle exec rspec spec/workspace/cli_spec.rb first.\"",
          message: {
            "type" => "inject",
            "workspace" => name,
            "work_item_ref" => "WC-42",
            "interrupt" => true,
            "body" => "Stop. Run bundle exec rspec spec/workspace/cli_spec.rb first."
          }
        },
        {
          label: "restart — clear the coding agent in one pane and hand it a fresh prompt",
          cli: "workspace agent-run restart --pane 0.1 --prompt \"Read HANDOFF.md and follow it.\" --wait",
          message: {
            "type" => "restart_agent",
            "workspace" => name,
            "pane" => "0.1",
            "prompt" => "Read HANDOFF.md and follow it.",
            "force" => false,
            "wait" => true
          }
        }
      ]

      examples.each_with_index do |example, i|
        @output.puts "#{i + 1}. #{example[:label]}"
        @output.puts "   Run it: #{example[:cli]}"
        @output.puts "   JSONL (sent as a single line):"
        JSON.pretty_generate(example[:message]).each_line do |line|
          @output.puts "   #{line}"
        end
        @output.puts unless i == examples.size - 1
      end
    end

    # If +body+ looks like JSON (parses successfully), compact it to a single
    # line so it travels safely as JSONL. Plain strings pass through unchanged.
    def jsonl_body(body)
      parsed = JSON.parse(body)
      compacted = parsed.to_json
      if compacted != body.strip
        @output.puts "(body compacted to JSONL)"
      end
      compacted
    rescue JSON::ParserError
      body
    end

    # Pretty-prints +message+ as the JSONL that will be sent, then sends it
    # (unless +dry_run+ is true) and pretty-prints the reply.
    def agent_run_send(name, message, dry_run: false)
      socket_path = @config.agent_socket_path(name)
      @output.puts "Sending JSONL to #{socket_path}:"
      JSON.pretty_generate(message).each_line { |line| @output.puts "  #{line}" }

      if dry_run
        @output.puts "(dry-run: not sent)"
        return
      end

      @output.puts
      reply = send_to_agent(name, message)
      @output.puts "Reply:"
      JSON.pretty_generate(reply).each_line { |line| @output.puts "  #{line}" }
      reply
    end

    # Drives and inspects a running agent's pipeline. These are operator tools:
    # everything that touches a pane goes through the agent that owns it, so a
    # manual nudge cannot get the agent's own view of the pipeline out of step.
    def cmd_pipeline(args)
      # The subcommand is the first non-option argument, so a leading flag
      # (e.g. `pipeline --json status`) is dispatched correctly regardless of
      # where it appears.
      index = args.index { |a| !a.start_with?("-") }
      subcommand = index && args[index]
      rest = index ? args[0...index] + args[(index + 1)..] : args

      # With --json the notice is in an action document's `warnings` instead, and stderr stays empty.
      @error_output.puts "Warning: #{PIPELINE_DEPRECATION}" if %w[start advance status reset].include?(subcommand) && !rest.include?("--json")
      case subcommand
      when "start" then cmd_pipeline_start(rest)
      when "advance" then cmd_pipeline_advance(rest)
      when "status" then cmd_pipeline_status(rest)
      when "reset" then cmd_pipeline_reset(rest)
      when "help", nil then @output.puts pipeline_help
      else
        raise UsageError, pipeline_help
      end
    end

    # Printed by every `pipeline` subcommand and in its help.
    PIPELINE_DEPRECATION = "`workspace pipeline` is deprecated and will be removed in a later release. " \
      "Use `workspace workflow` (see `workspace workflow --help`)."

    def pipeline_help
      <<~HELP
        Usage: workspace pipeline <subcommand> [options]

        Deprecated: use `workspace workflow`, which runs ordered steps in a workspace's agent pane
        and shows where a run is stuck. `pipeline` will be removed in a later release.

        Subcommands:
          start <project> --work-item REF    Send a work item into the project's pipeline
          advance <project> --work-item REF  Mark the running stage complete and move on
          status <project>                   Show what the project has in flight
          reset <project>                    Clear a stopped project's pipeline state

        Options:
          --work-item REF   Work item reference (e.g. WC-42)
          --body TEXT       Message body to send (start/advance)
          --json            Print JSON: the status (status), or an action document (start, advance, reset)

        'advance' marks the running stage complete even if it has not finished.

        Examples:
          workspace pipeline status myapp    # what is myapp working on?
          workspace pipeline status myapp --json    # same, for a script
          workspace pipeline start myapp --work-item WC-42 --body "/build add OAuth support"
          workspace pipeline advance myapp --work-item WC-42    # push a work item through by hand
          workspace pipeline reset myapp    # clear leftover state after stopping the agent
      HELP
    end

    def cmd_pipeline_start(args)
      project, work_item, body, json = parse_pipeline_args(args, "start")
      raise UsageError, "Missing project or --work-item.\n\n#{pipeline_help}" if project.nil? || work_item.nil?

      run_action("pipeline start", json: json) do
        reply = send_to_agent(project,
          "type" => "command", "workspace" => project, "work_item_ref" => work_item,
          "dispatch_id" => "manual-#{SecureRandom.hex(4)}",
          "body" => body || "Begin work on #{work_item}.")
        raise Error, "The agent for #{project} refused the work item: #{reply["error"]}" unless reply["ok"]
        @output.puts "Sent #{work_item} into #{project}'s pipeline"
        {results: json ? [action_row(project, "started", work_item_ref: work_item)] : [], warnings: [PIPELINE_DEPRECATION]}
      end
    end

    # Types the completion sentinel into the running stage's pane, which is
    # exactly what a finished stage would print, so the agent advances normally.
    #
    # The stage's token comes from the persisted state. If the stage moves on
    # between that read and the inject, the sentinel carries the old stage's
    # token and the new stage ignores it, rather than being ended unasked.
    def cmd_pipeline_advance(args)
      project, work_item, body, json = parse_pipeline_args(args, "advance")
      raise UsageError, "Missing project or --work-item.\n\n#{pipeline_help}" if project.nil? || work_item.nil?

      run_action("pipeline advance", json: json) do
        token = read_pipeline_state(project).dig(work_item, "sentinel_token")
        # The body reaches a live shell, so it is escaped rather than interpolated.
        sentinel = "#{SentinelPoller.marker(token)} #{body || "manual advance"}"
        reply = send_to_agent(project,
          "type" => "inject", "workspace" => project, "work_item_ref" => work_item,
          "interrupt" => true, "expected_token" => token, "body" => "echo #{Shellwords.escape(sentinel)}")
        unless reply["ok"]
          raise Error.new("The stage moved on before the advance landed; run 'workspace pipeline advance' again", code: "stale_token") if reply["error"] == "stale_token"
          raise Error, "The agent for #{project} refused the advance: #{reply["error"]}"
        end
        @output.puts "Nudged #{project}/#{work_item} to advance"
        {results: json ? [action_row(project, "advanced", work_item_ref: work_item)] : [], warnings: [PIPELINE_DEPRECATION]}
      end
    end

    # `workspace pipeline status --json`'s schema version.
    PIPELINE_JSON_SCHEMA_VERSION = 1

    def cmd_pipeline_status(args)
      as_json = false
      parser = OptionParser.new do |opts|
        opts.banner = "Usage: workspace pipeline status <project>"
        opts.on("--json", "Print JSON ({schema_version, ok, entries}; failures print {schema_version, ok: false, error, code}) instead of a table") { as_json = true }
      end
      parser.parse!(args)
      project = args.shift
      raise UsageError, parser.help if project.nil?

      entries = read_pipeline_state(project)
      return @output.puts JSON.generate({"schema_version" => PIPELINE_JSON_SCHEMA_VERSION, "ok" => true, "entries" => entries.values}) if as_json

      if entries.empty?
        @output.puts "No pipeline work in flight for #{project}"
        return
      end

      @output.puts "WORK ITEM  PANE  STAGE  DEADLINE"
      entries.each_value do |entry|
        deadline = format_deadline(entry["deadline_at"])
        @output.puts "#{entry["work_item_ref"]}  pane #{entry["pane_index"]}  #{entry["phase"] || "(no pipeline)"}  #{deadline}"
      end
    rescue OptionParser::ParseError, UsageError => e
      raise unless json_requested?(as_json, args)
      emit_json_error(PIPELINE_JSON_SCHEMA_VERSION, e, message: e.message.lines.first.strip)
    end

    # Renders a stage's deadline in local time plus how far off it is, so an
    # operator scanning the table doesn't have to convert UTC in their head.
    # `--json` keeps the raw ISO 8601 UTC string this formats.
    def format_deadline(deadline_at)
      return "-" if deadline_at.nil?

      deadline = Time.parse(deadline_at)
      remaining = deadline - @clock.call
      relative = (remaining >= 0) ? "in #{Duration.humanize(remaining)}" : "overdue #{Duration.humanize(-remaining)}"
      "#{deadline.localtime.strftime("%H:%M")} (#{relative})"
    end

    # Tolerates an unreadable state file the way the agent does, so the command
    # an operator reaches for when things look wrong is not the one that dies.
    def read_pipeline_state(project)
      state_path = @config.pipeline_state_path(project)
      return {} unless File.exist?(state_path)
      entries = JSON.parse(File.read(state_path))
      entries.is_a?(Hash) ? entries : {}
    rescue JSON::ParserError, SystemCallError
      @error_output.puts "Could not read #{project}'s pipeline state at #{state_path}; treating it as empty"
      {}
    end

    # The agent holds this state in memory while it runs, so clearing the file
    # under a live agent would only put the two out of step.
    def cmd_pipeline_reset(args)
      json = false
      parser = OptionParser.new do |opts|
        opts.banner = "Usage: workspace pipeline reset <project> [--json]"
        opts.on("--json", "Print one action document (see docs/README.json.md) instead of text") { json = true }
      end
      parser.parse!(args)
      project = args.shift
      raise UsageError, "Usage: workspace pipeline reset <project> [--json]" if project.nil? || args.any?

      run_action("pipeline reset", json: json) do
        if agent_running?(project)
          raise Error, "The agent for #{project} is running; stop it (Ctrl-C in its pane, " \
            "or kill the 'workspace agentd' process) before resetting its pipeline state"
        end

        state_path = @config.pipeline_state_path(project)
        File.unlink(state_path) if File.exist?(state_path)
        @output.puts "Cleared pipeline state for #{project}"
        {results: json ? [action_row(project, "reset")] : [], warnings: [PIPELINE_DEPRECATION]}
      end
    end

    def parse_pipeline_args(args, subcommand)
      work_item = nil
      body = nil
      json = false
      parser = OptionParser.new do |opts|
        opts.banner = "Usage: workspace pipeline #{subcommand} <project> --work-item REF [--json]"
        opts.on("--work-item REF", "Work item reference") { |v| work_item = v }
        opts.on("--body TEXT", "Message body") { |v| body = v }
        opts.on("--json", "Print one action document (see docs/README.json.md) instead of text") { json = true }
      end
      parser.parse!(args)
      project = args.shift
      raise UsageError, "Unexpected arguments: #{args.join(" ")}\n\n#{parser.help}" if args.any?
      [project, work_item, body, json]
    end

    def send_to_agent(project, message)
      socket = begin
        UNIXSocket.open(@config.agent_socket_path(project))
      rescue SystemCallError, IOError
        raise Error.new("No agent is running for #{project}. Start one with: workspace agentd --name #{project}", code: "no_daemon")
      end
      reply = begin
        socket.puts(message.to_json)
        socket.gets
      rescue SystemCallError, IOError
        raise Error.new("The agent for #{project} closed the connection without replying", code: "connection_failed")
      ensure
        socket.close
      end
      raise Error.new("The agent for #{project} closed the connection without replying", code: "connection_failed") if reply.nil?
      JSON.parse(reply)
    rescue JSON::ParserError
      raise Error.new("Unreadable reply from the agent for #{project}", code: "unreadable_reply")
    end

    def agent_running?(project)
      @config.agent_running?(project)
    end

    def cmd_run_and_report(args)
      parser = OptionParser.new do |opts|
        opts.banner = "Usage: workspace run-and-report '<command>'"
        opts.separator ""
        opts.separator "Run a shell command as a subprocess (bypassing tmux)."
        opts.separator "Captures stdout, stderr, and exit status, writes them under a UUID,"
        opts.separator "prints the JSON result, and exits with the command's exit code."
        opts.separator ""
        opts.separator "Examples:"
        opts.separator "  workspace run-and-report 'echo hello'    # run a command and capture its output"
        opts.separator "  workspace run-and-report 'rake spec'    # check the exit code in a script via $?"
        opts.separator "  workspace run-and-report 'bundle exec rspec' | jq '.status'    # parse the JSON result"
      end
      parser.parse!(args)

      raise UsageError, parser.help if args.empty?

      command = args.join(" ")
      project = @project_detector.detect(@working_dir)

      result = @run_and_report_command.call(command, project: project)

      @output.puts result.to_json
      @exit_handler.exit(result.status) unless result.status == 0
    end

    def cmd_report_run_status(args)
      parser = OptionParser.new do |opts|
        opts.banner = "Usage: workspace report-run-status <uuid> <exit_code>"
        opts.separator ""
        opts.separator "Internal command called by the --wait shell wrapper."
        opts.separator "Reads <uuid>.stdout and <uuid>.stderr from the run results directory,"
        opts.separator "writes the complete JSON result file, and exits 0."
      end
      parser.parse!(args)

      raise UsageError, parser.help if args.size < 2

      uuid = args[0]

      # UUIDs index into the run-results directory, so reject anything that could
      # escape it (e.g. "../../etc/passwd").
      unless uuid.match?(/\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/)
        raise UsageError, "Invalid UUID format: #{uuid.inspect}\n\n#{parser.help}"
      end

      exit_code = begin
        Integer(args[1])
      rescue ArgumentError, TypeError
        raise UsageError, "exit_code must be an integer, got: #{args[1].inspect}\n\n#{parser.help}"
      end

      stdout = @run_result_store.read_stdout(uuid)
      stderr = @run_result_store.read_stderr(uuid)

      result = Workspace::RunResult.new(
        uuid: uuid,
        project: nil,
        command: nil,
        status: exit_code,
        stdout: stdout,
        stderr: stderr,
        started_at: nil,
        finished_at: Time.now.utc.iso8601
      )

      @run_result_store.write(result)
    end

    def cmd_layout(args)
      subcommand = args.shift

      case subcommand
      when "save"
        project, name = resolve_layout_args(args)
        raise UsageError, layout_help_text unless project
        name ||= Commands::Layout::DEFAULT_NAME
        @layout_command.save(project, name)
      when "restore"
        project, name = resolve_layout_args(args)
        raise UsageError, layout_help_text unless project
        name ||= Commands::Layout::DEFAULT_NAME
        @layout_command.restore(project, name)
      when "list"
        project = settle_name(args[0]) || @project_detector.detect(@working_dir)
        raise UsageError, layout_help_text unless project
        @layout_command.list(project)
      when "help", "--help", "-h", nil
        layout_help
      else
        raise UsageError, "Unknown layout subcommand: #{subcommand}\n\n" + layout_help_text
      end
    end

    # Resolves layout save/restore args, handling auto-detection.
    # With 0 args: detect project, no layout name
    # With 1 arg: if project detected, treat arg as layout name; otherwise as project
    # With 2 args: first is project, second is layout name
    def resolve_layout_args(args)
      case args.size
      when 0
        [@project_detector.detect(@working_dir), nil]
      when 1
        detected = @project_detector.detect(@working_dir)
        if detected
          [detected, args[0]]
        else
          [args[0], nil]
        end
      else
        [args[0], args[1]]
      end
    end

    def layout_help
      @output.puts layout_help_text
    end

    def layout_help_text
      <<~HELP
        Usage: workspace layout <subcommand> <project> [name]

        Subcommands:
          save <project> [name]      Save the current pane layout (default name: 'default')
          restore <project> [name]   Restore a saved layout (default name: 'default')
          list <project>             List saved layouts for a project

        Layouts are auto-saved as '_before_resize' whenever you run 'workspace resize',
        so you can always undo with: workspace layout restore <project> _before_resize

        Examples:
          workspace layout save myproject           # save as 'default'
          workspace layout save myproject coding    # save as 'coding'
          workspace layout restore myproject        # restore 'default'
          workspace layout list myproject           # show saved layouts
      HELP
    end

    def cmd_init(args)
      dry_run = false
      force = false
      hooks = nil
      parser = OptionParser.new do |opts|
        opts.banner = "Usage: workspace init [options]"
        opts.separator ""
        opts.separator "Set up workspace by installing tmuxinator templates and creating"
        opts.separator "the config directory if it doesn't exist."
        opts.separator ""
        opts.separator "Options:"
        opts.on("--dry-run", "Show what would be done without making changes") do
          dry_run = true
        end
        opts.on("-f", "--force", "Overwrite existing templates even if they differ") do
          force = true
        end
        opts.on("--install-hooks", "Install agent session hooks without asking") do
          hooks = true
        end
        opts.on("--no-install-hooks", "Skip the agent session hooks step") do
          hooks = false
        end
        opts.separator ""
        opts.separator "Examples:"
        opts.separator "  workspace init    # install templates and create the config directory"
        opts.separator "  workspace init --dry-run    # preview what would be done"
        opts.separator "  workspace init --force    # overwrite modified templates"
        opts.separator "  workspace init --install-hooks    # install agent session hooks without prompting"
        opts.separator "  workspace init --no-install-hooks    # skip the hooks step entirely"
      end
      parser.parse!(args)

      @init_command.call(dry_run: dry_run, force: force, hooks: hooks)
    end

    def cmd_sessions(args)
      json = false
      watch = false
      interval = 2
      worktrees = false
      parser = OptionParser.new do |opts|
        opts.banner = "Usage: workspace sessions [options] [project]"
        opts.separator ""
        opts.separator "Show the coding-agent sessions running in a workspace's panes,"
        opts.separator "whether each is working, idle, waiting on a person, or done, and any"
        opts.separator "sub-agents they started."
        opts.separator ""
        opts.separator "STATE column: working (output changing), idle (output unchanged 30s+),"
        opts.separator "waiting (the agent asked for permission or input; needs the"
        opts.separator "Notification hook from workspace init), or done (the agent's turn"
        opts.separator "ended; needs the Stop hook). A waiting pane shows the"
        opts.separator "agent's message on the line below it. waiting is Claude Code only;"
        opts.separator "other agents (Codex, OpenCode, Pi) only ever show working or idle."
        opts.separator ""
        opts.separator "Requires a running agent daemon (workspace agentd <project>; re-run"
        opts.separator "`workspace init` if `workspace doctor` reports it missing)."
        opts.separator ""
        opts.separator "LOCK column: shows every lock a pane holds or waits on (e.g. \"edit ✓ devenv #2\","
        opts.separator "space-joined, edit first and others alphabetical). JSON output includes a locks array."
        opts.separator ""
        opts.separator "--worktrees also shows sessions for the project's child worktree workspaces"
        opts.separator "(config names \"<project>.worktree-*\"), one table per workspace that has an"
        opts.separator "agent daemon running; workspaces without one are omitted silently. With no"
        opts.separator "[project], the parent of the current worktree is used, so the whole family"
        opts.separator "shows even when run from inside a worktree. --json nests them under a"
        opts.separator "\"workspaces\" array."
        opts.separator ""
        opts.separator "Options:"
        opts.on("--json", "Emit the raw payload instead of a table") { json = true }
        opts.on("--watch", "Redraw until interrupted") { watch = true }
        opts.on("--interval SECONDS", Float, "Seconds between redraws (default 2)") do |value|
          interval = value
        end
        opts.on("--worktrees", "Also show sessions for child worktree workspaces") { worktrees = true }
        opts.separator ""
        opts.separator "Examples:"
        opts.separator "  workspace sessions    # sessions for the current directory's project"
        opts.separator "  workspace sessions my-project    # sessions for a named project"
        opts.separator "  workspace sessions --watch    # watch and redraw every 2 seconds"
        opts.separator "  workspace sessions --json    # emit raw JSON for scripting"
        opts.separator "  workspace sessions my-project --worktrees    # include the project's worktree workspaces"
      end

      parser.parse!(args)

      project = settle_name(args.first) || @project_detector.detect(@working_dir)
      raise UsageError, parser.help unless project

      result = @sessions_command.call(name: project, json: json, watch: watch, interval: interval, worktrees: worktrees)
      @exit_handler.exit(result[:exit_code]) if result && !result[:exit_code].zero?
    end

    def review_parser(options)
      OptionParser.new do |opts|
        opts.banner = "Usage: workspace review [show] [WORKSPACE] [--json]\n       workspace review list [PROJECT] [--json]"
        opts.separator ""
        opts.separator "Collect what you need to review a coding agent's finished work. A workspace is ready"
        opts.separator "when its agent is done (the Stop hook fired and no pane is working or waiting) and its"
        opts.separator "branch has commits its base branch (origin's default branch) lacks. A stopped workspace"
        opts.separator "is judged by its agent's last recorded state (agent_state_source \"recorded\" in --json)."
        opts.separator ""
        opts.separator "  show [WORKSPACE]  One workspace's packet: agent state, task, diffstat and commits against the"
        opts.separator "                    base, the pull request and its checks (read with `gh pr view`), open"
        opts.separator "                    questions, session count and the agent's last message. WORKSPACE"
        opts.separator "                    defaults to the one for the current directory. A workspace named"
        opts.separator "                    \"list\" is reviewed with `review show list`."
        opts.separator "  list [PROJECT]    The project's workspaces that are ready. PROJECT is a project name, a"
        opts.separator "                    member workspace name or a path; it defaults to the current directory's."
        opts.separator "                    Runs git only for workspaces whose agent is done, and never calls gh."
        opts.separator ""
        opts.separator "Reads only; nothing is written. A source that can't answer (no agent daemon, git or gh"
        opts.separator "failing or too slow) is reported as unavailable, never as clean."
        opts.separator ""
        opts.on("--json", "Print schema-versioned JSON (see docs/README.review.md)") { options[:json] = true }
        opts.on("-h", "--help", "Show this help") { options[:help] = true }
        opts.separator ""
        opts.separator "Examples:"
        opts.separator "  workspace review list    # what is ready in this project"
        opts.separator "  workspace review my-app.worktree-fix-login --json"
        opts.separator "  workspace review    # the packet for the workspace in the current directory"
      end
    end

    def cmd_review(args)
      options = {json: false}
      given = args.dup
      parser = review_parser(options)
      parser.parse!(args)
      return @output.puts(parser.help) if options[:help]

      raise Error, "review is not available: no review command was wired" unless @review_command

      subcommand = args.first if %w[show list].include?(args.first)
      args.shift if subcommand
      raise UsageError, "Unexpected argument: #{args[1]}. Run 'workspace review --help'." if args.size > 1

      result = if subcommand == "list"
        @review_command.list(project: args.first, json: options[:json])
      else
        name = settle_name(args.first) || @project_detector.detect(@working_dir)
        raise UsageError, "Missing workspace name.\n\n#{parser.help}" unless name

        @review_command.show(name: name, json: options[:json])
      end
      @exit_handler.exit(result[:exit_code]) unless result[:exit_code].zero?
    rescue OptionParser::ParseError, UsageError => e
      raise unless json_requested?(options[:json], given)
      emit_json_error(Commands::Review::JSON_SCHEMA_VERSION, e, message: e.message.lines.first.strip)
    end

    DAEMON_SUBCOMMANDS = %w[status restart log list].freeze

    def daemon_parser(options)
      OptionParser.new do |opts|
        opts.banner = "Usage: workspace daemon status [WORKSPACE] [--json]\n" \
          "       workspace daemon restart [WORKSPACE] [--wc-socket PATH] [--json]\n" \
          "       workspace daemon restart --all [--json]\n" \
          "       workspace daemon list [--json]\n" \
          "       workspace daemon log [WORKSPACE] [--lines N] [--json]"
        opts.separator ""
        opts.separator "Inspect or control a workspace's agent daemon (see `workspace agentd`)."
        opts.separator "  status    whether the daemon answers on its socket, its pid, and its socket and log paths"
        opts.separator "  restart   stop the daemon holding the socket (SIGTERM, even a hung one) and start a new one in the"
        opts.separator "            background; a daemon run in a terminal is replaced by a detached one. With none"
        opts.separator "            running, just start one"
        opts.separator "            --all restarts every running daemon, one after another, so each runs the code that is"
        opts.separator "            installed now; one that fails does not stop the rest, and the exit status is non-zero if any failed"
        opts.separator "  list      every running daemon: its workspace, pid, start time and socket"
        opts.separator "  log       the last lines of the log a background daemon writes; a daemon run in a"
        opts.separator "            terminal logs to that terminal instead"
        opts.separator ""
        opts.on("--name NAME", "Workspace name (defaults to WORKSPACE or the project detected from the current directory)") { |v| options[:name] = v }
        opts.on("--lines N", Integer, "log: how many trailing lines (default #{Commands::Daemon::DEFAULT_LINES})") { |v| options[:lines] = v }
        opts.on("--wc-socket PATH", "restart: work-coordinator socket for the new daemon (default: the old daemon's)") { |v| options[:wc_socket] = v }
        opts.on("--all", "restart: restart every running daemon instead of one workspace") { options[:all] = true }
        opts.on("--json", "Print one JSON document (see docs/README.daemon.md)") { options[:json] = true }
        opts.on("-h", "--help", "Show this help") { options[:help] = true }
        opts.separator ""
        opts.separator "Examples:"
        opts.separator "  workspace daemon list"
        opts.separator "  workspace daemon restart --all    # after installing a new version"
        opts.separator "  workspace daemon status my-app"
        opts.separator "  workspace daemon log my-app --lines 100"
        opts.separator "  workspace daemon restart my-app --json"
      end
    end

    def cmd_daemon(args)
      options = {json: false}
      given = args.dup
      parser = daemon_parser(options)
      subcommand = args.shift if DAEMON_SUBCOMMANDS.include?(args.first)
      parser.parse!(args)
      subcommand ||= args.shift if DAEMON_SUBCOMMANDS.include?(args.first)
      return @output.puts(parser.help) if options[:help]

      raise UsageError, "Missing subcommand: one of #{DAEMON_SUBCOMMANDS.join(", ")}.\n\n#{parser.help}" unless subcommand
      raise Error, "daemon is not available: no daemon command was wired" unless @daemon_command

      raise UsageError, "--all only applies to `daemon restart`." if options[:all] && subcommand != "restart"
      raise UsageError, "--lines only applies to `daemon log`." if options[:lines] && subcommand != "log"
      if subcommand == "list" || options[:all]
        what = (subcommand == "list") ? "daemon list" : "daemon restart --all"
        raise UsageError, "#{what} takes no workspace: it covers every running daemon." if options[:name] || args.any?
        raise UsageError, "--wc-socket can't be combined with --all: each daemon keeps its own." if options[:all] && options[:wc_socket]
        raise UsageError, "--wc-socket only applies to `daemon restart`." if options[:wc_socket]

        return (subcommand == "list") ? @daemon_command.list(json: options[:json]) : daemon_restart_all(options)
      end

      name = settle_name(options[:name] || args.shift)
      raise UsageError, "Unexpected argument: #{args.first}. Run 'workspace daemon --help'." if args.any?
      name ||= @project_detector.detect(@working_dir)
      raise UsageError, "Missing workspace name.\n\n#{parser.help}" unless name
      raise UsageError, "--wc-socket only applies to `daemon restart`." if options[:wc_socket] && subcommand != "restart"

      result = case subcommand
      when "status" then @daemon_command.status(name: name, json: options[:json])
      when "log" then @daemon_command.log(name: name, lines: options[:lines], json: options[:json])
      else daemon_restart(name, options)
      end
      @exit_handler.exit(result[:exit_code]) if result && !result[:exit_code].to_i.zero?
    rescue OptionParser::ParseError, UsageError => e
      raise unless json_requested?(options[:json], given)
      emit_json_error(Commands::Daemon::JSON_SCHEMA_VERSION, e, message: e.message.lines.first.strip)
    end

    # Shared by `daemon restart` and `agentd restart`. The caller's socket
    # path is made absolute so a later restart can read it back from the
    # daemon's command line.
    def daemon_restart(name, options)
      wc_socket = options[:wc_socket] && File.expand_path(options[:wc_socket], @working_dir)
      run_action("restart", json: options[:json]) do
        restarted = @daemon_command.restart(name: name, wc_socket: wc_socket)
        if restarted.ok?
          verb = (restarted.outcome == "restarted") ? "Restarted" : "Started"
          pids = [restarted.old_pid, restarted.pid].compact.join(" -> ")
          @output.puts "#{verb} agentd for #{name}#{" (pid #{pids})" unless pids.empty?}"
          @output.puts "Kept its work-coordinator socket: #{restarted.wc_socket}" if restarted.wc_socket && !options[:wc_socket]
        else
          @error_output.puts "Error: #{restarted.message}"
        end
        row = action_row(name, restarted.outcome, reason: restarted.reason, message: restarted.message,
          old_pid: restarted.old_pid, pid: restarted.pid, wc_socket: restarted.wc_socket)
        {exit_code: restarted.ok? ? 0 : 1, results: [row]}
      end
    end

    # `daemon restart --all`: restarts every running daemon and reports a row
    # for each. Any failed row makes the exit status non-zero.
    def daemon_restart_all(options)
      run_action("restart", json: options[:json]) do
        restarted = @daemon_command.restart_all
        @output.puts "No agentd processes are running." if restarted.empty?
        restarted.each do |name, r|
          if r.ok?
            verb = (r.outcome == "restarted") ? "Restarted" : "Started"
            pids = [r.old_pid, r.pid].compact.join(" -> ")
            @output.puts "#{verb} agentd for #{name}#{" (pid #{pids})" unless pids.empty?}"
          else
            @error_output.puts "Error: #{name}: #{r.message}"
          end
        end
        rows = restarted.map do |name, r|
          action_row(name, r.outcome, reason: r.reason, message: r.message, old_pid: r.old_pid, pid: r.pid, wc_socket: r.wc_socket)
        end
        {exit_code: (restarted.all? { |_, r| r.ok? }) ? 0 : 1, results: rows}
      end
    end

    def ui_parser(options)
      OptionParser.new do |opts|
        opts.banner = "Usage: workspace ui open task|review|notes|plan [WORKSPACE] [--print] [--json]\n" \
          "       workspace ui open pane [WORKSPACE] PANE [--print] [--json]\n" \
          "       workspace ui open inbox [--print] [--json]"
        opts.separator ""
        opts.separator "Open a view of the workspace UI through its workspace-ui:// link:"
        opts.separator "  task WORKSPACE     workspace-ui://task/WORKSPACE"
        opts.separator "  review WORKSPACE   workspace-ui://review/WORKSPACE"
        opts.separator "  notes WORKSPACE    workspace-ui://notes/WORKSPACE"
        opts.separator "  plan WORKSPACE     workspace-ui://plan/WORKSPACE"
        opts.separator "  pane WORKSPACE PANE  workspace-ui://pane/WORKSPACE/PANE"
        opts.separator "                     (PANE is a tmux pane id such as %19; WORKSPACE may be left out as for the others)"
        opts.separator "  inbox              workspace-ui://inbox"
        opts.separator ""
        opts.separator "A link only opens a view; it never starts an agent or runs a command. WORKSPACE (or --name)"
        opts.separator "defaults to the project detected from the current directory. Opening needs the UI app"
        opts.separator "installed, since it registers the scheme; without it `open` fails, the exit status is 1, and"
        opts.separator "--print still shows the link."
        opts.separator ""
        opts.on("--name NAME", "Workspace name (every view but inbox)") { |v| options[:name] = v }
        opts.on("--print", "Print the link and open nothing") { options[:print] = true }
        opts.on("--json", "Print one JSON action document (see docs/README.ui.md)") { options[:json] = true }
        opts.on("-h", "--help", "Show this help") { options[:help] = true }
        opts.separator ""
        opts.separator "Examples:"
        opts.separator "  workspace ui open task my-app"
        opts.separator "  workspace ui open review my-app.worktree-fix-login"
        opts.separator "  workspace ui open notes my-app"
        opts.separator "  workspace ui open plan my-app"
        opts.separator "  workspace ui open pane my-app %19"
        opts.separator "  workspace ui open inbox --print"
      end
    end

    def cmd_ui(args)
      options = {json: false, print: false}
      given = args.dup
      parser = ui_parser(options)
      subcommand = args.shift if args.first == "open"
      parser.parse!(args)
      subcommand ||= args.shift if args.first == "open"
      return @output.puts(parser.help) if options[:help]

      if !subcommand && args.any?
        hint = " Did you mean: workspace ui open #{args.join(" ")}?" if Commands::Ui::VIEWS.key?(args.first)
        raise UsageError, "Unknown ui subcommand: #{args.first}.#{hint} Run 'workspace ui --help'."
      end
      raise UsageError, "Missing subcommand: open.\n\n#{parser.help}" unless subcommand
      raise Error, "ui is not available: no ui command was wired" unless @ui_command

      view = args.shift
      raise UsageError, "Missing view: one of #{Commands::Ui::VIEWS.keys.join(", ")}.\n\n#{parser.help}" unless view
      pane = nil
      if view == Commands::Ui::PANE_VIEW
        # `pane WORKSPACE PANE`; a lone argument is the pane when --name or the current directory names the workspace.
        pane = args.pop if options[:name] || args.size == 1
        pane = args.pop if pane.nil? && args.size == 2
      end
      name = settle_name(options[:name] || args.shift)
      raise UsageError, "Unexpected argument: #{args.first}. Run 'workspace ui --help'." if args.any?
      if Commands::Ui::VIEWS[view]
        name ||= @project_detector.detect(@working_dir)
        raise UsageError, "#{view} needs a workspace: name one, pass --name, or run from inside a project." unless name
      end

      run_action("ui open", json: options[:json]) do
        opened = @ui_command.open(view: view, workspace: name, pane: pane, print_only: options[:print])
        @error_output.puts "Error: #{opened.message}" unless opened.ok?
        row_extra = pane ? {pane: pane} : {}
        row = action_row(name, opened.outcome, reason: opened.reason, message: opened.message, view: opened.view, url: opened.url, **row_extra)
        {exit_code: opened.ok? ? 0 : 1, results: [row]}
      end
    rescue OptionParser::ParseError, UsageError => e
      raise unless json_requested?(options[:json], given)
      emit_json_error(ACTION_JSON_SCHEMA_VERSION, e, message: e.message.lines.first.strip)
    end

    def binding_parser(options)
      OptionParser.new do |opts|
        opts.banner = "Usage: workspace binding set [WORKSPACE] [--pane PANE] --kind run|review|play --id ID [--pack NAME]... [options]\n" \
          "       workspace binding show [--pane %ID] [--json]\n" \
          "       workspace binding clear [--pane %ID] [--json]"
        opts.separator ""
        opts.separator "Bind a tmux pane to a workflow run, a PR review or a library play. When the agent"
        opts.separator "in a bound pane starts a session (startup, /clear, resume or compact), session-event"
        opts.separator "reminds it of its subject, so it survives a lost context. Nothing is typed into the pane."
        opts.separator ""
        opts.separator "A pane is stored by its tmux pane id (%19) and only counts in the tmux session it"
        opts.separator "was bound in. set takes a pane id or window.pane of the workspace's own session;"
        opts.separator "show and clear take a pane id. All three default to $TMUX_PANE, the pane the"
        opts.separator "command runs in. WORKSPACE (or --name) defaults to the project detected from the"
        opts.separator "current directory. start --play and launch --play bind the pane they sent a play"
        opts.separator "to (kind play). show marks a binding stale when the pane is no longer in the tmux"
        opts.separator "session and slot it was bound in; a stale binding is not announced."
        opts.separator ""
        opts.separator "--pack lists library packs (see `workspace instructions --help`) the hook also prints, so"
        opts.separator "they survive /clear and compaction. start and launch set it for the packs they send;"
        opts.separator "a pane sent packs but no play is bound with kind play and id play/<first pack>. Setting"
        opts.separator "a binding replaces the whole earlier one, its packs included."
        opts.separator ""
        opts.on("--name NAME", "Workspace name (set)") { |v| options[:name] = v }
        opts.on("--pane PANE", "Pane id (%19) or, for set, window.pane (0.1)") { |v| options[:pane] = v }
        opts.on("--kind KIND", "run, review or play (set)") { |v| options[:kind] = v }
        opts.on("--id ID", "Run id, review id such as acme/api#835, or play/NAME (set)") { |v| options[:id] = v }
        opts.on("--step STEP", "Step name (set)") { |v| options[:step] = v }
        opts.on("--attempt N", Integer, "Step attempt, 1 or more (set)") { |v| options[:attempt] = v }
        opts.on("--focus TEXT", "Review focus, e.g. security (set)") { |v| options[:focus] = v }
        opts.on("--instructions PATH", "File holding the pane's instructions (set); stored as an absolute path") { |v| options[:instructions] = absolute_unless_blank("--instructions", v) }
        opts.on("--artifacts PATH", "Directory holding the subject's artifacts (set); stored as an absolute path") { |v| options[:artifacts] = absolute_unless_blank("--artifacts", v) }
        opts.on("--pack NAME", "Library pack the agent is also reminded of (set; repeatable; replaces the stored list)") { |v| (options[:packs] ||= []) << v }
        opts.on("--json", "Print one JSON action document") { options[:json] = true }
        opts.on("-h", "--help", "Show this help") { options[:help] = true }
        opts.separator ""
        opts.separator "Examples:"
        opts.separator "  workspace binding set my-app --pane %5 --kind run --id wr_01 --step implement --attempt 2"
        opts.separator "  workspace binding show"
        opts.separator "  workspace binding clear --pane %5"
      end
    end

    # A path from the directory the command runs in; a blank one is left for
    # the command to refuse.
    def absolute_unless_blank(flag, path)
      path.strip.empty? ? path : File.expand_path(path, @working_dir)
    rescue ArgumentError => e
      # A path under a ~user that doesn't exist can't be expanded.
      raise UsageError, "#{flag}: can't make #{path} an absolute path: #{e.message}"
    end

    def cmd_binding(args)
      options = {json: false}
      given = args.dup
      parser = binding_parser(options)
      subcommand = args.shift if %w[set show clear].include?(args.first)
      parser.parse!(args)
      subcommand ||= args.shift if %w[set show clear].include?(args.first)
      return @output.puts(parser.help) if options[:help]

      raise UsageError, "Missing subcommand: set, show or clear.\n\n#{parser.help}" unless subcommand
      raise Error, "binding is not available: no binding command was wired" unless @binding_command

      if subcommand == "set"
        name = settle_name(options[:name] || args.shift) || @project_detector.detect(@working_dir)
        raise UsageError, "binding set needs a workspace: name one, pass --name, or run from inside a project." unless name
        pane = options[:pane] || ENV["TMUX_PANE"]
        raise UsageError, "binding set needs --pane (or to run inside a tmux pane)." unless pane
        raise UsageError, "binding set needs --kind and --id." unless options[:kind] && options[:id]
        raise UsageError, "Unexpected argument: #{args.first}. Run 'workspace binding --help'." if args.any?

        run_action("binding set", json: options[:json]) do
          check_packs(options[:packs]) if options[:packs]&.any?
          entry = @binding_command.set(workspace: name, pane: pane, **options.slice(:kind, :id, :step, :attempt, :focus, :instructions, :artifacts).merge(options.slice(:packs)))
          {exit_code: 0, results: [action_row(name, "bound", binding: entry)]}
        end
      else
        pane = options[:pane] || ENV["TMUX_PANE"]
        raise UsageError, "binding #{subcommand} needs --pane (or to run inside a tmux pane)." unless pane
        raise UsageError, "Unexpected argument: #{args.first}. Run 'workspace binding --help'." if args.any?

        run_action("binding #{subcommand}", json: options[:json]) do
          entry = (subcommand == "show") ? @binding_command.show(pane: pane) : @binding_command.clear(pane: pane)
          {exit_code: 0, results: [action_row(entry["workspace"], (subcommand == "show") ? "shown" : "cleared", binding: entry)]}
        end
      end
    rescue OptionParser::ParseError, UsageError => e
      raise unless json_requested?(options[:json], given)
      emit_json_error(ACTION_JSON_SCHEMA_VERSION, e, message: e.message.lines.first.strip)
    end

    # Reads each pack so a misspelt name fails now rather than silently never reminding the agent.
    def check_packs(names)
      return unless @instruction_composer
      @instruction_composer.compose(packs: names, cwd: @working_dir)
    end

    LIBRARY_SUBCOMMANDS = %w[list show info add update remove install uninstall installed].freeze

    def library_parser(options)
      OptionParser.new do |opts|
        opts.banner = "Usage: workspace library list [--kind KIND] [--global | --builtin | --project [NAME]] [--json]\n" \
          "       workspace library show REF [--global | --builtin | --project [NAME]] [--json]\n" \
          "       workspace library info REF [--global | --builtin | --project [NAME]] [--json]\n" \
          "       workspace library add PATH|- --kind KIND [--as NAME] [--link] [--force] [--project [NAME]] [--dry-run] [--json]\n" \
          "       workspace library update REF PATH|- [--link] [--project [NAME]] [--dry-run] [--json]\n" \
          "       workspace library remove REF [--yes] [--project [NAME]] [--dry-run] [--json]\n" \
          "       workspace library install REF [--name WS | --user] [--from global|project] [--force] [--dry-run] [--json]\n" \
          "       workspace library uninstall REF [--name WS | --user] [--force] [--dry-run] [--json]\n" \
          "       workspace library installed [--name WS | --user] [--kind skill|agent] [--json]"
        opts.separator ""
        opts.separator "A store of named plays, prompts, agents and skills under #{@config.library_dir}."
        opts.separator "A play is a document an agent reads and follows; a prompt is short text sent as typed;"
        opts.separator "an agent is a Claude Code subagent file; a skill is a directory holding SKILL.md, and"
        opts.separator "`workspace start --agent/--skill` copies them into a new worktree. Entries are"
        opts.separator "global unless --project narrows them to one project; a project entry hides a global one"
        opts.separator "of the same name. REF is kind/name, or a bare name when one kind has it. `lib` is an"
        opts.separator "alias for `library`, and `workspace library` alone lists."
        opts.separator ""
        opts.separator "workspace ships built-in plays, the instruction packs binding, orchestrator, commits"
        opts.separator "and review (see `workspace instructions --help`). They can't be changed. --play and"
        opts.separator "show search them last, so a project or global play of the same name comes first there;"
        opts.separator "`instructions compose --pack` always uses the built-in one."
        opts.separator ""
        opts.separator "  list      every entry visible from here, sorted by kind then name"
        opts.separator "  show      print the body, so --prompt \"$(workspace library show prompt/kickoff)\" works"
        opts.separator "  info      kind, name, scope, path, link target, description, modified time, effective"
        opts.separator "  add       copy PATH in (or link it with --link, or read - from stdin with --as NAME);"
        opts.separator "            the name defaults to the file name in kebab case; identical content is a no-op,"
        opts.separator "            different content under the same name needs --force"
        opts.separator "  update    replace an existing entry's content, or repoint its link"
        opts.separator "  remove    delete the entry or its link from the store; the source file is never touched"
        opts.separator "  install   copy a library skill or agent into an existing workspace's checkout"
        opts.separator "            (.claude/skills/NAME/ or .claude/agents/NAME.md unless library.install.skills_dir or"
        opts.separator "            agents_dir says otherwise), as start --skill/--agent does for a new one: identical"
        opts.separator "            content is unchanged, different content needs --force, a path the repo tracks is"
        opts.separator "            never overwritten; the copy is listed in info/exclude. --user copies to your home-level"
        opts.separator "            directory instead (library.install.user_skills_dir, user_agents_dir; ~/.claude/... by default)."
        opts.separator "            --from global|project copies that store's entry, not the project's over the global one"
        opts.separator "  uninstall delete that copy from the checkout, or with --user from the home-level directory; a copy that"
        opts.separator "            differs from the library entry needs --force; the library entry and the info/exclude line stay"
        opts.separator "  installed list the copies install made in a workspace's checkout (--name WS, default: the current"
        opts.separator "            directory's) or at user level (--user); read-only. A copy counts when its name is a library"
        opts.separator "            entry's or the repo's info/exclude lists it; modified = differs from that entry"
        opts.separator ""
        opts.on("--kind KIND", "agent, play, prompt, skill or spine (add: required; list: a filter);",
          "add --kind skill takes a directory holding SKILL.md;",
          "add --kind spine takes a folder of plan-spine stage files (a template for 'spine init')") { |v| options[:kind] = v }
        opts.on("--as NAME", "add: the entry name (lowercase letters, digits and hyphens)") { |v| options[:name] = v }
        opts.on("--link", "add, update: store a symlink to PATH instead of a copy") { options[:link] = true }
        opts.on("--force", "add: replace an entry that has different content;", "install: replace a copy that has different content;", "uninstall: remove a copy that differs from the library entry") { options[:force] = true }
        opts.on("--user", "install: copy to the user-level directory instead of a workspace;", "uninstall: remove the user-level copy") { options[:user] = true }
        opts.on("--from STORE", "install: copy the entry of this store, global or project (default: the project's, else global)") { |v| options[:from] = v }
        opts.on("--yes", "remove: don't ask") { options[:yes] = true }
        opts.on("--global", "reads: only the global store") { options[:global] = true }
        opts.on("--builtin", "reads: only the entries that ship with workspace") { options[:builtin] = true }
        opts.on("--project [NAME]", "--name [NAME]", "the project's store (NAME, or the project of the current directory);", "install, uninstall: the workspace to act on (default: the one of the current directory)") { |v| options[:project] = v || true }
        opts.on("--dry-run", "add, update, remove, install, uninstall: report what would happen and write nothing") { options[:dry_run] = true }
        opts.on("--json", "Print one JSON document (see docs/README.library.md)") { options[:json] = true }
        opts.on("-h", "--help", "Show this help") { options[:help] = true }
        opts.separator ""
        opts.separator "Examples:"
        opts.separator "  workspace library add --kind play --link ~/Notes/Agent\\ Orchestration\\ Playbook.md"
        opts.separator "  workspace library add kickoff.md --kind prompt --project"
        opts.separator "  workspace library list --kind play --json"
        opts.separator "  workspace library add ~/Notes/spine-template --kind spine --as team --link"
        opts.separator "  workspace start feature/x --prompt \"$(workspace library show prompt/kickoff)\""
        opts.separator "  workspace library remove play/agent-orchestration-playbook --yes"
        opts.separator "  workspace library install skill/write-tests --name my-app --json"
        opts.separator "  workspace library uninstall skill/write-tests --name my-app"
        opts.separator "  workspace library installed --name my-app --kind skill --json"
      end
    end

    def cmd_library(args)
      options = {json: false, link: false, force: false, yes: false, dry_run: false, user: false}
      given = args.dup
      parser = library_parser(options)
      subcommand = args.shift if LIBRARY_SUBCOMMANDS.include?(args.first)
      parser.parse!(args)
      subcommand ||= args.shift if LIBRARY_SUBCOMMANDS.include?(args.first)
      return @output.puts(parser.help) if options[:help]

      subcommand ||= "list" if args.empty?
      raise UsageError, "Unknown library subcommand: #{args.first}. One of #{LIBRARY_SUBCOMMANDS.join(", ")}. Run 'workspace library --help'." unless subcommand
      raise Error, "library is not available: no library command was wired" unless @library_command
      scopes = [("global" if options[:global]), ("builtin" if options[:builtin]), ("project" if options[:project])].compact
      raise UsageError, "--global, --builtin and --project can't be combined." if scopes.size > 1
      if scopes == ["builtin"] && %w[add update remove].include?(subcommand)
        raise UsageError, "library #{subcommand} can't change the built-in entries, which ship with workspace."
      end

      if %w[install uninstall installed].include?(subcommand) && (options[:global] || options[:builtin])
        raise UsageError, "library #{subcommand} takes --name WS, not --global or --builtin."
      end

      raise UsageError, "--from is for library install." if options[:from] && subcommand != "install"

      scope = scopes.first
      project = options[:project].is_a?(String) ? options[:project] : nil
      where = {scope: scope, project: project, cwd: @working_dir}
      ref = args.shift unless %w[list add installed].include?(subcommand)

      case subcommand
      when "list"
        raise UsageError, "Unexpected argument: #{args.first}. Run 'workspace library --help'." if args.any?
        @library_command.list(kind: options[:kind], json: options[:json], **where)
      when "show", "info"
        raise UsageError, "library #{subcommand} needs a REF (kind/name or name)." unless ref
        raise UsageError, "Unexpected argument: #{args.first}. Run 'workspace library --help'." if args.any?
        @library_command.public_send(subcommand, ref, json: options[:json], **where)
      when "add"
        path = args.shift
        raise UsageError, "library add needs a PATH, or - for stdin." unless path
        raise UsageError, "library add needs --kind (one of #{Workspace::LibraryStore::KINDS.join(", ")})." unless options[:kind]
        raise UsageError, "Unexpected argument: #{args.first}. Run 'workspace library --help'." if args.any?
        path, body = (path == "-") ? [nil, @input.read] : [path, nil]
        library_action("library add", options) do
          @library_command.add(kind: options[:kind], path: path, body: body, name: options[:name], link: options[:link],
            force: options[:force], dry_run: options[:dry_run], **where)
        end
      when "update"
        path = args.shift
        raise UsageError, "library update needs a REF and a PATH (or - for stdin)." unless ref && path
        raise UsageError, "Unexpected argument: #{args.first}. Run 'workspace library --help'." if args.any?
        path, body = (path == "-") ? [nil, @input.read] : [path, nil]
        library_action("library update", options) do
          @library_command.update(ref, path: path, body: body, link: options[:link], dry_run: options[:dry_run], **where)
        end
      when "installed"
        raise UsageError, "Unexpected argument: #{args.first}. Run 'workspace library --help'." if args.any?
        workspace = options[:project].is_a?(String) ? options[:project] : nil
        raise UsageError, "--user lists the user-level directories, so it takes no --name." if options[:user] && options[:project]
        @library_command.installed(name: workspace, user: options[:user], kind: options[:kind], json: options[:json], cwd: @working_dir)
      when "install", "uninstall"
        unless ref
          hint = if options[:project].to_s.match?(%r{\A(skill|agent)/})
            " --name took '#{options[:project]}' as the workspace name; give the REF first, or give --name a workspace."
          end
          raise UsageError, "library #{subcommand} needs a REF (skill/name or agent/name).#{hint}"
        end
        raise UsageError, "Unexpected argument: #{args.first}. Run 'workspace library --help'." if args.any?
        workspace = options[:project].is_a?(String) ? options[:project] : nil
        if options[:user]
          raise UsageError, "--user #{(subcommand == "install") ? "copies to" : "removes from"} the user-level directory, so it takes no --name." if options[:project]
        end
        library_install_action(options) do
          if subcommand == "install"
            @library_command.install(ref, name: workspace, force: options[:force], dry_run: options[:dry_run], user: options[:user], from: options[:from], cwd: @working_dir)
          else
            @library_command.uninstall(ref, name: workspace, force: options[:force], dry_run: options[:dry_run], user: options[:user], cwd: @working_dir)
          end
        end
      when "remove"
        raise UsageError, "library remove needs a REF (kind/name or name)." unless ref
        raise UsageError, "Unexpected argument: #{args.first}. Run 'workspace library --help'." if args.any?
        unless options[:yes] || options[:dry_run]
          Prompt.refuse_if_no_input!(@input, "Remove #{ref} from the library?", retry_flags: ["--yes"], destructive: true)
          raise UsageError, "library remove --json never prompts: pass --yes to remove, or --dry-run to preview." if options[:json]
          unless @input.respond_to?(:tty?) && @input.tty?
            raise UsageError, "library remove can't ask for confirmation without a terminal: pass --yes (or --dry-run)."
          end
        end
        library_action("library remove", options) do
          @library_command.remove(ref, yes: options[:yes], dry_run: options[:dry_run], **where)
        end
      end
    rescue OptionParser::ParseError, UsageError => e
      raise unless json_requested?(options[:json], given)
      emit_json_error(JsonEnvelope::SCHEMA_VERSION, e, message: e.message.lines.first.strip)
    end

    # Runs `library install` or `uninstall`: its own words, or with --json the one
    # `{ok, ref, workspace, result, path}` document.
    def library_install_action(options)
      result = options[:json] ? divert_output { yield } : yield
      @output.puts JSON.generate(result.to_h) if options[:json]
    end

    # Runs a library write under {#run_action}; a nil result is a declined prompt.
    def library_action(action, options)
      run_action(action, json: options[:json]) do
        result = yield
        next {exit_code: 0, results: [], status: "cancelled"} unless result
        row = action_row(result.workspace, result.outcome, message: result.message, entry: result.entry)
        {exit_code: 0, results: [row], status: options[:dry_run] ? "dry_run" : nil}
      end
    end

    def instructions_parser(options)
      OptionParser.new do |opts|
        opts.banner = "Usage: workspace instructions compose [--pack NAME]... [--pane %ID] [--name WORKSPACE] [--json]\n       workspace instructions compose --start [--pack NAME]... [--no-packs] [--name WORKSPACE] [--json]"
        opts.separator ""
        opts.separator "Print the instructions an agent is given, built from library packs. A pack is a"
        opts.separator "library play; workspace ships eight: binding (how to work in a bound pane),"
        opts.separator "orchestrator (delegate to sub-agents), commits (how to commit), review (review a"
        opts.separator "diff with reviewer sub-agents), notes (where working notes go), handoff (run"
        opts.separator "'workspace handoff check' after every task), dev (queue for the shared dev"
        opts.separator "environment before testing, release it when done) and implementation-plan"
        opts.separator "(keep the counted task list in IMPLEMENTATION_PLAN.md). With no"
        opts.separator "--pack, binding, orchestrator and commits are composed, in that order. Each"
        opts.separator "pack is printed under a heading that names where it came from."
        opts.separator ""
        opts.separator "Any other library play can be named as a pack too: the project's library is searched,"
        opts.separator "then global. A play named like a built-in pack never takes its place here; give your"
        opts.separator "own another name. `workspace library list --builtin` lists the built-in packs and"
        opts.separator "`workspace library show NAME --builtin` prints one."
        opts.separator ""
        opts.separator "Two packs get lines for the caller. binding is followed by the binding of --pane"
        opts.separator "when that pane is bound, and commits by the project's commands.test and"
        opts.separator "commands.lint when they are set (workspace config set commands.test ...)."
        opts.separator "--pane defaults to $TMUX_PANE, the pane the command runs in, unless --name is given."
        opts.separator "Text composed for another pane, as in start --prompt \"$(...)\", would carry this"
        opts.separator "pane's binding: name the packs and leave binding out, or bind that pane first."
        opts.separator ""
        opts.on("--pack NAME", "A pack to compose (repeatable, composed in the order given)") { |v| options[:packs] << v }
        opts.on("--pane PANE", "Pane id (%19) whose binding follows the binding pack (default $TMUX_PANE without --name)") { |v| options[:pane] = v }
        opts.on("--name WORKSPACE", "Compose for this workspace instead of the current directory") { |v| options[:name] = v }
        opts.on("--start", "Print what start and launch send with the first prompt, and send nothing: the automatic",
          "packs (notes, unless notes.instructions is false) then each --pack. Each pack in --json has a source") { options[:start] = true }
        opts.on("--no-packs", "With --start: leave out the automatic packs (cannot be combined with --pack)") { options[:no_packs] = true }
        opts.on("--json", "Print one JSON document (see docs/README.instructions.md)") { options[:json] = true }
        opts.on("-h", "--help", "Show this help") { options[:help] = true }
        opts.separator ""
        opts.separator "Examples:"
        opts.separator "  workspace instructions compose"
        opts.separator "  workspace instructions compose --pack orchestrator"
        opts.separator "  workspace instructions compose --pack commits --pack review --name my-app --json"
        opts.separator "  workspace instructions compose --start --name my-app    # what start and launch send"
        opts.separator "  workspace start feature/x --prompt \"$(workspace instructions compose --pack orchestrator)\""
      end
    end

    def cmd_instructions(args)
      options = {json: false, packs: [], start: false, no_packs: false}
      given = args.dup
      parser = instructions_parser(options)
      subcommand = args.shift if args.first == "compose"
      parser.parse!(args)
      subcommand ||= args.shift if args.first == "compose"
      return @output.puts(parser.help) if options[:help]

      unless subcommand
        raise UsageError, args.empty? ? "Missing subcommand: compose.\n\n#{parser.help}" : "Unknown instructions subcommand: #{args.first}. Run 'workspace instructions --help'."
      end
      raise UsageError, "Unexpected argument: #{args.first}. Run 'workspace instructions --help'." if args.any?
      raise Error, "instructions is not available: no instructions command was wired" unless @instructions_command

      # $TMUX_PANE is the caller's pane, which is not a pane of a workspace named with --name.
      pane = options[:pane] || (ENV["TMUX_PANE"] unless options[:name])
      raise UsageError, "--no-packs only works with --start." if options[:no_packs] && !options[:start]
      raise UsageError, "--no-packs cannot be combined with --pack." if options[:no_packs] && options[:packs].any?
      raise UsageError, "--pane has no effect with --start: the packs are composed for a pane that does not exist yet." if options[:start] && options[:pane]
      start = options[:start] ? {start: true, no_packs: options[:no_packs]} : {}
      @instructions_command.compose(packs: options[:packs], cwd: working_dir_for(options[:name]), pane: pane, json: options[:json], **start)
    rescue OptionParser::ParseError, UsageError => e
      raise unless json_requested?(options[:json], given)
      emit_json_error(JsonEnvelope::SCHEMA_VERSION, e, message: e.message.lines.first.strip)
    end

    WORKFLOW_SUBCOMMANDS = %w[show run status resume cancel approve reject advance].freeze

    def workflow_parser(options)
      OptionParser.new do |opts|
        opts.banner = "Usage: workspace workflow show [ID] [--json]\n" \
          "       workspace workflow run ID [--name WORKSPACE] [--input KEY=VALUE]... [--note TEXT] [--pane PANE] [--dry-run] [--json]\n" \
          "       workspace workflow status [RUN] [--name WORKSPACE] [--all] [--json]\n" \
          "       workspace workflow resume RUN [--from STEP] [--note TEXT] [--pane PANE] [--json]\n" \
          "       workspace workflow cancel RUN [--json]\n" \
          "       workspace workflow approve RUN [--note TEXT] [--json]\n" \
          "       workspace workflow reject RUN --note TEXT [--to STEP] [--json]"
        opts.separator ""
        opts.separator "Run a workflow in a workspace: an ordered list of steps, each done by the agent in the"
        opts.separator "workspace's Claude pane. A step gets its instructions in a file under .workflow/ in the"
        opts.separator "checkout and one typed line pointing at it, in a fresh conversation unless the step says"
        opts.separator "context: continue. A step is done when the agent's turn ends, every file it produces:"
        opts.separator "exists, and its status: check passes; the agent daemon (agentd) sees the turn end and"
        opts.separator "moves the run on. A failed step goes back along its on_fail: {goto, max}; a step with"
        opts.separator "gate: approve waits for `workflow approve`. Resources a step uses: are locks the run"
        opts.separator "holds, in the same queue as `lock acquire` and `dev up`."
        opts.separator ""
        opts.separator "Definitions are YAML files: #{@config.workflows_dir}/ID.yml, then the presets that"
        opts.separator "ship with workspace (rpiv: research, plan, implement, verify). See docs/README.workflow.md."
        opts.separator ""
        opts.separator "  show      list the definitions, or print one (inputs, steps)"
        opts.separator "  run       start a run in a workspace (the current one, or --name); --dry-run checks"
        opts.separator "            the inputs, the project's commands and the pane, and starts nothing"
        opts.separator "  status    the runs still going (or one run, or --all), each with its step and, when it"
        opts.separator "            is not moving, why: waiting_lock, waiting_you, turn_ended_incomplete,"
        opts.separator "            failed_check or pane_gone, with the commands that resolve it"
        opts.separator "  resume    get a run going again: ask for its lock again, run a failed or undelivered"
        opts.separator "            step again, look again at a step whose files were missing, or move it to the"
        opts.separator "            workspace's Claude pane when its own is gone; --from STEP starts again there"
        opts.separator "  cancel    end a run and release what it holds"
        opts.separator "  approve   pass a gate; refused from a pane a run is bound to (as is resume --from at"
        opts.separator "            a gate), so an agent doesn't pass its own plan by mistake"
        opts.separator "  reject    turn a gate down: the gated step (or --to an earlier one) runs again with the note"
        opts.separator ""
        opts.separator "`workflow advance RUN [--turn-ended --pane ID [--turn-started AT]]` is what the agent daemon runs to move a run"
        opts.separator "on when a turn ends; it is not meant to be typed."
        opts.separator ""
        opts.on("--name WORKSPACE", "run: the workspace to run in; status: only this workspace's runs") { |v| options[:name] = v }
        opts.on("--input KEY=VALUE", "run: a value for one of the workflow's inputs (repeatable)") { |v| options[:inputs] << v }
        opts.on("--note TEXT", "run: added to every step's instructions; resume, approve, reject: to the next attempt's") { |v| options[:note] = v }
        opts.on("--pane PANE", "run, resume: the pane to run in (%19 or 0.1) instead of the workspace's Claude pane") { |v| options[:pane] = v }
        opts.on("--from STEP", "resume: start again at this step") { |v| options[:from] = v }
        opts.on("--to STEP", "reject: the step to run again (the gated step, or one before it)") { |v| options[:to] = v }
        opts.on("--all", "status: finished runs too") { options[:all] = true }
        opts.on("--dry-run", "run: report what would start and start nothing") { options[:dry_run] = true }
        opts.on("--turn-ended", "advance: a turn ended in the run's pane") { options[:turn_ended] = true }
        opts.on("--turn-started AT", "advance: when that turn began (ISO 8601)") { |v| options[:turn_started] = v }
        opts.on("--json", "Print one JSON document (see docs/README.workflow.md)") { options[:json] = true }
        opts.on("-h", "--help", "Show this help") { options[:help] = true }
        opts.separator ""
        opts.separator "Examples:"
        opts.separator "  workspace workflow show rpiv"
        opts.separator "  workspace workflow run rpiv --name my-app.worktree-pdf --input task=\"PROJ-101 invoice PDF export\" --dry-run"
        opts.separator "  workspace workflow run rpiv --input task=\"PROJ-101 invoice PDF export\""
        opts.separator "  workspace workflow status --json"
        opts.separator "  workspace workflow approve wr_2610041230559x3k --note \"Skip the migration.\""
        opts.separator "  workspace workflow reject wr_2610041230559x3k --note \"Too big; split it.\""
        opts.separator "  workspace workflow resume wr_2610041230559x3k --from implement"
      end
    end

    def cmd_workflow(args)
      options = {json: false, inputs: [], all: false, dry_run: false, turn_ended: false}
      given = args.dup
      parser = workflow_parser(options)
      refuse_bad_bytes!(args)
      subcommand = args.shift if WORKFLOW_SUBCOMMANDS.include?(args.first)
      parser.parse!(args)
      subcommand ||= args.shift if WORKFLOW_SUBCOMMANDS.include?(args.first)
      return @output.puts(parser.help) if options[:help]

      unless subcommand
        raise UsageError, args.empty? ? "Missing subcommand: show, run, status, resume, cancel, approve or reject.\n\n#{parser.help}" : "Unknown workflow subcommand: #{args.first}. Run 'workspace workflow --help'."
      end
      raise Error, "workflow is not available: no workflow command was wired" unless @workflow_command
      subject = args.shift
      raise UsageError, "Unexpected argument: #{args.first}. Run 'workspace workflow --help'." if args.any?
      needs = {"run" => "an ID (see `workspace workflow show`)", "resume" => "a RUN id", "cancel" => "a RUN id", "approve" => "a RUN id",
               "reject" => "a RUN id", "advance" => "a RUN id"}[subcommand]
      raise UsageError, "workflow #{subcommand} needs #{needs}." if needs && subject.nil?

      case subcommand
      when "show" then @workflow_command.show(id: subject, json: options[:json])
      when "status"
        @workflow_command.status(run: subject, workspace: options[:name], all: options[:all], json: options[:json])
      when "advance"
        @workflow_command.advance(run: subject, turn_ended: options[:turn_ended], pane: options[:pane], turn_started: workflow_time(options[:turn_started]))
      when "run"
        name = options[:name] || @project_detector.detect(@working_dir)
        raise UsageError, "workflow run needs a workspace: pass --name, or run from inside a project." unless name
        inputs = workflow_inputs(options[:inputs])
        workflow_action("workflow run", options) do
          # The checkout's root, where the run's files go: the named workspace's, or the detected one's.
          root = options[:name] ? working_dir_for(name) : @project_config.project_root_for(name)
          @workflow_command.run(id: subject, workspace: name, worktree: root ? File.expand_path(root) : @working_dir, inputs: inputs,
            pane: options[:pane], note: options[:note], dry_run: options[:dry_run])
        end
      when "resume"
        workflow_action("workflow resume", options) { @workflow_command.resume(run: subject, from: options[:from], note: options[:note], pane: options[:pane], caller_pane: ENV["TMUX_PANE"]) }
      when "cancel" then workflow_action("workflow cancel", options) { @workflow_command.cancel(run: subject) }
      when "approve"
        workflow_action("workflow approve", options) { @workflow_command.approve(run: subject, note: options[:note], caller_pane: ENV["TMUX_PANE"]) }
      when "reject"
        raise UsageError, "workflow reject needs --note TEXT: the step runs again with it." if options[:note].to_s.strip.empty?
        workflow_action("workflow reject", options) { @workflow_command.reject(run: subject, note: options[:note], to: options[:to]) }
      end
    rescue OptionParser::ParseError, UsageError => e
      raise unless json_requested?(options[:json], given)
      emit_json_error(JsonEnvelope::SCHEMA_VERSION, e, message: e.message.lines.first.strip)
    end

    # Text that is not valid in its encoding can't be parsed as an option or stored in a
    # run's file; it is refused here, before a pane is typed into or a lock taken.
    # Arguments are read as UTF-8 whatever the locale: with none (cron, an app started by
    # launchd) Ruby tags them binary, which calls any bytes valid and can't be joined
    # with a definition's text.
    def refuse_bad_bytes!(args)
      args.map! { |arg| arg.dup.force_encoding(Encoding::UTF_8) }
      index = args.index { |arg| !arg.valid_encoding? }
      return unless index
      flag = (index.positive? && args[index - 1].start_with?("--")) ? args[index - 1] : "An argument"
      raise UsageError, "#{flag} holds bytes that are not valid UTF-8 text (was it cut in the middle of a character?)."
    end

    def workflow_time(text)
      text && Time.iso8601(text)
    rescue ArgumentError
      raise UsageError, "--turn-started takes an ISO 8601 time, got #{text[0, 40].inspect}."
    end

    def workflow_inputs(pairs)
      pairs.to_h do |pair|
        key, value = pair.split("=", 2)
        raise UsageError, "--input takes KEY=VALUE, got #{pair[0, 60].inspect}." if value.nil? || key.empty?
        [key, value]
      end
    end

    # Runs a workflow or step mutation under {#run_action}, with the command's row as the one result.
    def workflow_action(action, options)
      run_action(action, json: options[:json]) do
        row = yield
        {exit_code: (row["outcome"] == "failed") ? 1 : 0, results: [row], status: (row["outcome"] == "dry_run") ? "dry_run" : nil}
      end
    end

    def step_parser(options)
      OptionParser.new do |opts|
        opts.banner = "Usage: workspace step done [--status pass|fail] [--summary TEXT] [--json]\n" \
          "       workspace step status [--json]"
        opts.separator ""
        opts.separator "For the agent working on a workflow step, run from the pane the run is bound to."
        opts.separator "Neither is required: a step is decided when the agent's turn ends, from the files it"
        opts.separator "was told to leave and the step's check (see `workspace workflow --help`)."
        opts.separator ""
        opts.separator "  done      record what you say about the step, then end your turn. --status fail fails"
        opts.separator "            the step at the turn's end without running its check"
        opts.separator "  status    which run, step and attempt this pane is on, where its instructions are,"
        opts.separator "            and whether the files the step must leave exist"
        opts.separator ""
        opts.on("--status STATUS", "done: pass (default) or fail") { |v| options[:status] = v }
        opts.on("--summary TEXT", "done: one line about what was done, or what is left") { |v| options[:summary] = v }
        opts.on("--json", "Print one JSON document (see docs/README.workflow.md)") { options[:json] = true }
        opts.on("-h", "--help", "Show this help") { options[:help] = true }
        opts.separator ""
        opts.separator "Examples:"
        opts.separator "  workspace step status"
        opts.separator "  workspace step done --summary \"Plan written; three commits.\""
        opts.separator "  workspace step done --status fail --summary \"Two specs still fail in billing.\""
      end
    end

    def cmd_step(args)
      options = {json: false, status: "pass"}
      given = args.dup
      parser = step_parser(options)
      refuse_bad_bytes!(args)
      subcommand = args.shift if %w[done status].include?(args.first)
      parser.parse!(args)
      subcommand ||= args.shift if %w[done status].include?(args.first)
      return @output.puts(parser.help) if options[:help]

      unless subcommand
        raise UsageError, args.empty? ? "Missing subcommand: done or status.\n\n#{parser.help}" : "Unknown step subcommand: #{args.first}. Run 'workspace step --help'."
      end
      raise UsageError, "Unexpected argument: #{args.first}. Run 'workspace step --help'." if args.any?
      raise Error, "step is not available: no workflow command was wired" unless @workflow_command

      if subcommand == "status"
        @workflow_command.step_status(pane: ENV["TMUX_PANE"], json: options[:json])
      else
        workflow_action("step done", options) { @workflow_command.step_done(pane: ENV["TMUX_PANE"], status: options[:status], summary: options[:summary]) }
      end
    rescue OptionParser::ParseError, UsageError => e
      raise unless json_requested?(options[:json], given)
      emit_json_error(JsonEnvelope::SCHEMA_VERSION, e, message: e.message.lines.first.strip)
    end

    def snapshot_parser(options)
      OptionParser.new do |opts|
        opts.banner = "Usage: workspace snapshot --json [--name WORKSPACE]... [--pr]"
        opts.separator ""
        opts.separator "Print one JSON document with everything a UI polls: each project's workspaces (running"
        opts.separator "state, git facts, agent panes, open questions, pipeline entries), the repo-wide locks"
        opts.separator "and the dev environment, plus a cursor into the event log taken before anything is read."
        opts.separator ""
        opts.separator "Reads only; nothing is written. A source that can't answer (tmux, an agent daemon, git,"
        opts.separator "gh) is reported as unavailable, never as clean. Agent daemons are read in parallel,"
        opts.separator "1 second each; a running workspace without one is listed in daemons_unavailable."
        opts.separator ""
        opts.on("--json", "Print schema-versioned JSON (see docs/README.snapshot.md); required") { options[:json] = true }
        opts.on("--name WORKSPACE", "Only this workspace (repeatable); its project's locks and dev are still included") { |v| options[:names] << v }
        opts.on("--pr", "Also read each branch's pull request with `gh pr view` (adds git.pr; slower)") { options[:pr] = true }
        opts.on("-h", "--help", "Show this help") { options[:help] = true }
        opts.separator ""
        opts.separator "Examples:"
        opts.separator "  workspace snapshot --json"
        opts.separator "  workspace snapshot --json --name my-app.worktree-fix-login --pr"
      end
    end

    def cmd_snapshot(args)
      options = {json: false, names: [], pr: false}
      given = args.dup
      parser = snapshot_parser(options)
      parser.parse!(args)
      return @output.puts(parser.help) if options[:help]

      raise Error, "snapshot is not available: no snapshot command was wired" unless @snapshot_command
      raise UsageError, "Unexpected argument: #{args.first}. Run 'workspace snapshot --help'." unless args.empty?
      raise UsageError, "snapshot only has JSON output: pass --json." unless options[:json]

      result = @snapshot_command.call(names: options[:names], pr: options[:pr])
      @exit_handler.exit(result[:exit_code]) unless result[:exit_code].zero?
    rescue OptionParser::ParseError, UsageError => e
      raise unless json_requested?(options[:json], given)
      emit_json_error(Commands::Snapshot::JSON_SCHEMA_VERSION, e, message: e.message.lines.first.strip)
    end

    def cmd_hooks(args)
      case args.shift
      when "uninstall" then cmd_hooks_uninstall(args)
      when "help", "--help", "-h", nil then @output.puts hooks_help
      else raise UsageError, hooks_help
      end
    end

    def hooks_help
      <<~HELP
        Usage: workspace hooks <subcommand> [options]

        Manage the hooks workspace installs into coding agents' own settings
        ('workspace init', 'start' and 'doctor --fix' install them).

        Subcommands:
          uninstall   Remove workspace's hooks for one agent, keeping your own

        Examples:
          workspace hooks uninstall --agent codex --dry-run
          workspace hooks uninstall --agent=codex --json
      HELP
    end

    def cmd_hooks_uninstall(args)
      agent = nil
      name = nil
      project = nil
      dry_run = false
      json = false
      parser = OptionParser.new do |opts|
        opts.banner = "Usage: workspace hooks uninstall --agent KIND [--name WS | --project [NAME]] [--dry-run] [--json]"
        opts.separator ""
        opts.separator "Remove workspace's hooks from KIND's settings file: Codex's"
        opts.separator "$CODEX_HOME/hooks.json (default ~/.codex/hooks.json), or for claude"
        opts.separator "the .claude/settings.json of the current directory's project, or of"
        opts.separator "the checkouts --name or --project pick. Only handlers running"
        opts.separator "'workspace session-event' go; your own hooks and every other key stay."
        opts.separator "The file is backed up first. Running it again changes nothing."
        opts.separator "'workspace init', 'start' or 'doctor --fix' install them again."
        opts.separator ""
        opts.separator "Options:"
        opts.on("--agent KIND", "The agent whose hooks to remove: codex or claude") { |v| agent = v }
        opts.on("--name WS", "claude: the checkout of workspace WS, not the current directory") { |v| name = v }
        opts.on("--project [NAME]", "claude: every checkout of the project (main and worktrees); NAME is a project,",
          "a path in it or a member workspace, default the current directory's") { |v| project = v.to_s.empty? || v }
        opts.on("--dry-run", "Say what would be removed, and change nothing") { dry_run = true }
        opts.on("--json", "Print one action document (exit 3 when some checkouts failed)") { json = true }
        opts.separator ""
        opts.separator "Examples:"
        opts.separator "  workspace hooks uninstall --agent claude --project --dry-run"
        opts.separator "  workspace hooks uninstall --agent claude --name my-feature"
        opts.separator "  workspace hooks uninstall --agent codex --dry-run"
        opts.separator "  workspace hooks uninstall --agent=codex --json"
      end
      parser.parse!(args)
      raise UsageError, "Unexpected argument: #{args.first}\n\n#{parser.help}" if args.any?
      raise UsageError, "--agent is required.\n\n#{parser.help}" unless agent

      raise UsageError, "--name and --project can't be combined.\n\n#{parser.help}" if name && project

      run_action("hooks uninstall", json: json) do
        next hooks_uninstall_targets(agent, name, project, dry_run, json) if name || project

        result = @hooks_command.uninstall(agent: agent, dry_run: dry_run)
        outcome = if result["removed"].zero?
          "not_installed"
        else
          dry_run ? "would_remove" : "removed"
        end
        unless json
          verb = dry_run ? "Would remove" : "Removed"
          @output.puts(result["removed"].zero? ? "No workspace hooks in #{result["path"]}; nothing to remove." :
            "#{verb} #{result["removed"]} workspace hook(s) from #{result["path"]}#{" (backup: #{result["backup"]})" if result["backup"] && !dry_run}.")
        end
        {results: [action_row(nil, outcome, **result.transform_keys(&:to_sym))], status: dry_run ? "dry_run" : nil}
      end
    end

    # `hooks uninstall --name/--project`: one row per checkout.
    def hooks_uninstall_targets(agent, name, project, dry_run, json)
      rows = @hooks_command.uninstall_in(agent: agent, name: name, project: project, dry_run: dry_run)
      results = rows.map do |row|
        extra = row.except("workspace", "outcome", "reason", "message")
        action_row(row["workspace"], row["outcome"], reason: row["reason"], message: row["message"], **extra.transform_keys(&:to_sym))
      end
      derived = JsonEnvelope.action_status(results)
      unless json
        results.each do |row|
          label = row["workspace"] || row["checkout"]
          @output.puts case row["outcome"]
          when "failed", "skipped" then "#{label}: #{row["outcome"]}: #{row["message"]}"
          when "not_installed" then "#{label}: no workspace hooks in #{row["path"]}; nothing to remove."
          else "#{label}: #{(row["outcome"] == "removed") ? "Removed" : "Would remove"} #{row["removed"]} workspace hook(s) from #{row["path"]}#{" (backup: #{row["backup"]})" if row["backup"]}."
          end
        end
      end
      {results: results, status: (dry_run && derived == "ok") ? "dry_run" : nil,
       exit_code: JsonEnvelope::ACTION_EXIT_CODES.fetch(derived)}
    end

    def cmd_session_event(args)
      workspace = nil
      agent = nil
      parser = OptionParser.new do |opts|
        opts.banner = "Usage: workspace session-event [options]"
        opts.separator ""
        opts.separator "Forward one coding-agent hook event, read as JSON on stdin, to that"
        opts.separator "workspace's agent daemon. Installed as a hook by 'workspace init';"
        opts.separator "not normally run by hand."
        opts.separator ""
        opts.separator "Exits 2 when the caller's edit lock check fails (a PreToolUse for an"
        opts.separator "editing tool while another agent holds the edit lock); a missing daemon"
        opts.separator "otherwise never fails an agent's turn."
        opts.separator ""
        opts.separator "Options:"
        opts.on("--workspace NAME", "Send to NAME instead of the pane's session") do |value|
          workspace = value
        end
        opts.on("--agent KIND", "Read the payload as KIND's hook events: claude (the default) or codex") do |value|
          agent = value
        end
        opts.separator ""
        opts.separator "Examples:"
        opts.separator "  echo '{\"hook_event_name\":\"SessionStart\",\"session_id\":\"abc\"}' | workspace session-event"
        opts.separator "  echo '{\"hook_event_name\":\"Stop\"}' | workspace session-event --workspace my-project"
        opts.separator "  echo '{\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"Edit\"}' | workspace session-event --workspace my-project"
        opts.separator "  echo '{\"hook_event_name\":\"PermissionRequest\",\"tool_name\":\"Bash\"}' | workspace session-event --agent=codex"
      end
      parser.parse!(args)

      result = @session_event_command.call(workspace: workspace, agent: agent)
      @exit_handler.exit(result[:exit_code]) unless result[:exit_code].zero?
    end

    def cmd_doctor(args)
      headless = nil
      fix = false
      json = false
      parser = OptionParser.new do |opts|
        opts.banner = "Usage: workspace doctor [options]"
        opts.separator ""
        opts.separator "Check that all required dependencies are installed and configured."
        opts.separator ""
        opts.separator "Options:"
        opts.on("--[no-]headless", "Check for a headless setup (skips iTerm2 and window-tool), or not;",
          "default follows the same rule as 'workspace launch'") do |v|
          headless = v
        end
        opts.on("--fix", "Route Claude's statusLine through 'workspace statusline' (backs up",
          "settings.json first); the only fix this performs today") do
          fix = true
        end
        opts.on("--json", "Print one JSON document with a row per check (see docs/README.doctor.md);",
          "exits 1 when a check failed") { json = true }
        opts.separator ""
        opts.separator "Examples:"
        opts.separator "  workspace doctor    # check the current machine's setup"
        opts.separator "  workspace doctor --json    # the same checks as one document"
        opts.separator "  workspace doctor --fix    # also route Claude's statusLine through workspace statusline"
        opts.separator "  workspace doctor --headless    # check for a headless setup (skips iTerm2 and window-tool)"
      end
      parser.parse!(args)

      return @doctor.run(headless: headless, fix: fix) unless json

      result = divert_output { @doctor.report(headless: headless, fix: fix) }
      @output.puts JSON.generate(Doctor.document(result))
      @exit_handler.exit(1) if result[:issues].positive?
    end

    def cmd_relaunch(args)
      json = false
      parser = OptionParser.new do |opts|
        opts.banner = "Usage: workspace relaunch [--json]"
        opts.separator ""
        opts.separator "Stop all active workspace projects and relaunch them."
        opts.separator ""
        opts.on("--json", "Print one action document (see docs/README.json.md) instead of progress text;",
          "the text goes to stderr. Exit 0, 3 when some projects failed, 1 when all did") { json = true }
        opts.separator ""
        opts.separator "Example:"
        opts.separator "  workspace relaunch    # stop every active project and relaunch it (headless ones stay headless)"
      end
      parser.parse!(args)

      @state.load
      if @state.empty?
        raise Error, "No active workspace projects to relaunch." if json
        @error_output.puts "No active workspace projects to relaunch."
        @exit_handler.exit(1)
      end

      run_action("relaunch", json: json) do
        relaunch_active_projects(json)
      end
    end

    def relaunch_active_projects(json)
      projects = @state.keys.dup
      headless, windowed = projects.partition { |p| @state.dig(p, "headless") }
      @output.puts "Will relaunch: #{projects.join(", ")}"

      cmd_stop([])

      sleep 2

      # Each project comes back the way it was launched: headless ones stay
      # headless. Both batches are attempted even if the windowed batch
      # fails, so a windowed failure never silently drops the headless
      # relaunch; the combined exit code reflects either failure.
      launches = []
      launches << launch_projects(windowed.dup) if windowed.any?
      launches << launch_projects(headless.dup, headless: true) if headless.any?
      failed = launches.any? { |l| l[:exit_code] && !l[:exit_code].zero? }
      rows = json ? launches.flat_map { |l| launch_rows(l[:projects], l[:result], ok_outcome: "relaunched") } : []
      {exit_code: failed ? 1 : 0, results: rows}
    end

    def cmd_restore(args)
      dry_run = false
      json = false
      parser = OptionParser.new do |opts|
        opts.banner = "Usage: workspace restore [WORKSPACE...] [--dry-run] [--json]"
        opts.separator ""
        opts.separator "Bring back the coding-agent panes a reboot or a tmux restart took. For each"
        opts.separator "workspace (default: every active one), restore reads the session ledger, launches"
        opts.separator "the workspace if its tmux session is not running, recreates each recorded agent"
        opts.separator "pane that is gone (including panes you split by hand), and types"
        opts.separator "`claude --resume <session id>` into it from the session's directory."
        opts.separator ""
        opts.separator "It never types into a pane that already runs an agent or another program, and it"
        opts.separator "leaves the panes a workspace's config starts to the config. A session you ended"
        opts.separator "yourself (/exit, /clear) is not restored. Pane bindings move to the new panes."
        opts.separator ""
        opts.on("--dry-run", "Show what would be restored and which recorded panes can't be matched; change nothing") { dry_run = true }
        opts.on("--json", "Print one action document (see docs/README.restore.md) instead of text;",
          "the text goes to stderr. Exit 0, 3 when some rows failed, 1 when all did") { json = true }
        opts.separator ""
        opts.separator "Without --json the exit status is 1 when any workspace or pane failed, else 0."
        opts.separator "A recorded pane that could not be matched is reported, not a failure."
        opts.separator ""
        opts.separator "Examples:"
        opts.separator "  workspace restore --dry-run    # what would come back, and what can't"
        opts.separator "  workspace restore    # restore every active workspace"
        opts.separator "  workspace restore my-app --json"
      end
      parser.parse!(args)
      raise Error, "restore is not available: no restore command was wired" unless @restore_command

      names = restore_targets(args)
      run_action("restore", json: json) do
        @restore_command.call(names, dry_run: dry_run) { |missing| launch_for_restore(missing) }
      end
    end

    # The workspaces `restore` acts on: the ones named, else the active set.
    def restore_targets(names)
      @state.load
      unless names.empty?
        names.each do |name|
          next if @project_config.project_root_for(name)
          raise Error.new("Unknown workspace '#{name}'", code: "unknown_workspace", details: {"name" => name})
        end
        return names.uniq
      end
      raise Error, "No active workspace projects to restore. Name one: workspace restore WORKSPACE" if @state.empty?

      @state.keys.dup
    end

    # Launches the workspaces whose session is gone, each the way it was last
    # launched (headless ones stay headless), as `relaunch` does.
    #
    # @return [Hash{String=>String}] workspace => why it could not be launched
    def launch_for_restore(names)
      headless, windowed = names.partition { |name| @state.dig(name, "headless") }
      [[windowed, nil], [headless, true]].each_with_object({}) do |(batch, mode), failures|
        next if batch.empty?

        launch = launch_projects(batch.dup, headless: mode)
        launch_rows(launch[:projects], launch[:result]).each do |row|
          failures[row["workspace"]] = row["message"] || row["reason"] if row["outcome"] == "failed"
        end
      rescue Workspace::Error => e
        batch.each { |name| failures[name] = e.message }
      end
    end

    def cmd_add(args)
      json = false
      parser = OptionParser.new do |opts|
        opts.banner = "Usage: workspace add [--json] <path> [path2] ..."
        opts.separator ""
        opts.separator "Add tmuxinator configs for project directories."
        opts.separator "Uses the directory name as the project name."
        opts.separator "For paths inside .worktrees/, prefixes with the repo name"
        opts.separator "(e.g. repo/.worktrees/MYJIRA-123 → repo-MYJIRA-123)."
        opts.separator "Does nothing if a config already exists."
        opts.separator "New names are lowercase. A name that differs only in case from another"
        opts.separator "workspace's is refused (workspace_name_case_conflict); the same directory's"
        opts.separator "mixed-case config is reused."
        opts.separator "A path that is not a directory, or whose name is refused, is skipped with an"
        opts.separator "error message; the other paths are still added. Exit status: 0 if none was"
        opts.separator "skipped, 3 if some were, 1 if all were (the same with --json)."
        opts.separator "A new config for a path inside .worktrees/ also gets its notes directory"
        opts.separator "set up (see 'workspace notes dir'): stored as the config's notes.dir,"
        opts.separator "created, and kept out of git status. A problem there is a warning."
        opts.separator ""
        opts.separator "Options:"
        opts.on("--json", "Print one action document (see docs/README.json.md) instead of text, which goes",
          "to stderr; one row per path, outcome created, exists or failed (reason not_a_directory or",
          "workspace_name_case_conflict), with root and config_path. A failed path is skipped and the",
          "others are added. Exit 0 if no row failed, 3 if some did, 1 if all did") { json = true }
        opts.separator ""
        opts.separator "Examples:"
        opts.separator "  workspace add ~/Code/my-project   # add a project by path"
        opts.separator "  workspace add .    # add the current directory"
        opts.separator "  workspace add ~/Code/project-a ~/Code/project-b    # add multiple projects"
        opts.separator "  workspace add --json ~/Code/my-project    # created or exists, as JSON"
      end
      parser.parse!(args)

      raise UsageError, parser.help if args.empty?

      targets = args.map do |arg|
        name, root = @project_config.resolve_project_arg(arg)
        [name, root || File.expand_path(arg)]
      rescue Workspace::Error => e
        raise unless e.code == "workspace_name_case_conflict"

        [e, File.expand_path(arg)]
      end

      run_action("add", json: json) do
        warnings = []
        rows = targets.map do |name, root|
          if name.is_a?(Workspace::Error)
            next refuse_add(name.details["name"], root, name, json: json)
          end
          unless File.directory?(root)
            error = Workspace::Error.new("Not a directory: #{root}", code: "not_a_directory", details: {"path" => root})
            next refuse_add(name, root, error, json: json)
          end
          add_one_project(name, root, json: json, warnings: warnings)
        end
        failed = rows.count { |row| row && row["outcome"] == "failed" }
        exit_code = if failed == 0
          0
        else
          ((failed == targets.size) ? 1 : 3)
        end
        {results: rows.compact, warnings: warnings, exit_code: exit_code}
      end
    end

    # Adds one project for `cmd_add`. With `json`, returns the action row
    # (`created` or `exists`) and collects notes warnings. A refused name is
    # handled by {#refuse_add}.
    def add_one_project(name, root, json:, warnings:)
      created = @project_config.existing_name(name).nil?
      name = @project_config.create(name, root) || name
      @project_settings.ensure_exists(name)
      @output.puts "Project name: #{name}" unless json
      worktree = created && File.basename(File.dirname(root)) == ".worktrees"
      notes = worktree ? setup_notes_for_added_worktree(name, json: json) : nil
      return unless json

      warnings.concat(notes["warnings"]) if notes
      action_row(name, created ? "created" : "exists", root: root,
        config_path: @project_config.config_path_for(name), notes_dir: notes && notes["dir"])
    rescue Workspace::Error => e
      raise unless e.code == "workspace_name_case_conflict"

      refuse_add(name, root, e, json: json)
    end

    # A path `add` skips: an error line on stderr and a `failed` row (reason is
    # the error's code; only `--json` prints it). The other paths carry on.
    def refuse_add(name, root, error, json:)
      @error_output.puts "Error: #{error.message}"

      action_row(name, "failed", reason: error.code, message: error.message, root: root, details: error.details)
    end

    # A worktree config `add` just made gets its notes directory fixed the way
    # `start` fixes one. Problems are warnings; the config is already made.
    #
    # @return [Hash, nil] the notes setup result
    def setup_notes_for_added_worktree(name, json: false)
      return unless @notes_setup

      result = @notes_setup.call(name)
      result["warnings"].each { |message| @error_output.puts message }
      @output.puts "Notes directory: #{result["dir"]}" if result["dir"] && !json
      result
    end

    def cmd_statusline(args)
      parser = OptionParser.new do |opts|
        opts.banner = "Usage: workspace statusline"
        opts.separator ""
        opts.separator "Reads Claude Code's status-line JSON on stdin, records its context-window"
        opts.separator "usage for this pane, and prints a status line. Install as Claude Code's"
        opts.separator "statusLine command; not normally run by hand."
        opts.separator ""
        opts.separator "Never fails: bad input or a storage error still prints something and"
        opts.separator "exits 0. A `statusline.command` in the global config (see 'workspace"
        opts.separator "config set') delegates rendering to another command; a slow or hung"
        opts.separator "delegate falls back to the built-in line."
        opts.separator ""
        opts.separator "Example (installed in ~/.claude/settings.json):"
        opts.separator "  { \"statusLine\": { \"type\": \"command\", \"command\": \"workspace statusline\" } }"
      end
      parser.parse!(args)
      raise UsageError, parser.help if args.any?

      @statusline_command.call
    end

    def cmd_config(args)
      case args.first
      when "set"
        args.shift
        cmd_config_set(args)
      when "get"
        args.shift
        cmd_config_get(args)
      when "unset"
        args.shift
        cmd_config_unset(args)
      when "show"
        args.shift
        cmd_config_show(args)
      when "validate"
        args.shift
        cmd_config_validate(args)
      when "edit"
        args.shift
        cmd_config_edit(args)
      when "keys"
        args.shift
        cmd_config_keys(args)
      else
        cmd_config_show(args)
      end
    end

    def cmd_config_set(args)
      project = nil
      scope = nil
      json = false
      parser = OptionParser.new do |opts|
        opts.banner = "Usage: workspace config set [options] <key> [--] <value>"
        opts.separator ""
        opts.separator "Sets a config key in one layer's file. With no --scope the highest layer the"
        opts.separator "key allows at or below the workspace is written: the workspace's own file for a"
        opts.separator "key a worktree may override (dev.ready_timeout, notes.dir), else the project's"
        opts.separator "file, and the global file for a key that is global-only. The workspace is"
        opts.separator "inferred from cwd; --name picks it from anywhere. `workspace config show --json`"
        opts.separator "lists the layers each key allows (overridable_in)."
        opts.separator ""
        opts.separator "Allowed keys: #{ConfigSchema.settable_names.join(", ")}"
        opts.separator ""
        opts.separator "Note: this rewrites the whole YAML file, so comments already in it"
        opts.separator "are not kept. The old file is always copied to a .workspace-backup-*"
        opts.separator "file first; when it had a comment, a note on stderr names the backup"
        opts.separator "and the --json row has comments_preserved: false. A file that isn't"
        opts.separator "valid YAML is left untouched and the command fails; fix or remove it first."
        opts.separator ""
        opts.separator "Options:"
        opts.on("--project NAME", "--name NAME", "Workspace to configure instead of the one inferred from cwd (--name is the same)") { |v| project = v }
        opts.on("--scope SCOPE", "Layer to write: global, project or workspace (worktree is the same). A key that doesn't allow it fails with code scope_not_allowed") { |v| scope = v }
        opts.on("--json", "Print one action document (see docs/README.json.md) instead of text, which goes to stderr") { json = true }
        opts.separator ""
        opts.separator "Precedence: workspace > project > global > default (`workspace config --help`, docs/README.config.md \"Scopes\")."
        opts.separator ""
        opts.separator "Scopes: global is the machine-wide file, project is the main checkout's file and"
        opts.separator "workspace is the workspace's own file. In a main checkout there is no file of its"
        opts.separator "own besides the project's, so workspace writes the project file. The --json row"
        opts.separator "reports scope, layer (global, project or worktree), file and the key's effective"
        opts.separator "value after the write."
        opts.separator ""
        opts.separator "A value that starts with a dash goes after --:  workspace config set dev.up -- -x"
        opts.separator ""
        opts.separator "Examples:"
        opts.separator "  workspace config set --scope project handoff.auto true"
        opts.separator "  workspace config set --scope workspace dev.ready_timeout 90s"
        opts.separator "  workspace config set --scope project workflows.defaults.include commits"
        opts.separator "  workspace config set dev.up \"./start-dev\""
        opts.separator "  workspace config set dev.stop_timeout 20s"
        opts.separator "  workspace config set locks.idle_grace 10m"
        opts.separator "  workspace config set alerts.notify 'say \"$WORKSPACE_ALERT_TEXT\"'"
        opts.separator "  workspace config set alerts.idle_after 15m"
        opts.separator "  workspace config set notes.dir /Users/me/notes/myapp"
        opts.separator "  workspace config set notes.dir /Users/me/notes/myapp-fix --name myapp.worktree-fix"
        opts.separator "  workspace config set --project myapp dev.up \"bin/dev\""
        opts.separator "  workspace config set statusline.command \"~/bin/my-statusline\""
        opts.separator "  workspace config set context.source scrape"
        opts.separator "  workspace config set context.pattern '(\\d+)% ctx'"
        opts.separator "  workspace config set launch.headless true"
        opts.separator ""
        opts.separator "statusline.command, context.source, context.pattern, and launch.headless are"
        opts.separator "global (one per machine), not per project."
      end
      begin
        parser.parse!(args)
      rescue OptionParser::InvalidOption => e
        raise UsageError, "#{e.message} (durations must be positive; a negative value like \"-5m\" looks like a flag)"
      end
      key = args.shift
      value = args.shift
      raise UsageError, parser.help if key.nil? || value.nil? || args.any?

      run_action("config set", json: json) do
        result = @config_command.set(key, value, project: project, scope: config_scope(scope), cwd: @working_dir)
        {results: json ? [config_write_row(result, "set", project, value: value)] : []}
      end
    end

    CONFIG_SCOPE_CHOICES = %w[global project workspace worktree].freeze

    # "worktree" is another spelling of "workspace".
    def config_scope(scope)
      return nil if scope.nil?
      raise UsageError, "Unknown scope '#{scope}'. Use global, project or workspace." unless CONFIG_SCOPE_CHOICES.include?(scope)
      (scope == "worktree") ? "workspace" : scope
    end

    # The `config set/unset --json` row: the existing fields plus the layer written and the key's
    # effective value after the write (nil for a sensitive key or when it can't be worked out).
    def config_write_row(result, outcome, project, value: nil)
      extra = {key: result.key}
      extra[:value] = value if outcome == "set"
      outcome = "noop" if result.changed == false
      action_row(result.workspace, outcome, **extra, global: result.layer == "global", scope: result.scope, layer: result.layer,
        file: result.path, comments_preserved: result.comments_preserved, effective: config_effective_after(result.key, project))
    end

    def config_effective_after(key, project)
      return nil unless @config_report
      workspace = project || @project_detector.detect(@working_dir)
      return nil unless workspace
      @config_report.show(workspace, key: key)["keys"].first["effective"]
    rescue Workspace::Error
      nil
    end

    def cmd_config_keys(args)
      settable = false
      json = false
      parser = OptionParser.new do |opts|
        opts.banner = "Usage: workspace config keys [QUERY] [--settable] [--json]"
        opts.separator ""
        opts.separator "Describes the config keys: type, default, the layers that may hold each, whether"
        opts.separator "'config set' accepts it, when a change applies, and example values. Reads no config"
        opts.separator "file and prints no stored value (see 'workspace config' for those)."
        opts.separator ""
        opts.separator "With no QUERY, lists every key on one line. A QUERY equal to a key name prints that"
        opts.separator "key in full. Any other QUERY keeps the keys whose name or description text contains"
        opts.separator "it as a substring, ignoring case; with no match it fails with unknown_config_key."
        opts.separator ""
        opts.separator "Options:"
        opts.on("--settable", "Only the keys 'config set' accepts") { settable = true }
        opts.on("--json", "Print one document with a `keys` array (see docs/README.config.md)") { json = true }
        opts.separator ""
        opts.separator "Examples:"
        opts.separator "  workspace config keys"
        opts.separator "  workspace config keys timeout     # keys whose name or description mentions timeout"
        opts.separator "  workspace config keys dev.up      # one key in full, with example values"
        opts.separator "  workspace config keys --settable --json"
      end
      parser.parse!(args)
      query = args.shift
      raise UsageError, parser.help if args.any?

      @config_command.keys(query: query, settable: settable, json: json)
    end

    def cmd_config_get(args)
      project = nil
      scope = nil
      parser = OptionParser.new do |opts|
        opts.banner = "Usage: workspace config get <key> [options]"
        opts.separator ""
        opts.separator "Reads one layer's file, not the layered result (`workspace config <key>`"
        opts.separator "gives that). With no --scope it reads the file `config set` would write: the"
        opts.separator "workspace's own for a key a worktree may override, else the project's, else the"
        opts.separator "global file."
        opts.separator ""
        opts.separator "Prints the value on stdout and exits 0. If the key has no value,"
        opts.separator "prints nothing on stdout, a note on stderr, and exits 1."
        opts.separator ""
        opts.separator "Options:"
        opts.on("--project NAME", "--name NAME", "Workspace to read instead of the one inferred from cwd (--name is the same)") { |v| project = v }
        opts.on("--scope SCOPE", "Layer whose file to read: global, project or workspace (worktree is the same); scope_not_allowed when the key can't live there") { |v| scope = v }
        opts.separator ""
        opts.separator "Examples:"
        opts.separator "  workspace config get dev.up"
        opts.separator "  workspace config get --scope project handoff.auto --name myapp.worktree-fix"
      end
      parser.parse!(args)
      key = args.shift
      raise UsageError, parser.help if key.nil? || args.any?

      found = @config_command.get(key, project: project, scope: config_scope(scope), cwd: @working_dir)
      @exit_handler.exit(1) unless found
    end

    def cmd_config_unset(args)
      project = nil
      scope = nil
      json = false
      parser = OptionParser.new do |opts|
        opts.banner = "Usage: workspace config unset <key> [options]"
        opts.separator ""
        opts.separator "Removes a key from one layer's file (the one `config set` would write, unless"
        opts.separator "--scope names another). The layers below it then apply again. Like `set`, it"
        opts.separator "rewrites the file, keeps a .workspace-backup-* copy and drops comments."
        opts.separator ""
        opts.separator "Options:"
        opts.on("--project NAME", "--name NAME", "Workspace to configure instead of the one inferred from cwd (--name is the same)") { |v| project = v }
        opts.on("--scope SCOPE", "Layer to remove it from: global, project or workspace (worktree is the same); scope_not_allowed when the key can't live there") { |v| scope = v }
        opts.on("--json", "Print one action document (see docs/README.json.md) instead of text, which goes to stderr") { json = true }
        opts.separator ""
        opts.separator "Examples:"
        opts.separator "  workspace config unset dev.ready"
        opts.separator "  workspace config unset --scope workspace dev.ready_timeout --name myapp.worktree-fix --json"
      end
      parser.parse!(args)
      key = args.shift
      raise UsageError, parser.help if key.nil? || args.any?

      run_action("config unset", json: json) do
        result = @config_command.unset(key, project: project, scope: config_scope(scope), cwd: @working_dir)
        {results: json ? [config_write_row(result, "unset", project)] : []}
      end
    end

    def cmd_config_edit(args)
      project = nil
      scope = nil
      json = false
      parser = OptionParser.new do |opts|
        opts.banner = "Usage: workspace config edit [options]"
        opts.separator ""
        opts.separator "Opens one layer's config file in $VISUAL or $EDITOR (run without a shell, so"
        opts.separator "the command is split into words and the path is passed as its last argument)."
        opts.separator "A file that doesn't exist yet is created first with a comment header. With no"
        opts.separator "--scope the workspace's own file is opened (the project's file in a main checkout)."
        opts.separator ""
        opts.separator "Unlike 'config set', editing by hand keeps comments, but nothing checks the"
        opts.separator "keys or values; run 'workspace config validate' afterwards."
        opts.separator ""
        opts.separator "An editor path containing spaces must be quoted in $EDITOR."
        opts.separator "With no $VISUAL or $EDITOR set (or blank), under --no-input, or when stdin or"
        opts.separator "stdout is not a terminal, the path is printed, nothing is opened and the exit is 0."
        opts.separator "With --json nothing is opened either: one action document gives the path."
        opts.separator ""
        opts.separator "Options:"
        opts.on("--project NAME", "--name NAME", "Workspace to edit instead of the one inferred from cwd (--name is the same)") { |v| project = v }
        opts.on("--scope SCOPE", "File to edit: global, project or workspace (worktree is the same)") { |v| scope = v }
        opts.on("--json", "Print one action document (see docs/README.json.md); open no editor") { json = true }
        opts.separator ""
        opts.separator "Examples:"
        opts.separator "  workspace config edit"
        opts.separator "  workspace config edit --scope global"
        opts.separator "  workspace config edit --scope project --name myapp.worktree-fix --json"
      end
      parser.parse!(args)
      raise UsageError, parser.help if args.any?

      run_action("config edit", json: json) do
        result = @config_command.edit(project: project, scope: config_scope(scope), cwd: @working_dir)
        if json
          {results: [action_row(result.workspace, "ready", global: result.layer == "global", scope: result.scope, layer: result.layer, file: result.path, created: result.created)]}
        else
          open_in_editor(result.path)
          nil
        end
      end
    end

    # Runs $VISUAL or $EDITOR on +path+ without a shell. With neither set (blank counts as unset),
    # under --no-input, or when stdin or stdout is not a terminal, prints the path and opens nothing.
    def open_in_editor(path)
      command = [@env["VISUAL"], @env["EDITOR"]].find { |value| !value.to_s.strip.empty? }
      if command.nil? || (@input.respond_to?(:no_input?) && @input.no_input?) || !@interactive.call
        @output.puts path
        return
      end
      begin
        argv = Shellwords.split(command)
      rescue ArgumentError => e
        raise Error.new("$EDITOR is not a valid command (#{e.message}). Edit #{path} directly.", code: "editor_failed", details: {path: path})
      end
      return @output.puts(path) if argv.empty?

      unless @editor_launcher.call(argv + [path])
        raise Error.new("Could not run the editor '#{argv.first}'. The file is at #{path}", code: "editor_failed", details: {path: path, editor: argv.first})
      end
    end

    def cmd_config_validate(args)
      json = false
      name = nil
      parser = OptionParser.new do |opts|
        opts.banner = "Usage: workspace config validate [--name NAME] [--json]"
        opts.separator ""
        opts.separator "Check the config files a workspace reads (its own, its parent project's when it is"
        opts.separator "a worktree, and the global one): YAML syntax, key types and values, and keys"
        opts.separator "nothing reads. A file that can't be parsed is reported with its line and column"
        opts.separator "rather than failing the command. Exits 0 when there are no errors, 1 otherwise;"
        opts.separator "warnings and notes don't change the exit status."
        opts.separator ""
        opts.separator "Options:"
        opts.on("--name NAME", "--project NAME", "Workspace to check instead of the one inferred from cwd") { |v| name = v }
        opts.on("--json", "Print one document with a `valid` flag and the problems (see docs/README.config.md)") { json = true }
        opts.separator ""
        opts.separator "Examples:"
        opts.separator "  workspace config validate"
        opts.separator "  workspace config validate --name myproject.worktree-PROJ-123 --json"
      end
      parser.parse!(args)
      raise UsageError, parser.help if args.any?

      doc = config_report.validate(config_workspace(name, parser))
      if json
        @output.puts JSON.generate(doc)
      elsif doc["problems"].empty?
        @output.puts "No problems found in the config for '#{doc["workspace"]}'."
      else
        doc["problems"].each do |problem|
          place = [problem["file"], problem["line"], problem["column"]].compact.join(":")
          @output.puts "#{problem["severity"]}: #{place}: #{problem["message"]}"
        end
      end
      @exit_handler.exit(1) unless doc["valid"]
    end

    def config_report
      @config_report || raise(Error, "config reports are not available: no config report was wired")
    end

    # The workspace `config show/validate` act on: the named one, else the one detected from cwd.
    def config_workspace(name, parser)
      name || @project_detector.detect(@working_dir) || raise(UsageError, "Not in a workspace. Pass --name <workspace>.\n\n#{parser.help}")
    end

    def cmd_tmux(args)
      usage = "Usage: workspace tmux show [--name NAME] [--json]"
      case args.first
      when "show"
        args.shift
        cmd_tmux_show(args)
      when nil, "-h", "--help"
        @output.puts usage
        @output.puts
        @output.puts "  show    A workspace's tmuxinator file as session fields, windows and panes"
      else
        raise UsageError, usage
      end
    end

    def cmd_tmux_show(args)
      json = false
      name = nil
      parser = OptionParser.new do |opts|
        opts.banner = "Usage: workspace tmux show [--name NAME] [--json]"
        opts.separator ""
        opts.separator "Show a workspace's tmuxinator file (~/.config/tmuxinator/workspace.<name>.yml) as"
        opts.separator "session fields, windows and panes. Each pane has its command, a kind (claude,"
        opts.separator "agentd, banner, shell or command) and its line in the file; when the session is"
        opts.separator "running, each pane also has its tmux pane id and start command. Read-only: an"
        opts.separator "edit to the file takes effect the next time the session is launched."
        opts.separator ""
        opts.separator "Options:"
        opts.on("--name NAME", "--project NAME", "Workspace to show instead of the one inferred from cwd") { |v| name = v }
        opts.on("--json", "Print one document (see docs/README.tmux.md)") { json = true }
        opts.separator ""
        opts.separator "Examples:"
        opts.separator "  workspace tmux show"
        opts.separator "  workspace tmux show --name myproject --json"
      end
      parser.parse!(args)
      raise UsageError, parser.help if args.any?
      raise Error, "tmux show is not available: no tmuxinator report was wired" unless @tmuxinator_report

      doc = @tmuxinator_report.show(config_workspace(name, parser))
      return @output.puts(JSON.generate(doc)) if json

      print_tmux_show(doc)
    end

    def print_tmux_show(doc)
      @output.puts "# #{doc["file"]}"
      if doc["parse_error"]
        place = [doc["parse_error"]["line"], doc["parse_error"]["column"]].compact.join(":")
        @output.puts "Cannot parse (#{place}): #{doc["parse_error"]["message"]}"
        return
      end
      session = doc["session"]
      @output.puts "session #{session["name"]}  root #{session["root"]}  #{doc["running"] ? "running" : "not running"}"
      doc["windows"].each do |window|
        @output.puts "window #{window["index"]} #{window["name"]} (#{window["layout"]})"
        window["panes"].each do |pane|
          @output.puts "  pane #{pane["index"]} [#{pane["kind"]}] #{pane["command"].to_s.lines.first&.strip}"
        end
      end
    end

    def cmd_config_show(args)
      scope = nil
      json = false
      name = nil
      parser = OptionParser.new do |opts|
        opts.banner = "Usage: workspace config [show] [options] [key]"
        opts.separator ""
        opts.separator "Show project or global workspace configuration. With a key, print"
        opts.separator "that key's effective value (layering and defaults included, unlike"
        opts.separator "'workspace config get', which reads one file)."
        opts.separator ""
        opts.separator "With --scope, show one layer: the file of that scope (text) or, in --json, each"
        opts.separator "row's value/source_file/line/column from that file alone, with effective, source"
        opts.separator "and layers covering global up to that scope (project: global < project)."
        opts.separator ""
        opts.separator "Options:"
        opts.on("--scope SCOPE", "Show one layer: global, project or workspace (worktree is the same). In a main checkout workspace is the project's file") { |v| scope = config_scope(v) }
        opts.on("--global", "Same as --scope global") do
          raise UsageError, "--global and --scope #{scope} disagree: pass one" if scope && scope != "global"
          scope = "global"
        end
        opts.on("--name NAME", "Workspace to show instead of the one inferred from cwd") { |v| name = v }
        opts.on("--json", "Print the show document as JSON: every key with its effective value, source layer and files, or with a key just that key's row (see docs/README.config.md)") { json = true }
        opts.separator ""
        opts.separator "Config files:"
        opts.separator "  Global:  #{@project_settings.global_config_path}"
        opts.separator "  Project: #{@config.workspace_config_dir}/projects/<name>.yml"
        opts.separator ""
        opts.separator "Keys: 'workspace config' lists every key with its value and layer; docs/README.config.md"
        opts.separator "has the table of doc text, defaults and the layers each key may be set in"
        opts.separator "(overridable_in), and 'workspace config --json' gives the same as data."
        opts.separator "hooks and layouts are edited by hand ('config edit')."
        opts.separator ""
        opts.separator "Layers (highest wins): workspace (a worktree's own file) > project (the main"
        opts.separator "checkout's file) > global > the built-in default. Each key lists the layers it"
        opts.separator "allows (overridable_in); see docs/README.config.md. Choose the file with"
        opts.separator "--scope S on config set/get/unset/edit."
        opts.separator ""
        opts.separator "Note: 'show', 'validate', 'set', 'get', 'unset', 'edit' and 'keys' are reserved as the first"
        opts.separator "argument here and are always treated as subcommands. A key named one of"
        opts.separator "them, or a workspace named one of them, is reached with --name."
        opts.separator ""
        opts.separator "Examples:"
        opts.separator "  workspace config               # show config for project in current dir"
        opts.separator "  workspace config --name myproject    # show another workspace's config"
        opts.separator "  workspace config dev.up         # that key's effective value"
        opts.separator "  workspace config notes.dir      # where this workspace's notes go"
        opts.separator "  workspace config --global      # show global config"
        opts.separator "  workspace config --scope project --name myapp.worktree-fix    # the project's file"
        opts.separator "  workspace config --scope project --json dev.up    # dev.up as the project's file has it, and effective up to project"
        opts.separator "  workspace config dev.up --json    # that key's row in the show document"
        opts.separator "  workspace config validate --name myproject --json    # problems, with line and column"
        opts.separator "  workspace config set dev.up \"./start-dev\""
        opts.separator "  workspace config get dev.up"
        opts.separator "  workspace config unset dev.ready"
        opts.separator "  workspace config edit --scope global    # hand-edit a file, keeping its comments"
        opts.separator "  workspace config keys [QUERY]    # what each key is, its default and example values"
      end
      parser.parse!(args)
      key = args.shift
      raise UsageError, parser.help if args.any?
      if key
        raise UsageError, "Unknown config key '#{key}'. Keys: #{ConfigSchema.all.map(&:name).join(", ")}" if ConfigSchema.key(key).nil?
        doc = config_report.show(config_workspace(name, parser), key: key, **config_show_scope(scope))
        if json
          @output.puts JSON.generate(doc)
        else
          found = print_config_key_row(doc["keys"].first)
          @exit_handler.exit(1) unless found
        end
        return
      end

      if json
        @output.puts JSON.generate(config_report.show(config_workspace(name, parser), **config_show_scope(scope)))
        return
      end

      if scope == "global"
        data = @project_settings.load_global
        path = @project_settings.global_config_path
        @output.puts "# #{path}"
        if data.empty?
          @output.puts "# (no global config found)"
        else
          @output.puts YAML.dump(data)
        end
      else
        project = config_workspace(name, parser)
        config_report.show(project, scope: scope) if scope == "workspace"
        project = WorkspaceLineage.split_worktree_name(project)&.first || project if scope == "project"
        data = @project_settings.load(project)
        path = @project_settings.project_config_path(project)
        @output.puts "# #{path}"
        if data.empty?
          @output.puts "# (no config found for '#{project}')"
        else
          @output.puts YAML.dump(data)
        end
      end
    end

    def config_show_scope(scope)
      scope ? {scope: scope} : {}
    end

    # Prints one key row from `config show --json` for `workspace config <key>`:
    # the effective value for plain keys, the effective path for the notes keys,
    # YAML for mapping keys, and only set/unset status for sensitive keys.
    # Returns true when the key has a value, false when it is unset (the caller
    # exits 1, like `config get`).
    def print_config_key_row(row)
      return print_config_key_status(row) if row["sensitive"]
      if row.key?("effective_path") && row["effective_path"]
        @output.puts row["effective_path"]
        return true
      end

      value = row["effective"]
      if value.is_a?(Hash)
        return false if value.empty?
        @output.puts YAML.dump(value)
      elsif value.nil?
        @error_output.puts "#{row["key"]} is not set"
        return false
      else
        @output.puts value
      end
      true
    end

    # A sensitive key's value never prints; only whether it is set.
    def print_config_key_status(row)
      if row["source_file"]
        @error_output.puts "#{row["key"]} is set in #{row["source_file"]}"
        true
      else
        @error_output.puts "#{row["key"]} is not set"
        false
      end
    end

    def cmd_list(args)
      all = false
      json = false
      show_urls = false
      show_liveness = false
      envelope = false
      parser = OptionParser.new do |opts|
        opts.banner = "Usage: workspace list [options]"
        opts.separator ""
        opts.separator "List currently active (launched) projects."
        opts.separator "Plain list reads the state file and does not check that each project is still"
        opts.separator "running; add --liveness to check each project's tmux session."
        opts.separator ""
        opts.separator "Options:"
        opts.on("--all", "List all available projects (not just active ones)") do
          all = true
        end
        opts.on("--json", "Output as JSON") { json = true }
        opts.on("--json-envelope", "Output as JSON in the standard envelope (implies --json)") { json = envelope = true }
        opts.on("--show-urls", "Include the git origin URL alongside each project name") { show_urls = true }
        opts.on("--liveness", "Mark each active project alive, dead, or unknown from its tmux session") { show_liveness = true }
        opts.separator ""
        opts.separator "Examples:"
        opts.separator "  workspace list    # list active (launched) projects"
        opts.separator "  workspace list --all    # list all available projects"
        opts.separator "  workspace list-projects    # alias for 'list --all'"
        opts.separator "  workspace list --show-urls    # each active project with its git origin URL"
        opts.separator "  workspace list --json    # active projects as JSON"
        opts.separator "  workspace list --json-envelope    # {\"schema_version\":1,\"ok\":true,\"workspaces\":[...],\"warnings\":[]}"
        opts.separator "  workspace list --liveness    # each active project marked [alive], [dead], or [unknown]"
        opts.separator "  workspace list --liveness --json    # [{\"name\":\"my-notes\",\"alive\":true,\"window_alive\":true},...]"
        opts.separator "  workspace list --all --json --show-urls    # all projects with directories and URLs as JSON"
      end
      parser.parse!(args)

      raise Workspace::UsageError, "--liveness applies to active projects and can't be combined with --all" if all && show_liveness

      if all
        if json
          projects = @project_config.available_projects.map do |name|
            root = @project_config.project_root_for(name)
            directory = root ? File.expand_path(root) : nil
            entry = {"name" => name, "directory" => directory}
            entry["url"] = root ? @git.remote_url(directory || root) : nil if show_urls
            entry
          end
          @output.puts JSON.generate(wrap_json(envelope, "workspaces", projects))
        elsif show_urls
          rows = @project_config.available_projects.map do |name|
            root = @project_config.project_root_for(name)
            dir = root ? File.expand_path(root) : nil
            url = dir ? @git.remote_url(dir) : nil
            [name, url || ""]
          end
          name_width = rows.map { |r| r[0].length }.max || 0
          rows.each { |name, url| @output.puts "#{name.ljust(name_width)}  #{url}".rstrip }
        else
          @project_config.available_projects.each { |name| @output.puts name }
        end
        return
      end

      @state.load
      if @state.empty?
        if json
          @output.puts JSON.generate(wrap_json(envelope, "workspaces", []))
        else
          @output.puts "No active projects. Run 'workspace list --all' to see available projects."
        end
        return
      end

      if show_liveness
        list_with_liveness(json: json, show_urls: show_urls, envelope: envelope)
      elsif json && show_urls
        projects = @state.keys.sort.map do |name|
          root = @project_config.project_root_for(name)
          dir = root ? File.expand_path(root) : nil
          {"name" => name, "directory" => dir, "url" => (dir ? @git.remote_url(dir) : nil)}
        end
        @output.puts JSON.generate(wrap_json(envelope, "workspaces", projects))
      elsif json
        @output.puts JSON.generate(wrap_json(envelope, "workspaces", @state.keys.sort))
      elsif show_urls
        rows = @state.keys.sort.map do |name|
          root = @project_config.project_root_for(name)
          dir = root ? File.expand_path(root) : nil
          url = dir ? @git.remote_url(dir) : nil
          [name, url || ""]
        end
        name_width = rows.map { |r| r[0].length }.max || 0
        rows.each { |name, url| @output.puts "#{name.ljust(name_width)}  #{url}".rstrip }
      else
        @state.keys.sort.each { |p| @output.puts p }
      end
    end

    def cmd_status(args)
      json = false
      envelope = false
      parser = OptionParser.new do |opts|
        opts.banner = "Usage: workspace status [options]"
        opts.separator ""
        opts.separator "Show detailed state of tracked launcher sessions. Each is marked [alive] (its tmux"
        opts.separator "session exists), [dead] (the session is gone; remove it with 'workspace cleanup'),"
        opts.separator "or [unknown] (tmux didn't answer, or the project uses a custom tmux socket)."
        opts.separator ""
        opts.separator "Options:"
        opts.on("--json", "Output as JSON") { json = true }
        opts.on("--json-envelope", "Output as JSON in the standard envelope (implies --json)") { json = envelope = true }
        opts.separator ""
        opts.separator "Examples:"
        opts.separator "  workspace status          # tracked sessions with window ids, headless ones marked"
        opts.separator "  workspace status --json   # machine-readable state (unique ids, window ids, alive: true/false/null)"
        opts.separator "  workspace status --json-envelope    # the same under a \"status\" key, with schema_version, ok and warnings"
        opts.separator "  workspace status --json | jq -r '.[\"my-notes\"].iterm_window_id'    # one project's window id"
      end
      parser.parse!(args)

      @state.load
      if @state.empty?
        json ? @output.puts(JSON.generate(wrap_json(envelope, "status", {}))) : @output.puts("No tracked sessions.")
        return
      end

      alive = @liveness.call(@state.keys)
      if json
        windows = @window_liveness.call(@state.to_h)
        rows = @state.to_h.to_h { |project, info| [project, info.merge("alive" => alive[project], "window_alive" => windows[project])] }
        @output.puts JSON.pretty_generate(wrap_json(envelope, "status", rows))
      else
        @state.each do |project, info|
          wid = info["iterm_window_id"]
          wid_str = if info["headless"]
            "  headless"
          else
            wid ? "  window_id=#{wid}" : ""
          end
          @output.puts "  #{project}#{wid_str}  [#{liveness_label(alive[project])}]"
        end
      end
    end

    # The document a read-only `--json` command prints: the bare value, or with
    # `--json-envelope` the value under `key` after `schema_version` and `ok`.
    def wrap_json(envelope, key, value)
      return value unless envelope

      JsonEnvelope.document(key, value)
    end

    def liveness_label(alive)
      case alive
      when true then "alive"
      when false then "dead"
      else "unknown"
      end
    end

    def list_with_liveness(json:, show_urls:, envelope: false)
      names = @state.keys.sort
      alive = @liveness.call(names)
      windows = json ? @window_liveness.call(@state.to_h.slice(*names)) : {}
      entries = names.map do |name|
        entry = {"name" => name}
        if show_urls
          root = @project_config.project_root_for(name)
          dir = root ? File.expand_path(root) : nil
          entry["directory"] = dir
          entry["url"] = dir ? @git.remote_url(dir) : nil
        end
        entry["alive"] = alive[name]
        entry["window_alive"] = windows[name] if json
        entry
      end

      if json
        @output.puts JSON.generate(wrap_json(envelope, "workspaces", entries))
        return
      end

      name_width = entries.map { |e| e["name"].length }.max
      url_width = show_urls ? entries.map { |e| e["url"].to_s.length }.max : 0
      entries.each do |e|
        cells = [e["name"].ljust(name_width)]
        cells << e["url"].to_s.ljust(url_width) if show_urls
        cells << "[#{liveness_label(e["alive"])}]"
        @output.puts cells.join("  ")
      end
    end

    def cmd_capabilities(args)
      json = false
      help = false
      parser = OptionParser.new do |opts|
        opts.banner = "Usage: workspace capabilities [--json]"
        opts.separator ""
        opts.separator "Print what this workspace supports: the version, a revision number per feature"
        opts.separator "(0 means not available), exit codes, key paths, and where gh, tmux and window-tool are."
        opts.separator "Reads no state and starts no process, so it is cheap to call. Check a feature's"
        opts.separator "revision rather than comparing version numbers."
        opts.separator ""
        opts.on("--json", "Print one JSON document (see docs/README.capabilities.md)") { json = true }
        opts.on("-h", "--help", "Show this help") { help = true }
        opts.separator ""
        opts.separator "Examples:"
        opts.separator "  workspace capabilities    # a readable summary"
        opts.separator "  workspace capabilities --json | jq '.features.no_input'    # 1 when --no-input is supported"
      end
      parser.parse!(args)
      return @output.puts(parser.help) if help

      raise UsageError, "workspace capabilities takes no arguments." unless args.empty?
      raise Error, "capabilities is not available: no capabilities command was wired" unless @capabilities_command

      @capabilities_command.call(json: json)
    end

    def cmd_current(args)
      parser = OptionParser.new do |opts|
        opts.banner = "Usage: workspace current"
        opts.separator ""
        opts.separator "Print the workspace project name for the current directory."
        opts.separator "Detects worktree projects via .workspace-project marker files,"
        opts.separator "then falls back to matching active project roots."
        opts.separator ""
        opts.separator "Examples:"
        opts.separator "  workspace current    # print the current directory's project name"
        opts.separator "  PROJECT=$(workspace current) && workspace focus \"$PROJECT\"    # use in scripts"
      end
      parser.parse!(args)

      project = @project_detector.detect(@working_dir)
      unless project
        raise Workspace::Error, "Not inside a workspace project directory. Run 'workspace list --all' to see available projects."
      end

      @output.puts project
    end

    def cmd_repair(args)
      window_id = nil
      json = false
      parser = OptionParser.new do |opts|
        opts.banner = "Usage: workspace repair [project] [options]"
        opts.separator ""
        opts.separator "Rebuild state from live iTerm windows."
        opts.separator "Scans for windows with 'workspace-{name}' titles and"
        opts.separator "reconstructs the state file from what's actually running."
        opts.separator ""
        opts.separator "Options:"
        opts.on("--window-id WID", Integer, "Manually set the window ID for a project") do |wid|
          window_id = wid
        end
        opts.on("--json", "Print one action document (see docs/README.json.md) instead of text, which goes to stderr") { json = true }
        opts.separator ""
        opts.separator "Examples:"
        opts.separator "  workspace repair    # auto-rebuild state from all live workspace windows"
        opts.separator "  workspace repair homebrew-bin --window-id 1196    # manually set a project's window ID"
      end
      parser.parse!(args)

      if window_id
        project = args.first
        raise UsageError, "Project name required with --window-id\n\n#{parser.help}" unless project
        run_action("repair", json: json) do
          @repair_command.set_window_id(project, window_id)
          {results: json ? [action_row(project, "repaired", iterm_window_id: window_id)] : []}
        end
      else
        run_action("repair", json: json) do
          repaired = @repair_command.call
          rows = json ? repaired.map { |r| action_row(r["workspace"], "repaired", iterm_window_id: r["iterm_window_id"], unique_id: r["unique_id"]) } : []
          {results: rows}
        end
      end
    end

    def cmd_cleanup(args)
      force = false
      json = false
      dry_run = false
      tmux_dead_only = false
      parser = OptionParser.new do |opts|
        opts.banner = "Usage: workspace cleanup [options]"
        opts.separator ""
        opts.separator "Detect and remove zombie sessions from state."
        opts.separator "A zombie session is one where the state file has an entry but"
        opts.separator "the corresponding tmux session or iTerm window no longer exists."
        opts.separator ""
        opts.separator "Lists all zombie sessions and asks for confirmation before removing."
        opts.separator ""
        opts.separator "Options:"
        opts.on("-f", "--force", "Skip confirmation and remove zombies immediately") do
          force = true
        end
        opts.on("--dry-run", "List what would be removed; no prompt, nothing changes, exit 0") { dry_run = true }
        opts.on("--tmux-dead-only", "Count only entries whose tmux session is gone (a closed window alone",
          "does not make an entry a zombie)") { tmux_dead_only = true }
        opts.on("--json", "Print one action document (see docs/README.json.md) instead of text, which goes",
          "to stderr; without --force the prompt still asks (or fails under --no-input).",
          "Rows carry tmux_alive and window_alive (null: headless, or iTerm's windows",
          "could not be listed; a window that could not be read is never called gone)") { json = true }
        opts.separator ""
        opts.separator "Examples:"
        opts.separator "  workspace cleanup    # list zombie sessions and ask before removing"
        opts.separator "  workspace cleanup --dry-run --json    # report the zombies, change nothing"
        opts.separator "  workspace cleanup --tmux-dead-only --force    # remove only entries with no tmux session"
        opts.separator "  workspace cleanup --force    # remove all zombie sessions immediately"
      end
      parser.parse!(args)

      run_action("cleanup", json: json) do
        zombies = @cleanup_command.call(force: force, dry_run: dry_run, tmux_dead_only: tmux_dead_only)
        outcome = dry_run ? "would_remove" : "cleaned"
        rows = json ? zombies.map { |z| action_row(z[:project], outcome, tmux_alive: z[:tmux_alive], window_alive: z[:window_alive], headless: z[:headless] == true) } : []
        {results: rows, status: dry_run ? "dry_run" : nil}
      end
    end

    def cmd_prune(args)
      dry_run = false
      force = false
      json = false
      names = []
      parser = OptionParser.new do |opts|
        opts.banner = "Usage: workspace prune [options]"
        opts.separator ""
        opts.separator "Remove worktree-backed workspace projects whose associated GitHub PR"
        opts.separator "is closed or merged. Scans all tmuxinator configs and state entries."
        opts.separator ""
        opts.separator "For each eligible project, removes the git worktree, tmuxinator config,"
        opts.separator "project settings, and state entry."
        opts.separator ""
        opts.separator "A candidate with uncommitted changes to tracked files or commits that"
        opts.separator "haven't been pushed anywhere (untracked files don't count) is skipped"
        opts.separator "(and reported) rather than removed; the rest are still pruned. --force"
        opts.separator "removes those anyway, along with skipping the confirmation prompt."
        opts.separator ""
        opts.separator "--json removes every selected worktree without asking; narrow it with"
        opts.separator "--name or preview it with --dry-run (which runs the same unsaved-work check)."
        opts.separator "With --json the confirmation is skipped but the unsaved-work check still"
        opts.separator "runs. Output is one action document (see docs/README.prune.md); the scan"
        opts.separator "text goes to stderr. Exit 0 when every selected candidate was removed (or"
        opts.separator "on a dry run), 3 when some were skipped or failed, 1 when none were removed."
        opts.separator ""
        opts.separator "Requires the `gh` CLI to be installed and authenticated."
        opts.separator ""
        opts.separator "Options:"
        opts.on("--dry-run", "Show what would be removed without making changes") do
          dry_run = true
        end
        opts.on("-f", "--force", "Skip confirmation, and skip the uncommitted/unpushed-work check") do
          force = true
        end
        opts.on("--name NAME", "Prune only this workspace (repeatable; others are not_selected)") { |v| names << v }
        opts.on("--json", "Print one action document of per-candidate rows; no confirmation prompt") { json = true }
        opts.separator ""
        opts.separator "Examples:"
        opts.separator "  workspace prune --dry-run --json    # the candidates as rows, would_remove"
        opts.separator "  workspace prune --json --name=feat-a --name=feat-b    # prune two, skip unsaved work"
        opts.separator "  workspace prune --dry-run    # see what would be pruned without changing anything"
        opts.separator "  workspace prune    # prune with a confirmation prompt"
        opts.separator "  workspace prune --force    # prune without prompting, including candidates with unsaved work"
      end
      parser.parse!(args)

      unless json
        @prune_command.call(dry_run: dry_run, force: force, names: names)
        return
      end

      run_action("prune", json: true) do
        rows = @prune_command.call_structured(dry_run: dry_run, force: force, names: names)
        chosen = rows.reject { |r| r["outcome"] == "not_selected" }
        removed = chosen.count { |r| %w[removed would_remove].include?(r["outcome"]) }
        status = if dry_run && chosen.none? { |r| r["outcome"] == "failed" }
          "dry_run"
        elsif removed == chosen.size
          "ok"
        else
          removed.zero? ? "failed" : "partial"
        end
        {results: rows, status: status}
      end
    end

    def cmd_remove(args)
      yes = false
      dry_run = false
      json = false
      parser = OptionParser.new do |opts|
        opts.banner = "Usage: workspace remove [options] NAME"
        opts.separator ""
        opts.separator "Delete a workspace's generated files: its tmuxinator config, its project"
        opts.separator "settings file and its state entry. Each file is copied aside first"
        opts.separator "(<file>.workspace-backup-<time>). The project's directory, git worktrees and"
        opts.separator "notes are never touched."
        opts.separator ""
        opts.separator "Refuses while the workspace's tmux session is up (session_running; run"
        opts.separator "'workspace stop NAME' first) and for a worktree project (not_removable; use"
        opts.separator "'workspace kill', 'finish' or 'prune'). Asks before deleting unless --yes;"
        opts.separator "under --no-input it refuses without --yes."
        opts.separator ""
        opts.separator "Options:"
        opts.on("--yes", "Skip the confirmation prompt") { yes = true }
        opts.on("--dry-run", "List what would be removed; no prompt, nothing changes") { dry_run = true }
        opts.on("--json", "Print one action document (see docs/README.json.md) instead of text, which goes",
          "to stderr; a refusal is the error envelope. --json does not imply --yes: pass --yes in scripts") { json = true }
        opts.separator ""
        opts.separator "Examples:"
        opts.separator "  workspace remove myproject --dry-run    # see which files would go"
        opts.separator "  workspace remove myproject    # ask, then remove"
        opts.separator "  workspace remove myproject --yes --json    # no prompt, one action document"
      end
      parser.parse!(args)
      raise UsageError, "workspace remove takes exactly one NAME.\n\n#{parser.help}" unless args.size == 1
      raise Error, "remove is not available: no remove command was wired" unless @remove_command

      name = args.first
      run_action("remove", json: json) do
        row = @remove_command.call(name, yes: yes, dry_run: dry_run)
        if !json
          {}
        elsif row
          {results: [action_row(name, row["outcome"], files: row["files"], backups: row["backups"], state_entry: row["state_entry"])], status: dry_run ? "dry_run" : nil}
        else
          {results: [action_row(name, "cancelled", reason: "declined", message: "Not confirmed; nothing was removed.")], status: "cancelled"}
        end
      end
    end

    def cmd_set_pane_command(args)
      pane_index = nil
      parser = OptionParser.new do |opts|
        opts.banner = "Usage: workspace set-command <project> <command> --pane <N>"
        opts.separator ""
        opts.separator "Set the shell command for a specific pane in a project's tmuxinator config."
        opts.separator ""
        opts.separator "Pane index N is 1-based. If N exceeds the number of existing panes,"
        opts.separator "you will be asked whether to append a new pane."
        opts.separator ""
        opts.separator "Options:"
        opts.on("--pane N", Integer, "Pane index (1-based)") do |n|
          pane_index = n
        end
        opts.separator ""
        opts.separator "Examples:"
        opts.separator "  workspace set-command myproject 'vim .' --pane 2    # replace the second pane's command"
        opts.separator "  workspace set-command scooter 'ascii-banner \"scooter\" --rainbow' --pane 1    # replace the banner pane"
        opts.separator "  workspace set-command myproject 'htop' --pane 4    # add a fourth pane (prompts if only 3 exist)"
      end
      parser.parse!(args)

      project = args.shift
      command = args.join(" ").strip

      raise UsageError, "No command provided.\n\n#{parser.help}" if command.empty?

      @update_pane_command.call(project: project, command: command, pane_index: pane_index)
    end

    def cmd_deactivate(args)
      all = false
      json = false
      parser = OptionParser.new do |opts|
        opts.banner = "Usage: workspace deactivate [options] [project]"
        opts.separator ""
        opts.separator "Deactivate Claude in a project's tmux pane by sending Ctrl-C."
        opts.separator "Auto-detects the project from the current directory if not specified."
        opts.separator ""
        opts.separator "Options:"
        opts.on("--all", "Deactivate Claude in all active projects") { all = true }
        opts.on("--json", "Print one action document (see docs/README.json.md) instead of text, which goes to stderr") { json = true }
        opts.separator ""
        opts.separator "Examples:"
        opts.separator "  workspace deactivate my-project    # deactivate Claude in a specific project"
        opts.separator "  workspace deactivate    # auto-detected from the current directory"
        opts.separator "  workspace deactivate --all    # deactivate Claude in all active projects"
      end
      parser.parse!(args)

      projects = resolve_claude_targets(args, all, parser)
      run_action("deactivate", json: json) do
        {results: claude_rows(@claude_command.deactivate(projects), json)}
      end
    end

    def cmd_reactivate(args)
      all = false
      json = false
      parser = OptionParser.new do |opts|
        opts.banner = "Usage: workspace reactivate [options] [project]"
        opts.separator ""
        opts.separator "Reactivate Claude in a project's tmux pane with 'claude --continue || claude'."
        opts.separator "Auto-detects the project from the current directory if not specified."
        opts.separator ""
        opts.separator "Options:"
        opts.on("--all", "Reactivate Claude in all active projects") { all = true }
        opts.on("--json", "Print one action document (see docs/README.json.md) instead of text, which goes to stderr") { json = true }
        opts.separator ""
        opts.separator "Examples:"
        opts.separator "  workspace reactivate my-project    # reactivate Claude in a specific project"
        opts.separator "  workspace reactivate    # auto-detected from the current directory"
        opts.separator "  workspace reactivate --all    # reactivate Claude in all active projects"
      end
      parser.parse!(args)

      projects = resolve_claude_targets(args, all, parser)
      run_action("reactivate", json: json) do
        {results: claude_rows(@claude_command.reactivate(projects), json)}
      end
    end

    # `results` rows from {Commands::Claude}'s per-project outcomes.
    def claude_rows(outcomes, json)
      return [] unless json
      outcomes.map { |project, o| action_row(project, o["outcome"], reason: o["reason"], message: o["message"]) }
    end

    # `workspace event-log show --json`'s schema version.
    EVENT_LOG_JSON_SCHEMA_VERSION = 1

    def cmd_events(args)
      options = {follow: false, json: false, types: [], since: nil}
      help = false
      parser = OptionParser.new do |opts|
        opts.banner = "Usage: workspace events [--follow] [--json] [--types A,B] [--since CURSOR]"
        opts.separator ""
        opts.separator "Read the event log (#{@config.event_log_file}) and every agent daemon's"
        opts.separator "hook events (#{@config.hook_events_dir}/<workspace>.jsonl) as one stream,"
        opts.separator "oldest first. Each line carries a cursor; pass it to --since to resume"
        opts.separator "after that line. Only files are read, so a slow reader never holds up a daemon."
        opts.separator ""
        opts.separator "Hook event types: #{HookEventLog::TYPES.join(", ")}."
        opts.separator "Stream lines: follow_started (first, with a cursor) and gap (the cursor is older"
        opts.separator "than what is kept; the lines after its time follow)."
        opts.separator ""
        opts.separator "Options:"
        opts.on("--follow", "Keep reading new lines until stopped (JSONL with --json)") { options[:follow] = true }
        opts.on("--json", "JSON: one line per event with --follow, else one {schema_version, ok, events, cursor} document") { options[:json] = true }
        opts.on("--types A,B", "Only these types (repeatable, or comma-separated)") do |value|
          options[:types].concat(value.split(",").map(&:strip).reject(&:empty?))
        end
        opts.on("--since CURSOR", "Resume after the line that printed CURSOR") { |value| options[:since] = value }
        opts.on("-h", "--help", "Show this help") { help = true }
        opts.separator ""
        opts.separator "Without --since, --follow starts at the end of every file, and a plain read prints"
        opts.separator "what is kept: the current event log and each daemon's file and its rotated copy."
        opts.separator ""
        opts.separator "Examples:"
        opts.separator "  workspace events --follow --json"
        opts.separator "  workspace events --follow --json --types tool_started,tool_finished --since \"$CURSOR\""
        opts.separator "  workspace events --types session_started,session_ended"
      end
      parser.parse!(args)
      return @output.puts(parser.help) if help
      raise UsageError, "Unexpected argument: #{args.first}\n\n#{parser.help}" unless args.empty?

      @events_command.call(**options)
    end

    def cmd_event_log(args)
      # The subcommand is the first non-option argument, so a leading flag
      # (e.g. `event-log --json show`) is dispatched correctly regardless of
      # where it appears.
      index = args.index { |a| !a.start_with?("-") }
      subcommand = index && args[index]
      rest = index ? args[0...index] + args[(index + 1)..] : args

      case subcommand
      when "show"
        cmd_event_log_show(rest)
      when "compact"
        event_log = @state.event_log
        before_size = event_log.size
        state = event_log.compact
        after_size = event_log.size
        @output.puts "Compacted event log: #{before_size} -> #{after_size} bytes (#{state.size} project(s))"
      when "help", "--help", "-h", nil
        @output.puts <<~HELP
          Usage: workspace event-log <subcommand>

          Subcommands:
            show       Print events, oldest first (--project, --type, --limit, --json)
            compact    Compact the event log to current state only
            help       Show this help

          Besides state changes, the log records agent activity: dispatches,
          stage completions, timeouts and failures, lock waits and takeovers,
          and each agent pane's working/idle/waiting changes. Compacting drops
          that history, keeping only each live pane's latest state.

          The event log is at: #{@config.event_log_file}

          Examples:
            workspace event-log show --project myapp --limit 20    # the last 20 events for one project
            workspace event-log compact    # compact the event log to current state only
        HELP
      else
        message = "Unknown event-log subcommand: #{subcommand}"
        return emit_json_usage_error(EVENT_LOG_JSON_SCHEMA_VERSION, message) if json_requested?(false, args)
        raise UsageError, message
      end
    end

    def cmd_event_log_show(args)
      json = false
      project = nil
      types = []
      limit = nil
      parser = OptionParser.new do |opts|
        opts.banner = "Usage: workspace event-log show [options]"
        opts.separator ""
        opts.separator "Print event log entries, oldest first."
        opts.separator ""
        opts.separator "Options:"
        opts.on("--project NAME", "Only events for this project") { |value| project = value }
        opts.on("--type TYPE", "Only events of this type (repeatable, or comma-separated)") do |value|
          types.concat(value.split(",").map(&:strip).reject(&:empty?))
        end
        opts.on("--limit N", Integer, "Only the last N matching events") { |value| limit = value }
        opts.on("--json", "Emit {schema_version, ok, events} instead of lines") { json = true }
      end
      raw_args = args.dup
      begin
        parser.parse!(args)
        raise UsageError, "--limit must be greater than 0." if limit && limit <= 0
        raise UsageError, "Unexpected argument: #{args.first}" unless args.empty?
      rescue OptionParser::ParseError, UsageError => e
        return emit_json_error(EVENT_LOG_JSON_SCHEMA_VERSION, e) if json_requested?(json, raw_args)
        raise UsageError, (e.is_a?(UsageError) ? e.message : "#{e.message}\n\n#{parser.help}")
      end

      events = @state.event_log.events
      warn_unseen_event_types(types, events)
      events = events.select { |event| event["project"] == project || event.dig("data", "workspace") == project } if project
      events = events.select { |event| types.include?(event["type"]) } unless types.empty?
      events = events.last(limit) if limit

      if json
        @output.puts JSON.generate({"schema_version" => EVENT_LOG_JSON_SCHEMA_VERSION, "ok" => true, "events" => events})
      else
        events.each { |event| @output.puts format_event(event) }
      end
    end

    # Event types aren't a closed set: a log can hold types from an older or
    # newer workspace, so a type no event has is warned about, not rejected.
    def warn_unseen_event_types(types, events)
      logged = events.map { |event| event["type"] }.uniq.sort
      unseen = types.uniq - logged
      return if unseen.empty?
      Warn.puts(@error_output, "Warning: no #{unseen.join(", ")} events in the event log " \
        "(types it has: #{logged.empty? ? "none" : logged.join(", ")})")
    end

    # One line per event. Logged text can come from a pane (a stage's
    # summary), so control characters are blanked before reaching a terminal.
    def format_event(event)
      data = event["data"].is_a?(Hash) ? event["data"] : {}
      details = data.filter_map { |key, value| "#{key}=#{format_event_value(value)}" unless value.nil? }
      [event["timestamp"], event["project"], event["type"], *details].join("  ").gsub(/[[:cntrl:]]+/, " ")
    end

    # A bare string is ambiguous with the "  " field separator and with "="
    # inside key=value pairs, so such values are quoted with String#inspect;
    # plain values (no space, no "=") stay bare for readability. Scripts
    # should use --json rather than parsing this format.
    def format_event_value(value)
      return JSON.generate(value) unless value.is_a?(String)
      (value.include?(" ") || value.include?("=")) ? value.inspect : value
    end

    def cmd_whereis(args)
      parser = OptionParser.new do |opts|
        opts.banner = "Usage: workspace whereis"
        opts.separator ""
        opts.separator "Print the workspace installation directory."
        opts.separator ""
        opts.separator "Example:"
        opts.separator "  workspace whereis    # print the directory workspace is installed in"
      end
      parser.parse!(args)

      @output.puts @config.workspace_dir
    end

    def cmd_lookup(args)
      parser = OptionParser.new do |opts|
        opts.banner = "Usage: workspace lookup <path|branch|project>"
        opts.separator ""
        opts.separator "Find a workspace project by worktree path, branch name, or project key."
        opts.separator ""
        opts.separator "Arguments:"
        opts.separator "  /path/to/.worktrees/pr-21291   Worktree directory path"
        opts.separator "  pr-21291                       Branch name or project key"
        opts.separator "  AIKYA-389-skip-validation      Full branch name"
        opts.separator ""
        opts.separator "Returns the workspace project name if found, or exits with status 1 if not found."
        opts.separator ""
        opts.separator "Examples:"
        opts.separator "  workspace lookup ~/Code/zendesk/growth-engine/.worktrees/growth-engine-kick-test    # by worktree path"
        opts.separator "  workspace lookup PUFFINS-1876-use-lock-version    # by branch name"
        opts.separator "  workspace lookup growth-engine    # by project name"
        opts.separator "  workspace lookup ~/Documents/Obsidian-LocalOnly/Zendesk    # by project root directory"
      end
      parser.parse!(args)

      raise UsageError, parser.help if args.empty?

      query = args.first
      project = @lookup_command.call(query)

      if project
        @output.puts project
      else
        raise Workspace::Error, "No workspace project found for '#{query}'"
      end
    end

    def cmd_projects(args)
      # The subcommand is the first non-option argument, so a leading flag
      # (e.g. `projects --json`) still reaches the default `list`.
      index = args.index { |a| !a.start_with?("-") }
      subcommand = index && args[index]
      rest = index ? args[0...index] + args[(index + 1)..] : args

      case subcommand
      when "list", nil
        if rest.include?("--help") || rest.include?("-h")
          @output.puts projects_help
        else
          cmd_projects_list(rest)
        end
      when "show"
        if rest.include?("--help") || rest.include?("-h")
          @output.puts projects_show_parser({}).help
        else
          cmd_projects_show(rest)
        end
      when "members"
        if rest.include?("--help") || rest.include?("-h")
          @output.puts projects_members_parser({}).help
        else
          cmd_projects_members(rest)
        end
      when "stop"
        if rest.include?("--help") || rest.include?("-h")
          @output.puts projects_stop_parser({}).help
        else
          cmd_projects_stop(rest)
        end
      when "kill"
        if rest.include?("--help") || rest.include?("-h")
          @output.puts projects_kill_parser({}).help
        else
          cmd_projects_kill(rest)
        end
      when "group"
        cmd_projects_group(rest)
      when "help" then @output.puts projects_help
      else
        raise UsageError, "Unknown projects subcommand: #{subcommand}. Run 'workspace projects --help'."
      end
    rescue OptionParser::ParseError, UsageError => e
      raise unless json_requested?(false, args)
      emit_json_error(Commands::Projects::JSON_SCHEMA_VERSION, e, message: e.message.lines.first.strip)
    end

    def projects_help
      <<~HELP
        Usage: workspace projects [list [--running] | show [NAME|PATH] | members [NAME|PATH] | stop [NAME|PATH] [--dry-run]
                                  | group create NAME | group add GROUP PATH | group list | group show GROUP
                                  | kill NAME|PATH [--dry-run] [--yes] [--force] [--discard-unsaved] [--timeout DURATION]] [--json]

        Group workspaces by repository.

        A project is a repository's main checkout plus its linked git worktrees.
        Each member that has a tmuxinator config is a workspace. Other commands that
        take a [project] argument (launch, stop, sessions, pipeline...) and
        `list-projects` operate on single workspaces.

        Subcommands:
          list              One row per project: its workspaces and how many are running (default)
          show [NAME|PATH]  One project in detail: each workspace's running state, agent states, open
                            asks and pipeline entries, plus the repo-wide locks and dev environment.
                            NAME is a project name, a member workspace name or a path; it
                            defaults to the project containing the current directory.
          members [NAME|PATH]
                            The project's workspaces, one name per line, main checkout first, for
                            scripts: workspace projects members | while read -r ws; do ...; done
                            Same NAME rules as show. Runs no git unless --all is given.

        Actions:
          stop [NAME|PATH]  Stop every running workspace of the project (main checkout and worktrees).
                            No prompt and no unsaved-work check, like 'workspace stop'. The session you
                            run it from is stopped last. Same NAME rules as show.
          kill NAME|PATH    Remove every worktree workspace of the project (session, worktree, config,
                            state), never the main checkout. Checks every worktree first and removes
                            nothing if any has unsaved work, can't be checked, is gone, or runs the dev
                            env. Asks first; NAME is required. See 'workspace projects kill --help'.

          group create|add|list|show
                            Named groups of repositories (ids like group:billing), kept in
                            ~/.config/workspace/groups/. A repository is in at most one group.
                            See 'workspace projects group --help'. stop, kill, show and members refuse a group id.

        Options:
          --dry-run   stop, kill: show what would happen and change nothing
          --yes       kill only: don't ask for confirmation (required with --json or without a terminal)
          --force     kill only: let worktrees whose checkout is gone or that git can't check through
                      preflight (the last-moment unsaved-work re-check still applies)
          --discard-unsaved
                      kill only: remove worktrees that have unsaved work, losing it
          --running   list only: projects with at least one running workspace
          --path      members only: print checkout paths instead of workspace names (not with --json)
          --all       members only: also list worktrees that have no workspace config (runs git)
          --git       list only: add an UNSAVED column (runs git in every checkout)
          --json      Print schema-versioned JSON (see docs/README.projects.md)
          --no-agents show only: skip the agent daemons (no sockets are read)
          --no-git    show only: skip git (no branch or unsaved work, no unconfigured worktrees)
          --timeout SECONDS
                      show: how long to wait for each agent daemon (default 1) and for all
                      the git reads (default 5); members --all: for the worktree listing;
                      kill: for all the unsaved-work checks (a duration, e.g. 30s; default 5s)

        A workspace joins the project whose repository its directory belongs to. If that
        directory is gone, it is matched by config name. The note after a path flags a
        project with no git repo, a missing checkout, or a name shared with another project.

        Examples:
          workspace projects                # same as 'workspace projects list'
          workspace projects --running      # projects with something running
          workspace projects --json         # for a script
          workspace projects show           # the project for the current directory
          workspace projects show app --json
          workspace projects members        # one workspace per line
          workspace projects stop app --dry-run
          workspace projects kill app --dry-run
      HELP
    end

    def projects_show_parser(options)
      OptionParser.new do |opts|
        opts.banner = "Usage: workspace projects show [NAME|PATH] [--json] [--no-agents] [--no-git] [--timeout SECONDS]"
        opts.separator ""
        opts.separator "Show one project: its workspaces (running, headless, agent states, open asks, pipeline entries,"
        opts.separator "branch and unsaved work), worktrees with no workspace config, the repo-wide locks and the"
        opts.separator "dev environment. NAME is a project name, a member"
        opts.separator "workspace name or a path (use a path when two projects share a name); it defaults"
        opts.separator "to the project containing the current directory."
        opts.separator ""
        opts.on("--json", "Print schema-versioned JSON (see docs/README.projects.md)") { options[:json] = true }
        opts.on("--no-agents", "Don't ask the agent daemons for agent states") { options[:agents] = false }
        opts.on("--no-git", "Don't run git (no branch or unsaved work, no unconfigured worktrees)") { options[:git] = false }
        opts.on("--timeout SECONDS", Float, "Seconds to wait for each running workspace's agent daemon (default 1) and for all the git reads (default 5)") { |seconds| options[:timeout] = seconds }
        opts.separator ""
        opts.separator "A daemon that is down or doesn't answer in time shows as unavailable, and a checkout git can't answer for"
        opts.separator "shows as unknown (treated as unsaved); the command still exits 0."
        opts.separator ""
        opts.separator "Examples:"
        opts.separator "  workspace projects show"
        opts.separator "  workspace projects show app --json"
        opts.separator "  workspace projects show ~/src/app"
        opts.separator "  workspace projects show --no-agents    # skip the agent daemons"
        opts.separator "  workspace projects show --no-git       # skip git (fastest)"
        opts.separator "  workspace projects show --timeout 0.5"
      end
    end

    def cmd_projects_show(args)
      options = {json: false, agents: true, git: true, timeout: nil}
      projects_show_parser(options).parse!(args)
      validate_projects_timeout(options[:timeout])
      raise UsageError, "Unexpected argument: #{args[1]}. Run 'workspace projects show --help'." if args.size > 1
      raise Error, "projects is not available: no projects command was wired" unless @projects_command

      result = @projects_command.show(name: args.first, json: options[:json], agents: options[:agents], git: options[:git], timeout: options[:timeout])
      @exit_handler.exit(result[:exit_code]) unless result[:exit_code].zero?
    end

    def validate_projects_timeout(timeout)
      return if timeout.nil? || (timeout.finite? && timeout.positive?)
      raise UsageError, "--timeout must be a finite number greater than 0."
    end

    def projects_members_parser(options)
      OptionParser.new do |opts|
        opts.banner = "Usage: workspace projects members [NAME|PATH] [--path] [--all] [--timeout SECONDS] [--json]"
        opts.separator ""
        opts.separator "List a project's member workspaces, one per line, main checkout first. NAME is a project"
        opts.separator "name, a member workspace name or a path (use a path when two projects share a name);"
        opts.separator "it defaults to the project containing the current directory."
        opts.separator ""
        opts.on("--path", "Print each checkout's path instead of its workspace name (not with --json)") { options[:path] = true }
        opts.on("--all", "Also list worktrees that have no workspace config, shown only with --path or --json (runs git)") { options[:all] = true }
        opts.on("--timeout SECONDS", Float, "Seconds to wait for the worktree listing under --all (default 5)") { |seconds| options[:timeout] = seconds }
        opts.on("--json", "Print schema-versioned JSON (see docs/README.projects.md)") { options[:json] = true }
        opts.separator ""
        opts.separator "Without --all no git runs. Members whose checkout is gone are still listed. Names only: with --all"
        opts.separator "the unconfigured worktrees are omitted (a note goes to stderr) unless --path or --json is given."
        opts.separator "An empty result prints a note to stderr and nothing to stdout, so loop over the output"
        opts.separator "(for/while read -r) rather than pass it unquoted to a command that acts on every workspace"
        opts.separator "when given no argument."
        opts.separator ""
        opts.separator "Examples:"
        opts.separator "  workspace projects members"
        opts.separator "  for ws in $(workspace projects members app); do workspace stop \"$ws\"; done"
        opts.separator "  workspace projects members app | while read -r ws; do workspace stop \"$ws\"; done"
        opts.separator "  workspace projects members --path"
        opts.separator "  workspace projects members --all --json"
      end
    end

    def cmd_projects_members(args)
      options = {json: false, path: false, all: false, timeout: nil}
      projects_members_parser(options).parse!(args)
      validate_projects_timeout(options[:timeout])
      raise UsageError, "Unexpected argument: #{args[1]}. Run 'workspace projects members --help'." if args.size > 1
      raise UsageError, "--path and --json cannot be used together." if options[:path] && options[:json]
      raise Error, "projects is not available: no projects command was wired" unless @projects_command

      result = @projects_command.members(name: args.first, path: options[:path], all: options[:all], json: options[:json], timeout: options[:timeout])
      @exit_handler.exit(result[:exit_code]) unless result[:exit_code].zero?
    end

    def projects_stop_parser(options)
      OptionParser.new do |opts|
        opts.banner = "Usage: workspace projects stop [NAME|PATH] [--dry-run] [--json]"
        opts.separator ""
        opts.separator "Stop every running workspace of a project (its main checkout and worktrees) and their tmux"
        opts.separator "sessions in one step. NAME is a project name, a member workspace name or a path (use a path"
        opts.separator "when two projects share a name); it defaults to the project containing the current directory."
        opts.separator ""
        opts.on("--dry-run", "List the workspaces that would be stopped and stop nothing") { options[:dry_run] = true }
        opts.on("--json", "Print one schema-versioned result object (see docs/README.projects.md)") { options[:json] = true }
        opts.separator ""
        opts.separator "There is no prompt and no unsaved-work check, like 'workspace stop'. If you run this from inside"
        opts.separator "one of the project's sessions, that session is stopped last, after the result is printed."
        opts.separator "Exit status: 0 stopped or nothing running, 3 some stopped and some failed, 1 nothing stopped or"
        opts.separator "a usage error."
        opts.separator ""
        opts.separator "Examples:"
        opts.separator "  workspace projects stop                # the project for the current directory"
        opts.separator "  workspace projects stop app --dry-run"
        opts.separator "  workspace projects stop ~/src/app --json"
      end
    end

    def cmd_projects_stop(args)
      options = {json: false, dry_run: false}
      projects_stop_parser(options).parse!(args)
      raise UsageError, "Unexpected argument: #{args[1]}. Run 'workspace projects stop --help'." if args.size > 1
      raise Error, "projects stop is not available: no project actions command was wired" unless @project_actions_command

      result = @project_actions_command.stop(name: args.first, dry_run: options[:dry_run], json: options[:json])
      @exit_handler.exit(result[:exit_code]) unless result[:exit_code].zero?
    end

    def projects_kill_parser(options)
      OptionParser.new do |opts|
        opts.banner = "Usage: workspace projects kill NAME|PATH [--dry-run] [--yes] [--force] [--discard-unsaved] [--timeout DURATION] [--json]"
        opts.separator ""
        opts.separator "Remove every worktree workspace of a project in one step, each the way 'workspace kill' does"
        opts.separator "(tmux session, git worktree, tmuxinator config, project settings, state entry). The main"
        opts.separator "checkout is never removed, and worktrees with no workspace config are not touched. NAME is"
        opts.separator "required: a project name, a member workspace name or a path."
        opts.separator ""
        opts.on("--dry-run", "Run the checks and show what would be removed; remove nothing") { options[:dry_run] = true }
        opts.on("--yes", "Don't ask for confirmation (every check still runs)") { options[:yes] = true }
        opts.on("--force", "Let worktrees whose checkout is gone or that git can't check past preflight (kill still re-checks for unsaved work, so an unknown one can fail)") { options[:force] = true }
        opts.on("--discard-unsaved", "Also remove worktrees that have unsaved work, losing it") { options[:discard_unsaved] = true }
        opts.on("--timeout DURATION", "Time all the unsaved-work checks may take together, e.g. 10 or 30s (default 5s);",
          "a worktree not checked in time can't be checked") { |value| options[:timeout] = parse_duration_option("--timeout", value, positive: true) }
        opts.on("--json", "Print one schema-versioned result object (see docs/README.projects.md); needs --yes or --dry-run") { options[:json] = true }
        opts.separator ""
        opts.separator "Every worktree is checked before anything is removed. If any has unsaved work (uncommitted"
        opts.separator "changes to tracked files or unpushed commits), can't be checked, has a checkout that is gone,"
        opts.separator "or is running the dev environment, nothing is removed and each problem is listed. --force"
        opts.separator "overrides only a gone checkout or a failed check; unsaved work needs --discard-unsaved. A"
        opts.separator "running dev environment is never overridden: run 'workspace dev down' first."
        opts.separator ""
        opts.separator "--force does not skip the prompt; --yes does. Without a terminal, or with --json, pass --yes"
        opts.separator "(or --dry-run). If you run this from one of the worktrees, it is removed last."
        opts.separator "Exit status: 0 removed, nothing to remove, cancelled or a dry run that would proceed;"
        opts.separator "1 refused, nothing removed, or a usage error; 3 some removed and some failed."
        opts.separator ""
        opts.separator "Examples:"
        opts.separator "  workspace projects kill app --dry-run"
        opts.separator "  workspace projects kill app"
        opts.separator "  workspace projects kill app --yes --json"
        opts.separator "  workspace projects kill ~/src/app --force --yes"
      end
    end

    def cmd_projects_kill(args)
      options = {json: false, dry_run: false, yes: false, force: false, discard_unsaved: false, timeout: Commands::ProjectActions::DEFAULT_GIT_TIMEOUT}
      projects_kill_parser(options).parse!(args)
      raise UsageError, "projects kill needs a project NAME or PATH. Run 'workspace projects kill --help'." if args.empty?
      raise UsageError, "Unexpected argument: #{args[1]}. Run 'workspace projects kill --help'." if args.size > 1
      unless options[:yes] || options[:dry_run]
        Prompt.refuse_if_no_input!(@input, "Remove the worktrees of '#{args.first}' and kill their sessions?", retry_flags: ["--yes"], destructive: true)
        raise UsageError, "projects kill --json never prompts: pass --yes to remove, or --dry-run to preview." if options[:json]
        unless @input.respond_to?(:tty?) && @input.tty?
          raise UsageError, "projects kill can't ask for confirmation without a terminal: pass --yes (or --dry-run)."
        end
      end
      raise Error, "projects kill is not available: no project actions command was wired" unless @project_actions_command

      result = @project_actions_command.kill(name: args.first, dry_run: options[:dry_run], yes: options[:yes], force: options[:force],
        discard_unsaved: options[:discard_unsaved], json: options[:json], git_timeout: options[:timeout])
      @exit_handler.exit(result[:exit_code]) unless result[:exit_code].zero?
    end

    def projects_group_help
      <<~HELP
        Usage: workspace projects group create NAME [--json]
               workspace projects group add GROUP PATH [--json]
               workspace projects group list [--json]
               workspace projects group show GROUP [--json] [--no-agents] [--no-git] [--timeout SECONDS]

        A group names several repositories that belong together. Its id is group:<slug>
        (the slug is NAME in lowercase with dashes). Each repository is kept by the
        realpath of its git common dir, so a moved checkout stays in its group. The group
        is a file at ~/.config/workspace/groups/<slug>.yml that you may edit by hand.

        Subcommands:
          create NAME       Make an empty group
          add GROUP PATH    Add the repository containing PATH (a main checkout or a worktree).
                            GROUP is an id, a slug or a name. A repository in another group is
                            refused; adding it again to the same group does nothing.
          list              Every group with its repositories (exists: false when one is gone).
                            A group file that can't be read is named in "warnings" (--json) or on stderr.
          show GROUP        Each repository as 'projects show' shows it

        Options:
          --json            Print schema-versioned JSON (see docs/README.projects.md)
          --no-agents, --no-git, --timeout SECONDS
                            For show: the same as 'projects show'

        Examples:
          workspace projects group create Billing
          workspace projects group add billing ~/src/api
          workspace projects group list --json
      HELP
    end

    def cmd_projects_group(args)
      sub = args.index { |a| !a.start_with?("-") }
      action = sub && args[sub]
      rest = sub ? args[0...sub] + args[(sub + 1)..] : args.dup
      if action.nil? || action == "help" || args.include?("--help") || args.include?("-h")
        @output.puts projects_group_help
        return
      end
      unless %w[create add list show].include?(action)
        raise UsageError, "Unknown projects group subcommand: #{action}. Run 'workspace projects group --help'."
      end
      json = false
      show_options = {agents: true, git: true, timeout: nil}
      OptionParser.new do |opts|
        opts.on("--json") { json = true }
        if action == "show"
          opts.on("--no-agents") { show_options[:agents] = false }
          opts.on("--no-git") { show_options[:git] = false }
          opts.on("--timeout SECONDS", Float) { |seconds| show_options[:timeout] = seconds }
        end
      end.parse!(rest)
      validate_projects_timeout(show_options[:timeout])
      raise Error, "projects group is not available: no groups command was wired" unless @groups_command

      arity = {"create" => 1, "add" => 2, "list" => 0, "show" => 1}.fetch(action)
      usage = {"create" => "NAME", "add" => "GROUP PATH", "list" => "", "show" => "GROUP"}.fetch(action)
      if rest.size < arity
        raise UsageError, "projects group #{action} needs #{usage}. Run 'workspace projects group --help'."
      elsif rest.size > arity
        raise UsageError, "Unexpected argument: #{rest[arity]}. Run 'workspace projects group --help'."
      end
      result = case action
      when "create" then @groups_command.create(name: rest[0], json: json)
      when "add" then @groups_command.add(group: rest[0], path: rest[1], json: json)
      when "show" then @groups_command.show(group: rest[0], json: json, **show_options)
      else @groups_command.list(json: json)
      end
      @exit_handler.exit(result[:exit_code]) unless result[:exit_code].zero?
    rescue OptionParser::ParseError, UsageError => e
      raise unless json_requested?(false, args)
      emit_json_error(Commands::Projects::JSON_SCHEMA_VERSION, e, message: e.message.lines.first.strip)
    end

    def cmd_projects_list(args)
      running = false
      json = false
      git = false
      parser = OptionParser.new do |opts|
        opts.banner = "Usage: workspace projects [list] [--running] [--git] [--json]"
        opts.separator ""
        opts.separator "List projects (a repository's main checkout plus its worktrees) and their workspaces."
        opts.separator ""
        opts.on("--running", "Only projects with at least one running workspace") { running = true }
        opts.on("--git", "Add an UNSAVED column (runs git in every checkout, and counts worktrees with no workspace config)") { git = true }
        opts.on("--json", "Print schema-versioned JSON (see docs/README.projects.md)") { json = true }
        opts.separator ""
        opts.separator "Examples:"
        opts.separator "  workspace projects list"
        opts.separator "  workspace projects list --running --json"
        opts.separator "  workspace projects list --git    # which projects have unsaved work"
      end
      parser.parse!(args)
      raise UsageError, "Unexpected argument: #{args.first}. Run 'workspace projects --help'." if args.any?
      raise Error, "projects is not available: no projects command was wired" unless @projects_command

      result = @projects_command.list(running_only: running, json: json, git: git)
      @exit_handler.exit(result[:exit_code]) unless result[:exit_code].zero?
    end

    def cmd_parent(args)
      path = false
      json = false
      envelope = false
      parser = OptionParser.new do |opts|
        opts.banner = "Usage: workspace parent [NAME] [--path] [--json | --json-envelope]"
        opts.separator ""
        opts.separator "Print the parent workspace of the current (or given) workspace."
        opts.separator "In a non-worktree workspace, prints its own name."
        opts.separator ""
        opts.on("--path", "Print the parent's root directory instead of its name") { path = true }
        opts.on("--json", "Print name, path, git_common_dir, is_worktree, worktree as JSON") { json = true }
        opts.on("--json-envelope", "Print the same under a \"parent\" key in the standard envelope (implies --json)") { json = envelope = true }
        opts.separator ""
        opts.separator "Examples:"
        opts.separator "  workspace parent    # the parent of the current directory's workspace"
        opts.separator "  workspace parent app.worktree-login    # the parent of a named workspace"
        opts.separator "  workspace parent --path    # the parent's root directory"
        opts.separator "  workspace parent --json    # name, path, git_common_dir, is_worktree, worktree"
      end
      parser.parse!(args)
      raise UsageError, "--path and --json cannot be used together." if path && json

      name = args.first
      @parent_command.call(name, path: path, json: json, envelope: envelope)
    end

    def notes_parser(options)
      OptionParser.new do |opts|
        opts.banner = "Usage: workspace notes dir [--name WORKSPACE] [--create] [--json]"
        opts.separator ""
        opts.separator "Notes are the working files an agent or a person keeps for a workspace (plans,"
        opts.separator "findings, handoffs), outside the source tree."
        opts.separator ""
        opts.separator "Print where a workspace's notes are kept: the absolute path alone, so"
        opts.separator "\"$(workspace notes dir)\" works. The workspace is the one detected from the"
        opts.separator "current directory unless --name picks another."
        opts.separator ""
        opts.separator "The path is the workspace's own notes.dir (a worktree's own, or the project's for"
        opts.separator "a main checkout), else the project's notes.default_dir rule, else"
        opts.separator "tmp/workspace-notes in the checkout. Nothing is written to config."
        opts.separator ""
        opts.on("--name NAME", "Workspace to answer for instead of the one detected from the current directory") { |v| options[:name] = v }
        opts.on("--create", "Make the directory; inside the checkout, also keep it out of git (info/exclude)") { options[:create] = true }
        opts.on("--json", "Print one JSON document (see docs/README.notes.md)") { options[:json] = true }
        opts.on("-h", "--help", "Show this help") { options[:help] = true }
        opts.separator ""
        opts.separator "Examples:"
        opts.separator "  workspace notes dir    # /src/api/.worktrees/x/tmp/workspace-notes"
        opts.separator "  cd \"$(workspace notes dir --create)\"    # make it, then go there"
        opts.separator "  workspace notes dir --name api.worktree-x --json"
      end
    end

    def cmd_notes(args)
      options = {json: false, create: false}
      parser = notes_parser(options)
      subcommand = args.shift if args.first == "dir"
      parser.parse!(args)
      subcommand ||= args.shift if args.first == "dir"
      return @output.puts(parser.help) if options[:help]

      unless subcommand
        raise UsageError, args.empty? ? "Missing subcommand: dir.\n\n#{parser.help}" : "Unknown notes subcommand: #{args.first}. Run 'workspace notes --help'."
      end
      raise UsageError, "Unexpected argument: #{args.first}. Run 'workspace notes --help'." if args.any?
      raise Error, "notes is not available: no notes command was wired" unless @notes_command

      name = options[:name] || @project_detector.detect(@working_dir)
      raise Error.new("No workspace found for #{@working_dir}. Run from inside a workspace or pass --name.", code: "not_in_workspace", details: {"path" => @working_dir}) unless name

      @notes_command.dir(name: name, create: options[:create], json: options[:json])
    end

    def ticket_parser(options)
      OptionParser.new do |opts|
        opts.banner = "Usage: workspace ticket show REF [--name WORKSPACE] [--json]\n       workspace ticket list [--assigned|--recent] [--source gh|jira] [--limit N] [--name WORKSPACE] [--json]"
        opts.separator ""
        opts.separator "show: read a ticket the way 'workspace start' reads its argument, and say whether a worktree for"
        opts.separator "it already exists. REF is a JIRA key or URL, a pull request URL or #n, a GitHub issue URL,"
        opts.separator "or a branch name. Title and body come from gh (pull requests and issues) or jira (JIRA keys);"
        opts.separator "a plain branch has none. Writes nothing, creates nothing, fetches nothing from git."
        opts.separator ""
        opts.separator "list: tickets to pick from, newest change first: open GitHub issues and pull requests (gh) and"
        opts.separator "JIRA issues (jira), assigned to you (the default) or changed lately. A tool that is missing, slow"
        opts.separator "or signed out is a warning, and the other still answers. Each row says whether a workspace exists."
        opts.separator ""
        opts.on("--name NAME", "Look in this workspace's project instead of the one detected from the current directory") { |v| options[:name] = v }
        opts.on("--assigned", "list: open tickets assigned to you (the default)") do
          raise UsageError, "Use --assigned or --recent, not both." if options[:filter] == "recent"
          options[:filter] = "assigned"
        end
        opts.on("--recent", "list: open tickets changed lately, whoever they are assigned to") do
          raise UsageError, "Use --assigned or --recent, not both." if options[:filter] == "assigned"
          options[:filter] = "recent"
        end
        opts.on("--source SOURCE", "list: ask only gh or jira (repeatable; default both)") { |v| (options[:sources] ||= []) << v }
        opts.on("--limit N", Integer, "list: at most N tickets, 1 to #{Workspace::Commands::Ticket::MAX_LIMIT} (default #{Workspace::Commands::Ticket::DEFAULT_LIMIT})") { |v| options[:limit] = v }
        opts.on("--json", "Print one JSON document (see docs/README.ticket.md)") { options[:json] = true }
        opts.on("-h", "--help", "Show this help") { options[:help] = true }
        opts.separator ""
        opts.separator "Examples:"
        opts.separator "  workspace ticket show PROJ-123"
        opts.separator "  workspace ticket show https://github.com/acme/api/pull/41 --json"
        opts.separator "  workspace ticket show feature/login --name api"
        opts.separator "  workspace ticket list --json    # what is assigned to me"
        opts.separator "  workspace ticket list --recent --source=gh --limit=10"
      end
    end

    def cmd_ticket(args)
      options = {json: false, name: nil}
      parser = ticket_parser(options)
      parser.parse!(args)
      return @output.puts(parser.help) if options[:help]

      subcommand = args.shift
      raise UsageError, "Missing subcommand: show or list.\n\n#{parser.help}" unless subcommand
      raise UsageError, "Unknown ticket subcommand: #{subcommand}. Run 'workspace ticket --help'." unless %w[show list].include?(subcommand)
      if subcommand == "list"
        raise UsageError, "Unexpected argument: #{args.first}. Run 'workspace ticket --help'." if args.any?
        raise Error, "ticket is not available: no ticket command was wired" unless @ticket_command

        return @ticket_command.list(name: options[:name], filter: options[:filter] || "assigned", limit: options[:limit] || Workspace::Commands::Ticket::DEFAULT_LIMIT,
          sources: options[:sources] || [], json: options[:json])
      end
      list_only = {filter: "--assigned/--recent", sources: "--source", limit: "--limit"}.select { |key, _| options.key?(key) }.values
      raise UsageError, "#{list_only.first} applies to 'ticket list' only." if list_only.any?
      ref = args.shift
      raise UsageError, "Missing REF: a JIRA key or URL, a pull request or issue URL or #n, or a branch.\n\n#{parser.help}" unless ref
      raise UsageError, "Unexpected argument: #{args.first}. Run 'workspace ticket --help'." if args.any?
      raise Error, "ticket is not available: no ticket command was wired" unless @ticket_command

      @ticket_command.show(ref, name: options[:name], json: options[:json])
    end

    def spine_parser(options)
      OptionParser.new do |opts|
        opts.banner = "Usage: workspace spine show [WORKSPACE] [--name WORKSPACE] [--stage STAGE-PATH] [--body] [--evaluate] [--json]\n" \
                      "       workspace spine set [WORKSPACE] STAGE-PATH [--status VALUE] [--note TEXT] [--owner VALUE]\n" \
                      "                           [--if-revision REV] [--recursive] [--by LABEL] [--json]\n" \
                      "       workspace spine check [WORKSPACE] STAGE-PATH --item N [--item N ...] (--done | --undone)\n" \
                      "                             [--if-revision REV] [--by LABEL] [--json]\n" \
                      "       workspace spine verify [WORKSPACE] STAGE-PATH (--pass | --fail) --note TEXT [--by LABEL]\n" \
                      "                              [--if-revision REV] [--json]\n" \
                      "       workspace spine goal set [WORKSPACE] TEXT [--if-revision REV] [--by LABEL] [--json]\n" \
                      "       workspace spine start [WORKSPACE] STAGE-PATH [--pane PANE | --spawn KIND] [--play REF]\n" \
                      "                             [--if-revision REV] [--json]\n" \
                      "       workspace spine start [WORKSPACE] STAGE-PATH --fan-out [--spawn KIND] [--max N] [--json]"
        opts.separator ""
        opts.separator "show reads a workspace's stages: the stage files in spine/ of its notes directory, one"
        opts.separator "Markdown file per stage (10-research.md, 20-plan.md, ...), and sub-stages in a folder named"
        opts.separator "like a stage file without .md. Statuses are read as one of not_started, in_progress,"
        opts.separator "blocked, completed, skipped or unknown. A bad file is a warning in the answer, never an"
        opts.separator "error, and nothing is written, created or followed through a link."
        opts.separator ""
        opts.separator "set changes one stage's status, note or owner (give at least one). STAGE-PATH is the ids"
        opts.separator "joined with /, as show reports `path`, such as verify or implement/api. It rewrites only the"
        opts.separator "status, note, owner, updated and updated_by lines of the stage file and writes a spine_changed"
        opts.separator "event. Writers of a workspace take turns."
        opts.separator ""
        opts.separator "check ticks (--done) or unticks (--undone) items of a stage's '## Done when' checklist; N is the"
        opts.separator "item's 1-based position, as show lists them. Only the [ ] or [x] on that item's line changes, not"
        opts.separator "the frontmatter. An item already in the asked state is left alone. It writes a spine_changed event"
        opts.separator "with change done_when. Refuses an item that is not there (unknown_item)."
        opts.separator ""
        opts.separator "verify records a separate check of a completed stage: check (passed with --pass, failed with --fail),"
        opts.separator "checked_by, checked_at and check_note, and no other line. A stage opts in with a check: line in its file"
        opts.separator "(check: required); 'set --status completed' then makes it check: pending, and any other status resets it"
        opts.separator "to required. Refuses a stage that has not opted in (check_not_required) and one that is not completed"
        opts.separator "(stage_not_completed). It writes a spine_changed event with change check."
        opts.separator ""
        opts.separator "goal set writes title: in spine/goal.md (one line, at most 120 characters), keeping the rest of an"
        opts.separator "existing file, and makes the file (spine: 1, title, a '# TEXT' heading) when it is missing. Refuses"
        opts.separator "a workspace with no spine/ (no_spine). It writes a spine_changed event with change goal."
        opts.separator ""
        opts.separator "start gets an agent working on one stage: the pane named, a new one (--spawn), the stage's"
        opts.separator "owner when it is a live agent pane, else the main Claude Code or Codex pane; a workspace with"
        opts.separator "no session is launched. It first sets the stage in_progress with that pane as its owner, then"
        opts.separator "types the brief (the play, the spine pack, and the stage's path and file), then binds the pane."
        opts.separator "Refuses a stage that is completed or skipped (stage_done; not one whose check failed, which it reopens) or whose depends_on stages are not"
        opts.separator "(stage_waiting), and a pane that is busy (pane_busy)."
        opts.separator ""
        opts.separator "start --fan-out starts every sub-stage of STAGE-PATH (the folder named like its file) that is not"
        opts.separator "started and has no unmet depends_on, each in its own new pane (--spawn, default the main agent's"
        opts.separator "kind), at most --max (default 3); the rest are skipped. One result per sub-stage: spawned, refused"
        opts.separator "(with the code start would give, such as stage_waiting or stage_owned) or skipped. Exit status 1"
        opts.separator "only when nothing was spawned and something was refused. A stopped workspace (no_session), no"
        opts.separator "daemon (no_daemon) or a stage without sub-stages (no_substages) refuses the whole fan-out."
        opts.separator ""
        opts.separator "Other verb: init (create the folder from a template; run 'workspace spine init --help')."
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
        opts.separator "  workspace spine show    # the spine of the workspace you are in"
        opts.separator "  workspace spine show api.worktree-login --json"
        opts.separator "  workspace spine show --name=api.worktree-login --json"
        opts.separator "  workspace spine show --stage implement/api --body --json"
        opts.separator "  workspace spine show --evaluate --json    # state (incl. checking, check_failed), gate_results, disputes, checker and current for every stage"
        opts.separator "  workspace spine set verify --status in_progress"
        opts.separator "  workspace spine set verify --owner %6 --note \"waiting on CI\""
        opts.separator "  workspace spine set api.worktree-login review --status=completed --note=\"2 nits, fixed\" --json"
        opts.separator "  workspace spine set api.worktree-login implement --status completed --recursive --if-revision 9f8e7d6c"
        opts.separator "  workspace spine check verify --item 2 --done"
        opts.separator "  workspace spine check api.worktree-login implement/api --item 1 --item 3 --undone --if-revision 9f8e7d6c --json"
        opts.separator "  workspace spine verify relationships --pass --note \"74 commands classed, no gaps\""
        opts.separator "  workspace spine verify api.worktree-login verify --fail --note \"item 2 is not in the diff\" --by=\"claude %27\" --json"
        opts.separator "  workspace spine goal set \"Fix the OAuth refresh race\""
        opts.separator "  workspace spine start verify    # the stage's owner pane, else the main agent pane"
        opts.separator "  workspace spine start api.worktree-login implement/api --spawn codex --json"
        opts.separator "  workspace spine start research --pane %21 --play team-research"
        opts.separator "  workspace spine start implement --fan-out --max=2 --json    # one new agent per ready sub-stage"
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
    def cmd_spine_init(args)
      options = {json: false, name: nil, template: nil, dry_run: false}
      parser = spine_init_parser(options)
      parser.parse!(args)
      return @output.puts(parser.help) if options[:help]

      positional = settle_name(args.shift)
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

    def cmd_spine(args)
      index = spine_verb_index(args)
      if index && args[index] == "init"
        args.delete_at(index)
        return cmd_spine_init(args)
      end

      options = {json: false, name: nil}
      parser = spine_parser(options)
      parser.parse!(args)
      return @output.puts(parser.help) if options[:help]

      subcommand = args.shift
      raise UsageError, "Missing subcommand: show, set, check, verify, goal, start or init.\n\n#{parser.help}" unless subcommand
      raise UsageError, "Unknown spine subcommand: #{subcommand}. Run 'workspace spine --help'." unless %w[show set check start goal verify].include?(subcommand)
      if options[:pass] || options[:fail]
        raise UsageError, "--pass and --fail are for 'spine verify'. Run 'workspace spine --help'." unless subcommand == "verify"
      end
      return cmd_spine_verify(args, options, parser) if subcommand == "verify"
      return cmd_spine_goal(args, options, parser) if subcommand == "goal"
      return cmd_spine_check(args, options, parser) if subcommand == "check"
      if options[:items] || options[:check_done] || options[:check_undone]
        raise UsageError, "--item, --done and --undone are for 'spine check'. Run 'workspace spine --help'."
      end
      return cmd_spine_start(args, options, parser) if subcommand == "start"
      if options[:pane] || options[:spawn] || options[:play] || options[:fan_out] || options[:max]
        raise UsageError, "--pane, --spawn, --play, --fan-out and --max are for 'spine start'. Run 'workspace spine --help'."
      end
      return cmd_spine_set(args, options, parser) if subcommand == "set"

      positional = settle_name(args.shift)
      raise UsageError, "Unexpected argument: #{args.first}. Run 'workspace spine --help'." if args.any?
      if positional && options[:name] && positional != options[:name]
        raise UsageError, "Give the workspace once: '#{positional}' and --name #{options[:name]} differ."
      end
      raise Error, "spine is not available: no spine command was wired" unless @spine_command

      name = options[:name] || positional || @project_detector.detect(@working_dir)
      raise Error.new("No workspace found for #{@working_dir}. Run from inside a workspace or pass --name.", code: "not_in_workspace", details: {"path" => @working_dir}) unless name

      @spine_command.show(name: name, json: options[:json], stage: options[:stage], body: options[:body] || false, evaluate: options[:evaluate] || false)
    end

    def cmd_spine_set(args, options, parser)
      raise UsageError, "--stage, --body and --evaluate are for 'spine show'; 'spine set' takes the stage path as an argument." if options[:stage] || options[:body] || options[:evaluate]
      raise UsageError, "Give at least one of --status, --note and --owner.\n\n#{parser.help}" unless options[:status] || options[:note] || options[:owner]
      positional = (args.size > 1 && !options[:name]) ? settle_name(args.shift) : nil
      path = args.shift
      raise UsageError, "Missing STAGE-PATH, the stage's ids joined with / (as 'spine show' reports path).\n\n#{parser.help}" unless path
      raise UsageError, "Unexpected argument: #{args.first}. Run 'workspace spine --help'." if args.any?
      raise Error, "spine is not available: no spine command was wired" unless @spine_command

      name = options[:name] || positional || @project_detector.detect(@working_dir)
      raise Error.new("No workspace found for #{@working_dir}. Run from inside a workspace or pass --name.", code: "not_in_workspace", details: {"path" => @working_dir}) unless name

      @spine_command.set(name: name, path: path, status: options[:status], note: options[:note], owner: options[:owner], if_revision: options[:if_revision],
        recursive: options[:recursive] || false, by: options[:by], json: options[:json])
    end

    def cmd_spine_verify(args, options, parser)
      if options[:stage] || options[:body] || options[:evaluate] || options[:status] || options[:owner] || options[:recursive] || options[:pane] || options[:spawn] || options[:play] || options[:items] || options[:check_done] || options[:check_undone]
        raise UsageError, "spine verify takes --pass, --fail, --note, --by, --if-revision, --name and --json; the other options are for show, set, check and start."
      end
      raise UsageError, "Give only one of --pass and --fail." if options[:pass] && options[:fail]
      raise UsageError, "Give --pass or --fail." unless options[:pass] || options[:fail]
      raise UsageError, "Give --note TEXT: what was checked and what was found." if options[:note].to_s.strip.empty?
      positional = (args.size > 1 && !options[:name]) ? settle_name(args.shift) : nil
      path = args.shift
      raise UsageError, "Missing STAGE-PATH, the stage's ids joined with / (as 'spine show' reports path).\n\n#{parser.help}" unless path
      raise UsageError, "Unexpected argument: #{args.first}. Run 'workspace spine --help'." if args.any?
      raise Error, "spine is not available: no spine command was wired" unless @spine_command

      name = options[:name] || positional || @project_detector.detect(@working_dir)
      raise Error.new("No workspace found for #{@working_dir}. Run from inside a workspace or pass --name.", code: "not_in_workspace", details: {"path" => @working_dir}) unless name

      @spine_command.verify(name: name, path: path, verdict: options[:pass] ? "passed" : "failed", note: options[:note],
        by: options[:by], if_revision: options[:if_revision], json: options[:json])
    end

    def cmd_spine_goal(args, options, parser)
      if options[:stage] || options[:body] || options[:evaluate] || options[:status] || options[:note] || options[:owner] || options[:recursive] || options[:pane] || options[:spawn] || options[:play] || options[:items] || options[:check_done] || options[:check_undone]
        raise UsageError, "spine goal set takes --if-revision, --by, --name and --json; the other options are for show, set, check and start."
      end
      verb = args.shift
      raise UsageError, "Missing goal subcommand. Use 'workspace spine goal set TEXT'." unless verb
      raise UsageError, "Unknown spine goal subcommand: #{verb}. Use 'workspace spine goal set TEXT'." unless verb == "set"
      positional = (args.size > 1 && !options[:name]) ? settle_name(args.shift) : nil
      text = args.shift
      raise UsageError, "Missing TEXT, the goal as one line.\n\n#{parser.help}" unless text
      raise UsageError, "Unexpected argument: #{args.first}. Quote TEXT if it has spaces, and put -- before text that starts with a dash. Run 'workspace spine --help'." if args.any?
      raise Error, "spine is not available: no spine command was wired" unless @spine_command

      name = options[:name] || positional || @project_detector.detect(@working_dir)
      raise Error.new("No workspace found for #{@working_dir}. Run from inside a workspace or pass --name.", code: "not_in_workspace", details: {"path" => @working_dir}) unless name

      @spine_command.goal_set(name: name, text: text, if_revision: options[:if_revision], by: options[:by], json: options[:json])
    end

    def cmd_spine_check(args, options, parser)
      if options[:stage] || options[:body] || options[:evaluate] || options[:status] || options[:note] || options[:owner] || options[:recursive] || options[:pane] || options[:spawn] || options[:play]
        raise UsageError, "spine check takes --item, --done, --undone, --if-revision, --by and --json; the other options are for show, set and start."
      end
      raise UsageError, "Give at least one --item N." if options[:items].to_a.empty?
      raise UsageError, "--item takes a positive number." unless options[:items].all?(&:positive?)
      raise UsageError, "Give only one of --done and --undone." if options[:check_done] && options[:check_undone]
      raise UsageError, "Give --done or --undone." unless options[:check_done] || options[:check_undone]
      positional = (args.size > 1 && !options[:name]) ? settle_name(args.shift) : nil
      path = args.shift
      raise UsageError, "Missing STAGE-PATH, the stage's ids joined with / (as 'spine show' reports path).\n\n#{parser.help}" unless path
      raise UsageError, "Unexpected argument: #{args.first}. Run 'workspace spine --help'." if args.any?
      raise Error, "spine is not available: no spine command was wired" unless @spine_command

      name = options[:name] || positional || @project_detector.detect(@working_dir)
      raise Error.new("No workspace found for #{@working_dir}. Run from inside a workspace or pass --name.", code: "not_in_workspace", details: {"path" => @working_dir}) unless name

      @spine_command.check(name: name, path: path, items: options[:items], done: options[:check_done] ? true : false,
        if_revision: options[:if_revision], by: options[:by], json: options[:json])
    end

    def cmd_spine_start(args, options, parser)
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
      positional = (args.size > 1 && !options[:name]) ? settle_name(args.shift) : nil
      path = args.shift
      raise UsageError, "Missing STAGE-PATH, the stage's ids joined with / (as 'spine show' reports path).\n\n#{parser.help}" unless path
      raise UsageError, "Unexpected argument: #{args.first}. Run 'workspace spine --help'." if args.any?
      raise Error, "spine start is not available: no spine start command was wired" unless @spine_start_command

      name = options[:name] || positional || @project_detector.detect(@working_dir)
      raise Error.new("No workspace found for #{@working_dir}. Run from inside a workspace or pass --name.", code: "not_in_workspace", details: {"path" => @working_dir}) unless name

      start = -> {
        next @spine_start_command.fan_out(name: name, path: path, spawn: options[:spawn], max: options[:max] || Commands::SpineStart::DEFAULT_FAN_OUT) if options[:fan_out]
        @spine_start_command.start(name: name, path: path, pane: options[:pane], spawn: options[:spawn], play: options[:play],
          if_revision: options[:if_revision], launch: spine_launcher)
      }
      doc = options[:json] ? divert_output(&start) : start.call
      if options[:json]
        @output.puts JSON.generate(doc)
      elsif !doc["ok"] && doc["results"]
        @error_output.puts "Error: nothing was spawned for the sub-stages of #{doc["path"]} of #{name}; every startable sub-stage was refused (#{doc["results"].filter_map { |entry| entry["code"] if entry["result"] == "refused" }.uniq.join(", ")})."
      elsif !doc["ok"]
        @error_output.puts "Error: could not start stage #{doc["path"]} of #{name}: #{doc["message"]}"
      end
      @exit_handler.exit(1) unless doc["ok"]
    end

    # What `spine start` uses to launch a workspace that has no session: `launch --play REF --prompt BRIEF`, with the
    # packs a launch sends (the spine pack among them). Returns `{ok:, reason:, message:, pane:}`.
    def spine_launcher
      lambda do |workspace, play, prompt|
        launched = launch_projects([workspace], play: play, prompt: prompt, with_packs: true)
        launched_pane(launched)
      end
    end

    def pr_parser(options)
      OptionParser.new do |opts|
        opts.banner = "Usage: workspace pr create [--name WORKSPACE] [--draft] [--json]"
        opts.separator ""
        opts.separator "Open a pull request for a workspace's branch and leave the workspace alone. When the"
        opts.separator "branch already has a pull request, it is returned and nothing else happens. Otherwise the"
        opts.separator "branch is pushed to origin if it has no upstream, and 'gh pr create --fill' runs. Refuses a"
        opts.separator "branch with no commits ahead of its base. Needs 'gh', logged in."
        opts.separator ""
        opts.on("--name NAME", "The workspace (default: the one the current directory is in)") { |v| options[:name] = v }
        opts.on("--draft", "Open the pull request as a draft") { options[:draft] = true }
        opts.on("--json", "Print one JSON document (see docs/README.pr.md)") { options[:json] = true }
        opts.on("-h", "--help", "Show this help") { options[:help] = true }
        opts.separator ""
        opts.separator "Examples:"
        opts.separator "  workspace pr create"
        opts.separator "  workspace pr create --draft --json"
        opts.separator "  workspace pr create --name api.worktree-PROJ-123"
      end
    end

    def cmd_pr(args)
      options = {json: false, name: nil, draft: false}
      parser = pr_parser(options)
      parser.parse!(args)
      return @output.puts(parser.help) if options[:help]

      subcommand = args.shift
      raise UsageError, "Missing subcommand: create.\n\n#{parser.help}" unless subcommand
      raise UsageError, "Unknown pr subcommand: #{subcommand}. Run 'workspace pr --help'." unless subcommand == "create"
      raise UsageError, "Unexpected argument: #{args.first}. Run 'workspace pr --help'." if args.any?
      raise Error, "pr is not available: no pr command was wired" unless @pull_request_command

      @pull_request_command.create(name: options[:name], draft: options[:draft], json: options[:json], working_dir: @working_dir)
    end

    def rebase_parser(options)
      OptionParser.new do |opts|
        opts.banner = "Usage: workspace rebase --onto local|update|remote|upstream [--name WORKSPACE] [--json]"
        opts.separator ""
        opts.separator "Rebase a workspace's branch onto the repository's default branch."
        opts.separator "  local    the local default branch; nothing is fetched"
        opts.separator "  update   fetch origin, move the local default branch up to origin's (stashing and"
        opts.separator "           restoring changes in the checkout that has it), then rebase onto it"
        opts.separator "  remote   fetch origin, rebase onto origin/<default>"
        opts.separator "  upstream fetch the branch's own upstream and rebase onto it; works on the default"
        opts.separator "           branch too (refused: no_upstream, upstream_gone)"
        opts.separator "Refuses a workspace with changes to tracked files and never stashes them. A rebase that"
        opts.separator "stops on a conflict is aborted, so the workspace is left as it was."
        opts.separator ""
        opts.on("--onto TARGET", "local, update, remote or upstream (required)") { |v| options[:onto] = v }
        opts.on("--name NAME", "The workspace (default: the one the current directory is in)") { |v| options[:name] = v }
        opts.on("--json", "Print one JSON document (see docs/README.rebase.md)") { options[:json] = true }
        opts.on("-h", "--help", "Show this help") { options[:help] = true }
        opts.separator ""
        opts.separator "Examples:"
        opts.separator "  workspace rebase --onto update"
        opts.separator "  workspace rebase --onto remote --name api.worktree-PROJ-123 --json"
      end
    end

    def cmd_rebase(args)
      options = {json: false, name: nil, onto: nil}
      parser = rebase_parser(options)
      parser.parse!(args)
      return @output.puts(parser.help) if options[:help]

      raise UsageError, "Unexpected argument: #{args.first}. Run 'workspace rebase --help'." if args.any?
      raise UsageError, "Missing --onto local|update|remote|upstream.\n\n#{parser.help}" unless options[:onto]
      raise Error, "rebase is not available: no rebase command was wired" unless @rebase_command

      @rebase_command.call(name: options[:name], onto: options[:onto], json: options[:json], working_dir: @working_dir)
    end

    def push_parser(options)
      OptionParser.new do |opts|
        opts.banner = "Usage: workspace push [--name WORKSPACE] [--json]"
        opts.separator ""
        opts.separator "Push a workspace's branch to origin. A branch with no upstream is pushed with -u. When the"
        opts.separator "upstream has commits the branch lacks, the push uses --force-with-lease, but only if the"
        opts.separator "branch's own history once held all of them (a rebase replaced them); otherwise it is refused."
        opts.separator ""
        opts.on("--name NAME", "The workspace (default: the one the current directory is in)") { |v| options[:name] = v }
        opts.on("--json", "Print one JSON document (see docs/README.rebase.md)") { options[:json] = true }
        opts.on("-h", "--help", "Show this help") { options[:help] = true }
        opts.separator ""
        opts.separator "Examples:"
        opts.separator "  workspace push"
        opts.separator "  workspace push --name api.worktree-PROJ-123 --json"
      end
    end

    def cmd_push(args)
      options = {json: false, name: nil}
      parser = push_parser(options)
      parser.parse!(args)
      return @output.puts(parser.help) if options[:help]

      raise UsageError, "Unexpected argument: #{args.first}. Run 'workspace push --help'." if args.any?
      raise Error, "push is not available: no push command was wired" unless @push_command

      @push_command.call(name: options[:name], json: options[:json], working_dir: @working_dir)
    end

    def promote_parser(options)
      OptionParser.new do |opts|
        opts.banner = "Usage: workspace promote [BRANCH] [--name PROJECT] [--title TEXT] [--spine[=TEMPLATE] | --no-spine] [--plan[=TITLE]]\n" \
          "                         [--carry-note FILE]... [--launch [--prompt TEXT] [--prompt-timeout DURATION]]\n" \
          "                         [--agent-kind KIND] [--[no-]headless] [--force] [--dry-run] [--json]"
        opts.separator ""
        opts.separator "Move the work in a main checkout into a new workspace: the staged, unstaged and untracked changes, and"
        opts.separator "the commits of the branch it is on, go to a worktree at .worktrees/BRANCH; the main checkout is left"
        opts.separator "clean on the default branch. Ignored files stay behind. The plan (IMPLEMENTATION_PLAN.md) and spine/"
        opts.separator "move to the new notes directory (the old ones are renamed .moved-<time>), and each --carry-note is copied."
        opts.separator "BRANCH omitted moves the current branch; on the default branch, name a new one (made at HEAD)."
        opts.separator "Nothing is launched unless --launch: seed the new workspace first, as the promote pack says"
        opts.separator "(workspace instructions compose --pack promote)."
        opts.separator ""
        opts.on("--name PROJECT", "The main checkout's workspace, from any directory (default: the working directory, which",
          "must be the top of a main checkout)") { |v| options[:name] = v }
        opts.on("--title TEXT", "The new workspace's task title") { |v| options[:title] = v }
        opts.on("--spine=[TEMPLATE]", "Make the spine (spine init) when none was carried; TEMPLATE as for start --spine") { |v| options[:spine] = v || true }
        opts.on("--no-spine", "Make no spine, even when spine.auto is true") { options[:no_spine] = true }
        opts.on("--plan=[TITLE]", "Make the plan (plan init) when none was carried") { |v| options[:plan] = v || true }
        opts.on("--carry-note FILE", "Copy a note (relative to the main notes directory) into the new one; repeatable;",
          "never over a file that is there") { |v| options[:carry_notes] << v }
        opts.on("--launch", "Launch the new workspace once it is made: with a plan, as plan start does; else with --prompt") { options[:launch] = true }
        opts.on("--prompt TEXT", "With --launch: text for the agent's first prompt") { |v| options[:prompt] = v }
        opts.on("--prompt-timeout DURATION", "With --launch: how long to wait for the agent (default #{AgentReadiness::DEFAULT_TIMEOUT}s)") do |v|
          options[:prompt_timeout] = parse_duration_option("--prompt-timeout", v, positive: true)
        end
        opts.on("--agent-kind KIND", "The new workspace's main agent: #{AgentProvider.all.map(&:key).join(", ")}") { |v| options[:agent_kind] = v }
        opts.on("--[no-]headless", "With --launch: start the session in plain tmux (see workspace launch --help)") { |v| options[:headless] = v }
        opts.on("--force", "Move even while an agent pane of the main checkout works or waits (the caller's own",
          "pane, $TMUX_PANE, never counts)") { options[:force] = true }
        opts.on("--dry-run", "Say what would move and write nothing; on the default branch BRANCH may be left out") { options[:dry_run] = true }
        opts.on("--json", "Print one JSON document; other output goes to stderr") { options[:json] = true }
        opts.on("-h", "--help", "Show this help") { options[:help] = true }
        opts.separator ""
        opts.separator "A failure part way is undone (move_failed); if undoing fails too, the changes are kept under"
        opts.separator "refs/workspace/promote/<id> and the error lists the git commands that get them back (move_incomplete)."
        opts.separator "Allow 60s without --launch, and --prompt-timeout plus 60s with it."
        opts.separator ""
        opts.separator "Examples:"
        opts.separator "  workspace promote fix-login --dry-run --json"
        opts.separator "  workspace promote fix-login --title \"Fix the login bug\" --spine --plan --carry-note research-login.md --json"
        opts.separator "  workspace promote --name api --launch"
      end
    end

    def cmd_promote(args)
      options = {carry_notes: [], json: false}
      parser = promote_parser(options)
      parser.parse!(args)
      return @output.puts(parser.help) if options[:help]

      raise UsageError, "Unexpected argument: #{args[1]}. Run 'workspace promote --help'." if args.size > 1
      raise UsageError, "--spine cannot be combined with --no-spine." if options[:spine] && options[:no_spine]
      %i[prompt prompt_timeout].each do |key|
        raise UsageError, "--#{key.to_s.tr("_", "-")} needs --launch." if options.key?(key) && !options[:launch]
      end
      raise Error, "promote is not available: no promote command was wired" unless @promote_command

      json = options[:json]
      headless = @launch_mode.resolve(options[:headless]).headless?
      launch = options[:launch] && promote_launcher(headless: options[:headless], prompt_timeout: options[:prompt_timeout])
      call = lambda do
        @promote_command.call(working_dir: @working_dir, branch: args.first, name: options[:name], title: options[:title],
          spine: options[:no_spine] ? false : options[:spine], plan: options[:plan], carry_notes: options[:carry_notes],
          launch: launch, prompt: options[:prompt], headless: headless, agent_kind: options[:agent_kind],
          force: options[:force] == true, dry_run: options[:dry_run] == true, json: json)
      end
      result = json ? divert_output(&call) : call.call
      @output.puts JSON.generate(result[:json]) if json
      @exit_handler.exit(result[:exit_code]) unless result[:exit_code].zero?
    rescue UsageError => e
      raise unless e.code == CheckoutMove::BRANCH_REQUIRED
      report_failure(e, json ? ["--json"] : [], e.message, exit_code: 2)
    end

    # What `promote --launch` launches the new workspace with: {#launch_projects} with the packs composed from
    # its own checkout (after the carry), a play and a prompt. Returns `{ok:, started:, reason:, message:, pane:, packs:}`.
    def promote_launcher(headless:, prompt_timeout:)
      lambda do |workspace, prompt:, play:|
        launched = launch_projects([workspace], play: play, prompt: prompt, prompt_timeout: prompt_timeout, headless: headless, with_packs: true)
        row = launch_rows(launched[:projects], launched[:result], plays: launched[:plays], packs: launched[:packs],
          skipped_packs: launched[:skipped_packs], prompts: launched[:prompts]).first
        {ok: row["outcome"] != "failed", started: !%w[session_not_started not_launched].include?(row["reason"]),
         reason: row["reason"], message: row["message"], pane: row.dig("play", "pane") || row["pane"], packs: row["packs"]}
      end
    end

    PLAN_FLAGS = {
      "status" => %i[name all file group json],
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

    def plan_parser(options)
      OptionParser.new do |opts|
        opts.banner = "Usage: workspace plan status [--name WORKSPACE | --all | --file PATH | --group GROUP] [--json]\n" \
          "       workspace plan path [--name WORKSPACE] [--json]\n" \
          "       workspace plan show [--name WORKSPACE]\n" \
          "       workspace plan init [--name WORKSPACE] [--title TITLE] [--from FILE] [--force] [--json]\n" \
          "       workspace plan start [--name WORKSPACE] [--task ID [--pane PANE | --spawn KIND]] [--json]\n" \
          "       workspace plan pause [--name WORKSPACE] [--interrupt] [--json]\n" \
          "       workspace plan delete [--name WORKSPACE] --yes [--json]\n" \
          "       workspace plan task add --title TEXT [--id ID] [--state STATE] [--reason TEXT] [--phase NAME | --after ID] [--if-revision REV] [--name WORKSPACE] [--json]\n" \
          "       workspace plan task set-state --task ID --state STATE [--reason TEXT] [--if-revision REV] [--name WORKSPACE] [--json]\n" \
          "       workspace plan task set-title --task ID --title TEXT [--if-revision REV] [--name WORKSPACE] [--json]\n" \
          "       workspace plan task move --task ID (--after ID | --before ID | --phase NAME) [--if-revision REV] [--name WORKSPACE] [--json]"
        opts.separator ""
        opts.separator "A plan is IMPLEMENTATION_PLAN.md in the workspace's notes directory: one checklist"
        opts.separator "line per task under '## Tasks'. workspace counts it, and works out one state from the"
        opts.separator "plan, the session and the pane that owns the plan."
        opts.separator ""
        opts.separator "Subcommands:"
        opts.separator "  status   Count the plan and report its state (a workspace with no plan is a row, not an error)"
        opts.separator "  path     Print where the plan is (or would be)"
        opts.separator "  show     Print the plan file"
        opts.separator "  init     Write a new plan, or import an existing document with --from"
        opts.separator "  start    Set status: active, then launch the workspace with the implementation-plan play, or send"
        opts.separator "           the main agent pane the play and \"Continue the plan.\" (a working pane is left alone)."
        opts.separator "           With --task, send that one task to --pane, a new agent pane (--spawn), the task's owner,"
        opts.separator "           or the main agent pane; the pane is written onto the task line as its owner"
        opts.separator "  pause    Set status: paused; the agent stops before its next task. --interrupt also presses"
        opts.separator "           the agent's interrupt key (Escape for Claude Code and Codex) in each owner pane that works"
        opts.separator "  delete   Rename the plan to IMPLEMENTATION_PLAN.md.deleted-<time>; needs --yes; the session and worktree stay"
        opts.separator "  task     add, set-state, set-title or move one task line; --if-revision (the revision from status --json) refuses a stale edit"
        opts.separator "           with stale_revision. States: #{PlanFile::TASK_STATES.join(", ")}; blocked and skipped need --reason"
        opts.separator ""
        opts.on("--name NAME", "Workspace to act on instead of the one detected from the current directory") { |v| take_plan_flag(options, :name, v) }
        opts.on("--all", "status: every workspace") { take_plan_flag(options, :all, true) }
        opts.on("--group GROUP", "status: every workspace of every repository in a group (group:billing, billing or Billing; see projects group list)") { |v| take_plan_flag(options, :group, v) }
        opts.on("--file PATH", "status: read any file, with no workspace and a state from the file alone") { |v| take_plan_flag(options, :file, v) }
        opts.on("--title TITLE", "init: the plan's title (default: the workspace task's title); task add: the task's title; task set-title: the new title") { |v| take_plan_flag(options, :title, v) }
        opts.on("--from FILE", "init: import this document as the plan") { |v| take_plan_flag(options, :from, v) }
        opts.on("--force", "init: replace a plan that is already there") { take_plan_flag(options, :force, true) }
        opts.on("--yes", "delete: confirm the delete") { take_plan_flag(options, :yes, true) }
        opts.on("--task ID", "start: send only this task; task set-state, set-title and move: the task (its id, such as T3)") { |v| take_plan_flag(options, :task, v) }
        opts.on("--id ID", "task add: the new task's id (default: the next number after the plan's last id)") { |v| take_plan_flag(options, :id, v) }
        opts.on("--state STATE", "task add and set-state: #{PlanFile::TASK_STATES.join(", ")}") { |v| take_plan_flag(options, :state, v) }
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
        opts.separator "  workspace plan status    # api.worktree-x  working  7/20 (40%)  T9 Add the token store"
        opts.separator "  workspace plan status --all --json"
        opts.separator "  workspace plan status --group billing --json"
        opts.separator "  workspace plan init --title \"Auth rewrite\""
        opts.separator "  workspace plan path    # /src/api/tmp/workspace-notes/IMPLEMENTATION_PLAN.md"
        opts.separator "  workspace plan start --name api.worktree-x --json"
        opts.separator "  workspace plan start --task=T4 --pane=%23 --json"
        opts.separator "  workspace plan start --task=T5 --spawn=claude"
        opts.separator "  workspace plan pause --interrupt --json"
        opts.separator "  workspace plan task add --title \"Write the docs\" --phase=Docs --if-revision=9f8e7d6c --json"
        opts.separator "  workspace plan task set-state --task=T3 --state=blocked --reason=\"needs the dev database\""
        opts.separator "  workspace plan task set-title --task=T3 --title=\"Write the token store docs\""
        opts.separator "  workspace plan task move --task=T5 --after=T1"
        opts.separator "  workspace plan delete --yes"
      end
    end

    def take_plan_flag(options, key, value)
      options[key] = value
      options[:given] << key
    end

    def cmd_plan(args)
      options = {given: [], json: false, force: false, yes: false}
      parser = plan_parser(options)
      parser.parse!(args)
      return @output.puts(parser.help) if options[:help]

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
      if subcommand == "status" && options[:given].count { |key| %i[name all file group].include?(key) } > 1
        raise UsageError, "Give only one of --name, --all, --file and --group."
      end
      raise UsageError, "Give only one of --pane and --spawn." if options[:pane] && options[:spawn]
      raise UsageError, "--pane and --spawn need --task. Run 'workspace plan --help'." if (options[:pane] || options[:spawn]) && !options[:task]
      if options[:spawn] && !Commands::PlanDispatch::AGENT_KINDS.include?(options[:spawn])
        raise UsageError, "Unknown agent kind for --spawn: #{options[:spawn]}. One of #{Commands::PlanDispatch::AGENT_KINDS.join(", ")}."
      end
      raise Error, "plan is not available: no plan command was wired" unless @plan_command && @plan_dispatch_command && @plan_task_command

      return @plan_command.status_group(group: options[:group], json: options[:json]) if options[:group]
      return @plan_command.status(all: true, json: options[:json]) if options[:all]
      return @plan_command.status(file: options[:file], json: options[:json]) if options[:file]

      name = options[:name] || @project_detector.detect(@working_dir)
      raise Error.new("No workspace found for #{@working_dir}. Run from inside a workspace or pass --name.", code: "not_in_workspace", details: {"path" => @working_dir}) unless name

      case subcommand
      when "status" then @plan_command.status(names: [name], json: options[:json])
      when "path" then @plan_command.path(name: name, json: options[:json])
      when "show" then @plan_command.show(name: name)
      when "init"
        run_action("plan init", json: options[:json]) do
          created = @plan_command.init(name: name, title: options[:title], from: options[:from], force: options[:force])
          {exit_code: 0, results: [action_row(name, "created", message: created["message"], path: created["path"])]}
        end
      when "start"
        run_action("plan start", json: options[:json]) do
          row = if options[:task]
            @plan_dispatch_command.start_task(name: name, task_id: options[:task], pane: options[:pane], spawn: options[:spawn], launch: plan_launcher)
          else
            @plan_dispatch_command.start(name: name, launch: plan_launcher)
          end
          plan_verb_outcome(name, row, options[:json])
        end
      when "pause"
        run_action("plan pause", json: options[:json]) do
          plan_verb_outcome(name, @plan_command.pause(name: name, interrupt: options.fetch(:interrupt, false)), options[:json])
        end
      when "delete"
        run_action("plan delete", json: options[:json]) { plan_verb_outcome(name, @plan_command.delete(name: name, yes: options[:yes]), options[:json]) }
      when "task"
        run_action("plan task #{verb}", json: options[:json]) { plan_verb_outcome(name, plan_task_row(verb, name, options), options[:json]) }
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
      if options[:state] && !PlanFile::TASK_STATES.include?(options[:state])
        raise UsageError, "Unknown task state: #{options[:state]}. One of #{PlanFile::TASK_STATES.join(", ")}."
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
    def plan_verb_outcome(name, row, json)
      failed = row["outcome"] == "failed"
      @error_output.puts "Error: could not start the plan for #{name}: #{row["message"]}" if failed && !json
      extra = row.slice("task", "interrupts", "state", "title", "previous_state", "line", "phase", "revision", "counts", "percent").transform_keys(&:to_sym)
      {exit_code: failed ? 1 : 0, warnings: row["warnings"] || [],
       results: [action_row(name, row["outcome"], reason: row["reason"], message: row["message"], path: row["path"], pane: row["pane"], **extra)]}
    end

    # What `plan start` uses to launch a workspace that has no session: `launch --play implementation-plan
    # --prompt "Continue the plan."` (or a task's prompt), with the packs a launch sends. Returns `{ok:, reason:, message:, pane:}`.
    def plan_launcher
      lambda do |workspace, prompt = Commands::PlanDispatch::CONTINUE_PROMPT|
        launched_pane(launch_projects([workspace], play: Commands::PlanDispatch::PLAY, prompt: prompt, with_packs: true))
      end
    end

    # The one launched workspace's row from {#launch_projects}, as `{ok:, reason:, message:, pane:}`.
    def launched_pane(launched)
      row = launch_rows(launched[:projects], launched[:result], plays: launched[:plays], packs: launched[:packs], skipped_packs: launched[:skipped_packs], prompts: launched[:prompts]).first
      pane = row.dig("play", "pane") || row["pane"]
      {ok: row["outcome"] != "failed", reason: row["reason"], message: row["message"], pane: pane}
    end

    def cmd_dir(args)
      parser = OptionParser.new do |opts|
        opts.banner = "Usage: workspace dir <project>"
        opts.separator ""
        opts.separator "Print the root directory of a workspace project."
        opts.separator ""
        opts.separator "Examples:"
        opts.separator "  workspace dir work-notes     # /Users/zdennis/Documents/Obsidian-LocalOnly/Zendesk"
        opts.separator "  workspace dir growth-engine  # /Users/zdennis/Code/zendesk/growth-engine"
      end
      parser.parse!(args)

      raise UsageError, parser.help if args.empty?

      project = args.first
      root = @project_config.project_root_for(project)

      unless root
        raise Workspace::Error, "Project '#{project}' not found or has no root directory configured"
      end

      @output.puts File.expand_path(root)
    end

    def cmd_alfred(args)
      subcommand = args.shift

      case subcommand
      when "install"
        alfred_install(args)
      when "uninstall"
        alfred_uninstall(args)
      when "info"
        alfred_info(args)
      when "help", "--help", "-h", nil
        alfred_help
      else
        raise UsageError, "Unknown alfred subcommand: #{subcommand}\n\n" + alfred_help_text
      end
    end

    def alfred_help
      @output.puts alfred_help_text
    end

    def alfred_help_text
      <<~HELP
        Usage: workspace alfred <subcommand>

        Subcommands:
          install     Install or update the Alfred workflow
          uninstall   Remove the Alfred workflow
          info        Show workflow installation status

        The workflow lets you type 'wf' in Alfred to list and focus
        active workspace projects. Assign a hotkey in Alfred Preferences
        > Workflows > Workspace Focus.

        Examples:
          workspace alfred install    # install or update the Alfred workflow
          workspace alfred info    # show the workflow's installation status
          workspace alfred uninstall    # remove the Alfred workflow
      HELP
    end

    def alfred_workflows_dir
      File.expand_path("~/Library/Application Support/Alfred/Alfred.alfredpreferences/workflows")
    end

    def alfred_source_dir
      File.join(@config.workspace_dir, "extensions", "alfred", "workspace-focus")
    end

    def find_installed_workflow
      dir = alfred_workflows_dir
      return nil unless File.directory?(dir)

      plist = Dir.glob(File.join(dir, "*/info.plist")).find do |p|
        File.read(p).include?("com.zdennis.workspace-focus")
      end
      plist ? File.dirname(plist) : nil
    end

    def alfred_install(args)
      parser = OptionParser.new do |opts|
        opts.banner = "Usage: workspace alfred install"
        opts.separator ""
        opts.separator "Install or update the Alfred workflow for workspace focus."
        opts.separator "Copies workflow files to Alfred's preferences directory."
      end
      parser.parse!(args)

      unless File.directory?(alfred_workflows_dir)
        raise Error, "Alfred workflows directory not found at #{alfred_workflows_dir}\nIs Alfred installed?"
      end

      unless File.directory?(alfred_source_dir)
        raise Error, "Alfred workflow source not found at #{alfred_source_dir}"
      end

      existing = find_installed_workflow
      if existing
        target_dir = existing
        @output.puts "Updating existing workflow..."
      else
        workflow_id = "user.workflow.#{SecureRandom.uuid.upcase}"
        target_dir = File.join(alfred_workflows_dir, workflow_id)
        FileUtils.mkdir_p(target_dir)
        @output.puts "Installing new workflow..."
      end

      %w[info.plist list_projects.rb focus_project.rb].each do |file|
        src = File.join(alfred_source_dir, file)
        dst = File.join(target_dir, file)
        FileUtils.cp(src, dst)
        FileUtils.chmod(0o755, dst) if file.end_with?(".rb")
      end

      @output.puts "Installed to #{target_dir}"
      @output.puts "Type 'wf' in Alfred to list active workspace projects."
    end

    def alfred_uninstall(args)
      parser = OptionParser.new do |opts|
        opts.banner = "Usage: workspace alfred uninstall"
        opts.separator ""
        opts.separator "Remove the Alfred workflow for workspace focus."
      end
      parser.parse!(args)

      target_dir = find_installed_workflow
      unless target_dir
        @output.puts "Workspace Focus workflow is not installed."
        return
      end

      answer = Prompt.ask(@input, @output, "Remove workflow from #{target_dir}? [y/N] ")&.strip
      unless answer&.match?(/\Ay(es)?\z/i)
        @output.puts "Cancelled."
        return
      end

      FileUtils.rm_rf(target_dir)
      @output.puts "Removed."
    end

    def alfred_info(args)
      parser = OptionParser.new do |opts|
        opts.banner = "Usage: workspace alfred info"
        opts.separator ""
        opts.separator "Show the installation status of the Alfred workflow."
      end
      parser.parse!(args)

      unless File.directory?(alfred_workflows_dir)
        @output.puts "Alfred is not installed."
        return
      end

      target_dir = find_installed_workflow
      if target_dir
        @output.puts "Workspace Focus workflow is installed."
        @output.puts "Location: #{target_dir}"
        @output.puts "Keyword: wf"
      else
        @output.puts "Workspace Focus workflow is not installed."
        @output.puts "Run 'workspace alfred install' to install it."
      end
    end
  end
end
