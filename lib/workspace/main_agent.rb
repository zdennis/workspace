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
    # Words that may stand before a program in a shell command without being it.
    PREFIXES = %w[exec command nohup env caffeinate].freeze

    # @param project_config [Workspace::ProjectConfig] gives the path of a project's config
    def initialize(project_config:)
      @project_config = project_config
    end

    # @param project [String] the project's name (a worktree's parent project)
    # @return [String] an {AgentProvider} key such as "claude" or "codex", or "none"
    def kind(project)
      path = @project_config.config_path_for(project)
      return "claude" unless File.exist?(path)
      config = YAML.safe_load_file(path)
      return "none" unless config.is_a?(Hash)
      pane_commands(config["windows"]).each do |command|
        provider = provider_of(command)
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
    #
    # @param workspace [String] the workspace (its own tmuxinator config is read)
    # @param kind [String] an {AgentProvider} key
    # @return [String]
    def spawn_command(workspace, kind)
      provider = AgentProvider.find(kind) || raise(ArgumentError, "unknown agent kind #{kind.inspect}")
      [*own_commands(workspace), @project_config.agent_pane_command(kind)].compact.each do |command|
        fresh = fresh_part(command, provider)
        return fresh if fresh
      end
      provider.executable
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
    def fresh_part(command, provider)
      parts(command).map(&:strip).find do |part|
        words = program_words(part)
        File.basename(words.first.to_s) == provider.executable && (words.drop(1) & RESUME_FLAGS).empty?
      end
    end

    # The commands a shell line chains with `||`, `&&`, `;`, `|` or newlines.
    def parts(command) = command.split(/\|\||&&|;|\||\n/)

    # The words of one command from its program on, past environment settings and wrapper words.
    def program_words(part)
      words = part.split
      words.shift while words.first&.match?(/\A\w+=/) || PREFIXES.include?(words.first) || words.first(2) == %w[bundle exec]
      words
    end

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

    def provider_of(command)
      parts(command).each do |part|
        words = program_words(part)
        provider = AgentProvider.all.find { |candidate| candidate.executable == File.basename(words.first.to_s) }
        return provider if provider
      end
      nil
    end
  end
end
