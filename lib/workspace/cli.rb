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
      init doctor launch start stop add add-project kill finish relaunch
      focus deactivate reactivate tile resize capture agent agentd lock dev parent projects
      capabilities daemon sessions review snapshot ask session-event agent-run handoff pipeline run library lib instructions
      run-and-report report-run-status layout config tmux statusline current
      list-projects list status repair cleanup prune set-command event-log
      whereis lookup dir alfred version help
    ].freeze

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
    # @param restart_agent_command [Workspace::Commands::RestartAgent, nil] pre-built
    #   `agent-run restart` command; optional so test builders need not wire it
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
    # @param projects_command [Workspace::Commands::Projects, nil] pre-built projects command
    # @param capabilities_command [Workspace::Commands::Capabilities, nil] pre-built capabilities command
    # @param daemon_command [Workspace::Commands::Daemon, nil] pre-built daemon command
    # @param ui_command [Workspace::Commands::Ui, nil] pre-built ui command
    # @param binding_command [Workspace::Commands::Binding, nil] pre-built binding command
    # @param library_command [Workspace::Commands::Library, nil] pre-built library command
    # @param library [Workspace::Library, nil] resolves `launch --play` per project
    # @param instructions_command [Workspace::Commands::Instructions, nil] pre-built instructions command
    # @param review_command [Workspace::Commands::Review, nil] pre-built review command
    # @param snapshot_command [Workspace::Commands::Snapshot, nil] pre-built snapshot command
    # @param config_report [Workspace::ConfigReport, nil] builds the `config show/validate --json` documents
    # @param tmuxinator_report [Workspace::TmuxinatorReport, nil] builds the `tmux show --json` document
    # @param project_actions_command [Workspace::Commands::ProjectActions, nil] pre-built project-wide actions command
    # @param clock [#call] returns the current Time, for relative deadline display
    # @param liveness [#call, nil] maps project names to true, false, or nil
    #   (alive, dead, can't tell) for `list --liveness` and `status`; nil
    #   reports every project as unknown
    # @param launch_mode [Workspace::LaunchMode, nil] decides whether launch/start
    #   run headless when no --[no-]headless flag is given; nil builds one
    def initialize(config:, state:, project_config:, git:, window_manager:, doctor:, project_settings:, hook_runner:, project_detector:, launch_command:, kill_command:, finish_command:, start_command:, stop_command:, focus_command:, tile_command:, layout_command:, resize_command:, init_command:, repair_command:, cleanup_command:, prune_command:, claude_command:, lookup_command:, update_pane_command:, run_command:, run_result_store:, run_and_report_command:, capture_command:, wait_until_content_command:, lock_command:, dev_command:, parent_command:, agent_command:, sessions_command:, session_event_command:, config_command:, statusline_command:, ask_command:, restart_agent_command: nil, send_command: nil, ensure_agent_command: nil, handoff_command: nil, projects_command: nil, capabilities_command: nil, daemon_command: nil, ui_command: nil, binding_command: nil, library_command: nil, library: nil, instructions_command: nil, review_command: nil, snapshot_command: nil, project_actions_command: nil, config_report: nil, tmuxinator_report: nil, exit_handler: Kernel, logger: Workspace::Logger.new, output: $stdout, error_output: $stderr, input: $stdin, working_dir: Dir.pwd, clock: -> { Time.now }, launch_mode: nil, liveness: nil)
      @config = config
      @state = state
      @project_config = project_config
      @git = git
      @window_manager = window_manager
      @doctor = doctor
      @project_settings = project_settings
      @hook_runner = hook_runner
      @project_detector = project_detector
      @sessions_command = sessions_command
      @session_event_command = session_event_command
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
      @agent_command = agent_command
      @config_command = config_command
      @statusline_command = statusline_command
      @ask_command = ask_command
      @restart_agent_command = restart_agent_command
      @send_command = send_command
      @ensure_agent_command = ensure_agent_command
      @handoff_command = handoff_command
      @projects_command = projects_command
      @capabilities_command = capabilities_command
      @daemon_command = daemon_command
      @ui_command = ui_command
      @binding_command = binding_command
      @library_command = library_command
      @library = library
      @instructions_command = instructions_command
      @review_command = review_command
      @snapshot_command = snapshot_command
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
      @liveness = liveness || ->(names) { names.to_h { |name| [name, nil] } }
    end

    # Parses the subcommand from argv and dispatches to the appropriate method.
    #
    # @param argv [Array<String>] command-line arguments
    # @return [void]
    def run(argv)
      args = argv.dup
      @logger.enable! if args.delete("--debug")
      @input.no_input! if take_no_input_flag!(args) && @input.respond_to?(:no_input!)
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
      when "review"
        cmd_review(args)
      when "snapshot"
        cmd_snapshot(args)
      when "ask"
        cmd_ask(args)
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
      when "set-command"
        cmd_set_pane_command(args)
      when "event-log"
        cmd_event_log(args)
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

    # The directory a per-workspace command acts from: the named workspace's
    # root for `--name`, else the detected working directory.
    #
    # @param name [String, nil] value of `--name`
    # @return [String]
    # @raise [Workspace::Error] code `unknown_workspace` when no such workspace exists
    def working_dir_for(name)
      return @working_dir unless name

      root = @project_config.project_root_for(name)
      raise Error.new("Unknown project '#{name}'", code: "unknown_workspace", details: {"name" => name}) unless root

      File.expand_path(root)
    end

    # Whether `--json` appears as its own argument before a bare `--`.
    #
    # @param argv [Array<String>]
    def json_flag?(argv)
      argv.take_while { |arg| arg != "--" }.include?("--json")
    end

    def resolve_claude_targets(args, all, parser)
      if all
        @state.load
        @state.keys
      else
        project = args.first || @project_detector.detect(@working_dir)
        raise UsageError, parser.help unless project
        [project]
      end
    end

    def main_help
      @output.puts <<~HELP
        Usage: workspace <subcommand> [options]

        Subcommands:
          add             Add a tmuxinator config for a project directory
          agent           Drive a workspace agent: agent run "prompt" (umbrella)
          agentd          Run the long-lived workspace agent daemon for a project
          agent-run       Send a message to a running agent, or type into a pane (command, inject, restart, send)
          alfred          Manage the Alfred workflow for workspace focus
          ask             Record a question an unattended agent hit, with its default
          binding         Bind a pane to a workflow run, a PR review or a play, so it survives /clear and compaction
          capabilities    Print what this CLI supports, as feature revisions (for scripts and the UI)
          capture         Print a tmux pane's scrollback buffer to stdout
          cleanup         Detect and remove zombie sessions from state
          config          Show, validate, set, get or unset project or global configuration
          current         Print the workspace project name for the current directory
          daemon          Show, restart or read the log of a workspace's agent daemon
          dev             Start, stop, or inspect this repo's dev environment (devenv lock)
          deactivate      Deactivate Claude in a project's tmux pane (sends Ctrl-C)
          dir             Print the root directory of a workspace project
          doctor          Check that all required dependencies are installed
          event-log       Show or compact the event log (state changes and agent activity)
          finish          Verify a worktree is clean and pushed, then remove it (optionally opens a PR)
          focus           Bring a project's iTerm window to the front (not for headless projects)
          handoff         Check context usage and hand off to a fresh conversation
          help            Show this help message
          init            Install tmuxinator templates and create config directory
          instructions    Print the instructions built from library packs (binding, orchestrator, commits, review)
          kill            Kill a worktree project and remove its worktree (auto-detects from cwd)
          launch          Launch tmuxinator projects in iTerm windows, or headless in plain tmux
          layout          Save/restore tmux pane layouts (auto-saved before resize)
          library         Store named plays, prompts, agents and skills, beside the built-in packs (alias: lib)
          list            List currently active (launched) projects (--all for all available)
          lock            Acquire, release, inspect, or clear a shared repo-wide lock
          lookup          Find a workspace project by worktree path, branch, or project name
          parent          Print the parent workspace of the current (or given) workspace
          pipeline        Inspect and drive a project's agent pipeline
          projects        Group workspaces by repository (main checkout + worktrees)
          prune           Remove worktree projects whose PR is closed or merged
          reactivate      Reactivate Claude in a project's tmux pane
          relaunch        Stop and relaunch all active workspace projects
          repair          Rebuild state from live iTerm windows
          resize          Resize tmux panes for a running project
          run             Send a shell command to a pane in a running project's tmux session
          run-and-report  Run a command as a subprocess, capture stdout/stderr/exit status
          report-run-status  Internal: write run result for --wait (called by shell wrapper)
          session-event   Forward one agent hook event to its daemon (installed by init)
          review          Show a workspace's finished work for review, or list the ones ready
          sessions        Show coding-agent sessions and sub-agents in a workspace
          snapshot        Print everything a UI polls (projects, panes, git, asks, locks, dev) as one JSON document
          start           Create a worktree and launch it (from JIRA key, PR URL or #n, or branch)
          status          Show detailed state of tracked launcher sessions
          set-command     Set the shell command for a pane in a project config (--pane <N>)
          statusline      Render Claude Code's status line (install as its statusLine command)
          stop            Stop active workspace projects and their tmux sessions
          tile            Tile all windows for a project across the screen
          tmux            Show a workspace's tmuxinator file as windows and panes (tmux show --json)
          ui              Open a workspace-ui:// link: a task, a review or the inbox
          wait-until-content  Block until a pane shows content, then exec a command
          whereis         Print the workspace installation directory

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
        opts.separator "Examples:"
        opts.separator "  workspace launch my-project    # launch one project by name"
        opts.separator "  workspace launch my-notes work-notes billing    # launch several projects"
        opts.separator "  workspace launch ~/Code/my-project    # launch from a directory path (creates a config)"
        opts.separator "  workspace launch --reattach my-project    # reuse the pane's existing tmux session"
        opts.separator "  workspace launch --prompt \"Review the README\" my-project    # send the agent an initial prompt"
        opts.separator "  workspace launch --play kickoff my-project    # point the agent at a library play"
      end
      parser.parse!(args)

      raise UsageError, parser.help if args.empty?

      run_action("launch", json: json) do
        launched = launch_projects(args, reattach: reattach, headless: headless, prompt: prompt, prompt_timeout: prompt_timeout, play: play)
        {exit_code: launched[:exit_code], results: json ? launch_rows(launched[:projects], launched[:result], plays: launched[:plays]) : []}
      end
    end

    # Launches the given project args (already parsed, no leading flags) and
    # returns `{exit_code:, projects:, result:, plays:}` (the project names,
    # Launch's own result, and each project's resolved play) without exiting
    # -- so callers with multiple batches to run (e.g. cmd_relaunch) can
    # attempt every batch before deciding whether to exit. A play is resolved
    # for every project before any config is created.
    def launch_projects(args, reattach: false, headless: nil, prompt: nil, prompt_timeout: nil, play: nil)
      resolved = args.map { |arg| @project_config.resolve_project_arg(arg) }
      plays = play ? resolved.to_h { |name, root| [name, resolve_play(play, root || @project_config.project_root_for(name))] } : {}
      projects = resolved.map { |name, root| root ? @project_config.create(name, root) : name }

      prompts = projects.each_with_object({}) do |p, h|
        text = plays[p] ? @library.play_prompt(plays[p], prompt) : prompt
        h[p] = text if text
      end

      call_options = {reattach: reattach, prompts: prompts}
      call_options[:bindings] = plays.transform_values { |p| @library.play_binding(p) } if plays.any?
      call_options[:prompt_timeout] = prompt_timeout if prompt_timeout
      call_options[:headless] = true if @launch_mode.resolve(headless).headless?
      result = @launch_command.call(projects, **call_options)

      projects.each do |p|
        @project_settings.ensure_exists(p)
        @hook_runner.run(p, "post_launch")
      end
      {exit_code: result && result[:exit_code], projects: projects, result: result, plays: plays}
    end

    # The play `launch --play` sends one project, from its root's library, then global.
    def resolve_play(play, root)
      raise Error, "--play is not available: no library was wired." unless @library
      @library.play(play, cwd: root)
    end

    # One `results` row per launched project, from the state Launch wrote.
    def launch_rows(projects, result, ok_outcome: "launched", plays: {})
      @state.load
      reused = result&.dig(:reused) || []
      prompt_failures = result&.dig(:prompt_failures) || {}
      start_failures = result&.dig(:start_failures) || {}
      projects.map do |project|
        entry = @state[project]
        details = {iterm_window_id: entry.is_a?(Hash) ? entry["iterm_window_id"] : nil, headless: entry.is_a?(Hash) && entry["headless"] == true}
        if plays[project]
          details[:play] = plays[project].merge("delivered" => !result.nil? && !entry.nil? && !prompt_failures.key?(project) && !start_failures.key?(project),
            "pane" => result&.dig(:bound_panes, project))
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
      agents = []
      skills = []
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
        opts.on("--agent NAME", "Copy a library agent into the worktree's .claude/agents/ (repeatable).",
          "Listed in the repo's info/exclude; a file the repo tracks there is kept") do |v|
          agents << v
        end
        opts.on("--skill NAME", "Copy a library skill directory into the worktree's .claude/skills/",
          "(repeatable), the same way. Unknown names fail before the worktree is created") do |v|
          skills << v
        end
        opts.on("--base REF", "Branch/ref to create a new branch from, instead of prompting") do |v|
          base = v
        end
        opts.on("--title TITLE", "A human title for the workspace's task; it labels the agent panes in",
          "`workspace sessions --json`. The panes also get WORKSPACE_TASK=<task id>") do |v|
          title = v
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
        opts.separator "  workspace start PROJ-123 --title \"Fix the login bug\"    # name the task shown in `workspace sessions`"
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
      start_options[:agents] = agents if agents.any?
      start_options[:skills] = skills if skills.any?
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
        {results: rows}
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
          {results: [action_row(killed, "killed")]}
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
        opts.on("--json", "Print one action document (see docs/README.json.md) instead of text, which goes to stderr") { json = true }
        opts.separator ""
        opts.separator "Examples:"
        opts.separator "  workspace focus    # focus the current directory's project"
        opts.separator "  workspace focus my-notes --pane %19    # focus the window and select pane %19"
        opts.separator "  workspace focus my-notes    # focus a specific project"
        opts.separator "  workspace focus --shake my-notes    # shake the window after focusing"
        opts.separator "  workspace focus --highlight my-notes    # highlight the window green (default)"
        opts.separator "  workspace focus --highlight --color blue my-notes    # highlight in another color"
      end
      parser.parse!(args)

      project = args.first || @project_detector.detect(@working_dir)
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
        project = args.first || @project_detector.detect(@working_dir)
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

      @run_command.call(
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

    def cmd_agentd(args)
      name = nil
      wc_socket = nil
      force = false
      ensure_running = false

      parser = OptionParser.new do |opts|
        opts.banner = "Usage: workspace agentd [PROJECT] [options]"
        opts.separator ""
        opts.separator "Run the long-lived workspace agent daemon for a project."
        opts.separator "Registers with the work-coordinator and serves commands until terminated."
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
      end
      parser.parse!(args)

      name ||= args.shift
      raise UsageError, "Unexpected argument: #{args.first}.\n\n#{parser.help}" if args.any?
      name ||= @project_detector.detect(@working_dir)
      raise UsageError, parser.help if name.nil?

      if ensure_running
        raise UsageError, "--ensure and --force can't be combined: --ensure never replaces a running agent.\n\n#{parser.help}" if force
        return ensure_agent(name, wc_socket)
      end

      @exit_handler.exit(1) unless @agent_command.call(name: name, wc_socket: wc_socket, force: force)
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
      when "help", "--help", "-h", nil then @output.puts ask_help
      else cmd_ask_record(args)
      end
    end

    def ask_help
      <<~HELP
        Usage: workspace ask "<question>" --default "<default taken>" [options]
               workspace ask list [--json]
               workspace ask answer <id> "<answer>" [--deliver] [--json]

        Records a question an unattended agent hit, with the default it took,
        so the agent can keep going instead of blocking on a person. Never
        reads stdin; returns once the question is recorded and any notify
        command has finished (it is stopped after 10 seconds).

        Subcommands:
          list                    Show open questions for this workspace
          answer <id> <answer>    Resolve an open question (alias: resolve); with --deliver,
                                  also type the answer and Enter into the pane that asked

        A first word of list, answer, resolve or help is a subcommand only
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
      json = false
      parser = OptionParser.new do |opts|
        opts.banner = "Usage: workspace ask list [--json]"
        opts.on("--name NAME", "Workspace to act on instead of the one detected from cwd") { |v| workspace = v }
        opts.on("--json", "Emit the documented JSON schema instead of a table") { json = true }
      end
      parser.parse!(args)
      raise UsageError, parser.help if args.any?

      result = @ask_command.list(working_dir: working_dir_for(workspace), json: json)
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
      when "__run" then cmd_dev_run(args)
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

        Options (every subcommand):
          --name WS         Act on workspace WS instead of the one detected from the
                            current directory

        Options (up):
          --wait            Queue behind another worktree's dev env
          --force           Stop another worktree's dev env, then start this one
                            (--takeover, the old flag, still works; unrelated to
                            `down --force`)
          --no-ready        Don't wait for the dev.ready check
          --max-wait DUR    Give up after DUR, e.g. "9m" (a plain number is seconds;
                            exit 75; implies --wait). With --force, it limits
                            the whole switch.

        Options (down):
          --force           Also kill a process group left behind by a dead wrapper

        Note: `up` from the worktree that already holds the devenv lock is
        a no-op (exit 0); it doesn't restart the dev command.

        Exit codes (up):
          0   running (or already running for this worktree)
          1   running for another worktree (without --wait/--force), or failed to start;
              also a --force whose target is already being stopped by another
              `lock clear`/`dev down`/`dev up --force`
          4   devenv lock cleared while waiting
          6   ready check failed (the env is stopped and the lock released)
          75  still queued after --max-wait

        Exit codes (down):
          0   stopped (or nothing was running)
          1   could not stop the process group, or it's already being stopped by
              another `lock clear`/`dev down`/`dev up --force`

        Examples:
          workspace dev up
          workspace dev up --wait --max-wait 10m
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
      json = false
      parser = OptionParser.new do |opts|
        opts.banner = "Usage: workspace dev up [--wait] [--force] [--no-ready] [--max-wait DURATION] [--json]"
        opts.on("--name NAME", "Workspace to act on instead of the one detected from cwd") { |v| workspace = v }
        opts.on("--wait", "Queue behind another worktree's dev env") { wait = true }
        opts.on("--force", "--takeover", "Stop another worktree's dev env, then start this one") { force = true }
        opts.on("--[no-]ready", "Wait for the dev.ready check (default: on)") { |v| ready = v }
        opts.on("--max-wait DURATION", "Give up after DURATION (e.g. \"9m\", or a plain number of seconds); exits 75; implies --wait") { |v| max_wait = parse_duration_option("--max-wait", v) }
        opts.on("--json", "Print one action document (see docs/README.json.md) instead of text, which goes to stderr") { json = true }
      end
      parser.parse!(args)
      raise UsageError, parser.help if args.any?

      run_action("dev up", json: json) do
        result = @dev_command.up(wait: wait, takeover: force, ready: ready, max_wait: max_wait, working_dir: working_dir_for(workspace))
        rows = json ? [exit_code_row(workspace || @project_detector.detect(@working_dir), "started", result[:exit_code])] : []
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
               workspace handoff new NAME (--handoff-doc PATH|--handoff-prompt TEXT) [options]

        Watches a coding agent's context-window usage and hands off to a fresh
        conversation before it fills up: `check` tells the agent to save its state
        once usage crosses a threshold, `new` clears the conversation and resumes it
        (the same flow as `workspace agent-run restart`).

        NAME defaults to the workspace detected from the current directory.

        Options (check):
          --pane N               Pane index (default: the first Claude Code pane;
                                  see `workspace sessions NAME` to list panes)
          --threshold PCT        Context usage percent that triggers a handoff, 1-100
                                  (default: handoff.threshold, or 11)
          --context-pct N        Skip detection and use this value (0-100)
          --handoff-doc PATH     Doc the agent updates and resumes from
          --handoff-prompt TEXT  Prompt sent verbatim instead of a doc
          --json                 Print the result as JSON

        Options (new):
          --pane N               Pane index (default: the first Claude Code pane;
                                  see `workspace sessions NAME` to list panes)
          --handoff-doc PATH     Doc the agent reads and resumes from (one of
                                  --handoff-doc/--handoff-prompt is required)
          --handoff-prompt TEXT  Prompt sent verbatim instead of a doc (one of
                                  --handoff-doc/--handoff-prompt is required)
          --wait                 Wait for the restart to finish and report how it
                                  went (don't use this from the agent being restarted)
          --json                 Print the result as JSON

        Exit codes (check): 0 under the threshold, 1 at/over it (a save-state prompt
        was sent), 2 when context usage can't be determined (nothing was sent).

        Examples:
          workspace handoff check myapp --handoff-doc HANDOFF.md
          workspace handoff check myapp --pane 2 --threshold 20 --json    # for scripting
          workspace handoff new myapp --pane 1 --handoff-doc HANDOFF.md    # without going through check
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
        opts.on("--pane N", "Pane index or tmux pane id (e.g. '%19', from 'workspace sessions --json'); default: the first Claude Code pane") { |v| pane = v }
        opts.on("--threshold PCT", "Context usage percent that triggers a handoff") { |v| threshold = v }
        opts.on("--context-pct N", Integer, "Skip detection and use this value") { |v| context_pct = v }
        opts.on("--handoff-doc PATH", "Doc the agent updates and resumes from") { |v| handoff_doc = v }
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
        opts.on("--pane N", "Pane index or tmux pane id (e.g. '%19', from 'workspace sessions --json'); default: the first Claude Code pane") { |v| pane = v }
        opts.on("--handoff-doc PATH", "Doc the agent reads and resumes from") { |v| handoff_doc = v }
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
      raise UsageError, "Missing --handoff-doc or --handoff-prompt.\n\n#{parser.help}" if handoff_doc.nil? && handoff_prompt.nil?
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

    def pipeline_help
      <<~HELP
        Usage: workspace pipeline <subcommand> [options]

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
        {results: json ? [action_row(project, "started", work_item_ref: work_item)] : []}
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
        {results: json ? [action_row(project, "advanced", work_item_ref: work_item)] : []}
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
        {results: json ? [action_row(project, "reset")] : []}
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
        project = args[0] || @project_detector.detect(@working_dir)
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

      project = args.first || @project_detector.detect(@working_dir)
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
        opts.separator "branch has commits its base branch (origin's default branch) lacks."
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
        name = args.first || @project_detector.detect(@working_dir)
        raise UsageError, "Missing workspace name.\n\n#{parser.help}" unless name

        @review_command.show(name: name, json: options[:json])
      end
      @exit_handler.exit(result[:exit_code]) unless result[:exit_code].zero?
    rescue OptionParser::ParseError, UsageError => e
      raise unless json_requested?(options[:json], given)
      emit_json_error(Commands::Review::JSON_SCHEMA_VERSION, e, message: e.message.lines.first.strip)
    end

    DAEMON_SUBCOMMANDS = %w[status restart log].freeze

    def daemon_parser(options)
      OptionParser.new do |opts|
        opts.banner = "Usage: workspace daemon status [WORKSPACE] [--json]\n" \
          "       workspace daemon restart [WORKSPACE] [--wc-socket PATH] [--json]\n" \
          "       workspace daemon log [WORKSPACE] [--lines N] [--json]"
        opts.separator ""
        opts.separator "Inspect or control a workspace's agent daemon (see `workspace agentd`)."
        opts.separator "  status    whether the daemon answers on its socket, its pid, and its socket and log paths"
        opts.separator "  restart   stop the daemon holding the socket (SIGTERM, even a hung one) and start a new one in the"
        opts.separator "            background; a daemon run in a terminal is replaced by a detached one. With none"
        opts.separator "            running, just start one"
        opts.separator "  log       the last lines of the log a background daemon writes; a daemon run in a"
        opts.separator "            terminal logs to that terminal instead"
        opts.separator ""
        opts.on("--name NAME", "Workspace name (defaults to WORKSPACE or the project detected from the current directory)") { |v| options[:name] = v }
        opts.on("--lines N", Integer, "log: how many trailing lines (default #{Commands::Daemon::DEFAULT_LINES})") { |v| options[:lines] = v }
        opts.on("--wc-socket PATH", "restart: work-coordinator socket for the new daemon") { |v| options[:wc_socket] = v }
        opts.on("--json", "Print one JSON document (see docs/README.daemon.md)") { options[:json] = true }
        opts.on("-h", "--help", "Show this help") { options[:help] = true }
        opts.separator ""
        opts.separator "Examples:"
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

      name = options[:name] || args.shift
      raise UsageError, "Unexpected argument: #{args.first}. Run 'workspace daemon --help'." if args.any?
      name ||= @project_detector.detect(@working_dir)
      raise UsageError, "Missing workspace name.\n\n#{parser.help}" unless name
      raise UsageError, "--lines only applies to `daemon log`." if options[:lines] && subcommand != "log"
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

    def daemon_restart(name, options)
      run_action("restart", json: options[:json]) do
        restarted = @daemon_command.restart(name: name, wc_socket: options[:wc_socket])
        if restarted.ok?
          verb = (restarted.outcome == "restarted") ? "Restarted" : "Started"
          pids = [restarted.old_pid, restarted.pid].compact.join(" -> ")
          @output.puts "#{verb} agentd for #{name}#{" (pid #{pids})" unless pids.empty?}"
        else
          @error_output.puts "Error: #{restarted.message}"
        end
        row = action_row(name, restarted.outcome, reason: restarted.reason, message: restarted.message,
          old_pid: restarted.old_pid, pid: restarted.pid)
        {exit_code: restarted.ok? ? 0 : 1, results: [row]}
      end
    end

    def ui_parser(options)
      OptionParser.new do |opts|
        opts.banner = "Usage: workspace ui open task|review [WORKSPACE] [--print] [--json]\n" \
          "       workspace ui open inbox [--print] [--json]"
        opts.separator ""
        opts.separator "Open a view of the workspace UI through its workspace-ui:// link:"
        opts.separator "  task WORKSPACE     workspace-ui://task/WORKSPACE"
        opts.separator "  review WORKSPACE   workspace-ui://review/WORKSPACE"
        opts.separator "  inbox              workspace-ui://inbox"
        opts.separator ""
        opts.separator "A link only opens a view; it never starts an agent or runs a command. WORKSPACE (or --name)"
        opts.separator "defaults to the project detected from the current directory. Opening needs the UI app"
        opts.separator "installed, since it registers the scheme; without it `open` fails, the exit status is 1, and"
        opts.separator "--print still shows the link."
        opts.separator ""
        opts.on("--name NAME", "Workspace name (task and review)") { |v| options[:name] = v }
        opts.on("--print", "Print the link and open nothing") { options[:print] = true }
        opts.on("--json", "Print one JSON action document (see docs/README.ui.md)") { options[:json] = true }
        opts.on("-h", "--help", "Show this help") { options[:help] = true }
        opts.separator ""
        opts.separator "Examples:"
        opts.separator "  workspace ui open task my-app"
        opts.separator "  workspace ui open review my-app.worktree-fix-login"
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
      name = options[:name] || args.shift
      raise UsageError, "Unexpected argument: #{args.first}. Run 'workspace ui --help'." if args.any?
      if Commands::Ui::VIEWS[view]
        name ||= @project_detector.detect(@working_dir)
        raise UsageError, "#{view} needs a workspace: name one, pass --name, or run from inside a project." unless name
      end

      run_action("ui open", json: options[:json]) do
        opened = @ui_command.open(view: view, workspace: name, print_only: options[:print])
        @error_output.puts "Error: #{opened.message}" unless opened.ok?
        row = action_row(name, opened.outcome, reason: opened.reason, message: opened.message, view: opened.view, url: opened.url)
        {exit_code: opened.ok? ? 0 : 1, results: [row]}
      end
    rescue OptionParser::ParseError, UsageError => e
      raise unless json_requested?(options[:json], given)
      emit_json_error(ACTION_JSON_SCHEMA_VERSION, e, message: e.message.lines.first.strip)
    end

    def binding_parser(options)
      OptionParser.new do |opts|
        opts.banner = "Usage: workspace binding set [WORKSPACE] [--pane PANE] --kind run|review|play --id ID [options]\n" \
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
        opts.on("--name NAME", "Workspace name (set)") { |v| options[:name] = v }
        opts.on("--pane PANE", "Pane id (%19) or, for set, window.pane (0.1)") { |v| options[:pane] = v }
        opts.on("--kind KIND", "run, review or play (set)") { |v| options[:kind] = v }
        opts.on("--id ID", "Run id, review id such as acme/api#835, or play/NAME (set)") { |v| options[:id] = v }
        opts.on("--step STEP", "Step name (set)") { |v| options[:step] = v }
        opts.on("--attempt N", Integer, "Step attempt, 1 or more (set)") { |v| options[:attempt] = v }
        opts.on("--focus TEXT", "Review focus, e.g. security (set)") { |v| options[:focus] = v }
        opts.on("--instructions PATH", "File holding the pane's instructions (set); stored as an absolute path") { |v| options[:instructions] = absolute_unless_blank(v) }
        opts.on("--artifacts PATH", "Directory holding the subject's artifacts (set); stored as an absolute path") { |v| options[:artifacts] = absolute_unless_blank(v) }
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
    def absolute_unless_blank(path)
      path.strip.empty? ? path : File.expand_path(path, @working_dir)
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
        name = options[:name] || args.shift || @project_detector.detect(@working_dir)
        raise UsageError, "binding set needs a workspace: name one, pass --name, or run from inside a project." unless name
        pane = options[:pane] || ENV["TMUX_PANE"]
        raise UsageError, "binding set needs --pane (or to run inside a tmux pane)." unless pane
        raise UsageError, "binding set needs --kind and --id." unless options[:kind] && options[:id]
        raise UsageError, "Unexpected argument: #{args.first}. Run 'workspace binding --help'." if args.any?

        run_action("binding set", json: options[:json]) do
          entry = @binding_command.set(workspace: name, pane: pane, **options.slice(:kind, :id, :step, :attempt, :focus, :instructions, :artifacts))
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

    LIBRARY_SUBCOMMANDS = %w[list show info add update remove].freeze

    def library_parser(options)
      OptionParser.new do |opts|
        opts.banner = "Usage: workspace library list [--kind KIND] [--global | --builtin | --project [NAME]] [--json]\n" \
          "       workspace library show REF [--global | --builtin | --project [NAME]] [--json]\n" \
          "       workspace library info REF [--global | --builtin | --project [NAME]] [--json]\n" \
          "       workspace library add PATH|- --kind KIND [--as NAME] [--link] [--force] [--project [NAME]] [--dry-run] [--json]\n" \
          "       workspace library update REF PATH|- [--link] [--project [NAME]] [--dry-run] [--json]\n" \
          "       workspace library remove REF [--yes] [--project [NAME]] [--dry-run] [--json]"
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
        opts.separator ""
        opts.on("--kind KIND", "agent, play, prompt or skill (add: required; list: a filter);",
          "add --kind skill takes a directory holding SKILL.md") { |v| options[:kind] = v }
        opts.on("--as NAME", "add: the entry name (lowercase letters, digits and hyphens)") { |v| options[:name] = v }
        opts.on("--link", "add, update: store a symlink to PATH instead of a copy") { options[:link] = true }
        opts.on("--force", "add: replace an entry that has different content") { options[:force] = true }
        opts.on("--yes", "remove: don't ask") { options[:yes] = true }
        opts.on("--global", "reads: only the global store") { options[:global] = true }
        opts.on("--builtin", "reads: only the entries that ship with workspace") { options[:builtin] = true }
        opts.on("--project [NAME]", "--name [NAME]", "the project's store (NAME, or the project of the current directory)") { |v| options[:project] = v || true }
        opts.on("--dry-run", "add, update, remove: report what would happen and write nothing") { options[:dry_run] = true }
        opts.on("--json", "Print one JSON document (see docs/README.library.md)") { options[:json] = true }
        opts.on("-h", "--help", "Show this help") { options[:help] = true }
        opts.separator ""
        opts.separator "Examples:"
        opts.separator "  workspace library add --kind play --link ~/Notes/Agent\\ Orchestration\\ Playbook.md"
        opts.separator "  workspace library add kickoff.md --kind prompt --project"
        opts.separator "  workspace library list --kind play --json"
        opts.separator "  workspace start feature/x --prompt \"$(workspace library show prompt/kickoff)\""
        opts.separator "  workspace library remove play/agent-orchestration-playbook --yes"
      end
    end

    def cmd_library(args)
      options = {json: false, link: false, force: false, yes: false, dry_run: false}
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

      scope = scopes.first
      project = options[:project].is_a?(String) ? options[:project] : nil
      where = {scope: scope, project: project, cwd: @working_dir}
      ref = args.shift unless subcommand == "list" || subcommand == "add"

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
        raise UsageError, "library add needs --kind play or --kind prompt." unless options[:kind]
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
        opts.banner = "Usage: workspace instructions compose [--pack NAME]... [--pane %ID] [--name WORKSPACE] [--json]"
        opts.separator ""
        opts.separator "Print the instructions an agent is given, built from library packs. A pack is a"
        opts.separator "library play; workspace ships four: binding (how to work in a bound pane),"
        opts.separator "orchestrator (delegate to sub-agents), commits (how to commit) and review (review a"
        opts.separator "diff with reviewer sub-agents). With no --pack, binding, orchestrator and commits are"
        opts.separator "composed, in that order. Each pack is printed under a heading that names where it"
        opts.separator "came from."
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
        opts.on("--json", "Print one JSON document (see docs/README.instructions.md)") { options[:json] = true }
        opts.on("-h", "--help", "Show this help") { options[:help] = true }
        opts.separator ""
        opts.separator "Examples:"
        opts.separator "  workspace instructions compose"
        opts.separator "  workspace instructions compose --pack orchestrator"
        opts.separator "  workspace instructions compose --pack commits --pack review --name my-app --json"
        opts.separator "  workspace start feature/x --prompt \"$(workspace instructions compose --pack orchestrator)\""
      end
    end

    def cmd_instructions(args)
      options = {json: false, packs: []}
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
      @instructions_command.compose(packs: options[:packs], cwd: working_dir_for(options[:name]), pane: pane, json: options[:json])
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

    def cmd_session_event(args)
      workspace = nil
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
        opts.separator ""
        opts.separator "Examples:"
        opts.separator "  echo '{\"hook_event_name\":\"SessionStart\",\"session_id\":\"abc\"}' | workspace session-event"
        opts.separator "  echo '{\"hook_event_name\":\"Stop\"}' | workspace session-event --workspace my-project"
        opts.separator "  echo '{\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"Edit\"}' | workspace session-event --workspace my-project"
      end
      parser.parse!(args)

      result = @session_event_command.call(workspace: workspace)
      @exit_handler.exit(result[:exit_code]) unless result[:exit_code].zero?
    end

    def cmd_doctor(args)
      headless = nil
      fix = false
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
        opts.separator ""
        opts.separator "Examples:"
        opts.separator "  workspace doctor    # check the current machine's setup"
        opts.separator "  workspace doctor --fix    # also route Claude's statusLine through workspace statusline"
        opts.separator "  workspace doctor --headless    # check for a headless setup (skips iTerm2 and window-tool)"
      end
      parser.parse!(args)

      @doctor.run(headless: headless, fix: fix)
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

    def cmd_add(args)
      parser = OptionParser.new do |opts|
        opts.banner = "Usage: workspace add <path> [path2] ..."
        opts.separator ""
        opts.separator "Add tmuxinator configs for project directories."
        opts.separator "Uses the directory name as the project name."
        opts.separator "For paths inside .worktrees/, prefixes with the repo name"
        opts.separator "(e.g. repo/.worktrees/MYJIRA-123 → repo-MYJIRA-123)."
        opts.separator "Does nothing if a config already exists."
        opts.separator ""
        opts.separator "Examples:"
        opts.separator "  workspace add ~/Code/my-project    # add a project by path"
        opts.separator "  workspace add .    # add the current directory"
        opts.separator "  workspace add ~/Code/project-a ~/Code/project-b    # add multiple projects"
      end
      parser.parse!(args)

      raise UsageError, parser.help if args.empty?

      args.each do |arg|
        name, root = @project_config.resolve_project_arg(arg)
        root ||= File.expand_path(arg)
        unless File.directory?(root)
          @error_output.puts "Error: Not a directory: #{root}"
          next
        end
        @project_config.create(name, root)
        @project_settings.ensure_exists(name)
        @output.puts "Project name: #{name}"
      end
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
      else
        cmd_config_show(args)
      end
    end

    def cmd_config_set(args)
      project = nil
      json = false
      parser = OptionParser.new do |opts|
        opts.banner = "Usage: workspace config set <key> <value> [options]"
        opts.separator ""
        opts.separator "Sets a project config key. The project is inferred from cwd"
        opts.separator "(a worktree resolves to its parent project)."
        opts.separator ""
        opts.separator "Allowed keys: #{ConfigSchema.settable_names.join(", ")}"
        opts.separator ""
        opts.separator "Note: this rewrites the whole YAML file, so YAML.dump drops"
        opts.separator "any comments already in it. A file that isn't valid YAML is"
        opts.separator "left untouched and the command fails; fix or remove it first."
        opts.separator ""
        opts.separator "Options:"
        opts.on("--project NAME", "--name NAME", "Project to configure instead of the one inferred from cwd (--name is the same)") { |v| project = v }
        opts.on("--json", "Print one action document (see docs/README.json.md) instead of text, which goes to stderr") { json = true }
        opts.separator ""
        opts.separator "Examples:"
        opts.separator "  workspace config set dev.up \"./start-dev\""
        opts.separator "  workspace config set dev.stop_timeout 20s"
        opts.separator "  workspace config set locks.idle_grace 10m"
        opts.separator "  workspace config set alerts.notify 'say \"$WORKSPACE_ALERT_TEXT\"'"
        opts.separator "  workspace config set alerts.idle_after 15m"
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
        name = @config_command.set(key, value, project: project, cwd: @working_dir)
        {results: json ? [action_row(name, "set", key: key, value: value, global: name.nil?)] : []}
      end
    end

    def cmd_config_get(args)
      project = nil
      parser = OptionParser.new do |opts|
        opts.banner = "Usage: workspace config get <key> [options]"
        opts.separator ""
        opts.separator "Prints the value on stdout and exits 0. If the key has no value,"
        opts.separator "prints nothing on stdout, a note on stderr, and exits 1."
        opts.separator ""
        opts.on("--project NAME", "--name NAME", "Project to read instead of the one inferred from cwd (--name is the same)") { |v| project = v }
      end
      parser.parse!(args)
      key = args.shift
      raise UsageError, parser.help if key.nil? || args.any?

      found = @config_command.get(key, project: project, cwd: @working_dir)
      @exit_handler.exit(1) unless found
    end

    def cmd_config_unset(args)
      project = nil
      parser = OptionParser.new do |opts|
        opts.banner = "Usage: workspace config unset <key> [options]"
        opts.on("--project NAME", "--name NAME", "Project to configure instead of the one inferred from cwd (--name is the same)") { |v| project = v }
      end
      parser.parse!(args)
      key = args.shift
      raise UsageError, parser.help if key.nil? || args.any?

      @config_command.unset(key, project: project, cwd: @working_dir)
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
      name || @project_detector.detect(@working_dir) || raise(UsageError, parser.help)
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
      global = false
      json = false
      name = nil
      parser = OptionParser.new do |opts|
        opts.banner = "Usage: workspace config [show] [options] [project]"
        opts.separator ""
        opts.separator "Show project or global workspace configuration."
        opts.separator ""
        opts.separator "Options:"
        opts.on("--global", "Show global configuration instead of project config") do
          global = true
        end
        opts.on("--name NAME", "Workspace to show instead of the one inferred from cwd (the same as the project argument)") { |v| name = v }
        opts.on("--json", "Print every config key with its effective value, source layer and files (see docs/README.config.md)") { json = true }
        opts.separator ""
        opts.separator "Config files:"
        opts.separator "  Global:  #{@project_settings.global_config_path}"
        opts.separator "  Project: #{@config.workspace_config_dir}/projects/<name>.yml"
        opts.separator ""
        opts.separator "Global settings:"
        opts.separator "  hooks:                         Global hooks (applied to all projects)"
        opts.separator "  layouts:                       Default tmux pane layouts"
        opts.separator "  event_log_compact_threshold:   Size warning threshold for the event log"
        opts.separator "                                 Formats: \"10kb\", \"1mb\", \"500b\", \"1024\""
        opts.separator "                                 Default: 1mb"
        opts.separator "  statusline.command:            Delegate 'workspace statusline' rendering to"
        opts.separator "                                 another command. Set via 'workspace config set'."
        opts.separator "  context.source:                'statusline' (default) or 'scrape'. Set via"
        opts.separator "                                 'workspace config set'."
        opts.separator "  context.pattern:               Regex (one capture group) used when"
        opts.separator "                                 context.source is 'scrape'."
        opts.separator "  launch.headless:               'true' or 'false': whether launch/start run"
        opts.separator "                                 headless by default on this machine."
        opts.separator ""
        opts.separator "Project settings (in projects/<name>.yml):"
        opts.separator "  hooks:                         Project-specific hooks (post_launch, etc.)"
        opts.separator "  layouts:                       Project-specific tmux pane layouts"
        opts.separator "  worktree_hooks:                Hooks seeded into new worktrees"
        opts.separator "  dev.up, dev.ready,             Set via 'workspace config set' (see"
        opts.separator "  dev.stop_timeout,              'workspace config set --help')"
        opts.separator "  dev.startup_timeout,"
        opts.separator "  dev.ready_timeout,"
        opts.separator "  dev.kill_grace:"
        opts.separator "  locks.idle_grace:              How long an idle agent keeps a lock before"
        opts.separator "                                 the next waiter may take it (default: 5m)"
        opts.separator "  locks.ps_timeout:              How long to wait for 'ps' before giving up"
        opts.separator "                                 (default: 5s, must be > 0)"
        opts.separator "  locks.reap_interval:           How often the background session-monitor"
        opts.separator "                                 sweeps out stale lock holders (default: 30s,"
        opts.separator "                                 must be > 0; takes effect next time the"
        opts.separator "                                 monitor starts)"
        opts.separator "  alerts.notify:                 Command the session-monitor daemon runs when an"
        opts.separator "                                 agent pane starts waiting on a person or stays"
        opts.separator "                                 idle past alerts.idle_after; details arrive in"
        opts.separator "                                 WORKSPACE_ALERT_* environment variables (see"
        opts.separator "                                 docs/README.sessions.md). Unset: no alerts"
        opts.separator "  alerts.idle_after:             How long an agent pane may sit idle before it"
        opts.separator "                                 alerts (default: 10m, must be > 0). Both take"
        opts.separator "                                 effect next time the monitor starts"
        opts.separator ""
        opts.separator "Note: 'show', 'validate', 'set', 'get', and 'unset' are reserved as the first"
        opts.separator "argument here and are always treated as subcommands, so a project literally"
        opts.separator "named one of them can't be shown this way (see docs/README.config.md for"
        opts.separator "the workaround)."
        opts.separator ""
        opts.separator "Examples:"
        opts.separator "  workspace config myproject     # show project config"
        opts.separator "  workspace config               # show config for project in current dir"
        opts.separator "  workspace config --global      # show global config"
        opts.separator "  workspace config show --name myproject --json    # every key, its value and where it comes from"
        opts.separator "  workspace config validate --name myproject --json    # problems, with line and column"
        opts.separator "  workspace config set dev.up \"./start-dev\""
        opts.separator "  workspace config get dev.up"
        opts.separator "  workspace config unset dev.ready"
        opts.separator ""
        opts.separator "To edit by hand, open the config file directly (loses the set/get/unset"
        opts.separator "validation, but keeps comments):"
        opts.separator "  $EDITOR #{@project_settings.global_config_path}"
        opts.separator "  $EDITOR #{@config.workspace_config_dir}/projects/<name>.yml"
      end
      parser.parse!(args)

      if json
        raise UsageError, "--json can't be combined with --global: the global file is one of the layers in the document" if global
        @output.puts JSON.generate(config_report.show(config_workspace(name || args.first, parser)))
        return
      end

      if global
        data = @project_settings.load_global
        path = @project_settings.global_config_path
        @output.puts "# #{path}"
        if data.empty?
          @output.puts "# (no global config found)"
        else
          @output.puts YAML.dump(data)
        end
      else
        project = name || args.first || @project_detector.detect(@working_dir)
        raise UsageError, parser.help unless project
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

    def cmd_list(args)
      all = false
      json = false
      show_urls = false
      show_liveness = false
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
        opts.on("--show-urls", "Include the git origin URL alongside each project name") { show_urls = true }
        opts.on("--liveness", "Mark each active project alive, dead, or unknown from its tmux session") { show_liveness = true }
        opts.separator ""
        opts.separator "Examples:"
        opts.separator "  workspace list    # list active (launched) projects"
        opts.separator "  workspace list --all    # list all available projects"
        opts.separator "  workspace list-projects    # alias for 'list --all'"
        opts.separator "  workspace list --show-urls    # each active project with its git origin URL"
        opts.separator "  workspace list --json    # active projects as JSON"
        opts.separator "  workspace list --liveness    # each active project marked [alive], [dead], or [unknown]"
        opts.separator "  workspace list --liveness --json    # [{\"name\":\"my-notes\",\"alive\":true},...]"
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
          @output.puts JSON.generate(projects)
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
          @output.puts "[]"
        else
          @output.puts "No active projects. Run 'workspace list --all' to see available projects."
        end
        return
      end

      if show_liveness
        list_with_liveness(json: json, show_urls: show_urls)
      elsif json && show_urls
        projects = @state.keys.sort.map do |name|
          root = @project_config.project_root_for(name)
          dir = root ? File.expand_path(root) : nil
          {"name" => name, "directory" => dir, "url" => (dir ? @git.remote_url(dir) : nil)}
        end
        @output.puts JSON.generate(projects)
      elsif json
        @output.puts JSON.generate(@state.keys.sort)
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
      parser = OptionParser.new do |opts|
        opts.banner = "Usage: workspace status [options]"
        opts.separator ""
        opts.separator "Show detailed state of tracked launcher sessions. Each is marked [alive] (its tmux"
        opts.separator "session exists), [dead] (the session is gone; remove it with 'workspace cleanup'),"
        opts.separator "or [unknown] (tmux didn't answer, or the project uses a custom tmux socket)."
        opts.separator ""
        opts.separator "Options:"
        opts.on("--json", "Output as JSON") { json = true }
        opts.separator ""
        opts.separator "Examples:"
        opts.separator "  workspace status          # tracked sessions with window ids, headless ones marked"
        opts.separator "  workspace status --json   # machine-readable state (unique ids, window ids, alive: true/false/null)"
        opts.separator "  workspace status --json | jq -r '.[\"my-notes\"].iterm_window_id'    # one project's window id"
      end
      parser.parse!(args)

      @state.load
      if @state.empty?
        json ? @output.puts("{}") : @output.puts("No tracked sessions.")
        return
      end

      if @state.empty?
        json ? @output.puts("{}") : @output.puts("No tracked sessions.")
        return
      end

      alive = @liveness.call(@state.keys)
      if json
        @output.puts JSON.pretty_generate(@state.to_h.to_h { |project, info| [project, info.merge("alive" => alive[project])] })
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

    def liveness_label(alive)
      case alive
      when true then "alive"
      when false then "dead"
      else "unknown"
      end
    end

    def list_with_liveness(json:, show_urls:)
      names = @state.keys.sort
      alive = @liveness.call(names)
      entries = names.map do |name|
        entry = {"name" => name}
        if show_urls
          root = @project_config.project_root_for(name)
          dir = root ? File.expand_path(root) : nil
          entry["directory"] = dir
          entry["url"] = dir ? @git.remote_url(dir) : nil
        end
        entry["alive"] = alive[name]
        entry
      end

      if json
        @output.puts JSON.generate(entries)
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
        opts.on("--json", "Print one action document (see docs/README.json.md) instead of text, which goes",
          "to stderr; without --force the prompt still asks (or fails under --no-input)") { json = true }
        opts.separator ""
        opts.separator "Examples:"
        opts.separator "  workspace cleanup    # list zombie sessions and ask before removing"
        opts.separator "  workspace cleanup --force    # remove all zombie sessions immediately"
      end
      parser.parse!(args)

      run_action("cleanup", json: json) do
        cleaned = @cleanup_command.call(force: force)
        {results: json ? cleaned.map { |p| action_row(p, "cleaned") } : []}
      end
    end

    def cmd_prune(args)
      dry_run = false
      force = false
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
        opts.separator "Requires the `gh` CLI to be installed and authenticated."
        opts.separator ""
        opts.separator "Options:"
        opts.on("--dry-run", "Show what would be removed without making changes") do
          dry_run = true
        end
        opts.on("-f", "--force", "Skip confirmation, and skip the uncommitted/unpushed-work check") do
          force = true
        end
        opts.separator ""
        opts.separator "Examples:"
        opts.separator "  workspace prune --dry-run    # see what would be pruned without changing anything"
        opts.separator "  workspace prune    # prune with a confirmation prompt"
        opts.separator "  workspace prune --force    # prune without prompting, including candidates with unsaved work"
      end
      parser.parse!(args)

      @prune_command.call(dry_run: dry_run, force: force)
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
      parser = OptionParser.new do |opts|
        opts.banner = "Usage: workspace parent [NAME] [--path] [--json]"
        opts.separator ""
        opts.separator "Print the parent workspace of the current (or given) workspace."
        opts.separator "In a non-worktree workspace, prints its own name."
        opts.separator ""
        opts.on("--path", "Print the parent's root directory instead of its name") { path = true }
        opts.on("--json", "Print name, path, git_common_dir, is_worktree, worktree as JSON") { json = true }
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
      @parent_command.call(name, path: path, json: json)
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
