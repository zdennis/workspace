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
    # @param agent_command [Workspace::Commands::Agent] pre-built agent command
    # @param restart_agent_command [Workspace::Commands::RestartAgent, nil] pre-built
    #   `agent-run restart` command; optional so test builders need not wire it
    # @param logger [Workspace::Logger] debug logger
    # @param output [IO] output stream for user-facing messages
    # @param error_output [IO] error output stream for warnings and errors
    # @param input [IO] input stream for interactive prompts
    # @param exit_handler [#exit] callable for process exit (Kernel in production, FakeExitHandler in tests)
    # @param parent_command [Workspace::Commands::Parent] pre-built parent command
    # @param dev_command [Workspace::Commands::Dev] pre-built dev command
    # @param clock [#call] returns the current Time, for relative deadline display
    def initialize(config:, state:, project_config:, git:, window_manager:, doctor:, project_settings:, hook_runner:, project_detector:, launch_command:, kill_command:, finish_command:, start_command:, stop_command:, focus_command:, tile_command:, layout_command:, resize_command:, init_command:, repair_command:, cleanup_command:, prune_command:, claude_command:, lookup_command:, update_pane_command:, run_command:, run_result_store:, run_and_report_command:, capture_command:, lock_command:, dev_command:, parent_command:, agent_command:, sessions_command:, session_event_command:, config_command:, statusline_command:, ask_command:, restart_agent_command: nil, exit_handler: Kernel, logger: Workspace::Logger.new, output: $stdout, error_output: $stderr, input: $stdin, working_dir: Dir.pwd, clock: -> { Time.now })
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
      @lock_command = lock_command
      @dev_command = dev_command
      @parent_command = parent_command
      @agent_command = agent_command
      @config_command = config_command
      @statusline_command = statusline_command
      @ask_command = ask_command
      @restart_agent_command = restart_agent_command
      @exit_handler = exit_handler
      @logger = logger
      @output = output
      @error_output = error_output
      @input = input
      @working_dir = working_dir
      @clock = clock
    end

    # Parses the subcommand from argv and dispatches to the appropriate method.
    #
    # @param argv [Array<String>] command-line arguments
    # @return [void]
    def run(argv)
      args = argv.dup
      @logger.enable! if args.delete("--debug")
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
      when "agent"
        cmd_agent(args)
      when "lock"
        cmd_lock(args)
      when "dev"
        cmd_dev(args)
      when "parent"
        cmd_parent(args)
      when "sessions"
        cmd_sessions(args)
      when "ask"
        cmd_ask(args)
      when "session-event"
        cmd_session_event(args)
      when "agent-run"
        cmd_agent_run(args)
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
        @output.puts "workspace #{Workspace::VERSION}"
      when "help", "--help", "-h", nil
        main_help
      else
        @error_output.puts "Unknown subcommand: #{subcommand}"
        @error_output.puts
        main_help
        @exit_handler.exit(1)
      end
    rescue UsageError => e
      @error_output.puts e.message
      @exit_handler.exit(1)
    rescue OptionParser::ParseError => e
      @error_output.puts e.message
      @exit_handler.exit(1)
    rescue Workspace::Commands::Run::NotSubmittedError => e
      @error_output.puts "Error: #{e.message}"
      @exit_handler.exit(Workspace::Commands::Run::NotSubmittedError::EXIT_CODE)
    rescue Error => e
      @error_output.puts "Error: #{e.message}"
      @exit_handler.exit(1)
    end

    private

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
          agent           Run the workspace agent for a project (long-lived)
          agent-run       Send a message to a running agent (command, inject, restart a pane)
          alfred          Manage the Alfred workflow for workspace focus
          ask             Record a question an unattended agent hit, with its default
          capture         Print a tmux pane's scrollback buffer to stdout
          cleanup         Detect and remove zombie sessions from state
          config          Show project or global configuration
          current         Print the workspace project name for the current directory
          dev             Start, stop, or inspect this repo's dev environment (devenv lock)
          deactivate      Deactivate Claude in a project's tmux pane (sends Ctrl-C)
          dir             Print the root directory of a workspace project
          doctor          Check that all required dependencies are installed
          event-log       Show or compact the event log (state changes and agent activity)
          finish          Verify a worktree is clean and pushed, then remove it (optionally opens a PR)
          focus           Bring a project's iTerm window to the front
          help            Show this help message
          init            Install tmuxinator templates and create config directory
          kill            Kill a worktree project and remove its worktree (auto-detects from cwd)
          launch          Launch tmuxinator projects in iTerm windows
          layout          Save/restore tmux pane layouts (auto-saved before resize)
          list            List currently active (launched) projects (--all for all available)
          lock            Acquire, release, inspect, or clear a shared repo-wide lock
          lookup          Find a workspace project by worktree path, branch, or project name
          parent          Print the parent workspace of the current (or given) workspace
          pipeline        Inspect and drive a project's agent pipeline
          prune           Remove worktree projects whose PR is closed or merged
          reactivate      Reactivate Claude in a project's tmux pane
          relaunch        Stop and relaunch all active workspace projects
          repair          Rebuild state from live iTerm windows
          resize          Resize tmux panes for a running project
          run             Send a shell command to a pane in a running project's tmux session
          run-and-report  Run a command as a subprocess, capture stdout/stderr/exit status
          report-run-status  Internal: write run result for --wait (called by shell wrapper)
          session-event   Forward one agent hook event to its daemon (installed by init)
          sessions        Show coding-agent sessions and sub-agents in a workspace
          start           Create a worktree and launch it (from JIRA key, PR URL, or branch)
          status          Show detailed state of tracked launcher sessions
          set-command     Set the shell command for a pane in a project config (--pane <N>)
          statusline      Render Claude Code's status line (install as its statusLine command)
          stop            Stop active workspace projects and their tmux sessions
          tile            Tile all windows for a project across the screen
          whereis         Print the workspace installation directory

        Global options:
          --debug         Print detailed debug output to stderr

        Run 'workspace <subcommand> --help' for subcommand-specific help.

        Environment variables:
          WORKSPACE_DEBUG   Enable debug output (same as --debug)
      HELP
    end

    def cmd_launch(args)
      reattach = false
      prompt = nil
      prompt_timeout = nil
      parser = OptionParser.new do |opts|
        opts.banner = "Usage: workspace launch [options] <project1> [project2] ..."
        opts.separator ""
        opts.separator "Launch tmuxinator projects in iTerm2, each in its own window."
        opts.separator "Reuses existing launcher panes when available."
        opts.separator "Windows are arranged left-to-right with slight overlap."
        opts.separator ""
        opts.separator "Options:"
        opts.on("--reattach", "Reattach to existing tmux sessions, preserving session state.") do
          reattach = true
        end
        opts.on("--prompt PROMPT", "Send an initial prompt to the coding agent in each project, once it is",
          "ready (up to #{AgentReadiness::DEFAULT_TIMEOUT}s); exits 1 if it can't be sent") do |p|
          prompt = p
        end
        opts.on("--prompt-timeout DURATION", "How long to wait for the coding agent to be ready for --prompt",
          "(e.g. \"90s\", or a plain number of seconds); default #{AgentReadiness::DEFAULT_TIMEOUT}s") do |v|
          prompt_timeout = parse_duration_option("--prompt-timeout", v, positive: true)
        end
        opts.separator ""
        opts.separator "Note: --reattach uses tmux -CC attach which may trigger an iTerm dialog."
        opts.separator "To suppress it, set iTerm > Settings > General > tmux >"
        opts.separator "  'When attaching, restore windows' to 'Always'."
      end
      parser.parse!(args)

      raise UsageError, parser.help if args.empty?

      projects = args.map do |arg|
        name, root = @project_config.resolve_project_arg(arg)
        if root
          @project_config.create(name, root)
        else
          name
        end
      end

      prompts = prompt ? projects.each_with_object({}) { |p, h| h[p] = prompt } : {}

      call_options = {reattach: reattach, prompts: prompts}
      call_options[:prompt_timeout] = prompt_timeout if prompt_timeout
      result = @launch_command.call(projects, **call_options)

      projects.each do |p|
        @project_settings.ensure_exists(p)
        @hook_runner.run(p, "post_launch")
      end
      @exit_handler.exit(result[:exit_code]) if result && !result[:exit_code].zero?
    end

    def cmd_start(args)
      prompt = nil
      prompt_timeout = nil
      base = nil
      yes = false
      json = false
      parser = OptionParser.new do |opts|
        opts.banner = "Usage: workspace start [options] <jira-key|jira-url|pr-url|branch>"
        opts.separator ""
        opts.separator "Create a git worktree and launch it as a workspace project."
        opts.separator ""
        opts.separator "Accepts:"
        opts.separator "  PROJ-123                                  JIRA issue key (used as branch name)"
        opts.separator "  https://mycompany.atlassian.net/.../123   JIRA URL (extracts issue key)"
        opts.separator "  https://github.com/.../pull/471           GitHub PR URL (fetches branch name)"
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
        opts.on("--base REF", "Branch/ref to create a new branch from, instead of prompting") do |v|
          base = v
        end
        opts.on("--yes", "Accept every default instead of prompting (e.g. the default base branch)") do
          yes = true
        end
        opts.on("--json", "Emit the documented JSON schema instead of plain text (see docs/README.start.md);",
          "never prompts (see --base/--yes). Only the JSON goes to stdout; progress/warnings",
          "go to stderr or the warnings field (docs/README.start.md)") do
          json = true
        end
        opts.separator ""
        opts.separator "The worktree is created in .worktrees/ under the project root."
        opts.separator "Never blocks on stdin when stdin isn't a TTY: pass --base/--yes, or it exits with"
        opts.separator "a usage error naming the flag it needed."
      end
      parser.parse!(args)

      if args.empty?
        raise UsageError, parser.help unless json
        return emit_json_usage_error(Workspace::Commands::Start::JSON_SCHEMA_VERSION, parser.help.lines.first.strip)
      end

      result = @start_command.call(args.first, prompt: prompt, prompt_timeout: prompt_timeout,
        base: base, yes: yes, json: json)
      @exit_handler.exit(result[:exit_code]) if result && !result[:exit_code].zero?
      # post_start hook — project name not easily available here,
      # so hooks for start should use post_launch (which fires from Launch)
    rescue OptionParser::ParseError, UsageError => e
      raise unless json_requested?(json, args)
      emit_json_usage_error(Workspace::Commands::Start::JSON_SCHEMA_VERSION, e.message.lines.first.strip)
    end

    def cmd_stop(args)
      parser = OptionParser.new do |opts|
        opts.banner = "Usage: workspace stop [project1] [project2] ..."
        opts.separator ""
        opts.separator "Stop workspace projects and their tmux sessions."
        opts.separator "If no projects are specified, stops all active workspace projects."
        opts.separator "Projects can be restarted with 'workspace launch'."
      end
      parser.parse!(args)

      stopped = @stop_command.call(args)

      stopped.each { |p| @hook_runner.run(p, "post_stop") }
    end

    def cmd_kill(args)
      force = false
      parser = OptionParser.new do |opts|
        opts.banner = "Usage: workspace kill [project]"
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
      end
      parser.parse!(args)

      # The hook runs from inside Kill, before the session is killed: kill may
      # be running inside that session, and nothing after the kill would run.
      @kill_command.call(args.first, force: force, working_dir: @working_dir) do |project|
        @hook_runner.run(project, "post_kill")
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
      emit_json_usage_error(Workspace::Commands::Finish::JSON_SCHEMA_VERSION, e.message.lines.first.strip)
    end

    def cmd_focus(args)
      shake = false
      highlight = false
      highlight_color = "green"
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
      end
      parser.parse!(args)

      project = args.first || @project_detector.detect(@working_dir)
      raise UsageError, parser.help unless project

      @focus_command.call(project, shake: shake, highlight: highlight ? highlight_color : nil)

      @hook_runner.run(project, "post_focus")
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
          "Target pane: zero-based index, 'window.pane' (e.g. '0.1', as shown by 'workspace sessions'), 'bottom', or a title substring (e.g. 'Claude Code')") do |n|
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
          "Target pane: zero-based index, 'window.pane' (e.g. '0.1', from 'workspace sessions'), 'bottom', or a title substring (e.g. 'Claude Code')") do |n|
          pane_opt = n
        end
        opts.on("--lines N", Integer,
          "Number of lines from the bottom to capture (default: 100)") do |n|
          lines_opt = n
        end
        opts.on("--all", "Capture full pane history up to tmux history-limit") do
          all = true
        end
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

    def cmd_agent(args)
      name = nil
      wc_socket = nil
      force = false

      parser = OptionParser.new do |opts|
        opts.banner = "Usage: workspace agent [options]"
        opts.separator ""
        opts.separator "Run the long-lived workspace agent for a project."
        opts.separator "Registers with the work-coordinator and serves commands until terminated."
        opts.separator ""
        opts.separator "Options:"
        opts.on("--name NAME", "Workspace name (defaults to the detected project)") { |v| name = v }
        opts.on("--wc-socket PATH", "Path to the work-coordinator socket") { |v| wc_socket = v }
        opts.on("-f", "--force", "Kill any running agent for this workspace before starting") { force = true }
      end
      parser.parse!(args)

      name ||= @project_detector.detect(@working_dir)
      raise UsageError, parser.help if name.nil?

      @exit_handler.exit(1) unless @agent_command.call(name: name, wc_socket: wc_socket, force: force)
    end

    def cmd_ask(args)
      # Recording always takes --default, so with it a first word like
      # "list" or "help" is the question text, not a subcommand.
      return cmd_ask_record(args) if args.any? { |a| a == "--default" || a.start_with?("--default=") }

      # The subcommand is the first non-option argument, so a leading flag
      # (e.g. `ask --json list`) doesn't get mistaken for the question text.
      index = args.index { |a| !a.start_with?("-") }
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
               workspace ask answer <id> "<answer>" [--json]

        Records a question an unattended agent hit, with the default it took,
        so the agent can keep going instead of blocking on a person. Never
        reads stdin; returns once the question is recorded and any notify
        command has finished (it is stopped after 10 seconds).

        Subcommands:
          list                    Show open questions for this workspace
          answer <id> <answer>    Resolve an open question (alias: resolve)

        A first word of list, answer, resolve or help is a subcommand only
        without --default; `workspace ask list --default x` records "list".

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
      HELP
    end

    def cmd_ask_record(args)
      default = nil
      context = nil
      json = false
      parser = OptionParser.new do |opts|
        opts.banner = "Usage: workspace ask \"<question>\" --default \"<default taken>\" [options]"
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

      result = @ask_command.call(question: question, default: default, context: context, working_dir: @working_dir, json: json)
      @exit_handler.exit(result[:exit_code]) unless result[:exit_code].zero?
    rescue OptionParser::ParseError => e
      raise unless json_requested?(json, args)
      emit_json_usage_error(Commands::Ask::JSON_SCHEMA_VERSION, e.message)
    end

    def cmd_ask_list(args)
      json = false
      parser = OptionParser.new do |opts|
        opts.banner = "Usage: workspace ask list [--json]"
        opts.on("--json", "Emit the documented JSON schema instead of a table") { json = true }
      end
      parser.parse!(args)
      raise UsageError, parser.help if args.any?

      result = @ask_command.list(working_dir: @working_dir, json: json)
      @exit_handler.exit(result[:exit_code]) unless result[:exit_code].zero?
    rescue OptionParser::ParseError => e
      raise unless json_requested?(json, args)
      emit_json_usage_error(Commands::Ask::JSON_SCHEMA_VERSION, e.message)
    end

    def cmd_ask_answer(args)
      json = false
      parser = OptionParser.new do |opts|
        opts.banner = "Usage: workspace ask answer <id> \"<answer>\" [--json]"
        opts.on("--json", "Emit the documented JSON schema instead of a message") { json = true }
      end
      parser.parse!(args)

      id = args.shift
      answer = args.shift
      if id.nil? || answer.nil? || args.any?
        raise UsageError, parser.help unless json_requested?(json, args)
        return emit_json_usage_error(Commands::Ask::JSON_SCHEMA_VERSION, "workspace ask answer: an id and an answer are required.")
      end

      result = @ask_command.answer(id, answer, working_dir: @working_dir, json: json)
      @exit_handler.exit(result[:exit_code]) unless result[:exit_code].zero?
    rescue OptionParser::ParseError => e
      raise unless json_requested?(json, args)
      emit_json_usage_error(Commands::Ask::JSON_SCHEMA_VERSION, e.message)
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
                                     `dev up --takeover` is kept either way, not
                                     removed.
          instructions [<name>]      Print the prompt block that tells a coding
                                     agent how to use the lock (default: edit)

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
      task = nil
      wait = false
      poll = Commands::Lock::DEFAULT_POLL_SECONDS
      max_wait = nil
      parser = OptionParser.new do |opts|
        opts.banner = "Usage: workspace lock acquire <name> [options]"
        opts.on("--task TEXT", "Free-text description shown to other waiters") { |v| task = v }
        opts.on("--wait", "Enqueue and poll instead of refusing when busy") { wait = true }
        opts.on("--poll DURATION", "Time between polls while waiting (e.g. \"5s\", or a plain number of seconds)") { |v| poll = parse_duration_option("--poll", v) }
        opts.on("--max-wait DURATION", "Give up after DURATION (e.g. \"9m\", or a plain number of seconds); exits 75; implies --wait") { |v| max_wait = parse_duration_option("--max-wait", v) }
      end
      parser.parse!(args)

      name = args.shift
      raise UsageError, parser.help if name.nil? || args.any?

      result = @lock_command.acquire(name, task: task, wait: wait, poll: poll, max_wait: max_wait, working_dir: @working_dir)
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

    # Emits the documented `--json` error contract (see docs/README.lock.md,
    # docs/README.dev.md) to stdout and exits, for usage/validation errors
    # raised before a command's own `status_json` branch is reached (e.g. bad
    # option, extra argument, invalid lock name).
    #
    # @param schema_version [Integer] the command's JSON schema version
    # @param message [String] error message (single line; not the full help text)
    def emit_json_usage_error(schema_version, message)
      @output.puts JSON.generate({"schema_version" => schema_version, "error" => message})
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
      all = false
      parser = OptionParser.new do |opts|
        opts.banner = "Usage: workspace lock release [<name>|--all]"
        opts.on("--all", "Release every lock this agent holds") { all = true }
      end
      parser.parse!(args)

      name = args.shift
      raise UsageError, parser.help if (!all && name.nil?) || (all && name) || args.any?

      result = @lock_command.release(name, all: all, working_dir: @working_dir)
      @exit_handler.exit(result[:exit_code]) unless result[:exit_code].zero?
    end

    def cmd_lock_status(args)
      json = false
      parser = OptionParser.new do |opts|
        opts.banner = "Usage: workspace lock status [<name>] [--json]"
        opts.on("--json", "Emit the documented JSON schema instead of a table (see docs/README.lock.md)") { json = true }
        opts.separator ""
        opts.separator "Audit trail: locks.jsonl next to locks.json; see docs/README.lock.md."
      end
      parser.parse!(args)

      name = args.shift
      raise UsageError, parser.help if args.any?

      result = @lock_command.status(name, working_dir: @working_dir, json: json)
      @exit_handler.exit(result[:exit_code]) unless result[:exit_code].zero?
    rescue OptionParser::ParseError, UsageError => e
      raise unless json_requested?(json, args)
      emit_json_usage_error(Commands::Lock::JSON_SCHEMA_VERSION, e.message)
    end

    def cmd_lock_clear(args)
      all = false
      json = false
      parser = OptionParser.new do |opts|
        opts.banner = "Usage: workspace lock clear [<name>|--all] [--json]"
        opts.on("--all", "Clear every lock in this namespace") { all = true }
        opts.on("--json", "Emit the documented JSON schema instead of text (see docs/README.lock.md)") { json = true }
      end
      parser.parse!(args)

      name = args.shift
      raise UsageError, parser.help if (!all && name.nil?) || (all && name)
      raise UsageError, "workspace lock clear: too many arguments.\n\n#{parser.help}" if args.any?

      result = @lock_command.clear(name, all: all, working_dir: @working_dir, json: json)
      @exit_handler.exit(result[:exit_code]) unless result[:exit_code].zero?
    rescue OptionParser::ParseError, UsageError => e
      raise unless json_requested?(json, args)
      emit_json_usage_error(Commands::Lock::JSON_SCHEMA_VERSION, e.message.lines.first.strip)
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

        Options (up):
          --wait            Queue behind another worktree's dev env
          --takeover        Stop another worktree's dev env, then start this one
          --no-ready        Don't wait for the dev.ready check
          --max-wait DUR    Give up after DUR, e.g. "9m" (a plain number is seconds;
                            exit 75; implies --wait). With --takeover, it limits
                            the whole takeover.

        Options (down):
          --force           Also kill a process group left behind by a dead wrapper

        Note: `up` from the worktree that already holds the devenv lock is
        a no-op (exit 0); it doesn't restart the dev command.

        Exit codes (up):
          0   running (or already running for this worktree)
          1   running for another worktree (without --wait/--takeover), or failed to start;
              also a --takeover whose target is already being stopped by another
              `lock clear`/`dev down`/`dev up --takeover`
          4   devenv lock cleared while waiting
          6   ready check failed (the env is stopped and the lock released)
          75  still queued after --max-wait

        Exit codes (down):
          0   stopped (or nothing was running)
          1   could not stop the process group, or it's already being stopped by
              another `lock clear`/`dev down`/`dev up --takeover`

        Examples:
          workspace dev up
          workspace dev up --wait --max-wait 10m
          workspace dev up --takeover
          workspace dev status
          workspace dev down
      HELP
    end

    def cmd_dev_up(args)
      wait = false
      takeover = false
      ready = true
      max_wait = nil
      parser = OptionParser.new do |opts|
        opts.banner = "Usage: workspace dev up [--wait] [--takeover] [--no-ready] [--max-wait DURATION]"
        opts.on("--wait", "Queue behind another worktree's dev env") { wait = true }
        opts.on("--takeover", "Stop another worktree's dev env, then start this one") { takeover = true }
        opts.on("--[no-]ready", "Wait for the dev.ready check (default: on)") { |v| ready = v }
        opts.on("--max-wait DURATION", "Give up after DURATION (e.g. \"9m\", or a plain number of seconds); exits 75; implies --wait") { |v| max_wait = parse_duration_option("--max-wait", v) }
      end
      parser.parse!(args)
      raise UsageError, parser.help if args.any?

      result = @dev_command.up(wait: wait, takeover: takeover, ready: ready, max_wait: max_wait, working_dir: @working_dir)
      @exit_handler.exit(result[:exit_code]) unless result[:exit_code].zero?
    end

    def cmd_dev_down(args)
      force = false
      parser = OptionParser.new do |opts|
        opts.banner = "Usage: workspace dev down [--force]"
        opts.on("--force", "Also kill a process group left behind by a dead wrapper") { force = true }
      end
      parser.parse!(args)
      raise UsageError, parser.help if args.any?

      result = @dev_command.down(force: force, working_dir: @working_dir)
      @exit_handler.exit(result[:exit_code]) unless result[:exit_code].zero?
    end

    def cmd_dev_status(args)
      json = false
      parser = OptionParser.new do |opts|
        opts.banner = "Usage: workspace dev status [--json]"
        opts.on("--json", "Emit the documented JSON schema instead of a table (see docs/README.dev.md)") { json = true }
      end
      parser.parse!(args)
      raise UsageError, parser.help if args.any?

      result = @dev_command.status(working_dir: @working_dir, json: json)
      @exit_handler.exit(result[:exit_code]) unless result[:exit_code].zero?
    rescue OptionParser::ParseError, UsageError => e
      raise unless json_requested?(json, args)
      emit_json_usage_error(Commands::Dev::JSON_SCHEMA_VERSION, e.message)
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
    # Usage with a subcommand:
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
          examples   Print all stock example messages without sending anything

        Raw mode (paste a full message directly):
          --body JSON         Complete message JSON; workspace is read from the message
          --dry-run           Print without sending

        Options (command):
          --name NAME         Workspace name (default: detected from cwd)
          --work-item REF     Work item reference, e.g. WC-42  (required)
          --body TEXT         Text to type into the first pipeline pane
          --dry-run           Print the message without sending it

        Options (inject):
          --name NAME         Workspace name (default: detected from cwd)
          --work-item REF     Work item reference  (required)
          --body TEXT         Text to inject into the pane  (required)
          --interrupt         Interrupt the running stage first (sends Ctrl-C)
          --dry-run           Print the message without sending it

        Options (restart; see `workspace agent-run restart --help`):
          --pane PANE         Pane to restart: %12, 0.1, session:0.1, or a pane index  (required)
          --prompt TEXT       Text typed once /clear is confirmed  (required)
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
      raise UsageError, "Missing --work-item.\n\n#{agent_run_help}" if work_item.nil?

      message = {
        "type" => "command",
        "workspace" => name,
        "work_item_ref" => work_item,
        "dispatch_id" => "debug-#{SecureRandom.hex(4)}",
        "body" => jsonl_body(body || "Begin work on #{work_item}.")
      }
      agent_run_send(name, message, dry_run: dry_run)
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
        opts.on("--json", "Print the result as JSON; errors as {\"schema_version\":1,\"error\":...}") { json = true }
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
      emit_json_usage_error(Commands::RestartAgent::JSON_SCHEMA_VERSION, e.message.lines.first.strip)
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
    end

    # Drives and inspects a running agent's pipeline. These are operator tools:
    # everything that touches a pane goes through the agent that owns it, so a
    # manual nudge cannot get the agent's own view of the pipeline out of step.
    def cmd_pipeline(args)
      case args.shift
      when "start" then cmd_pipeline_start(args)
      when "advance" then cmd_pipeline_advance(args)
      when "status" then cmd_pipeline_status(args)
      when "reset" then cmd_pipeline_reset(args)
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
          --json            Print status as JSON (status only)

        'advance' marks the running stage complete even if it has not finished.
      HELP
    end

    def cmd_pipeline_start(args)
      project, work_item, body = parse_pipeline_args(args, "start")
      raise UsageError, "Missing project or --work-item.\n\n#{pipeline_help}" if project.nil? || work_item.nil?

      reply = send_to_agent(project,
        "type" => "command", "workspace" => project, "work_item_ref" => work_item,
        "dispatch_id" => "manual-#{SecureRandom.hex(4)}",
        "body" => body || "Begin work on #{work_item}.")
      raise Error, "The agent for #{project} refused the work item: #{reply["error"]}" unless reply["ok"]
      @output.puts "Sent #{work_item} into #{project}'s pipeline"
    end

    # Types the completion sentinel into the running stage's pane, which is
    # exactly what a finished stage would print, so the agent advances normally.
    #
    # The stage's token comes from the persisted state. If the stage moves on
    # between that read and the inject, the sentinel carries the old stage's
    # token and the new stage ignores it, rather than being ended unasked.
    def cmd_pipeline_advance(args)
      project, work_item, body = parse_pipeline_args(args, "advance")
      raise UsageError, "Missing project or --work-item.\n\n#{pipeline_help}" if project.nil? || work_item.nil?

      token = read_pipeline_state(project).dig(work_item, "sentinel_token")
      # The body reaches a live shell, so it is escaped rather than interpolated.
      sentinel = "#{SentinelPoller.marker(token)} #{body || "manual advance"}"
      reply = send_to_agent(project,
        "type" => "inject", "workspace" => project, "work_item_ref" => work_item,
        "interrupt" => true, "expected_token" => token, "body" => "echo #{Shellwords.escape(sentinel)}")
      unless reply["ok"]
        raise Error, "The stage moved on before the advance landed; run 'workspace pipeline advance' again" if reply["error"] == "stale_token"
        raise Error, "The agent for #{project} refused the advance: #{reply["error"]}"
      end
      @output.puts "Nudged #{project}/#{work_item} to advance"
    end

    def cmd_pipeline_status(args)
      as_json = false
      parser = OptionParser.new do |opts|
        opts.banner = "Usage: workspace pipeline status <project>"
        opts.on("--json", "Print the in-flight entries as JSON") { as_json = true }
      end
      parser.parse!(args)
      project = args.shift
      raise UsageError, parser.help if project.nil?

      entries = read_pipeline_state(project)
      return @output.puts JSON.pretty_generate(entries.values) if as_json

      if entries.empty?
        @output.puts "No pipeline work in flight for #{project}"
        return
      end

      @output.puts "WORK ITEM  PANE  STAGE  DEADLINE"
      entries.each_value do |entry|
        deadline = format_deadline(entry["deadline_at"])
        @output.puts "#{entry["work_item_ref"]}  pane #{entry["pane_index"]}  #{entry["phase"] || "(no pipeline)"}  #{deadline}"
      end
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
      project = args.shift
      raise UsageError, "Usage: workspace pipeline reset <project>" if project.nil?

      if agent_running?(project)
        raise Error, "The agent for #{project} is running; stop it (Ctrl-C in its pane, " \
          "or kill the 'workspace agent' process) before resetting its pipeline state"
      end

      state_path = @config.pipeline_state_path(project)
      File.unlink(state_path) if File.exist?(state_path)
      @output.puts "Cleared pipeline state for #{project}"
    end

    def parse_pipeline_args(args, subcommand)
      work_item = nil
      body = nil
      parser = OptionParser.new do |opts|
        opts.banner = "Usage: workspace pipeline #{subcommand} <project> --work-item REF"
        opts.on("--work-item REF", "Work item reference") { |v| work_item = v }
        opts.on("--body TEXT", "Message body") { |v| body = v }
      end
      parser.parse!(args)
      project = args.shift
      raise UsageError, "Unexpected arguments: #{args.join(" ")}\n\n#{parser.help}" if args.any?
      [project, work_item, body]
    end

    def send_to_agent(project, message)
      socket = begin
        UNIXSocket.open(@config.agent_socket_path(project))
      rescue SystemCallError, IOError
        raise Error, "No agent is running for #{project}. Start one with: workspace agent --name #{project}"
      end
      reply = begin
        socket.puts(message.to_json)
        socket.gets
      rescue SystemCallError, IOError
        raise Error, "The agent for #{project} closed the connection without replying"
      ensure
        socket.close
      end
      raise Error, "The agent for #{project} closed the connection without replying" if reply.nil?
      JSON.parse(reply)
    rescue JSON::ParserError
      raise Error, "Unreadable reply from the agent for #{project}"
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
      end
      parser.parse!(args)

      @init_command.call(dry_run: dry_run, force: force, hooks: hooks)
    end

    def cmd_sessions(args)
      json = false
      watch = false
      interval = 2
      parser = OptionParser.new do |opts|
        opts.banner = "Usage: workspace sessions [options] [project]"
        opts.separator ""
        opts.separator "Show the coding-agent sessions running in a workspace's panes,"
        opts.separator "whether each is working, idle, or waiting on a person, and any"
        opts.separator "sub-agents they started."
        opts.separator ""
        opts.separator "STATE column: working (output changing), idle (output unchanged 30s+),"
        opts.separator "or waiting (the agent asked for permission or input; needs the"
        opts.separator "Notification hook from workspace init). A waiting pane shows the"
        opts.separator "agent's message on the line below it. waiting is Claude Code only;"
        opts.separator "other agents (Codex, OpenCode, Pi) only ever show working or idle."
        opts.separator ""
        opts.separator "Requires a running agent daemon (workspace agent <project>; re-run"
        opts.separator "`workspace init` if `workspace doctor` reports it missing)."
        opts.separator ""
        opts.separator "LOCK column: shows every lock a pane holds or waits on (e.g. \"edit ✓ devenv #2\","
        opts.separator "space-joined, edit first and others alphabetical). JSON output includes a locks array."
        opts.separator ""
        opts.separator "Options:"
        opts.on("--json", "Emit the raw payload instead of a table") { json = true }
        opts.on("--watch", "Redraw until interrupted") { watch = true }
        opts.on("--interval SECONDS", Float, "Seconds between redraws (default 2)") do |value|
          interval = value
        end
      end

      parser.parse!(args)

      project = args.first || @project_detector.detect(@working_dir)
      raise UsageError, parser.help unless project

      result = @sessions_command.call(name: project, json: json, watch: watch, interval: interval)
      @exit_handler.exit(result[:exit_code]) if result && !result[:exit_code].zero?
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
      end
      parser.parse!(args)

      result = @session_event_command.call(workspace: workspace)
      @exit_handler.exit(result[:exit_code]) unless result[:exit_code].zero?
    end

    def cmd_doctor(args)
      parser = OptionParser.new do |opts|
        opts.banner = "Usage: workspace doctor"
        opts.separator ""
        opts.separator "Check that all required dependencies are installed and configured."
      end
      parser.parse!(args)

      @doctor.run
    end

    def cmd_relaunch(args)
      parser = OptionParser.new do |opts|
        opts.banner = "Usage: workspace relaunch"
        opts.separator ""
        opts.separator "Stop all active workspace projects and relaunch them."
      end
      parser.parse!(args)

      @state.load
      if @state.empty?
        @error_output.puts "No active workspace projects to relaunch."
        @exit_handler.exit(1)
      end

      projects = @state.keys.dup
      @output.puts "Will relaunch: #{projects.join(", ")}"

      cmd_stop([])

      sleep 2

      cmd_launch(projects.dup)
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

    # Project config keys `workspace config set/get/unset` allow. Unlisted
    # dotted keys are rejected so typos don't silently create config.
    # Keys `workspace config set/get/unset` allow, mirrored here only for
    # help text; {Commands::Config::ALLOWED_KEYS} is the source of truth.
    CONFIG_ALLOWED_KEYS = Commands::Config::ALLOWED_KEYS + Commands::Config::GLOBAL_ALLOWED_KEYS

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
      else
        cmd_config_show(args)
      end
    end

    def cmd_config_set(args)
      project = nil
      parser = OptionParser.new do |opts|
        opts.banner = "Usage: workspace config set <key> <value> [options]"
        opts.separator ""
        opts.separator "Sets a project config key. The project is inferred from cwd"
        opts.separator "(a worktree resolves to its parent project)."
        opts.separator ""
        opts.separator "Allowed keys: #{CONFIG_ALLOWED_KEYS.join(", ")}"
        opts.separator ""
        opts.separator "Note: this rewrites the whole YAML file, so YAML.dump drops"
        opts.separator "any comments already in it."
        opts.separator ""
        opts.separator "Options:"
        opts.on("--project NAME", "Project to configure instead of the one inferred from cwd") { |v| project = v }
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
        opts.separator ""
        opts.separator "statusline.command, context.source, and context.pattern are global"
        opts.separator "(one status line and one context source per machine), not per project."
      end
      begin
        parser.parse!(args)
      rescue OptionParser::InvalidOption => e
        raise UsageError, "#{e.message} (durations must be positive; a negative value like \"-5m\" looks like a flag)"
      end
      key = args.shift
      value = args.shift
      raise UsageError, parser.help if key.nil? || value.nil? || args.any?

      @config_command.set(key, value, project: project, cwd: @working_dir)
    end

    def cmd_config_get(args)
      project = nil
      parser = OptionParser.new do |opts|
        opts.banner = "Usage: workspace config get <key> [options]"
        opts.separator ""
        opts.separator "Prints the value on stdout and exits 0. If the key has no value,"
        opts.separator "prints nothing on stdout, a note on stderr, and exits 1."
        opts.separator ""
        opts.on("--project NAME", "Project to read instead of the one inferred from cwd") { |v| project = v }
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
        opts.on("--project NAME", "Project to configure instead of the one inferred from cwd") { |v| project = v }
      end
      parser.parse!(args)
      key = args.shift
      raise UsageError, parser.help if key.nil? || args.any?

      @config_command.unset(key, project: project, cwd: @working_dir)
    end

    def cmd_config_show(args)
      global = false
      parser = OptionParser.new do |opts|
        opts.banner = "Usage: workspace config [options] [project]"
        opts.separator ""
        opts.separator "Show project or global workspace configuration."
        opts.separator ""
        opts.separator "Options:"
        opts.on("--global", "Show global configuration instead of project config") do
          global = true
        end
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
        opts.separator "Note: 'set', 'get', and 'unset' are reserved as the first argument"
        opts.separator "here and are always treated as subcommands, so a project literally"
        opts.separator "named 'set', 'get', or 'unset' can't be shown this way (see"
        opts.separator "docs/README.config.md for the workaround)."
        opts.separator ""
        opts.separator "Examples:"
        opts.separator "  workspace config myproject     # show project config"
        opts.separator "  workspace config               # show config for project in current dir"
        opts.separator "  workspace config --global      # show global config"
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
        project = args.first || @project_detector.detect(@working_dir)
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
      parser = OptionParser.new do |opts|
        opts.banner = "Usage: workspace list [options]"
        opts.separator ""
        opts.separator "List currently active (launched) projects."
        opts.separator ""
        opts.separator "Options:"
        opts.on("--all", "List all available projects (not just active ones)") do
          all = true
        end
        opts.on("--json", "Output as JSON") { json = true }
        opts.on("--show-urls", "Include the git origin URL alongside each project name") { show_urls = true }
      end
      parser.parse!(args)

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

      if json && show_urls
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
        opts.separator "Show detailed state of tracked launcher sessions."
        opts.separator ""
        opts.separator "Options:"
        opts.on("--json", "Output as JSON") { json = true }
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

      if json
        @output.puts JSON.pretty_generate(@state.to_h)
      else
        @state.each do |project, info|
          wid = info["iterm_window_id"]
          wid_str = wid ? "  window_id=#{wid}" : ""
          @output.puts "  #{project}#{wid_str}  [alive]"
        end
      end
    end

    def cmd_current(args)
      parser = OptionParser.new do |opts|
        opts.banner = "Usage: workspace current"
        opts.separator ""
        opts.separator "Print the workspace project name for the current directory."
        opts.separator "Detects worktree projects via .workspace-project marker files,"
        opts.separator "then falls back to matching active project roots."
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
      end
      parser.parse!(args)

      if window_id
        project = args.first
        raise UsageError, "Project name required with --window-id\n\n#{parser.help}" unless project
        @repair_command.set_window_id(project, window_id)
      else
        @repair_command.call
      end
    end

    def cmd_cleanup(args)
      force = false
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
      end
      parser.parse!(args)

      @cleanup_command.call(force: force)
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
      end
      parser.parse!(args)

      project = args.shift
      command = args.join(" ").strip

      raise UsageError, "No command provided.\n\n#{parser.help}" if command.empty?

      @update_pane_command.call(project: project, command: command, pane_index: pane_index)
    end

    def cmd_deactivate(args)
      all = false
      parser = OptionParser.new do |opts|
        opts.banner = "Usage: workspace deactivate [options] [project]"
        opts.separator ""
        opts.separator "Deactivate Claude in a project's tmux pane by sending Ctrl-C."
        opts.separator "Auto-detects the project from the current directory if not specified."
        opts.separator ""
        opts.separator "Options:"
        opts.on("--all", "Deactivate Claude in all active projects") { all = true }
      end
      parser.parse!(args)

      projects = resolve_claude_targets(args, all, parser)
      @claude_command.deactivate(projects)
    end

    def cmd_reactivate(args)
      all = false
      parser = OptionParser.new do |opts|
        opts.banner = "Usage: workspace reactivate [options] [project]"
        opts.separator ""
        opts.separator "Reactivate Claude in a project's tmux pane with 'claude --continue || claude'."
        opts.separator "Auto-detects the project from the current directory if not specified."
        opts.separator ""
        opts.separator "Options:"
        opts.on("--all", "Reactivate Claude in all active projects") { all = true }
      end
      parser.parse!(args)

      projects = resolve_claude_targets(args, all, parser)
      @claude_command.reactivate(projects)
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
        opts.on("--json", "Emit {schema_version, events} instead of lines") { json = true }
      end
      raw_args = args.dup
      begin
        parser.parse!(args)
        raise UsageError, "--limit must be greater than 0." if limit && limit <= 0
        raise UsageError, "Unexpected argument: #{args.first}" unless args.empty?
      rescue OptionParser::ParseError, UsageError => e
        return emit_json_usage_error(EVENT_LOG_JSON_SCHEMA_VERSION, e.message) if json_requested?(json, raw_args)
        raise UsageError, (e.is_a?(UsageError) ? e.message : "#{e.message}\n\n#{parser.help}")
      end

      events = @state.event_log.events
      warn_unseen_event_types(types, events)
      events = events.select { |event| event["project"] == project || event.dig("data", "workspace") == project } if project
      events = events.select { |event| types.include?(event["type"]) } unless types.empty?
      events = events.last(limit) if limit

      if json
        @output.puts JSON.generate({"schema_version" => EVENT_LOG_JSON_SCHEMA_VERSION, "events" => events})
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

      @output.print "Remove workflow from #{target_dir}? [y/N] "
      answer = @input.gets&.strip
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
