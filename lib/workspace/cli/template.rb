require "optparse"

module Workspace
  class CLI
    # The `template` verb: parses its arguments with the same usage text the CLI prints and hands
    # the parsed values to {Commands::Template}. It writes and exits only through the
    # {Invocation} it is given.
    class Template
      # The flags each `template` verb takes. (`--name` on `new` and `use` is the workspace whose settings or project the verb works in.)
      SUBCOMMANDS = {
        "list" => %i[scope name json],
        "status" => %i[all project json],
        "apply" => %i[all project dry_run diff force rollback json],
        "show" => %i[kind name json],
        "path" => %i[kind name json],
        "variables" => %i[kind name json],
        "render" => %i[kind name sample diff file json],
        "validate" => %i[kind name file json],
        "diff" => %i[kind name against json],
        "new" => %i[name from scope json],
        "edit" => %i[kind name json],
        "use" => %i[kind name scope json]
      }.freeze

      # @param template_command [Workspace::Commands::Template, nil] `template` verbs; nil refuses `template`
      # @param common [CLI::Common] the output, exit and help helpers
      # @param names [CLI::Names] finds the workspace of the working directory
      # @param working_dir [String] the directory the CLI runs from
      def initialize(template_command:, common:, names:, working_dir:)
        @template_command = template_command
        @common = common
        @names = names
        @working_dir = working_dir
      end

      # Runs one `template` command line.
      #
      # @param verb [String] the verb {CLI::ROUTES} sent here (`template`)
      # @param args [Array<String>] the arguments after the verb (changed in place)
      # @param invocation [Invocation] the run's streams, exit handler and flags
      # @return [void]
      # @raise [Workspace::UsageError, Workspace::Error] for the CLI's rescue funnel to report
      def call(verb, args, invocation)
        return if @common.verb_help_shown?(invocation, HelpPages::TEMPLATE, args)

        options = {given: []}
        parser = parser(options)
        parser.parse!(args)
        return invocation.output.puts(parser.help) if options[:help]

        subcommand = args.shift
        return invocation.output.puts(parser.help) unless subcommand

        raise UsageError, "Unknown tmuxinator template subcommand: #{subcommand}. Run 'workspace template --help'." unless SUBCOMMANDS.key?(subcommand)

        options[:given].uniq.each do |key|
          raise UsageError, "--#{key} does not apply to 'template #{subcommand}'. Run 'workspace template --help'." unless SUBCOMMANDS[subcommand].include?(key)
        end
        raise UsageError, "'template #{subcommand}' needs a tmuxinator template NAME. Run 'workspace template #{subcommand} --help'." if %w[new use].include?(subcommand) && args.empty?
        limit = {"list" => 0, "variables" => 0, "status" => nil, "apply" => nil}.fetch(subcommand, 1)
        raise UsageError, "Unexpected argument: #{args[limit]}. Run 'workspace template --help'." if limit && args.size > limit
        raise Error, "template is not available: no template command was wired" unless @template_command

        workspace = options[:name] || @names.workspace_here
        json = options[:json] || false
        case subcommand
        when "list" then @template_command.list(workspace: workspace, scope: options[:scope], cwd: @working_dir, json: json)
        when "status" then @template_command.status(names: args.dup, all: options[:all] || false, project: options[:project], cwd: @working_dir, json: json)
        when "apply" then apply(args.dup, options, invocation)
        when "show" then @template_command.show(set: args.first, kind: options[:kind], workspace: workspace, json: json)
        when "path" then @template_command.path(set: args.first, kind: options[:kind], workspace: workspace, json: json)
        when "variables" then @template_command.variables(kind: options[:kind], workspace: options[:name] ? workspace : nil, json: json)
        when "render" then render(args.first, options, workspace, invocation)
        when "validate"
          ok = @template_command.validate(set: args.first, file: options[:file], kind: options[:kind], workspace: workspace, json: json)
          invocation.exit_handler.exit(1) unless ok
        when "diff" then @template_command.diff(set: args.first, against: options[:against], kind: options[:kind], workspace: workspace, json: json)
        when "new" then change(invocation, "template new", json) { @template_command.new(name: args.first, from: options[:from], scope: options[:scope], workspace: workspace, cwd: @working_dir) }
        when "edit" then edit(args.first, options, workspace, invocation)
        when "use" then change(invocation, "template use", json) { @template_command.use(name: args.first, scope: options[:scope], kind: options[:kind], workspace: workspace, cwd: @working_dir) }
        end
      end

      private

      # Runs a verb that changes something and reports its row, as an action document under --json.
      def change(invocation, action, json)
        @common.run_action(invocation, action, json: json) do
          row = yield
          {results: [row], exit_code: 0}
        end
      end

      # `apply` reports one row per workspace, as an action document under --json.
      def apply(names, options, invocation)
        json = options[:json] || false
        @common.run_action(invocation, "template apply", json: json) do
          @template_command.apply(names: names, all: options[:all] || false, project: options[:project], cwd: @working_dir,
            dry_run: options[:dry_run] || false, diff: options[:diff] || false, force: options[:force] || false,
            rollback: options[:rollback] || false, json: json)
        end
      end

      # `edit` opens the editor on each file unless --json is given (a script edits the files itself), then checks them.
      def edit(set, options, workspace, invocation)
        opener = options[:json] ? nil : lambda do |paths|
          next if @common.open_in_editor(invocation, *paths)
          invocation.error_output.puts "Nothing was opened: set $VISUAL or $EDITOR (and run from a terminal) to edit these files from here."
        end
        @common.run_action(invocation, "template edit", json: options[:json] || false) do
          row = @template_command.edit(set: set, kind: options[:kind], workspace: workspace, opener: opener)
          {results: [row], exit_code: (row["outcome"] == "failed") ? 1 : 0}
        end
      end

      # `render` fills from the named workspace, else the current one, unless --sample asks for sample values.
      def render(set, options, workspace, invocation)
        sample = options[:sample] || false
        ok = @template_command.render(set: set, file: options[:file], kind: options[:kind], workspace: sample ? options[:name] : workspace,
          context: workspace, sample: sample, diff: options[:diff] || false, json: options[:json] || false)
        invocation.exit_handler.exit(1) unless ok
      end

      def parser(options)
        OptionParser.new do |opts|
          opts.banner = HelpPages.overview_usage(HelpPages::TEMPLATE)
          opts.separator ""
          opts.separator "A tmuxinator template is a set of tmuxinator layout files (project.yml for a standard project,"
          opts.separator "worktree.yml for a git worktree) that new tmuxinator configs are rendered from. Sets are"
          opts.separator "`template` entries of the library; `tmuxinator.template` and `tmuxinator.worktree_template` choose one."
          opts.separator ""
          opts.separator "Subcommands:"
          HelpPages.overview_verbs(HelpPages::TEMPLATE).each { |line| opts.separator line }
          opts.separator "Run `workspace template VERB --help` for a verb's options."
          opts.separator ""
          opts.on("--from NAME", HelpPages::TEMPLATE_FROM_TEXT) { |v| take(options, :from, v) }
          opts.on("--scope SCOPE", HelpPages::TEMPLATE_SCOPE_TEXT) { |v| take(options, :scope, v) }
          opts.on("--kind KIND", HelpPages::TEMPLATE_KIND_TEXT) { |v| take(options, :kind, v) }
          opts.on("--name NAME", HelpPages::TEMPLATE_NAME_TEXT) { |v| take(options, :name, v) }
          opts.on("--file FILE", HelpPages::TEMPLATE_FILE_TEXT) { |v| take(options, :file, v) }
          opts.on("--against NAME", HelpPages::TEMPLATE_AGAINST_TEXT) { |v| take(options, :against, v) }
          opts.on("--sample", HelpPages::TEMPLATE_SAMPLE_TEXT) { take(options, :sample, true) }
          opts.on("--diff", HelpPages::TEMPLATE_DIFF_TEXT) { take(options, :diff, true) }
          opts.on("--dry-run", HelpPages::TEMPLATE_DRY_RUN_TEXT) { take(options, :dry_run, true) }
          opts.on("--force", HelpPages::TEMPLATE_FORCE_TEXT) { take(options, :force, true) }
          opts.on("--rollback-all-on-error", HelpPages::TEMPLATE_ROLLBACK_TEXT) { take(options, :rollback, true) }
          opts.on("--all", HelpPages::TEMPLATE_ALL_TEXT) { take(options, :all, true) }
          opts.on("--project [NAME]", HelpPages::TEMPLATE_PROJECT_TEXT) { |v| take(options, :project, v || true) }
          opts.on("--json", "Print one JSON document") { take(options, :json, true) }
          opts.on("-h", "--help", "Show this help") { options[:help] = true }
          opts.separator ""
          opts.separator "Examples:"
          opts.separator "  workspace template list    # every tmuxinator template, and which one a new config of each kind uses"
          opts.separator "  workspace template status --all    # which tmuxinator configs are current, stale, edited or have no render record"
          opts.separator "  workspace template apply --all --dry-run --diff    # what re-rendering every tmuxinator config would change, writing nothing"
          opts.separator "  workspace template variables --name api.worktree-login    # the placeholders and what that config holds"
          opts.separator "  workspace template render --sample    # fill the tmuxinator template with sample values, writing nothing"
          opts.separator "  workspace template validate team    # check the tmuxinator template team before using it"
          opts.separator "  workspace template new team --from default    # start your own copy of the default tmuxinator template"
          opts.separator "  workspace template edit team    # change it in $EDITOR, then check it"
          opts.separator "  workspace template use team    # make new tmuxinator configs render from it"
          opts.separator "  workspace template diff team    # how the tmuxinator template team differs from the default"
        end
      end

      def take(options, key, value)
        options[key] = value
        options[:given] << key
      end
    end
  end
end
