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

    private

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
      command.split(/\|\||&&|;|\||\n/).each do |part|
        words = part.split
        words.shift while words.first&.match?(/\A\w+=/) || PREFIXES.include?(words.first) || words.first(2) == %w[bundle exec]
        provider = AgentProvider.all.find { |candidate| candidate.executable == File.basename(words.first.to_s) }
        return provider if provider
      end
      nil
    end
  end
end
