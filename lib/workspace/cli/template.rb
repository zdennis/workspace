require "optparse"

module Workspace
  class CLI
    # The `template` verb: parses its arguments with the same usage text the CLI prints and hands
    # the parsed values to {Commands::Template}. It writes and exits only through the
    # {Invocation} it is given.
    class Template
      # The flags each `template` verb takes.
      SUBCOMMANDS = {
        "list" => %i[scope name json],
        "show" => %i[kind name json],
        "path" => %i[kind name json]
      }.freeze

      # @param template_command [Workspace::Commands::Template, nil] `template list|show|path`; nil refuses `template`
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
        raise UsageError, "Unexpected argument: #{args[(subcommand == "list") ? 0 : 1]}. Run 'workspace template --help'." if args.size > ((subcommand == "list") ? 0 : 1)
        raise Error, "template is not available: no template command was wired" unless @template_command

        workspace = options[:name] || @names.workspace_here
        json = options[:json] || false
        case subcommand
        when "list" then @template_command.list(workspace: workspace, scope: options[:scope], cwd: @working_dir, json: json)
        when "show" then @template_command.show(set: args.first, kind: options[:kind], workspace: workspace, json: json)
        when "path" then @template_command.path(set: args.first, kind: options[:kind], workspace: workspace, json: json)
        end
      end

      private

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
          opts.on("--scope SCOPE", HelpPages::TEMPLATE_SCOPE_TEXT) { |v| take(options, :scope, v) }
          opts.on("--kind KIND", HelpPages::TEMPLATE_KIND_TEXT) { |v| take(options, :kind, v) }
          opts.on("--name NAME", HelpPages::TEMPLATE_NAME_TEXT) { |v| take(options, :name, v) }
          opts.on("--json", "Print one JSON document") { take(options, :json, true) }
          opts.on("-h", "--help", "Show this help") { options[:help] = true }
          opts.separator ""
          opts.separator "Examples:"
          opts.separator "  workspace template list    # every tmuxinator template, and which one a new config of each kind uses"
          opts.separator "  workspace template show --kind worktree    # the worktree layout a new worktree config is rendered from"
          opts.separator "  workspace template path team    # where the files of the tmuxinator template team are"
        end
      end

      def take(options, key, value)
        options[key] = value
        options[:given] << key
      end
    end
  end
end
