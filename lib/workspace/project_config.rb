module Workspace
  # Manages tmuxinator config file generation for projects and worktrees.
  class ProjectConfig
    # @param config [Workspace::Config] configuration for path lookups
    # @param git [Workspace::Git] git operations for sanitize_for_filesystem
    # @param output [IO] output stream for user-facing messages
    def initialize(config:, git:, output: $stdout)
      @config = config
      @output = output
      @git = git
      @root_cache = {}
    end

    # @param arg [String] a project name or path
    # @return [Array(String, String), Array(String, nil)] [project_name, project_root] or [name, nil];
    #   a name taken from a path is settled by {#settle_new_name}
    # @raise [Workspace::Error] code `workspace_name_case_conflict` (see {#settle_new_name})
    def resolve_project_arg(arg)
      if arg == "." || arg.include?("/") || File.directory?(arg)
        root = File.expand_path(arg)
        [settle_new_name(WorkspaceLineage.name_from_path(root), root), root]
      else
        [arg, nil]
      end
    end

    # @param name [String] project name
    # @param root [String] project root directory
    # @return [String] the project name
    # @raise [Workspace::Error] if the template is missing
    # @raise [Workspace::Error] code `workspace_name_case_conflict` (see {#settle_new_name})
    def create(name, root)
      name = settle_new_name(name, root)
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
    # @return [String] the config name {#create_worktree} gives that worktree (lowercase)
    def worktree_config_name(project_name, worktree_name)
      WorkspaceName.normalize("#{project_name}.worktree-#{@git.sanitize_for_filesystem(worktree_name)}")
    end

    # @param project_name [String] parent project name
    # @param worktree_name [String] worktree directory name
    # @param worktree_path [String] full path to the worktree
    # @param branch_name [String] git branch name
    # @param task_id [String, nil] the workspace's task id; exported as `WORKSPACE_TASK`
    #   in every pane through the template's `{{PRE_WINDOW}}` line, which is dropped without one
    # @return [String] the config name
    # @raise [Workspace::Error] if the worktree template is missing
    def create_worktree(project_name, worktree_name, worktree_path, branch_name, quiet: false, task_id: nil, agent_kind: nil)
      project_name = WorkspaceName.normalize(project_name)
      tmux_session_name = "#{project_name}.wt-#{@git.sanitize_for_filesystem(worktree_name)}"
        .tr(".", "-").downcase
      config_name = settle_worktree_name(project_name, worktree_name, worktree_path)
      config_path = @config.config_path_for(config_name)

      if File.exist?(config_path)
        @output.puts "Config already exists: #{config_path}" unless quiet
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
        .sub(/^\{\{PRE_WINDOW\}\}\n/, task_id ? "pre_window: export WORKSPACE_TASK=#{task_id}\n" : "")

      content = with_agent_kind(content, agent_kind) if agent_kind
      File.write(config_path, content)
      @output.puts "Created config: #{config_path}" unless quiet
      config_name
    end

    # @param name [String] project or config name
    # @param quiet [Boolean] print nothing to the output stream
    # @return [void]
    def remove(name, quiet: false)
      path = config_path_for(name)
      if File.exist?(path)
        File.delete(path)
        @output.puts "Removed config: #{path}" unless quiet
      end
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

    # Returns the root directory for a project by reading its tmuxinator config.
    # Results are cached for the lifetime of this instance.
    #
    # @param name [String] project name
    # @return [String, nil] the project root path, or nil if config doesn't exist
    def project_root_for(name)
      return @root_cache[name] if @root_cache.key?(name)

      @root_cache[name] = read_project_root(name)
    end

    # @return [Array<String>] sorted list of available project names
    def available_projects
      Dir.glob(File.join(@config.tmuxinator_dir, "workspace.*.yml"))
        .map { |f| File.basename(f, ".yml").delete_prefix("workspace.") }
        .reject { |n| n.match?(/^project-.*template$/) }
        .sort
    end

    # The name a new config is written under: lowercase. A config already on disk
    # whose name differs only in case (found by comparing the real file names, as
    # the file system itself ignores case) decides it:
    # - the same workspace (same root directory), written earlier with mixed
    #   case: its own name, so the config is reused and keeps working until its
    #   agentd start migrates it;
    # - another workspace (different root): refused, as the two would share one
    #   set of files and one socket on a case-insensitive file system.
    #
    # @param name [String] the name wanted
    # @param root [String, nil] the directory the workspace is for
    # @return [String]
    # @raise [Workspace::Error] code `workspace_name_case_conflict`, details `name`, `existing`, `existing_root`
    def settle_new_name(name, root)
      wanted = WorkspaceName.normalize(name)
      variants = available_projects.select { |other| other != wanted && WorkspaceName.same?(other, wanted) }
      return wanted if variants.empty?

      same = variants.find { |other| root && same_directory?(project_root_for(other), root) }
      return same if same

      existing = variants.first
      existing_root = project_root_for(existing)
      raise Workspace::Error.new(
        "Can't create workspace '#{wanted}': workspace '#{existing}' (#{existing_root || "root unknown"}) already exists and differs only in case. " \
        "'#{existing}' will be renamed to lowercase the next time its agentd starts; " \
        "until then, use '#{existing}' (see `workspace list`) or use a different directory name.",
        code: "workspace_name_case_conflict",
        details: {"name" => wanted, "existing" => existing, "existing_root" => existing_root}
      )
    end

    # @param project_name [String] parent project name
    # @param worktree_name [String] worktree directory name
    # @param worktree_path [String] full path to the worktree
    # @return [String] the config name a worktree gets: {#worktree_config_name} settled by {#settle_new_name}
    # @raise [Workspace::Error] code `workspace_name_case_conflict`
    def settle_worktree_name(project_name, worktree_name, worktree_path)
      settle_new_name(worktree_config_name(project_name, worktree_name), worktree_path)
    end

    # @return [String, nil] the config name that matches +name+ ignoring case, the exact spelling first
    def existing_name(name)
      projects = available_projects
      projects.find { |other| other == name } || projects.find { |other| WorkspaceName.same?(other, name) }
    end

    # Refuses an agent kind the installed worktree template cannot take, so `start` fails before it
    # creates anything.
    #
    # @param kind [String] an {AgentProvider} key
    # @raise [Workspace::Error] code `template_outdated` when the template has no Claude Code pane to swap
    def check_agent_kind!(kind)
      return if kind == "claude" || !File.exist?(@config.worktree_template_path)
      return if File.read(@config.worktree_template_path).match?(AGENT_PANE)
      raise Workspace::Error.new("The worktree template has no Claude Code pane to swap for #{kind}; run `workspace init --force` to refresh it.",
        code: "template_outdated", details: {"kind" => kind})
    end

    AGENT_PANE = /^(\s*- )claude --dangerously-skip-permissions.*$/

    private

    # Swaps the template's Claude Code pane for another agent's executable. Works on the installed
    # template whatever its age, since it matches the pane line rather than a placeholder.
    def with_agent_kind(content, kind)
      return content if kind == "claude"
      provider = AgentProvider.all.find { |candidate| candidate.key == kind }
      swapped = content.sub(AGENT_PANE) { "#{$1}#{provider.executable}" }
      if swapped == content
        raise Workspace::Error, "The worktree template has no Claude Code pane to swap for #{kind}; run `workspace init --force` to refresh it."
      end
      swapped
    end

    def same_directory?(first, second)
      return false if first.nil? || second.nil?

      File.realpath(first) == File.realpath(second)
    rescue SystemCallError
      File.expand_path(first) == File.expand_path(second)
    end

    def read_project_root(name)
      path = config_path_for(name)
      return nil unless File.exist?(path)

      require "yaml"
      config = YAML.safe_load_file(path)
      config&.dig("root")
    rescue Psych::SyntaxError
      nil
    end
  end
end
