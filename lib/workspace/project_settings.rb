require "yaml"
require "fileutils"

module Workspace
  # Reads and writes per-project YAML configuration from ~/.config/workspace/projects/.
  # Also reads global config from ~/.config/workspace/config.yml.
  class ProjectSettings
    # @param config [Workspace::Config] configuration for path lookups
    def initialize(config:)
      @config = config
    end

    # @param project_name [String] project name
    # @return [Hash] parsed project config, or empty hash if none exists
    def load(project_name)
      path = project_config_path(project_name)
      return {} unless File.exist?(path)
      YAML.safe_load_file(path) || {}
    rescue Psych::SyntaxError
      {}
    end

    # @param project_name [String] project name
    # @param data [Hash] config data to write
    # @return [void]
    def save(project_name, data)
      path = project_config_path(project_name)
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, YAML.dump(data))
    end

    # @return [Hash] parsed global config, or empty hash if none exists
    def load_global
      path = global_config_path
      return {} unless File.exist?(path)
      YAML.safe_load_file(path) || {}
    rescue Psych::SyntaxError
      {}
    end

    # Creates a default project config if one does not already exist.
    #
    # @param project_name [String] project name
    # @return [void]
    def ensure_exists(project_name)
      path = project_config_path(project_name)
      return if File.exist?(path)
      save(project_name, {"hooks" => {}, "layouts" => {}})
    end

    # @param project_name [String] project name
    # @param event [String] hook event name (e.g. "post_launch")
    # @return [String, nil] hook script or nil
    def hook_for(project_name, event)
      data = load(project_name)
      data.dig("hooks", event)
    end

    # @param project_name [String] project name
    # @return [Hash] merged layouts (project overrides global)
    def layouts_for(project_name)
      global_layouts = load_global.dig("layouts") || {}
      project_layouts = load(project_name).dig("layouts") || {}
      global_layouts.merge(project_layouts)
    end

    # Returns the full claude command for a project, including MCP server flags
    # if configured. Project-level claude.mcp_servers overrides global.
    #
    # @param project_name [String] project name
    # @return [String] the claude command string
    def claude_command_for(project_name)
      servers = load(project_name).dig("claude", "mcp_servers")
      servers = load_global.dig("claude", "mcp_servers") unless servers&.any?
      if servers&.any?
        flag = "--mcp-servers #{servers.join(",")}"
        "claude --continue #{flag} || claude #{flag}"
      else
        "claude --continue || claude"
      end
    end

    # @param project_name [String] project name
    # @return [String] path to the project config file
    def project_config_path(project_name)
      File.join(@config.workspace_config_dir, "projects", "#{project_name}.yml")
    end

    # @return [String] path to the global config file
    def global_config_path
      File.join(@config.workspace_config_dir, "config.yml")
    end
  end
end
