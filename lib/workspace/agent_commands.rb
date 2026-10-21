module Workspace
  # Reads which coding agent a workspace runs (`agent.kind`) and the command
  # that starts each agent (`agent.commands.<kind>`), layered global, project
  # and worktree like the other layered keys through {ConfigResolver}.
  #
  # A stored value that no longer parses, or a config file that can't be parsed,
  # is ignored: the reader falls back to the default (the next layer is not
  # consulted), as {PlanConfig} does.
  class AgentCommands
    # Words that may stand before a program in a shell command without being it.
    PREFIXES = %w[exec command nohup env caffeinate].freeze

    # @param part [String] one shell command (no `||`, `&&`, `;` or `|`)
    # @return [Array<String>] its words from the program on, past `VAR=value` settings and wrapper words
    #   (`env`, `exec`, `bundle exec`, ...)
    def self.program_words(part)
      words = part.to_s.split
      words.shift while words.first&.match?(/\A\w+=/) || PREFIXES.include?(words.first) || words.first(2) == %w[bundle exec]
      words
    end

    # @param command [String] one shell command, e.g. `FOO=1 /opt/bin/claude-dev --x`
    # @return [String, nil] the basename of its program (`claude-dev`); nil when it has none
    def self.program_for(command)
      program = program_words(command).first
      program && File.basename(program)
    end

    # @param config_resolver [Workspace::ConfigResolver]
    def initialize(config_resolver:)
      @config_resolver = config_resolver
    end

    # @param workspace [String] a workspace or worktree workspace name
    # @return [String] the effective agent kind; "claude" when unset, invalid or the config can't be parsed
    def kind(workspace)
      default = ConfigSchema.default("agent.kind")
      winner = view(workspace).resolve("agent.kind").winner
      winner ? ConfigSchema.parse("agent.kind", winner.value) : default
    rescue ArgumentError, ConfigParseError
      default
    end

    # @param workspace [String] a workspace or worktree workspace name
    # @param kind [String] an {AgentProvider} key
    # @return [String] the effective command for that agent; the provider's executable when unset, invalid
    #   or the config can't be parsed
    # @raise [ArgumentError] if `kind` is not an {AgentProvider} key
    def command_for(workspace, kind)
      name = "agent.commands.#{kind}"
      default = provider(kind).executable
      begin
        winner = view(workspace).resolve(name).winner
        winner ? ConfigSchema.parse(name, winner.value) : default
      rescue ArgumentError, ConfigParseError
        default
      end
    end

    # @param workspace [String, nil] a workspace or worktree workspace name; nil reads the global layer alone
    # @param kind [String] an {AgentProvider} key
    # @return [String] the program (basename) the configured command starts, which is what must be on PATH;
    #   the provider's executable when the command has no program
    # @raise [ArgumentError] if `kind` is not an {AgentProvider} key
    def executable_for(workspace, kind)
      command = workspace ? command_for(workspace, kind) : global_command_for(kind)
      self.class.program_for(command) || provider(kind).executable
    end

    # @param workspace [String] a workspace or worktree workspace name
    # @param kind [String] an {AgentProvider} key
    # @return [Array<String>] the program names (basenames) that count as that agent: the provider's
    #   executable plus the program of the command each applicable layer holds; only the executable when
    #   the config can't be parsed
    # @raise [ArgumentError] if `kind` is not an {AgentProvider} key
    def names_for(workspace, kind)
      name = "agent.commands.#{kind}"
      executable = provider(kind).executable
      configured = begin
        view(workspace).resolve(name).hits.filter_map do |hit|
          self.class.program_for(ConfigSchema.parse(name, hit.value))
        rescue ArgumentError
          nil
        end
      rescue ConfigParseError
        []
      end
      ([executable] + configured).uniq
    end

    # @param workspace [String] a workspace or worktree workspace name
    # @return [Hash{String => Array<String>}] for each agent kind with a program other than the provider's
    #   executable, those extra names; what {AgentProvider.detect} takes as `aliases:`
    def aliases_for(workspace)
      AgentProvider.all.each_with_object({}) do |provider, aliases|
        extra = names_for(workspace, provider.key) - [provider.executable]
        aliases[provider.key] = extra unless extra.empty?
      end
    end

    # @param workspace [String] a workspace or worktree workspace name
    # @return [Workspace::AgentDetector] detects agents by the providers plus that workspace's configured names
    def detector(workspace)
      AgentDetector.new(aliases: aliases_for(workspace))
    end

    # @param workspace [String] a workspace or worktree workspace name
    # @return [Hash] `{detector: ...}` when the workspace configures a program of its own, else `{}`; splatted
    #   into the readiness calls so an unconfigured workspace passes nothing extra
    def detector_options(workspace)
      detector = detector(workspace)
      detector.aliases? ? {detector: detector} : {}
    end

    private

    def global_command_for(kind)
      name = "agent.commands.#{kind}"
      default = provider(kind).executable
      begin
        winner = @config_resolver.view(workspace: "global", upto: "global").resolve(name).winner
        winner ? ConfigSchema.parse(name, winner.value) : default
      rescue ArgumentError, ConfigParseError
        default
      end
    end

    def view(workspace) = @config_resolver.view(workspace: workspace)

    def provider(kind)
      AgentProvider.find(kind) or raise ArgumentError, "unknown agent kind #{kind.inspect}"
    end
  end
end
