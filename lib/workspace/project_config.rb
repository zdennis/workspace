module Workspace
  # Manages tmuxinator config file generation for projects and worktrees.
  class ProjectConfig
    # @param config [Workspace::Config] configuration for path lookups
    # @param output [IO] output stream for user-facing messages
    # @param git [Workspace::Git] git operations for sanitize_for_filesystem
    def initialize(config:, git:, output: $stdout)
      @config = config
      @output = output
      @git = git
    end

    # @param arg [String] a project name or path
    # @return [Array(String, String), Array(String, nil)] [project_name, project_root] or [name, nil]
    def resolve_project_arg(arg)
      if arg == "." || arg.include?("/") || File.directory?(arg)
        root = File.expand_path(arg)
        name = File.basename(root)
        [name, root]
      else
        [arg, nil]
      end
    end

    # @param name [String] project name
    # @param root [String] project root directory
    # @return [String] the project name
    # @raise [Workspace::Error] if the template is missing
    def create(name, root)
      config_path = @config.config_path_for(name)
      if File.exist?(config_path)
        @output.puts "Config already exists: #{config_path}"
        return name
      end

      unless File.exist?(@config.project_template_path)
        raise Workspace::Error, "Template not found: #{@config.project_template_path}"
      end

      template = File.read(@config.project_template_path)
      content = template
        .gsub("{{PROJECT_NAME}}", name)
        .gsub("{{PROJECT_ROOT}}", root)
        .gsub("{{CONFIG_PATH}}", config_path)

      File.write(config_path, content)
      @output.puts "Created config: #{config_path}"
      name
    end

    # @param project_name [String] parent project name
    # @param worktree_name [String] worktree directory name
    # @param worktree_path [String] full path to the worktree
    # @param branch_name [String] git branch name
    # @return [String] the config name
    # @raise [Workspace::Error] if the worktree template is missing
    def create_worktree(project_name, worktree_name, worktree_path, branch_name)
      tmux_session_name = "#{project_name}.wt-#{@git.sanitize_for_filesystem(worktree_name)}"
        .tr(".", "-")
      config_name = "#{project_name}.worktree-#{@git.sanitize_for_filesystem(worktree_name)}"
      config_path = @config.config_path_for(config_name)

      if File.exist?(config_path)
        @output.puts "Config already exists: #{config_path}"
        return config_name
      end

      unless File.exist?(@config.worktree_template_path)
        raise Workspace::Error, "Worktree template not found: #{@config.worktree_template_path}"
      end

      template = File.read(@config.worktree_template_path)
      content = template
        .gsub("{{TMUX_SESSION_NAME}}", tmux_session_name)
        .gsub("{{WORKTREE_PATH}}", worktree_path)
        .gsub("{{PROJECT_NAME}}", project_name)
        .gsub("{{WORKTREE_BRANCH}}", branch_name)
        .gsub("{{DISPLAY_NAME}}", "#{project_name}/#{worktree_name}")
        .gsub("{{CONFIG_PATH}}", config_path)

      File.write(config_path, content)
      @output.puts "Created config: #{config_path}"
      config_name
    end

    # @param name [String] project name
    # @return [String] path to the tmuxinator config file for the given project
    def config_path_for(name)
      @config.config_path_for(name)
    end

    # @param name [String] project name
    # @return [Boolean] whether a config exists for this project
    def exists?(name)
      File.exist?(config_path_for(name))
    end

    # @return [Array<String>] sorted list of available project names
    def available_projects
      Dir.glob(File.join(@config.tmuxinator_dir, "*.yml"))
        .map { |f| File.basename(f, ".yml") }
        .reject { |n| n.match?(/^project-.*template$/) }
        .sort
    end
  end
end
