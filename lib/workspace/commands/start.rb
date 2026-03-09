module Workspace
  module Commands
    # Creates a git worktree and launches it as a workspace project.
    # Accepts JIRA keys, GitHub PR/issue URLs, or branch names as input.
    class Start
      # @param git [Workspace::Git] git operations
      # @param project_config [Workspace::ProjectConfig] config generation
      # @param project_settings [Workspace::ProjectSettings] per-project settings
      # @param launch_command [#call] launch command (Commands::Launch or similar)
      # @param output [IO] output stream for user-facing messages
      # @param input [IO] input stream for interactive prompts
      def initialize(git:, project_config:, project_settings:, launch_command:, output: $stdout, input: $stdin)
        @git = git
        @project_config = project_config
        @project_settings = project_settings
        @launch_command = launch_command
        @output = output
        @input = input
      end

      # Creates a worktree from the given input and launches it.
      #
      # @param input_string [String] JIRA key, PR URL, or branch name
      # @param prompt [String, nil] optional prompt to send to Claude after launching
      # @return [void]
      # @raise [Workspace::Error] if not in a git repository
      def call(input_string, prompt: nil)
        root = @git.root
        raise Workspace::Error, "Not inside a git repository." unless root

        project_name = ProjectConfig.name_from_path(root)
        parsed = @git.parse_start_input(input_string)

        branch_name = resolve_branch_name(parsed)
        worktree_dir_name = @git.sanitize_for_filesystem(branch_name)
        worktree_path = File.join(root, ".worktrees", worktree_dir_name)

        if @git.worktree_exists?(worktree_path)
          @output.puts "Worktree already exists at: #{worktree_path}"
          config_name = @project_config.create_worktree(project_name, worktree_dir_name, worktree_path, branch_name)
          seed_worktree_hooks(project_name, config_name)
          write_project_marker(worktree_path, config_name)
          @output.puts "Launching #{config_name}..."
          prompts = prompt ? {config_name => prompt} : {}
          @launch_command.call([config_name], prompts: prompts)
          return
        end

        result = resolve_or_create_branch(branch_name)
        return if result == :cancelled

        branch_name = result[:branch_name]
        worktree_dir_name = @git.sanitize_for_filesystem(branch_name)
        worktree_path = File.join(root, ".worktrees", worktree_dir_name)

        # Check if a worktree for this branch exists at a non-standard location
        existing_path = @git.find_worktree_by_branch(branch_name)
        if existing_path
          @output.puts "Adopting existing worktree at: #{existing_path}"
          adopt_dir_name = File.basename(existing_path)
          config_name = @project_config.create_worktree(project_name, adopt_dir_name, existing_path, branch_name)
          seed_worktree_hooks(project_name, config_name)
          write_project_marker(existing_path, config_name)
          @output.puts "Launching #{config_name}..."
          prompts = prompt ? {config_name => prompt} : {}
          @launch_command.call([config_name], prompts: prompts)
          return
        end

        create_worktree_directory(root)
        @git.create_worktree(worktree_path, branch_name, base: result[:base_branch])
        @output.puts "Worktree created at: #{worktree_path}"

        ensure_gitignore(root)

        config_name = @project_config.create_worktree(project_name, worktree_dir_name, worktree_path, branch_name)
        seed_worktree_hooks(project_name, config_name)
        write_project_marker(worktree_path, config_name)
        @output.puts "Launching #{config_name}..."
        prompts = prompt ? {config_name => prompt} : {}
        @launch_command.call([config_name], prompts: prompts)
      end

      private

      def resolve_branch_name(parsed)
        case parsed[:type]
        when :pr_url
          @output.puts "Fetching PR details..."
          branch = @git.resolve_branch_from_pr(parsed[:value])
          @output.puts "PR branch: #{branch}"
          branch
        when :issue_url, :jira_key, :branch
          parsed[:value]
        end
      end

      def resolve_or_create_branch(branch_name)
        @output.puts "Fetching remote branches..."

        if @git.branch_exists?(branch_name)
          @output.puts "Branch '#{branch_name}' exists."
          return {branch_name: branch_name, base_branch: nil}
        end

        matches = @git.find_matching_branches(branch_name)
        if matches.any?
          if matches.size == 1 && matches.first == branch_name
            @output.puts "Found exact remote match: #{branch_name}"
            return {branch_name: branch_name, base_branch: nil}
          end

          selected = @git.prompt_branch_selection(matches, branch_name)
          if selected
            @output.puts "Using branch: #{selected}"
            return {branch_name: selected, base_branch: nil}
          end

          base = @git.prompt_base_branch
          unless base
            @output.puts "Cancelled."
            return :cancelled
          end
          @output.puts "Will create '#{branch_name}' from '#{base}'"
          return {branch_name: branch_name, base_branch: base}
        end

        base = @git.prompt_base_branch
        unless base
          @output.puts "Cancelled."
          return :cancelled
        end
        @output.puts "Will create '#{branch_name}' from '#{base}'"
        {branch_name: branch_name, base_branch: base}
      end

      def seed_worktree_hooks(parent_project, worktree_config_name)
        parent_data = @project_settings.load(parent_project)
        worktree_hooks = parent_data["worktree_hooks"]
        return unless worktree_hooks&.any?

        worktree_data = @project_settings.load(worktree_config_name)
        return if worktree_data["hooks"]&.any?

        worktree_data["hooks"] = worktree_hooks.dup
        @project_settings.save(worktree_config_name, worktree_data)
      end

      def write_project_marker(worktree_path, config_name)
        return unless File.directory?(worktree_path)
        File.write(File.join(worktree_path, ".workspace-project"), config_name)
      end

      def create_worktree_directory(root)
        worktrees_dir = File.join(root, ".worktrees")
        Dir.mkdir(worktrees_dir) unless File.directory?(worktrees_dir)
      end

      def ensure_gitignore(root)
        gitignore = File.join(root, ".gitignore")
        if File.exist?(gitignore)
          unless File.read(gitignore).include?(".worktrees")
            File.open(gitignore, "a") { |f| f.puts ".worktrees" }
            @output.puts "Added .worktrees to .gitignore"
          end
        end
      end
    end
  end
end
