require "optparse"
require "json"
require "time"

module Workspace
  class CLI
    # The `work-queue` verb (and its other name `wq`): parses its arguments with the usage text the
    # help pages carry and hands the parsed values to {Commands::WorkQueue}. An action verb goes
    # through {Common#run_action} with the queue and its revision as the document's `extra`; a
    # read verb prints for a person, or one `--json` document built from the Hash the command
    # returns. It writes and exits only through the {Invocation} it is given.
    class WorkQueue
      # The flags each verb takes, besides the positional words. `history` has its own table.
      SUBCOMMANDS = {
        "add" => %i[name json top after_current before after headless on_fail dedupe_key ref prompt input text workflow],
        "list" => %i[name project json watch interval],
        "show" => %i[name json],
        "active" => %i[name json watch interval],
        "rm" => %i[name json],
        "move" => %i[name json before after top bottom if_revision],
        "cancel" => %i[name json and_continue],
        "enable" => %i[name json],
        "disable" => %i[name json],
        "resume" => %i[name json],
        "skip" => %i[name json],
        "advance" => %i[name json],
        "status" => %i[name project json],
        "history" => %i[name project json since before state all yes]
      }.freeze

      # The flags each `history` verb takes.
      HISTORY_SUBCOMMANDS = {
        "list" => %i[name project json since before state],
        "show" => %i[name json],
        "clear" => %i[name json before all yes]
      }.freeze

      # The kinds `add` takes.
      KINDS = %w[workflow go].freeze

      # The advance outcomes that mean something went wrong (a held item at a gate is not one).
      FAILURE_OUTCOMES = %w[launch_failed claim_lost interrupted failed cancelled].freeze

      # The failure outcomes that are a failure only when the queue paused for them.
      PAUSING_OUTCOMES = %w[failed cancelled].freeze

      # The outcomes `history list --state` can name.
      STATES = %w[succeeded failed cancelled skipped interrupted launch_failed].freeze

      # Seconds between redraws of `--watch` when `--interval` is not given.
      DEFAULT_INTERVAL = 2.0

      # The key a read verb's payload goes under in its document.
      PRIMARY_KEYS = {"list" => "queues", "status" => "queues", "show" => "item", "active" => "item",
                      "history list" => "entries", "history show" => "entry"}.freeze

      # @param work_queue_command [Workspace::Commands::WorkQueue, nil] one method per verb; nil refuses `work-queue`
      # @param common [CLI::Common] the output, exit and help helpers
      def initialize(work_queue_command:, common:)
        @command = work_queue_command
        @common = common
      end

      # Runs one `work-queue` or `wq` command line.
      #
      # @param _verb [String] the verb {CLI::ROUTES} sent here (`work-queue` or `wq`)
      # @param args [Array<String>] the arguments after the verb (changed in place)
      # @param invocation [Invocation] the run's streams, exit handler and flags
      # @return [void]
      # @raise [Workspace::UsageError, Workspace::Error] for the CLI's rescue funnel to report
      def call(_verb, args, invocation)
        return if @common.verb_help_shown?(invocation, HelpPages::WORK_QUEUE, args)

        options = {given: [], json: false, inputs: []}
        parser = parser(options)
        parser.parse!(args)
        return invocation.output.puts(parser.help) if options[:help]

        verb = args.shift
        return invocation.output.puts(parser.help) unless verb
        raise UsageError, "Unknown work-queue subcommand: #{verb}. One of #{SUBCOMMANDS.keys.join(", ")}. Run 'workspace work-queue --help'." unless SUBCOMMANDS.key?(verb)

        sub = (verb == "history") ? history_verb(args) : nil
        flags = sub ? HISTORY_SUBCOMMANDS.fetch(sub) : SUBCOMMANDS.fetch(verb)
        label = sub ? "history #{sub}" : verb
        options[:given].uniq.each do |key|
          raise UsageError, "--#{key.to_s.tr("_", "-")} does not apply to 'work-queue #{label}'. Run 'workspace work-queue #{label} --help'." unless flags.include?(key)
        end
        raise UsageError, "Give only one of --name and --project." if options[:name] && options[:project]
        raise Error, "work-queue is not available: no work-queue command was wired" unless @command

        check_watch(options)
        dispatch(label, args, options, invocation)
      end

      private

      def history_verb(args)
        sub = args.shift
        raise UsageError, "Missing history subcommand: one of #{HISTORY_SUBCOMMANDS.keys.join(", ")}. Run 'workspace work-queue history --help'." unless sub
        raise UsageError, "Unknown history subcommand: #{sub}. One of #{HISTORY_SUBCOMMANDS.keys.join(", ")}." unless HISTORY_SUBCOMMANDS.key?(sub)
        sub
      end

      def check_watch(options)
        raise UsageError, "--interval needs --watch. Add --watch, or drop --interval." if options[:given].include?(:interval) && !options[:watch]
        raise UsageError, "--watch redraws a screen and cannot be combined with --json. Drop one of them." if options[:watch] && options[:json]
        interval = options[:interval]
        raise UsageError, "--interval needs a number of seconds above 0, not #{interval}." if interval && interval <= 0
      end

      def watching(invocation, options)
        result = yield(options[:interval] || DEFAULT_INTERVAL)
        invocation.exit_handler.exit(result[:exit_code]) if result && !result[:exit_code].zero?
      end

      def take(options, key, value)
        options[key] = value
        options[:given] << key
      end

      def parser(options)
        OptionParser.new do |opts|
          opts.banner = HelpPages.overview_usage(HelpPages::WORK_QUEUE)
          opts.separator ""
          opts.separator "Each workspace has its own queue of items that run one at a time (`wq` is another name for"
          opts.separator "`work-queue`). A queue is off until `work-queue enable`. Only `work-queue advance` moves it, one"
          opts.separator "pass by hand, so run it again after each item ends."
          opts.separator ""
          opts.separator "Subcommands:"
          HelpPages.overview_verbs(HelpPages::WORK_QUEUE).each { |line| opts.separator line }
          opts.separator "Run `workspace work-queue VERB --help` for a verb's options."
          opts.separator ""
          opts.on("--name NAME", "Workspace whose queue to use (default: detected from the current directory)") { |v| take(options, :name, v) }
          opts.on("--project [NAME]", "list, status and history list: every workspace of a project (read only)") { |v| take(options, :project, v || true) }
          opts.on("--top", "add: put the item first among the queued ones; move: move it there") { take(options, :top, true) }
          opts.on("--bottom", "move: move the item to the end") { take(options, :bottom, true) }
          opts.on("--after-current", "add: put the item right after the one that is running") { take(options, :after_current, true) }
          opts.on("--before VALUE", "add and move: place the item before this item id; history list and clear: finished before this date") { |v| take(options, :before, v) }
          opts.on("--after ID", "add and move: place the item after this item id") { |v| take(options, :after, v) }
          opts.on("--if-revision N", "move: refuse with stale_revision unless the queue's revision is N") { |v| take(options, :if_revision, v) }
          opts.on("--headless", "add: run the item without a pane") { take(options, :headless, true) }
          opts.on("--on-fail MODE", "add: stop (pause the queue when it fails, the default) or continue") { |v| take(options, :on_fail, v) }
          opts.on("--dedupe-key KEY", "add: adding the same key again changes nothing") { |v| take(options, :dedupe_key, v) }
          opts.on("--ref REF", "add workflow: the ticket, pull request or branch to start from") { |v| take(options, :ref, v) }
          opts.on("--prompt TEXT", "add workflow: the task text") { |v| take(options, :prompt, v) }
          opts.on("--input K=V", "add: a workflow input (repeatable)") { |v| options[:inputs] << v && options[:given] << :input }
          opts.on("--text", "add go: ARG is free text, not a ticket, pull request or branch") { take(options, :text, true) }
          opts.on("--workflow ID", "add go: the workflow to run instead of the one config picks") { |v| take(options, :workflow, v) }
          opts.on("--and-continue", "cancel: go on to the next item instead of pausing the queue") { take(options, :and_continue, true) }
          opts.on("--since DATE", "history list: finished at or after this date (2026-01-31 or 2026-01-31T09:00:00Z)") { |v| take(options, :since, v) }
          opts.on("--state STATE", "history list: only this outcome (#{STATES.join(", ")})") { |v| take(options, :state, v) }
          opts.on("--all", "history clear: remove every finished item") { take(options, :all, true) }
          opts.on("--yes", "history clear: skip the question") { take(options, :yes, true) }
          opts.on("--watch", "list and active: redraw every --interval seconds until Ctrl-C") { take(options, :watch, true) }
          opts.on("--interval SECONDS", Float, "list and active with --watch: seconds between redraws (default #{DEFAULT_INTERVAL.to_i})") { |v| take(options, :interval, v) }
          opts.on("--json", "Print one JSON document") { take(options, :json, true) }
          opts.on("-h", "--help", "Show this help") { options[:help] = true }
          opts.separator ""
          opts.separator "Examples:"
          HelpPages.overview_examples(HelpPages::WORK_QUEUE, per_verb: 1).first(8).each { |line| opts.separator line }
        end
      end

      def dispatch(label, args, options, invocation)
        name = options[:name]
        json = options[:json]
        case label
        when "add" then add(args, options, invocation)
        when "list"
          if options[:watch]
            watching(invocation, options) { |interval| @command.watch_list(name: name, project: options[:project], interval: interval) }
          else
            read(invocation, label, json) { @command.list(name: name, project: options[:project]) }
          end
        when "show"
          id = one_id(args, label)
          read(invocation, label, json) { @command.show(id: id, name: name) }
        when "active"
          no_args(args, label)
          if options[:watch]
            watching(invocation, options) { |interval| @command.watch_active(name: name, interval: interval) }
          else
            read(invocation, label, json) { @command.active(name: name) }
          end
        when "status"
          no_args(args, label)
          read(invocation, label, json) { @command.status(name: name, project: options[:project]) }
        when "rm"
          raise UsageError, "work-queue rm needs at least one item ID. Run 'workspace work-queue rm --help'." if args.empty?
          ids = args.dup
          action(invocation, label, options) { @command.rm(ids: ids, name: name) }
        when "move" then move(args, options, invocation)
        when "cancel", "skip"
          raise UsageError, "Unexpected argument: #{args[1]}. Run 'workspace work-queue #{label} --help'." if args.size > 1
          id = args.first
          action(invocation, label, options, judge_from: (label == "cancel") ? 1 : nil) do
            (label == "cancel") ? @command.cancel(id: id, name: name, and_continue: options[:and_continue] || false) : @command.skip(id: id, name: name)
          end
        when "enable", "disable", "resume", "advance"
          no_args(args, label)
          action(invocation, label, options, judge_from: (label == "advance") ? 0 : nil) { @command.public_send(label, name: name) }
        when "history list"
          no_args(args, label)
          since = date(options[:since], "--since")
          before = date(options[:before], "--before")
          if options[:state] && !STATES.include?(options[:state])
            raise UsageError, "Unknown state: #{options[:state]}. One of #{STATES.join(", ")}."
          end
          read(invocation, label, json) { @command.history_list(name: name, project: options[:project], since: since, before: before, state: options[:state]) }
        when "history show"
          id = one_id(args, label)
          read(invocation, label, json) { @command.history_show(id: id, name: name) }
        when "history clear" then history_clear(args, options, invocation)
        end
      end

      def add(args, options, invocation)
        kind = args.shift
        raise UsageError, "Missing kind: one of #{KINDS.join(", ")}. Run 'workspace work-queue add --help'." unless kind
        raise UsageError, "Unknown kind: #{kind}. One of #{KINDS.join(", ")}. Run 'workspace work-queue add --help'." unless KINDS.include?(kind)

        positions = {top: options[:top], after_current: options[:after_current], before: options[:before], after: options[:after]}.select { |_, v| v }
        raise UsageError, "Give only one of --top, --after-current, --before and --after." if positions.size > 1
        if kind == "workflow"
          %i[text workflow].each { |key| raise UsageError, "--#{key} applies to 'add go', not 'add workflow'." if options[:given].include?(key) }
          raise UsageError, "work-queue add workflow needs a workflow ID. Run 'workspace work-queue add --help'." if args.empty?
          raise UsageError, "Unexpected argument: #{args[1]}. Run 'workspace work-queue add --help'." if args.size > 1
          spec = {"workflow" => args.first, "ref" => options[:ref], "prompt" => options[:prompt]}
        else
          %i[ref prompt].each { |key| raise UsageError, "--#{key} applies to 'add workflow', not 'add go'." if options[:given].include?(key) }
          raise UsageError, "Unexpected argument: #{args[1]}. Run 'workspace work-queue add --help'." if args.size > 1
          raise UsageError, "work-queue add go needs an ARG: a ticket, pull request or branch, or with --text the text. Run 'workspace work-queue add --help'." if args.empty?
          spec = {"argument" => args.first, "text" => options[:text], "workflow" => options[:workflow]}
        end
        spec = spec.compact
        inputs = parse_inputs(options[:inputs])
        spec["inputs"] = inputs unless inputs.empty?
        if options[:on_fail] && !%w[stop continue].include?(options[:on_fail])
          raise UsageError, "Unknown --on-fail: #{options[:on_fail]}. One of stop, continue."
        end
        position = if options[:top] then :top
        elsif options[:after_current] then :after_current
        elsif options[:before] then {before: options[:before]}
        elsif options[:after] then {after: options[:after]}
        else :bottom
        end
        action(invocation, "add", options) do
          @command.add(kind: kind, spec: spec, name: options[:name], position: position, headless: options[:headless] || false,
            on_fail: options[:on_fail] || "stop", dedupe_key: options[:dedupe_key])
        end
      end

      def move(args, options, invocation)
        id = one_id(args, "move")
        place = {before: options[:before], after: options[:after], top: options[:top], bottom: options[:bottom]}
        raise UsageError, "Give exactly one of --before, --after, --top and --bottom. Run 'workspace work-queue move --help'." unless place.values.count { |v| v } == 1
        revision = options[:if_revision]
        unless revision.nil?
          raise UsageError, "--if-revision needs a whole number, not '#{revision}'." unless revision.match?(/\A\d+\z/)
          revision = revision.to_i
        end
        action(invocation, "move", options) do
          @command.move(id: id, name: options[:name], before: options[:before], after: options[:after], top: options[:top] || false,
            bottom: options[:bottom] || false, if_revision: revision)
        end
      end

      def history_clear(args, options, invocation)
        no_args(args, "history clear")
        raise UsageError, "Give exactly one of --before DATE and --all. Run 'workspace work-queue history clear --help'." unless [options[:before], options[:all]].count { |v| v } == 1
        before = date(options[:before], "--before")
        action(invocation, "history clear", options) do
          @command.history_clear(name: options[:name], before: before, all: options[:all] || false, yes: options[:yes] || false, json: options[:json])
        end
      end

      def one_id(args, label)
        raise UsageError, "work-queue #{label} needs an item ID. Run 'workspace work-queue #{label} --help'." if args.empty?
        raise UsageError, "Unexpected argument: #{args[1]}. Run 'workspace work-queue #{label} --help'." if args.size > 1
        args.first
      end

      def no_args(args, label)
        raise UsageError, "Unexpected argument: #{args.first}. Run 'workspace work-queue #{label} --help'." if args.any?
      end

      def parse_inputs(list)
        list.each_with_object({}) do |pair, inputs|
          key, value = pair.split("=", 2)
          raise UsageError, "--input needs KEY=VALUE, not '#{pair}'." if key.to_s.empty? || value.nil?
          inputs[key] = value
        end
      end

      def date(text, flag)
        return nil if text.nil?
        raise ArgumentError unless text.match?(/\A\d{4}-\d{2}-\d{2}/)
        Time.parse(text)
      rescue ArgumentError
        raise UsageError, "#{flag} needs a date such as 2026-01-31 or 2026-01-31T09:00:00Z, not '#{text}'."
      end

      # An action verb: the command's rows go through run_action, with the queue and revision beside them.
      # With +judge_from+, rows from that index on that ended badly make the status `failed` (all of
      # them) or `partial`, as {JsonEnvelope} does, and the exit code follows it with or without --json.
      def action(invocation, label, options, judge_from: nil)
        json = options[:json]
        @common.run_action(invocation, "work-queue #{label}", json: json) do
          rows = yield
          extra = json ? @command.action_extra(name: options[:name]) : {}
          status = judge_from && (failure_status(rows, judge_from) || "ok")
          {exit_code: JsonEnvelope::ACTION_EXIT_CODES.fetch(status || "ok"), status: status,
           results: rows.map { |row| {"workspace" => extra["queue"]}.merge(row) },
           warnings: rows.flat_map { |row| row["warnings"] || [] }, extra: extra}.compact
        end
      end

      # A failed or cancelled run is a failure of the pass only when the queue paused for it, which its
      # row says by offering `work-queue resume`; under `--on-fail continue` the queue goes on.
      def failure?(row)
        return false unless FAILURE_OUTCOMES.include?(row["outcome"])
        return true unless PAUSING_OUTCOMES.include?(row["outcome"])
        (row["next_actions"] || []).any? { |a| a["action"] == "work-queue resume" }
      end

      def failure_status(rows, from)
        failed = rows.drop(from).count { |row| failure?(row) }
        return nil if failed.zero?
        (failed == rows.size) ? "failed" : "partial"
      end

      # A read verb: the command prints for a person; under --json its Hash is one document.
      def read(invocation, label, json)
        return yield unless json

        doc = @common.divert_output(invocation) { yield }
        key = PRIMARY_KEYS.fetch(label)
        out = JsonEnvelope.document(key, doc[key], warnings: doc["warnings"] || [])
        invocation.output.puts JSON.generate(out.merge(doc.except(key, "warnings")))
      end
    end
  end
end
