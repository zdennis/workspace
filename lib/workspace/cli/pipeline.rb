require "optparse"
require "json"
require "securerandom"
require "shellwords"
require "time"

module Workspace
  class CLI
    # The deprecated `pipeline` verb: parses its subcommands with the same usage text the CLI
    # always printed, reads and resets a workspace's pipeline state through {PipelineState}, and
    # sends the `command` and `inject` messages it builds through an {AgentMessageClient}. It
    # writes and exits only through the {Invocation} it is given, so `--help --json` captures
    # what it prints.
    #
    # These are operator tools: everything that touches a pane goes through the agent that owns
    # it, so a manual nudge cannot get the agent's own view of the pipeline out of step.
    class Pipeline
      # Printed by every `pipeline` subcommand and in its help.
      DEPRECATION = "`workspace pipeline` is deprecated and will be removed in a later release. " \
        "Use `workspace workflow` (see `workspace workflow --help`)."

      # `workspace pipeline status --json`'s schema version.
      JSON_SCHEMA_VERSION = 1

      # @param config [Workspace::Config] names each workspace's pipeline state file and says whether its agent runs
      # @param agent_client [Workspace::AgentMessageClient] sends one message to a workspace's agent daemon
      # @param common [CLI::Common] the output, exit and help helpers
      # @param names [CLI::Names] settles the workspace names given
      # @param clock [#call] returns the current Time, for the relative deadline in `status`
      def initialize(config:, agent_client:, common:, names:, clock: -> { Time.now })
        @config = config
        @agent_client = agent_client
        @common = common
        @names = names
        @clock = clock
      end

      # Runs one `pipeline` command line. The subcommand is the first non-option argument, so a
      # leading flag (e.g. `pipeline --json status`) is dispatched correctly wherever it appears.
      #
      # @param _verb [String] the verb {CLI::ROUTES} sent here (`pipeline`)
      # @param args [Array<String>] the arguments after the verb
      # @param invocation [Invocation] the run's streams, exit handler and flags
      # @return [void]
      # @raise [Workspace::UsageError, Workspace::Error] without `--json`, for the CLI's rescue funnel to report
      def call(_verb, args, invocation)
        index = args.index { |a| !a.start_with?("-") }
        subcommand = index && args[index]
        rest = index ? args[0...index] + args[(index + 1)..] : args

        # With --json the notice is in an action document's `warnings` instead, and stderr stays empty.
        invocation.error_output.puts "Warning: #{DEPRECATION}" if %w[start advance status reset].include?(subcommand) && !rest.include?("--json")
        return if subcommand && @common.verb_help_shown?(invocation, HelpPages::PIPELINE, [subcommand, *rest])

        case subcommand
        when "start" then start(rest, invocation)
        when "advance" then advance(rest, invocation)
        when "status" then status(rest, invocation)
        when "reset" then reset(rest, invocation)
        when "help", nil then invocation.output.puts help
        else
          raise UsageError, help
        end
      end

      private

      def help
        <<~HELP
          #{HelpPages.overview_usage(HelpPages::PIPELINE)}

          Deprecated: use `workspace workflow`, which runs ordered steps in a workspace's agent pane
          and shows where a run is stuck. `pipeline` will be removed in a later release.

          #{HelpPages.overview_verbs(HelpPages::PIPELINE).join("\n")}

          Examples:
          #{HelpPages.overview_examples(HelpPages::PIPELINE).join("\n")}
            workspace pipeline start --help    # read the page of one subcommand
        HELP
      end

      def start(args, invocation)
        project, work_item, body, json = parse_args(args, "start", invocation)
        raise UsageError, "Missing project or --work-item.\n\n#{page("start")}" if project.nil? || work_item.nil?

        @common.run_action(invocation, "pipeline start", json: json) do
          reply = @agent_client.call(project,
            AgentProtocol.command(workspace: project, work_item_ref: work_item,
              dispatch_id: "manual-#{SecureRandom.hex(4)}", body: body || "Begin work on #{work_item}."))
          raise Error, "The agent for #{project} refused the work item: #{reply["error"]}" unless reply["ok"]
          invocation.output.puts "Sent #{work_item} into #{project}'s pipeline"
          {results: json ? [@common.action_row(project, "started", work_item_ref: work_item)] : [], warnings: [DEPRECATION]}
        end
      end

      # Types the completion sentinel into the running stage's pane, which is
      # exactly what a finished stage would print, so the agent advances normally.
      #
      # The stage's token comes from the persisted state. If the stage moves on
      # between that read and the inject, the sentinel carries the old stage's
      # token and the new stage ignores it, rather than being ended unasked.
      def advance(args, invocation)
        project, work_item, body, json = parse_args(args, "advance", invocation)
        raise UsageError, "Missing project or --work-item.\n\n#{page("advance")}" if project.nil? || work_item.nil?

        @common.run_action(invocation, "pipeline advance", json: json) do
          token = read_state(project, invocation).dig(work_item, "sentinel_token")
          # The body reaches a live shell, so it is escaped rather than interpolated.
          sentinel = "#{SentinelPoller.marker(token)} #{body || "manual advance"}"
          reply = @agent_client.call(project,
            AgentProtocol.inject(workspace: project, work_item_ref: work_item, interrupt: true, expected_token: token,
              body: "echo #{Shellwords.escape(sentinel)}"))
          unless reply["ok"]
            raise Error.new("The stage moved on before the advance landed; run 'workspace pipeline advance' again", code: "stale_token") if reply["error"] == "stale_token"
            raise Error, "The agent for #{project} refused the advance: #{reply["error"]}"
          end
          invocation.output.puts "Nudged #{project}/#{work_item} to advance"
          {results: json ? [@common.action_row(project, "advanced", work_item_ref: work_item)] : [], warnings: [DEPRECATION]}
        end
      end

      def status(args, invocation)
        as_json = false
        parser = OptionParser.new do |opts|
          opts.on("--json") { as_json = true }
        end
        parser.parse!(args)
        project = @names.settle_name(invocation, args.shift)
        raise UsageError, page("status") if project.nil?

        entries = read_state(project, invocation)
        return invocation.output.puts JSON.generate({"schema_version" => JSON_SCHEMA_VERSION, "ok" => true, "entries" => entries.values}) if as_json

        if entries.empty?
          invocation.output.puts "No pipeline work in flight for #{project}"
          return
        end

        invocation.output.puts "WORK ITEM  PANE  STAGE  DEADLINE"
        entries.each_value do |entry|
          deadline = format_deadline(entry["deadline_at"])
          invocation.output.puts "#{entry["work_item_ref"]}  pane #{entry["pane_index"]}  #{entry["phase"] || "(no pipeline)"}  #{deadline}"
        end
      rescue OptionParser::ParseError, UsageError => e
        raise unless @common.json_requested?(as_json, args)
        @common.emit_json_error(invocation, JSON_SCHEMA_VERSION, e, message: e.message.lines.first.strip)
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
      def read_state(project, invocation)
        state_path = @config.pipeline_state_path(project)
        entries = PipelineState.read(state_path)
        return entries if entries

        invocation.error_output.puts "Could not read #{project}'s pipeline state at #{state_path}; treating it as empty"
        {}
      end

      # The agent holds this state in memory while it runs, so clearing the file
      # under a live agent would only put the two out of step.
      def reset(args, invocation)
        json = false
        parser = OptionParser.new do |opts|
          opts.on("--json") { json = true }
        end
        parser.parse!(args)
        project = @names.settle_name(invocation, args.shift)
        raise UsageError, page("reset") if project.nil? || args.any?

        @common.run_action(invocation, "pipeline reset", json: json) do
          if @config.agent_running?(project)
            raise Error, "The agent for #{project} is running; stop it (Ctrl-C in its pane, " \
              "or kill the 'workspace agentd' process) before resetting its pipeline state"
          end

          PipelineState.reset(@config.pipeline_state_path(project))
          invocation.output.puts "Cleared pipeline state for #{project}"
          {results: json ? [@common.action_row(project, "reset")] : [], warnings: [DEPRECATION]}
        end
      end

      def parse_args(args, verb, invocation)
        work_item = nil
        body = nil
        json = false
        parser = OptionParser.new do |opts|
          opts.on("--work-item REF") { |v| work_item = v }
          opts.on("--body TEXT") { |v| body = v }
          opts.on("--json") { json = true }
        end
        parser.parse!(args)
        project = @names.settle_name(invocation, args.shift)
        raise UsageError, "Unexpected arguments: #{args.join(" ")}\n\n#{page(verb)}" if args.any?
        [project, work_item, body, json]
      end

      # The page of one pipeline verb, as text.
      def page(verb)
        HelpPages.render(HelpPages::PIPELINE.fetch(verb)).join("\n")
      end
    end
  end
end
