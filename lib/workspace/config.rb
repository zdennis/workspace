module Workspace
  # Centralizes all path constants and configuration for the workspace CLI.
  class Config
    # @param workspace_dir [String] override for the workspace installation directory
    def initialize(workspace_dir: nil)
      @workspace_dir = workspace_dir || File.expand_path("../..", __dir__)
    end

    # @return [String] the workspace installation directory
    attr_reader :workspace_dir

    # @return [String] path to the tmuxinator config directory
    def tmuxinator_dir
      File.expand_path("~/.config/tmuxinator")
    end

    # @return [String] path to the JSON state file
    def state_file
      File.expand_path("~/.workspace-state.json")
    end

    # @return [String] path to the project template
    def project_template_path
      File.join(tmuxinator_dir, "project-template.yml")
    end

    # @return [String] path to the worktree project template
    def worktree_template_path
      File.join(tmuxinator_dir, "project-worktree-template.yml")
    end

    # @return [String] the window-tool binary name
    def window_tool
      "window-tool"
    end

    # @param name [String] the project name
    # @return [String] path to the tmuxinator config file for the given project
    def config_path_for(name)
      File.join(tmuxinator_dir, "#{name}.yml")
    end
  end
end
