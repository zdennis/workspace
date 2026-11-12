require "optparse"
require "json"
require "securerandom"

module Workspace
  class CLI
    # The `agent-run` and `handoff` verbs, and `agent run PROMPT`, which {CLI::Agent} hands here:
    # parses their arguments with the same usage text the CLI always printed, hands the parsed
    # values to their commands ({Commands::RestartAgent}, {Commands::Send}, {Commands::PromptQueue},
    # {Commands::Handoff}), and sends the `command` and `inject` messages it builds through an
    # {AgentMessageClient}. It writes and exits only through the {Invocation} it is given, so
    # `--help --json` captures what it prints.
    class AgentRun
      # @param config [Workspace::Config] names the agent socket a message is sent to
      # @param agent_client [Workspace::AgentMessageClient] sends one message to a workspace's agent daemon
      # @param restart_agent_command [Workspace::Commands::RestartAgent, nil] `agent-run restart`; nil refuses it
      # @param send_command [Workspace::Commands::Send, nil] `agent-run send`; nil refuses it
      # @param prompt_queue_command [Workspace::Commands::PromptQueue, nil] `agent-run queue`; nil refuses it
      # @param handoff_command [Workspace::Commands::Handoff, nil] `handoff check` and `handoff new`; nil refuses them
      # @param project_detector [Workspace::ProjectDetector] finds the workspace of the working directory
      # @param common [CLI::Common] the output, exit and help helpers
      # @param names [CLI::Names] settles and checks the workspace names given
      # @param working_dir [String] the directory the CLI runs from
      def initialize(config:, agent_client:, restart_agent_command:, send_command:, prompt_queue_command:, handoff_command:,
        project_detector:, common:, names:, working_dir:)
        @config = config
        @agent_client = agent_client
        @restart_agent_command = restart_agent_command
        @send_command = send_command
        @prompt_queue_command = prompt_queue_command
        @handoff_command = handoff_command
        @project_detector = project_detector
        @common = common
        @names = names
        @working_dir = working_dir
      end

      # Runs one `agent-run` or `handoff` command line.
      #
      # @param verb [String] the verb {CLI::ROUTES} sent here
      # @param args [Array<String>] the arguments after the verb (changed in place)
      # @param invocation [Invocation] the run's streams, exit handler and flags
      # @return [void]
      # @raise [Workspace::UsageError, Workspace::Error] without `--json`, for the CLI's rescue funnel to report
      def call(verb, args, invocation)
        case verb
        when "agent-run" then agent_run(args, invocation)
        when "handoff" then handoff(args, invocation)
        end
      end

      # `workspace agent run PROMPT`: the prompt is the positional arguments
      # joined with a space, so a multi-word prompt needs no quoting. Everything
      # else matches `agent-run command` minus the default body — the prompt
      # positional is required.
      #
      # @param args [Array<String>] the arguments after `agent run`
      # @param invocation [Invocation] the run's streams, exit handler and flags
      # @return [void]
      # @raise [Workspace::UsageError] for the CLI's rescue funnel to report
      def prompt(args, invocation)
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
          opts.separator ""
          opts.separator "Examples:"
          opts.separator "  workspace agent run Add OAuth support    # send the prompt to the project in this directory; no quotes needed"
          opts.separator "  workspace agent run --name myapp \"Run the linter and report any issues\"    # a named workspace"
          opts.separator "  workspace agent run --dry-run \"Add OAuth support\"    # print the message, send nothing"
          opts.separator "  workspace agent run --work-item WC-42 \"Fix the flaky spec\"    # tie the prompt to a work item"
          opts.separator "  workspace agent run --json \"Add OAuth support\"    # one JSON document with the reply; exits 0 whatever it says"
        end
        parser.parse!(args)

        name ||= @project_detector.detect(@working_dir)
        raise UsageError, "Missing workspace name.\n\n#{parser.help}" if name.nil?

        prompt = args.join(" ")
        raise UsageError, "Missing prompt.\n\n#{parser.help}" if prompt.empty?
        work_item ||= SecureRandom.uuid

        unless json
          message = build_command_message(invocation, name: name, work_item: work_item, body: prompt, dispatch_prefix: "agent-run-")
          send_message(invocation, name, message, dry_run: dry_run)
          return
        end

        # Not an action document (the agent's reply is the result), so it diverts and prints by hand.
        message = reply = nil
        @common.divert_output(invocation) do
          message = build_command_message(invocation, name: name, work_item: work_item, body: prompt, dispatch_prefix: "agent-run-")
          reply = send_message(invocation, name, message, dry_run: dry_run)
        end
        doc = {"schema_version" => Common::ACTION_JSON_SCHEMA_VERSION, "ok" => true, "workspace" => name,
               "work_item_ref" => work_item, "dispatch_id" => message["dispatch_id"], "dry_run" => dry_run}
        doc[dry_run ? "message" : "reply"] = dry_run ? message : reply
        invocation.output.puts JSON.generate(doc)
      rescue OptionParser::ParseError => e
        raise UsageError, "#{e.message}\nIf the prompt starts with a dash or looks like a flag, pass it after --.\n\n#{parser.help}"
      end

      private

      # Sends a raw JSONL message to a running agent socket for manual testing and
      # exploration. Always pretty-prints what is being sent before sending it.
      #
      # Usage with a subcommand (--work-item defaults to a random UUID):
      #   workspace agent-run command --work-item WC-42
      #
      # Usage with raw JSON body (workspace is read from the message):
      #   workspace agent-run --body '{"type":"command","workspace":"myproject",...}'
      def agent_run(args, invocation)
        body = nil
        dry_run = false
        help = false

        # Peek for --body / --dry-run before deciding whether to dispatch to a
        # subcommand. OptionParser would consume them anyway; doing it here lets
        # us keep a clean subcommand path for the common case.
        parser = OptionParser.new do |opts|
          opts.on("--body JSON", "Full message JSON to send directly (workspace read from message)") { |v| body = v }
          opts.on("--dry-run", "Print without sending") { dry_run = true }
          opts.on("-h", "--help", "Show this help") { help = true }
        end
        parser.order!(args)  # stops at the first non-option so subcommand words survive

        return invocation.output.puts(agent_run_help) if help
        return if @common.verb_help_shown?(invocation, HelpPages::AGENT_RUN, args)

        if body
          return agent_run_raw(invocation, body, dry_run: dry_run)
        end

        subcommand = args.shift
        case subcommand
        when "command" then agent_run_command(args, invocation)
        when "inject" then agent_run_inject(args, invocation)
        when "restart" then agent_run_restart(args, invocation)
        when "send" then agent_run_send(args, invocation)
        when "queue" then agent_run_queue(args, invocation)
        when "examples" then agent_run_examples(invocation)
        when "help" then invocation.output.puts agent_run_help
        else
          raise UsageError, agent_run_help
        end
      end

      # Parses +body+ as the full message JSON, compacts it to one line, and
      # sends it directly to the agent socket named in the message's "workspace"
      # field. Useful for copy-pasting an example and firing it immediately.
      def agent_run_raw(invocation, body, dry_run: false)
        message = begin
          JSON.parse(jsonl_body(invocation, body))
        rescue JSON::ParserError => e
          raise UsageError, "Invalid JSON in --body: #{e.message}"
        end

        name = message["workspace"]
        raise UsageError, "Message JSON must include a \"workspace\" key" if name.nil? || name.empty?

        send_message(invocation, name, message, dry_run: dry_run)
      end

      def agent_run_help
        <<~HELP
          Usage: workspace agent-run <subcommand> [options]
                 workspace agent-run --body '<full message JSON>' [--dry-run]

          Send a raw JSONL message to a running agent socket.
          Always prints the message being sent before sending it.

          Subcommands:
          #{HelpPages.overview_verbs(HelpPages::AGENT_RUN).join("\n")}

          Raw mode (paste a full message directly):
            --body JSON         Complete message JSON; workspace is read from the message
            --dry-run           Print without sending

          Run `workspace agent-run VERB --help` for a verb's options.

          Examples:
            workspace agent-run command --body "Add OAuth support"    # send a task to the current directory's workspace
            workspace agent-run command --name myapp --dry-run    # see the message for a named workspace, send nothing
            workspace agent-run inject --work-item WC-42 --body "Use Postgres, not SQLite"    # steer a running work item
            workspace agent-run restart --pane %18 --prompt "Resume from HANDOFF.md"    # clear a pane's agent and give it a prompt
            workspace agent-run send --pane %19 --body "yes"    # type into a pane and press Enter
            workspace agent-run queue list    # what `send --when-idle` has queued
            workspace agent-run queue cancel --id 3f9a2c41d07b5e88    # take a queued prompt back
            workspace agent-run --body '{"type":"command","workspace":"myapp","work_item_ref":"WC-42","dispatch_id":"debug-1","body":"go"}' --dry-run    # a full message you wrote
            workspace agent-run examples    # stock messages to copy, nothing sent
        HELP
      end

      def agent_run_command(args, invocation)
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

        message = build_command_message(invocation, name: name, work_item: work_item, body: body)
        send_message(invocation, name, message, dry_run: dry_run)
      end

      # Builds the "command" message shared by `agent run` and
      # `agent-run command`.
      def build_command_message(invocation, name:, work_item:, body:, dispatch_prefix: "debug-")
        AgentProtocol.command(workspace: name, work_item_ref: work_item,
          dispatch_id: "#{dispatch_prefix}#{SecureRandom.hex(4)}", body: jsonl_body(invocation, body || "Begin work."))
      end

      def agent_run_inject(args, invocation)
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

        message = AgentProtocol.inject(workspace: name, work_item_ref: work_item, interrupt: interrupt, body: jsonl_body(invocation, body))
        send_message(invocation, name, message, dry_run: dry_run)
      end

      # Asks the agent daemon to /clear the coding agent in one named pane and,
      # once its context usage has dropped, type a prompt into it.
      def agent_run_restart(args, invocation)
        name = nil
        pane = nil
        prompt = nil
        force = false
        wait = false
        timeout = nil
        json = false

        parser = OptionParser.new do |opts|
          opts.on("--name NAME") { |v| name = v }
          opts.on("--pane PANE") { |v| pane = v }
          opts.on("--prompt TEXT") { |v| prompt = v }
          opts.on("--force") { force = true }
          opts.on("--wait") { wait = true }
          opts.on("--timeout DURATION") { |v| timeout = @common.parse_duration_option("--timeout", v, positive: true) }
          opts.on("--json") { json = true }
        end
        parser.parse!(args)
        page = HelpPages.render(HelpPages::AGENT_RUN.fetch("restart")).join("\n")
        raise UsageError, "Unexpected argument: #{args.first}\n\n#{page}" if args.any?

        name ||= @project_detector.detect(@working_dir)
        raise UsageError, "Missing workspace name (pass --name).\n\n#{page}" if name.nil?
        raise UsageError, "Missing --pane.\n\n#{page}" if pane.nil? || pane.strip.empty?
        raise UsageError, "Missing --prompt.\n\n#{page}" if prompt.nil? || prompt.strip.empty?
        if timeout && timeout > Commands::Agent::MAX_RESTART_TIMEOUT
          raise UsageError, "--timeout: at most #{Commands::Agent::MAX_RESTART_TIMEOUT}s"
        end
        raise Error, "workspace agent-run restart is not available in this build" unless @restart_agent_command

        result = @restart_agent_command.call(name: name, pane: pane, prompt: prompt, force: force, wait: wait,
          timeout: timeout, json: json)
        invocation.exit_handler.exit(result[:exit_code]) unless result[:exit_code].zero?
      rescue OptionParser::ParseError, UsageError => e
        raise unless @common.json_requested?(json, args)
        @common.emit_json_error(invocation, Commands::RestartAgent::JSON_SCHEMA_VERSION, e, message: e.message.lines.first.strip)
      end

      # Types text or tmux key names into one named pane. The pane must be a
      # pane id or window.pane of the workspace's own tmux session; there is
      # no default pane. See {Workspace::Commands::Send}.
      def agent_run_send(args, invocation)
        name = nil
        pane = nil
        body = nil
        keys = nil
        no_enter = false
        when_idle = false
        clear_first = false
        interrupt = false
        json = false

        parser = OptionParser.new do |opts|
          opts.on("--name NAME") { |v| name = v }
          opts.on("--pane PANE") { |v| pane = v }
          opts.on("--body TEXT") { |v| body = v }
          opts.on("--keys KEYS") { |v| keys = v }
          opts.on("--no-enter") { no_enter = true }
          opts.on("--when-idle") { when_idle = true }
          opts.on("--clear-first") { clear_first = true }
          opts.on("--interrupt") { interrupt = true }
          opts.on("--json") { json = true }
        end
        parser.parse!(args)
        page = HelpPages.render(HelpPages::AGENT_RUN.fetch("send")).join("\n")
        raise UsageError, "Unexpected argument: #{args.first}\n\n#{page}" if args.any?

        name ||= @project_detector.detect(@working_dir)
        raise UsageError, "Missing workspace name (pass --name).\n\n#{page}" if name.nil?
        raise UsageError, "Missing --pane.\n\n#{page}" if pane.nil? || pane.strip.empty?
        raise UsageError, "Pass --body or --keys, not both.\n\n#{page}" if body && keys
        raise UsageError, "Missing --body or --keys.\n\n#{page}" if body.nil? && keys.nil?
        raise UsageError, "--body can't be empty.\n\n#{page}" if body && body.empty?
        raise UsageError, "--no-enter applies to --body; --keys never presses Enter on its own.\n\n#{page}" if no_enter && keys
        [["--when-idle", when_idle], ["--clear-first", clear_first]].each do |flag, given|
          raise UsageError, "#{flag} takes --body, not --keys.\n\n#{page}" if given && keys
          raise UsageError, "#{flag} always presses Enter; drop --no-enter.\n\n#{page}" if given && no_enter
        end
        if interrupt
          raise UsageError, "--interrupt takes --body, not --keys.\n\n#{page}" if keys
          raise UsageError, "--interrupt always presses Enter; drop --no-enter.\n\n#{page}" if no_enter
          if when_idle || clear_first
            raise UsageError, "--interrupt types now or not at all; it does not combine with --when-idle or --clear-first.\n\n#{page}"
          end
        end
        raise Error, "workspace agent-run send is not available in this build" unless @send_command
        return @send_command.interrupt_through_daemon(name: name, pane: pane, body: body, json: json) if interrupt
        if when_idle || clear_first
          return @send_command.through_daemon(name: name, pane: pane, body: body, when_idle: when_idle,
            clear_first: clear_first, json: json)
        end

        key_names = keys && Commands::Send.parse_keys(keys)
        @send_command.call(name: name, pane: pane, body: body, keys: key_names, enter: !no_enter, json: json)
      end

      def agent_run_queue_help
        HelpPages.render(HelpPages::AGENT_RUN.fetch("queue")).join("\n") + "\n"
      end

      def agent_run_queue(args, invocation)
        verb = args.shift
        case verb
        when "list" then agent_run_queue_list(args, invocation)
        when "cancel" then agent_run_queue_cancel(args, invocation)
        when "-h", "--help", "help" then invocation.output.puts agent_run_queue_help
        when nil then raise UsageError, "Missing queue verb (list or cancel).\n\n#{agent_run_queue_help}"
        else raise UsageError, "Unknown queue verb: #{verb}.\n\n#{agent_run_queue_help}"
        end
      end

      def agent_run_queue_list(args, invocation)
        name = nil
        pane = nil
        json = false
        parser = OptionParser.new do |opts|
          opts.banner = "Usage: workspace agent-run queue list [--name NAME] [--pane PANE] [--json]"
          opts.on("--name NAME", "Workspace name (default: detected from cwd)") { |v| name = v }
          opts.on("--pane PANE", "Only this pane: a pane id (%19) or window.pane (0.1)") { |v| pane = v }
          opts.on("--json", "Print {\"entries\":[...]} as JSON; errors as {\"schema_version\":1,\"ok\":false,\"error\":...}") { json = true }
        end
        parser.parse!(args)
        raise UsageError, "Unexpected argument: #{args.first}\n\n#{parser.help}" if args.any?
        name ||= @project_detector.detect(@working_dir)
        raise UsageError, "Missing workspace name (pass --name).\n\n#{parser.help}" if name.nil?
        raise UsageError, "--pane can't be empty.\n\n#{parser.help}" if pane && pane.strip.empty?
        raise Error, "workspace agent-run queue is not available in this build" unless @prompt_queue_command

        @prompt_queue_command.list(name: name, pane: pane, json: json)
      end

      def agent_run_queue_cancel(args, invocation)
        name = nil
        id = nil
        json = false
        parser = OptionParser.new do |opts|
          opts.banner = "Usage: workspace agent-run queue cancel --id ID [--name NAME] [--json]"
          opts.on("--id ID", "The id `send --when-idle` answered  (required)") { |v| id = v }
          opts.on("--name NAME", "Workspace name (default: look through every workspace's queue)") { |v| name = v }
          opts.on("--json", "Print {\"cancelled\":true,\"id\",\"pane_id\",\"text\"} as JSON; errors as {\"schema_version\":1,\"ok\":false,\"error\":...}") { json = true }
        end
        parser.parse!(args)
        raise UsageError, "Unexpected argument: #{args.first}\n\n#{parser.help}" if args.any?
        raise UsageError, "Missing --id.\n\n#{parser.help}" if id.nil? || id.strip.empty?
        raise Error, "workspace agent-run queue is not available in this build" unless @prompt_queue_command

        @prompt_queue_command.cancel(id: id.strip, name: name, json: json)
      end

      def handoff_help
        <<~HELP
          #{HelpPages.overview_usage(HelpPages::HANDOFF)}

          Watches a coding agent's context-window usage and hands off to a fresh
          conversation before it fills up: `check` tells the agent to save its state
          once usage crosses a threshold, `new` clears the conversation and resumes it
          (the same flow as `workspace agent-run restart`).

          #{HelpPages.overview_verbs(HelpPages::HANDOFF).join("\n")}
          Run `workspace handoff VERB --help` for a verb's options.

          Examples:
            workspace handoff check    # this project's agent: a save-state prompt only if it is over the threshold
            workspace handoff check myapp --threshold 20 --json    # a named workspace, for a script
            workspace handoff new    # restart the first Claude Code pane (else Codex) of this project, which may not be yours
            workspace handoff new myapp --pane "$TMUX_PANE"    # an agent restarting its own pane
        HELP
      end

      # Dispatches `workspace handoff check|new`. Never guesses a pane or a
      # context percentage; see {Workspace::Commands::Handoff}.
      def handoff(args, invocation)
        original_args = args.dup
        subcommand = args.shift
        case subcommand
        when "check", "new"
          send(:"handoff_#{subcommand}", args, invocation) unless @common.verb_help_shown?(invocation, HelpPages::HANDOFF, [subcommand, *args])
        when "help", "--help", "-h" then invocation.output.puts handoff_help
        else
          raise UsageError, handoff_help
        end
      rescue UsageError => e
        raise unless @common.json_requested?(false, original_args)
        @common.emit_json_error(invocation, Commands::Handoff::JSON_SCHEMA_VERSION, e, message: e.message.lines.first.strip)
      end

      def handoff_check(args, invocation)
        pane = nil
        threshold = nil
        context_pct = nil
        handoff_doc = nil
        handoff_prompt = nil
        json = false
        name_opt = nil

        page = HelpPages.render(HelpPages::HANDOFF.fetch("check")).join("\n")
        parser = OptionParser.new do |opts|
          opts.on("--name WS") { |v| name_opt = v }
          opts.on("--pane PANE") { |v| pane = v }
          opts.on("--threshold PCT") { |v| threshold = v }
          opts.on("--context-pct N", Integer) { |v| context_pct = v }
          opts.on("--handoff-doc PATH") { |v| handoff_doc = v }
          opts.on("--handoff-prompt TEXT") { |v| handoff_prompt = v }
          opts.on("--json") { json = true }
        end
        parser.parse!(args)
        raise UsageError, "--handoff-doc and --handoff-prompt are mutually exclusive.\n\n#{page}" if handoff_doc && handoff_prompt
        if threshold
          begin
            threshold = HandoffConfig.parse_threshold(threshold)
          rescue ArgumentError => e
            raise UsageError, "--threshold #{e.message}\n\n#{page}"
          end
        end

        name = @names.pick_workspace_name(invocation, name_opt, args.shift)
        name ||= @project_detector.detect(@working_dir)
        raise UsageError, "Missing workspace name.\n\n#{page}" if name.nil?
        raise UsageError, "Unexpected argument: #{args.first}\n\n#{page}" if args.any?
        raise Error, "workspace handoff is not available in this build" unless @handoff_command

        result = @handoff_command.check(name: name, pane: pane, threshold: threshold, context_pct: context_pct,
          handoff_doc: handoff_doc, handoff_prompt: handoff_prompt, json: json)
        invocation.exit_handler.exit(result[:exit_code]) unless result[:exit_code].zero?
      rescue OptionParser::ParseError, UsageError, Error => e
        raise unless @common.json_requested?(json, args)
        @common.emit_json_error(invocation, Commands::Handoff::JSON_SCHEMA_VERSION, e, message: e.message.lines.first.strip)
      end

      def handoff_new(args, invocation)
        pane = nil
        handoff_doc = nil
        handoff_prompt = nil
        wait = false
        json = false
        name_opt = nil

        page = HelpPages.render(HelpPages::HANDOFF.fetch("new")).join("\n")
        parser = OptionParser.new do |opts|
          opts.on("--name WS") { |v| name_opt = v }
          opts.on("--pane PANE") { |v| pane = v }
          opts.on("--handoff-doc PATH") { |v| handoff_doc = v }
          opts.on("--handoff-prompt TEXT") { |v| handoff_prompt = v }
          opts.on("--wait") { wait = true }
          opts.on("--json") { json = true }
        end
        parser.parse!(args)
        raise UsageError, "--handoff-doc and --handoff-prompt are mutually exclusive.\n\n#{page}" if handoff_doc && handoff_prompt

        name = @names.pick_workspace_name(invocation, name_opt, args.shift)
        name ||= @project_detector.detect(@working_dir)
        raise UsageError, "Missing workspace name.\n\n#{page}" if name.nil?
        raise UsageError, "Unexpected argument: #{args.first}\n\n#{page}" if args.any?
        raise Error, "workspace handoff is not available in this build" unless @handoff_command

        result = @handoff_command.new(name: name, pane: pane, handoff_doc: handoff_doc, handoff_prompt: handoff_prompt, wait: wait, json: json)
        invocation.exit_handler.exit(result[:exit_code]) unless result[:exit_code].zero?
      rescue OptionParser::ParseError, Error => e
        raise unless @common.json_requested?(json, args)
        @common.emit_json_error(invocation, Commands::Handoff::JSON_SCHEMA_VERSION, e, message: e.message.lines.first.strip)
      end

      def agent_run_examples(invocation)
        name = @project_detector.detect(@working_dir) || "workspace"

        examples = [
          {
            label: "command — check GitHub CI status (safe, read-only)",
            cli: "workspace agent-run command --work-item WC-42 --body \"What is the current status of GitHub CI for this branch?\"",
            message: AgentProtocol.command(workspace: name, work_item_ref: "WC-42", dispatch_id: "debug-abcd1234",
              body: "What is the current status of GitHub CI for this branch?")
          },
          {
            label: "command — run the linter (safe, re-runnable)",
            cli: "workspace agent-run command --work-item WC-42 --body \"Run the linter and report any issues.\"",
            message: AgentProtocol.command(workspace: name, work_item_ref: "WC-42", dispatch_id: "debug-abcd1234",
              body: "Run the linter and report any issues.")
          },
          {
            label: "inject — queue a steer for the next pipeline stage",
            cli: "workspace agent-run inject --work-item WC-42 --body \"Focus on the failing tests, not the linter warnings.\"",
            message: AgentProtocol.inject(workspace: name, work_item_ref: "WC-42", interrupt: false,
              body: "Focus on the failing tests, not the linter warnings.")
          },
          {
            label: "inject --interrupt — urgent steer: stop current stage and redirect",
            cli: "workspace agent-run inject --interrupt --work-item WC-42 --body \"Stop. Run bundle exec rspec spec/system/workspace/cli_spec.rb first.\"",
            message: AgentProtocol.inject(workspace: name, work_item_ref: "WC-42", interrupt: true,
              body: "Stop. Run bundle exec rspec spec/system/workspace/cli_spec.rb first.")
          },
          {
            label: "restart — clear the coding agent in one pane and hand it a fresh prompt",
            cli: "workspace agent-run restart --pane 0.1 --prompt \"Read HANDOFF.md and follow it.\" --wait",
            message: AgentProtocol.restart_agent(workspace: name, pane: "0.1", prompt: "Read HANDOFF.md and follow it.",
              force: false, wait: true)
          }
        ]

        examples.each_with_index do |example, i|
          invocation.output.puts "#{i + 1}. #{example[:label]}"
          invocation.output.puts "   Run it: #{example[:cli]}"
          invocation.output.puts "   JSONL (sent as a single line):"
          JSON.pretty_generate(example[:message]).each_line do |line|
            invocation.output.puts "   #{line}"
          end
          invocation.output.puts unless i == examples.size - 1
        end
      end

      # If +body+ looks like JSON (parses successfully), compact it to a single
      # line so it travels safely as JSONL. Plain strings pass through unchanged.
      def jsonl_body(invocation, body)
        parsed = JSON.parse(body)
        compacted = parsed.to_json
        if compacted != body.strip
          invocation.output.puts "(body compacted to JSONL)"
        end
        compacted
      rescue JSON::ParserError
        body
      end

      # Pretty-prints +message+ as the JSONL that will be sent, then sends it
      # (unless +dry_run+ is true) and pretty-prints the reply.
      def send_message(invocation, name, message, dry_run: false)
        socket_path = @config.agent_socket_path(name)
        invocation.output.puts "Sending JSONL to #{socket_path}:"
        JSON.pretty_generate(message).each_line { |line| invocation.output.puts "  #{line}" }

        if dry_run
          invocation.output.puts "(dry-run: not sent)"
          return
        end

        invocation.output.puts
        reply = @agent_client.call(name, message)
        invocation.output.puts "Reply:"
        JSON.pretty_generate(reply).each_line { |line| invocation.output.puts "  #{line}" }
        reply
      end
    end
  end
end
