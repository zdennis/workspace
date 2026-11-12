require "optparse"

module Workspace
  class CLI
    # The `agent`, `agentd`, `daemon`, `sessions` and `review` verbs: parses their arguments with
    # the same usage text the CLI always printed and hands the parsed values to the agent daemon's
    # commands ({Commands::Agent}, {Commands::EnsureAgent}, {Commands::Daemon}) and the ones that
    # read it ({Commands::AgentStatus}, {Commands::AgentExecutables}, {Commands::Sessions},
    # {Commands::Review}). It writes and exits only through the {Invocation} it is given, so
    # `--help --json` captures what it prints.
    class Agent
      # The verbs of `daemon`, in the order `daemon --help` lists them.
      DAEMON_SUBCOMMANDS = %w[status restart log list].freeze

      # The `agentd` flags `restart` doesn't take: beside one, `restart` is the workspace's name.
      AGENTD_RUN_FLAGS = %w[-f --force --ensure].freeze

      # @param agent_command [Workspace::Commands::Agent] runs the agent daemon in the terminal (`agentd`)
      # @param ensure_agent_command [Workspace::Commands::EnsureAgent, nil] `agentd --ensure`; nil refuses it
      # @param daemon_command [Workspace::Commands::Daemon, nil] `daemon` and `agentd restart`; nil refuses them
      # @param sessions_command [Workspace::Commands::Sessions] `sessions`
      # @param review_command [Workspace::Commands::Review, nil] `review`; nil refuses it
      # @param agent_status_command [Workspace::Commands::AgentStatus, nil] `agent status`; nil refuses it
      # @param agent_executables_command [Workspace::Commands::AgentExecutables, nil] `agent executables`; nil refuses it
      # @param agent_run [#call] runs `agent run PROMPT` given its arguments and the {Invocation}; it builds
      #   and sends its message the way `agent-run command` does
      # @param project_detector [Workspace::ProjectDetector] finds the workspace of the working directory
      # @param common [CLI::Common] the output, exit and help helpers
      # @param names [CLI::Names] settles and checks the workspace names given
      # @param working_dir [String] the directory the CLI runs from
      def initialize(agent_command:, ensure_agent_command:, daemon_command:, sessions_command:, review_command:, agent_status_command:,
        agent_executables_command:, agent_run:, project_detector:, common:, names:, working_dir:)
        @agent_command = agent_command
        @ensure_agent_command = ensure_agent_command
        @daemon_command = daemon_command
        @sessions_command = sessions_command
        @review_command = review_command
        @agent_status_command = agent_status_command
        @agent_executables_command = agent_executables_command
        @agent_run = agent_run
        @project_detector = project_detector
        @common = common
        @names = names
        @working_dir = working_dir
      end

      # Runs one `agent`, `agentd`, `daemon`, `sessions` or `review` command line.
      #
      # @param verb [String] the verb {CLI::ROUTES} sent here
      # @param args [Array<String>] the arguments after the verb (changed in place)
      # @param invocation [Invocation] the run's streams, exit handler and flags
      # @return [void]
      # @raise [Workspace::UsageError, Workspace::Error] without `--json`, for the CLI's rescue funnel to report
      def call(verb, args, invocation)
        case verb
        when "agent" then agent(args, invocation)
        when "agentd" then agentd(args, invocation)
        when "daemon" then daemon(args, invocation)
        when "sessions" then sessions(args, invocation)
        when "review" then review(args, invocation)
        end
      end

      private

      # Umbrella for driving a workspace's agent. `agent run PROMPT` sends a
      # command message to the agent's pipeline; anything the daemon used to
      # accept falls back to it with a deprecation warning pointing at
      # `workspace agentd`.
      def agent(args, invocation)
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
        when "run" then @agent_run.call(rest, invocation)
        when "status" then agent_status(rest, invocation)
        when "executables" then agent_executables(rest, invocation)
        when "help" then invocation.output.puts agent_help
        when nil
          if args.include?("--help") || args.include?("-h")
            invocation.output.puts agent_help
          else
            # Daemon-era usage was all-flag (`agent --name myapp`), so a bare
            # all-flag invocation still starts the daemon, with a warning.
            invocation.error_output.puts "`workspace agent` for the daemon is deprecated; use `workspace agentd`"
            agentd(args, invocation)
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
          i += %w[--name --wc-socket --kind].include?(arg) ? 2 : 1
        end
        nil
      end

      def agent_help
        <<~HELP
          Usage: workspace agent <subcommand> [options]

          Subcommands:
            run PROMPT    Send a prompt to the workspace's pipeline (a "command" message)
            status        Ask an agent pane for a status line, or post one (see `agent status --help`)
            executables   List the agent programs on PATH by family and which one each runs (see `agent executables --help`)

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
            workspace agent run "Add OAuth support"    # send a prompt to the pipeline of the project in this directory
            workspace agent run --name myapp --dry-run "Add OAuth support"    # show the message for a named workspace, send nothing
            workspace agent status request --pane %19    # ask the agent in one pane for a status line
            workspace agent executables --kind claude    # which claude program is on PATH and which one runs
        HELP
      end

      def agent_executables(args, invocation)
        name = nil
        kind = nil
        json = false
        help = false
        parser = OptionParser.new do |opts|
          opts.banner = "Usage: workspace agent executables [--kind KIND] [--name WORKSPACE] [--json]"
          opts.separator ""
          opts.separator "List the coding-agent programs on PATH by family (claude, codex, opencode, pi): a file named"
          opts.separator "the family program or starting with it and a dash (claude-dev). Marks the one each family runs,"
          opts.separator "and lists a configured program that is not found. Reads directory listings only; runs nothing."
          opts.separator "Pick one with `workspace config set agent.commands.<kind> NAME-OR-PATH`."
          opts.separator ""
          opts.separator "Options:"
          opts.on("--kind KIND", "Only this family: #{AgentProvider.all.map(&:key).join(", ")}") { |v| kind = v }
          opts.on("--name NAME", "Workspace whose settings decide the marked program (default: detected from cwd, else global settings)") { |v| name = v }
          opts.on("--json", "Print one JSON document: workspace, path_dirs, executables, effective, kind[, truncated]") { json = true }
          opts.on("-h", "--help", "Show this help") { help = true }
          opts.separator ""
          opts.separator "Errors: unknown_agent_kind (details.kind, details.known), unknown_workspace."
          opts.separator ""
          opts.separator "Examples:"
          opts.separator "  workspace agent executables    # every family's programs on PATH, the one each runs marked"
          opts.separator "  workspace agent executables --kind claude    # only the claude family"
          opts.separator "  workspace agent executables --name api --kind codex    # the program workspace api's settings pick for codex"
          opts.separator "  workspace agent executables --json    # one JSON document, for a script"
        end
        parser.parse!(args)
        return invocation.output.puts(parser.help) if help

        raise UsageError, "Unexpected argument: #{args.first}\n\n#{parser.help}" if args.any?
        raise Error, "workspace agent executables is not available in this build" unless @agent_executables_command

        @agent_executables_command.call(name: name, detected: name ? nil : @project_detector.detect(@working_dir), kind: kind, json: json)
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
            workspace agent status request --pane %19    # ask the agent in pane %19 for a status line
            workspace agent status request --name api --pane 0.1 --json    # a named workspace, the pane as window.pane, JSON out
            workspace agent status post --summary "Writing specs for the parser"    # an agent reports its own status
            workspace agent status post --reply-to sr-0a1b2c3d4e5f --summary "Waiting on CI" --progress 3/7    # answer a request
        HELP
      end

      def agent_status(args, invocation)
        verb = args.first&.start_with?("-") ? nil : args.shift
        case verb
        when "request" then agent_status_request(args)
        when "post" then agent_status_post(args)
        when "help", nil
          unless verb == "help" || @common.help_requested?(args)
            raise UsageError, "Missing agent status verb (request or post).\n\n#{agent_status_help}"
          end
          invocation.output.puts agent_status_help
        else
          raise UsageError, "Unknown agent status verb: #{verb}.\n\n#{agent_status_help}"
        end
      end

      def agent_status_request(args)
        name = nil
        pane = nil
        json = false
        parser = OptionParser.new do |opts|
          opts.banner = "Usage: workspace agent status request --pane PANE [--name NAME] [--json]"
          opts.separator ""
          opts.separator "Ask the agent in one pane for a status line. The agent daemon types a fixed line"
          opts.separator "carrying a request id; the agent answers with `workspace agent status post --reply-to ID`."
          opts.separator "Nothing is typed unless the pane can take text safely (see `agent status --help`); when it can,"
          opts.separator "the line is typed into that pane for real."
          opts.separator ""
          opts.separator "Options:"
          opts.on("--name NAME", "Workspace name (default: detected from cwd)") { |v| name = v }
          opts.on("--pane PANE", "Pane id (%19) or window.pane (0.1)  (required)") { |v| pane = v }
          opts.on("--json", "Print one JSON document: request_id, pane, pane_id, expires_at, delivery") { json = true }
          opts.separator ""
          opts.separator "Exit codes: 0 typed and submitted; 1 refused or failed; 2 landed but not confirmed submitted."
          opts.separator ""
          opts.separator "Examples:"
          opts.separator "  workspace agent status request --pane %19    # ask the agent in pane %19 of the project in this directory"
          opts.separator "  workspace agent status request --name api --pane 0.1    # a named workspace, the pane as window.pane"
          opts.separator "  workspace agent status request --pane %19 --json    # one JSON document with the request id"
        end
        parser.parse!(args)
        raise UsageError, "Unexpected argument: #{args.first}\n\n#{parser.help}" if args.any?
        name ||= @project_detector.detect(@working_dir)
        raise UsageError, "Missing workspace name (pass --name).\n\n#{parser.help}" if name.nil?
        raise UsageError, "Missing --pane.\n\n#{parser.help}" if pane.nil? || pane.strip.empty?
        raise Error, "workspace agent status is not available in this build" unless @agent_status_command

        @agent_status_command.request(name: name, pane: pane, json: json)
      end

      def agent_status_post(args)
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
          opts.separator "Every post writes a line to the workspace's event log; outside a tmux pane it is refused (no_pane)."
          opts.separator ""
          opts.separator "Options:"
          opts.on("--summary TEXT", "One line on what the agent is doing (required; cut to #{AgentStatusDesk::MAX_SUMMARY} characters)") { |v| summary = v }
          opts.on("--task ID", "The task being worked on") { |v| task = v }
          opts.on("--progress N/M", "Steps done out of the total, e.g. 3/7") { |v| progress = v }
          opts.on("--reply-to ID", "The status request this answers (from the typed line)") { |v| reply_to = v }
          opts.on("--json", "Print one JSON document: the line as logged, plus truncated") { json = true }
          opts.separator ""
          opts.separator "Examples:"
          opts.separator "  workspace agent status post --summary \"Writing specs for the parser\"    # report what this pane is doing"
          opts.separator "  workspace agent status post --summary \"Writing specs for the parser\" --task T3 --progress 3/7    # with the task and steps done"
          opts.separator "  workspace agent status post --reply-to sr-0a1b2c3d4e5f --summary \"Waiting on CI\"    # answer a status request"
          opts.separator "  workspace agent status post --summary \"Waiting on CI\" --json    # one JSON document, the line as logged"
        end
        parser.parse!(args)
        raise UsageError, "Unexpected argument: #{args.first}\n\n#{parser.help}" if args.any?
        raise UsageError, "Missing --summary.\n\n#{parser.help}" if summary.nil? || summary.strip.empty?
        raise UsageError, "--reply-to can't be empty.\n\n#{parser.help}" if reply_to && reply_to.strip.empty?
        raise Error, "workspace agent status is not available in this build" unless @agent_status_command

        @agent_status_command.post(summary: summary, task: task, progress: progress && Commands::AgentStatus.parse_progress(progress),
          reply_to: reply_to&.strip, json: json)
      end

      # `restart` is a subcommand only as the first word that isn't a flag or a
      # flag's value, so `--name restart` still names a workspace. With --force
      # or --ensure, which restart doesn't take, it is the workspace's name, as
      # it was before the subcommand existed (`agentd --ensure restart`).
      def agentd(args, invocation)
        index = agent_subcommand_index(args)
        if index && args[index] == "restart" && (args & AGENTD_RUN_FLAGS).empty?
          return agentd_restart(args[0...index] + args[(index + 1)..], invocation)
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

        name = @names.settle_name(invocation, name || args.shift)
        raise UsageError, "Unexpected argument: #{args.first}.\n\n#{parser.help}" if args.any?
        name ||= @project_detector.detect(@working_dir)
        raise UsageError, parser.help if name.nil?
        @names.require_known_workspace!(name)

        if ensure_running
          raise UsageError, "--ensure and --force can't be combined: --ensure never replaces a running agent.\n\n#{parser.help}" if force
          return ensure_agent(name, wc_socket, invocation)
        end

        invocation.exit_handler.exit(1) unless @agent_command.call(name: name, wc_socket: wc_socket, force: force)
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
          opts.separator "  workspace agentd restart scooter --wc-socket /tmp/wc-dev.sock    # a named project, the new agent on another coordinator socket"
          opts.separator "  workspace agentd restart scooter --json    # a named project, one JSON action document"
          opts.separator "  workspace agentd restart --name restart    # a workspace that is itself named restart"
        end
      end

      def agentd_restart(args, invocation)
        options = {json: false}
        given = args.dup
        parser = agentd_restart_parser(options)
        parser.parse!(args)
        return invocation.output.puts(parser.help) if options[:help]

        raise Error, "agentd restart is not available: no daemon command was wired" unless @daemon_command

        name = @names.settle_name(invocation, options[:name] || args.shift)
        raise UsageError, "Unexpected argument: #{args.first}. Run 'workspace agentd restart --help'." if args.any?
        name ||= @project_detector.detect(@working_dir)
        raise UsageError, "Missing workspace name.\n\n#{parser.help}" unless name
        @names.require_known_workspace!(name)

        daemon_restart(name, options, invocation)
      rescue OptionParser::ParseError, UsageError => e
        raise unless @common.json_requested?(options[:json], given)
        @common.emit_json_error(invocation, Commands::Daemon::JSON_SCHEMA_VERSION, e, message: e.message.lines.first.strip)
      end

      def ensure_agent(name, wc_socket, invocation)
        raise Error, "workspace agentd --ensure is not available in this build" unless @ensure_agent_command

        result = @ensure_agent_command.call(name: name, wc_socket: wc_socket)
        case result.status
        when :running then invocation.output.puts "agentd for #{name} is already running"
        when :started then invocation.output.puts "Started agentd for #{name}"
        when :invalid_config then invocation.exit_handler.exit(1)
        else
          invocation.error_output.puts "Error: Could not start the agent daemon for #{name}: #{result.detail}"
          invocation.exit_handler.exit(1)
        end
      end

      def sessions(args, invocation)
        json = false
        watch = false
        interval = 2
        worktrees = false
        name_opt = nil
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
          opts.on("--name WS", "The project, as an option (same as the positional [project])") { |v| name_opt = v }
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

        project = @names.pick_workspace_name(invocation, name_opt, args.first) || @project_detector.detect(@working_dir)
        raise UsageError, parser.help unless project

        result = @sessions_command.call(name: project, json: json, watch: watch, interval: interval, worktrees: worktrees)
        invocation.exit_handler.exit(result[:exit_code]) if result && !result[:exit_code].zero?
      end

      def review_parser(options)
        OptionParser.new do |opts|
          opts.banner = HelpPages.overview_usage(HelpPages::REVIEW)
          opts.separator ""
          opts.separator "Collect what you need to review a coding agent's finished work. A workspace is ready"
          opts.separator "when its agent is done (the Stop hook fired and no pane is working or waiting) and its"
          opts.separator "branch has commits its base branch (origin's default branch) lacks. A stopped workspace"
          opts.separator "is judged by its agent's last recorded state (agent_state_source \"recorded\" in --json)."
          opts.separator ""
          HelpPages.overview_verbs(HelpPages::REVIEW).each { |line| opts.separator line }
          opts.separator "Run `workspace review VERB --help` for a verb's options."
          opts.separator ""
          opts.separator "Reads only; nothing is written. A source that can't answer (no agent daemon, git or gh"
          opts.separator "failing or too slow) is reported as unavailable, never as clean."
          opts.separator ""
          opts.on("--name WS", "For show: the workspace, as an option (same as the positional WORKSPACE)") { |v| options[:name] = v }
          opts.on("--patch", "For show: include the unified patch of the diffstat's range (git.patch in --json)") { options[:patch] = true }
          opts.on("--max-bytes N", Integer, "For show --patch: most patch bytes to return, 1 to 5242880 (default 200000)") { |v| options[:max_bytes] = v }
          opts.on("--json", "Print schema-versioned JSON (see docs/README.review.md)") { options[:json] = true }
          opts.on("-h", "--help", "Show this help") { options[:help] = true }
          opts.separator ""
          opts.separator "Examples:"
          opts.separator "  workspace review    # the packet for the workspace in the current directory"
          opts.separator "  workspace review list    # what is ready in this project"
          opts.separator "  workspace review my-app.worktree-fix-login --json    # the packet for one workspace by name, as JSON"
          opts.separator "  workspace review --patch --max-bytes 50000 --json    # the packet with the patch cut at 50000 bytes"
        end
      end

      def review(args, invocation)
        return if @common.verb_help_shown?(invocation, HelpPages::REVIEW, args)

        options = {json: false}
        given = args.dup
        parser = review_parser(options)
        parser.parse!(args)
        return invocation.output.puts(parser.help) if options[:help]

        raise Error, "review is not available: no review command was wired" unless @review_command

        subcommand = args.first if %w[show list].include?(args.first)
        args.shift if subcommand
        raise UsageError, "Unexpected argument: #{args[1]}. Run 'workspace review --help'." if args.size > 1

        raise UsageError, "--name is for 'review show'; 'review list' takes a PROJECT argument instead: run 'workspace review list PROJECT' (or 'workspace review list' inside the project)." if options[:name] && subcommand == "list"

        raise UsageError, "--patch and --max-bytes are for 'review show'." if subcommand == "list" && (options[:patch] || options[:max_bytes])
        raise UsageError, "--max-bytes needs --patch." if options[:max_bytes] && !options[:patch]

        result = if subcommand == "list"
          @review_command.list(project: args.first, json: options[:json])
        else
          name = @names.pick_workspace_name(invocation, options[:name], args.first) || @project_detector.detect(@working_dir)
          raise UsageError, "Missing workspace name.\n\n#{parser.help}" unless name

          patch = options[:patch] ? {patch: options[:max_bytes] || Commands::Review::DEFAULT_PATCH_BYTES} : {}
          @review_command.show(name: name, json: options[:json], **patch)
        end
        invocation.exit_handler.exit(result[:exit_code]) unless result[:exit_code].zero?
      rescue OptionParser::ParseError, UsageError => e
        raise unless @common.json_requested?(options[:json], given)
        @common.emit_json_error(invocation, Commands::Review::JSON_SCHEMA_VERSION, e, message: e.message.lines.first.strip)
      end

      def daemon_parser(options)
        OptionParser.new do |opts|
          opts.banner = HelpPages.overview_usage(HelpPages::DAEMON)
          opts.separator ""
          opts.separator "Inspect or control a workspace's agent daemon (see `workspace agentd`)."
          HelpPages.overview_verbs(HelpPages::DAEMON).each { |line| opts.separator line }
          opts.separator "Run `workspace daemon VERB --help` for a verb's options."
          opts.separator ""
          opts.on("--name NAME", "Workspace name (defaults to WORKSPACE or the project detected from the current directory)") { |v| options[:name] = v }
          opts.on("--lines N", Integer, "log: how many trailing lines (default #{Commands::Daemon::DEFAULT_LINES})") { |v| options[:lines] = v }
          opts.on("--wc-socket PATH", "restart: work-coordinator socket for the new daemon (default: the old daemon's)") { |v| options[:wc_socket] = v }
          opts.on("--all", "restart: restart every running daemon instead of one workspace") { options[:all] = true }
          opts.on("--json", "Print one JSON document (see docs/README.daemon.md)") { options[:json] = true }
          opts.on("-h", "--help", "Show this help") { options[:help] = true }
          opts.separator ""
          opts.separator "Examples:"
          opts.separator "  workspace daemon list    # every running daemon"
          opts.separator "  workspace daemon status my-app    # is its daemon answering"
          opts.separator "  workspace daemon log my-app --lines 100    # the last 100 lines of its log"
          opts.separator "  workspace daemon restart my-app --json    # one JSON action document"
          opts.separator "  workspace daemon restart --all    # SIGTERM each running daemon and start it again"
        end
      end

      def daemon(args, invocation)
        return if @common.verb_help_shown?(invocation, HelpPages::DAEMON, args)

        options = {json: false}
        given = args.dup
        parser = daemon_parser(options)
        subcommand = args.shift if DAEMON_SUBCOMMANDS.include?(args.first)
        parser.parse!(args)
        subcommand ||= args.shift if DAEMON_SUBCOMMANDS.include?(args.first)
        return invocation.output.puts(parser.help) if options[:help]

        raise UsageError, "Missing subcommand: one of #{DAEMON_SUBCOMMANDS.join(", ")}.\n\n#{parser.help}" unless subcommand
        raise Error, "daemon is not available: no daemon command was wired" unless @daemon_command

        raise UsageError, "--all only applies to `daemon restart`." if options[:all] && subcommand != "restart"
        raise UsageError, "--lines only applies to `daemon log`." if options[:lines] && subcommand != "log"
        if subcommand == "list" || options[:all]
          what = (subcommand == "list") ? "daemon list" : "daemon restart --all"
          raise UsageError, "#{what} takes no workspace: it covers every running daemon." if options[:name] || args.any?
          raise UsageError, "--wc-socket can't be combined with --all: each daemon keeps its own." if options[:all] && options[:wc_socket]
          raise UsageError, "--wc-socket only applies to `daemon restart`." if options[:wc_socket]

          return (subcommand == "list") ? @daemon_command.list(json: options[:json]) : daemon_restart_all(options, invocation)
        end

        name = @names.settle_name(invocation, options[:name] || args.shift)
        raise UsageError, "Unexpected argument: #{args.first}. Run 'workspace daemon --help'." if args.any?
        name ||= @project_detector.detect(@working_dir)
        raise UsageError, "Missing workspace name.\n\n#{parser.help}" unless name
        raise UsageError, "--wc-socket only applies to `daemon restart`." if options[:wc_socket] && subcommand != "restart"

        result = case subcommand
        when "status" then @daemon_command.status(name: name, json: options[:json])
        when "log" then @daemon_command.log(name: name, lines: options[:lines], json: options[:json])
        else daemon_restart(name, options, invocation)
        end
        invocation.exit_handler.exit(result[:exit_code]) if result && !result[:exit_code].to_i.zero?
      rescue OptionParser::ParseError, UsageError => e
        raise unless @common.json_requested?(options[:json], given)
        @common.emit_json_error(invocation, Commands::Daemon::JSON_SCHEMA_VERSION, e, message: e.message.lines.first.strip)
      end

      # Shared by `daemon restart` and `agentd restart`. The caller's socket
      # path is made absolute so a later restart can read it back from the
      # daemon's command line.
      def daemon_restart(name, options, invocation)
        wc_socket = options[:wc_socket] && File.expand_path(options[:wc_socket], @working_dir)
        @common.run_action(invocation, "restart", json: options[:json]) do
          restarted = @daemon_command.restart(name: name, wc_socket: wc_socket)
          if restarted.ok?
            verb = (restarted.outcome == "restarted") ? "Restarted" : "Started"
            pids = [restarted.old_pid, restarted.pid].compact.join(" -> ")
            invocation.output.puts "#{verb} agentd for #{name}#{" (pid #{pids})" unless pids.empty?}"
            invocation.output.puts "Kept its work-coordinator socket: #{restarted.wc_socket}" if restarted.wc_socket && !options[:wc_socket]
          else
            invocation.error_output.puts "Error: #{restarted.message}"
          end
          row = @common.action_row(name, restarted.outcome, reason: restarted.reason, message: restarted.message,
            old_pid: restarted.old_pid, pid: restarted.pid, wc_socket: restarted.wc_socket)
          {exit_code: restarted.ok? ? 0 : 1, results: [row]}
        end
      end

      # `daemon restart --all`: restarts every running daemon and reports a row
      # for each. Any failed row makes the exit status non-zero.
      def daemon_restart_all(options, invocation)
        @common.run_action(invocation, "restart", json: options[:json]) do
          restarted = @daemon_command.restart_all
          invocation.output.puts "No agentd processes are running." if restarted.empty?
          restarted.each do |name, r|
            if r.ok?
              verb = (r.outcome == "restarted") ? "Restarted" : "Started"
              pids = [r.old_pid, r.pid].compact.join(" -> ")
              invocation.output.puts "#{verb} agentd for #{name}#{" (pid #{pids})" unless pids.empty?}"
            else
              invocation.error_output.puts "Error: #{name}: #{r.message}"
            end
          end
          rows = restarted.map do |name, r|
            @common.action_row(name, r.outcome, reason: r.reason, message: r.message, old_pid: r.old_pid, pid: r.pid, wc_socket: r.wc_socket)
          end
          {exit_code: (restarted.all? { |_, r| r.ok? }) ? 0 : 1, results: rows}
        end
      end
    end
  end
end
