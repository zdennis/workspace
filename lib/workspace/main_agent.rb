require "yaml"

module Workspace
  # Says which coding agent a project's main agent pane runs, by reading the
  # panes of its tmuxinator config for the first command that starts a known
  # agent ({AgentProvider}). `start` and `launch` use it to know whether the
  # `handoff` pack, which relies on Claude Code, can be sent.
  #
  # A project with no config yet is made from a template that runs Claude Code,
  # so it counts as `claude`. A config that cannot be read, or that runs no known
  # agent, is `none`.
  class MainAgent
    # @param project_config [Workspace::ProjectConfig] gives the path of a project's config
    # @param agent_commands [Workspace::AgentCommands, nil] the programs configured for each agent kind,
    #   which count as that agent; nil knows only the providers' executables
    def initialize(project_config:, agent_commands: nil)
      @project_config = project_config
      @agent_commands = agent_commands
    end

    # @param project [String] the project's name (a worktree's parent project)
    # @return [String] an {AgentProvider} key such as "claude" or "codex", or "none"
    def kind(project)
      path = @project_config.config_path_for(project)
      return "claude" unless File.exist?(path)
      config = YAML.safe_load_file(path)
      return "none" unless config.is_a?(Hash)
      pane_commands(config["windows"]).each do |command|
        provider = provider_of(command, project)
        return provider.key if provider
      end
      "none"
    rescue SystemCallError, Psych::Exception
      "none"
    end

    # Words that make an agent command resume an old conversation; a new pane must start a fresh one.
    RESUME_FLAGS = %w[--continue -c --resume -r resume].freeze

    # The command a new pane runs to start a fresh +kind+ agent for the workspace (`plan start --spawn`):
    # the workspace's own pane command for that kind when its config has one, else the command a new
    # worktree config would run for it ({ProjectConfig#agent_pane_command}), else the bare executable.
    # Of a chain such as `claude --flag --continue || claude --flag`, the first part that starts the
    # agent without resuming is taken, so a spawned Claude Code keeps the main pane's flags but not its conversation.
    # For Claude Code its program is swapped for the configured command ({ProjectConfig#with_configured_program}),
    # so a stale `claude` fallback half of `claude-dev --continue || claude` starts `claude-dev`;
    # the template's command is already swapped, so it is not swapped again.
    #
    # @param workspace [String] the workspace (its own tmuxinator config is read)
    # @param kind [String] an {AgentProvider} key
    # @return [String]
    def spawn_command(workspace, kind)
      provider = AgentProvider.find(kind) || raise(ArgumentError, "unknown agent kind #{kind.inspect}")
      own_commands(workspace).each do |command|
        fresh = fresh_part(command, provider, workspace)
        return @project_config.with_configured_program(fresh, kind, workspace) if fresh
      end
      if (template = @project_config.agent_pane_command(kind, workspace))
        fresh = fresh_part(template, provider, workspace)
        return fresh if fresh
      end
      @agent_commands ? @agent_commands.command_for(workspace, kind) : provider.executable
    end

    private

    def own_commands(workspace)
      path = @project_config.config_path_for(workspace)
      return [] unless File.exist?(path)
      config = YAML.safe_load_file(path)
      config.is_a?(Hash) ? pane_commands(config["windows"]) : []
    rescue SystemCallError, Psych::Exception
      []
    end

    # The first part of +command+ that runs +provider+'s program without resuming, as written. Only
    # that part is kept: a `cd src && claude` pane gives `claude`.
    def fresh_part(command, provider, workspace)
      names = names_for(workspace, provider)
      parts(command).map(&:strip).find do |part|
        words = AgentCommands.program_words(part)
        names.include?(File.basename(words.first.to_s)) && (words.drop(1) & RESUME_FLAGS).empty?
      end
    end

    # The commands a shell line chains with `||`, `&&`, `;`, `|` or newlines.
    def parts(command) = command.split(/\|\||&&|;|\||\n/)

    # The commands of every pane, in file order; a window's own keys (root, layout, ...) are not commands.
    def pane_commands(windows)
      Array(windows).flat_map do |window|
        next [] unless window.is_a?(Hash)
        window.values.flat_map { |body| body.is_a?(Hash) ? strings(body["panes"]) : strings(body) }
      end
    end

    # Every string under +node+, in file order.
    def strings(node)
      case node
      when String then [node]
      when Array then node.flat_map { |item| strings(item) }
      when Hash then node.values.flat_map { |item| strings(item) }
      else []
      end
    end

    # The program names that count as +provider+ for +workspace+: its executable and any configured one.
    def names_for(workspace, provider)
      @agent_commands ? @agent_commands.names_for(workspace, provider.key) : [provider.executable]
    end

    def provider_of(command, project)
      parts(command).each do |part|
        words = AgentCommands.program_words(part)
        program = File.basename(words.first.to_s)
        provider = AgentProvider.all.find { |candidate| names_for(project, candidate).include?(program) }
        return provider if provider
      end
      nil
    end
  end
end
