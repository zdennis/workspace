require "json"
require "fileutils"

module Workspace
  module Commands
    # Creates a git worktree and launches it as a workspace project.
    # Accepts JIRA keys, GitHub PR/issue URLs, or branch names as input.
    class Start
      JSON_SCHEMA_VERSION = 1

      # @param git [Workspace::Git] git operations
      # @param project_config [Workspace::ProjectConfig] config generation
      # @param project_settings [Workspace::ProjectSettings] per-project settings
      # @param launch_command [#call] launch command (Commands::Launch or similar)
      # @param output [IO] output stream for user-facing messages
      # @param input [IO] input stream for interactive prompts
      # @param lineage [Workspace::WorkspaceLineage] writes the `.workspace-project` marker
      # @param hook_installer [Workspace::HookInstaller, nil] installs agent hooks
      #   (edit lock enforcement, session monitoring) into the new worktree; nil skips it
      # @param which [#call] returns true when an executable is on PATH
      def initialize(git:, project_config:, project_settings:, launch_command:, lineage: WorkspaceLineage.new,
        hook_installer: nil, which: nil, output: $stdout, input: $stdin, error_output: $stderr)
        @git = git
        @project_config = project_config
        @project_settings = project_settings
        @launch_command = launch_command
        @lineage = lineage
        @hook_installer = hook_installer
        @which = which || Workspace::Which
        @output = output
        @input = input
        @error_output = error_output
      end

      # Creates a worktree from the given input and launches it.
      #
      # @param input_string [String] JIRA key, PR URL, or branch name
      # @param prompt [String, nil] optional prompt to send to the coding agent after launching
      # @param prompt_timeout [Numeric, nil] seconds to wait for the agent to be
      #   ready before giving up on the prompt; nil uses the launch command's default
      # @param base [String, nil] branch/ref to create a new branch from, skipping the
      #   base-branch prompt
      # @param yes [Boolean] accept every default instead of prompting
      # @param headless [Boolean] launch the session in the background with plain
      #   tmux instead of in iTerm2 (see Commands::Launch#call)
      # @param json [Boolean] emit the documented JSON schema instead of plain text; on
      #   an error, prints `{"schema_version":1,"error":"..."}` to stdout and returns
      #   +{exit_code: 1}+ instead of raising
      # @return [Hash, nil] the launch result (+{exit_code:, prompt_failures:}+) merged
      #   with the JSON payload when +json+ is true, or nil if branch selection was
      #   cancelled (only possible when not +json+ and not +yes+)
      # @raise [Workspace::Error] if not in a git repository (unless +json+ is true)
      # @raise [Workspace::UsageError] if a prompt would block on a non-TTY stdin and
      #   neither +base+ nor +yes+ resolves it (unless +json+ is true)
      def call(input_string, prompt: nil, prompt_timeout: nil, base: nil, yes: false, headless: false, json: false)
        return call_json(input_string, prompt: prompt, prompt_timeout: prompt_timeout, base: base, yes: yes, headless: headless) if json

        start!(input_string, prompt: prompt, prompt_timeout: prompt_timeout, base: base, yes: yes, headless: headless, quiet: false)
      end

      private

      def call_json(input_string, prompt:, prompt_timeout:, base:, yes:, headless:)
        payload = start!(input_string, prompt: prompt, prompt_timeout: prompt_timeout, base: base, yes: yes, headless: headless, quiet: true)
        @output.puts JSON.generate(payload[:json])
        {exit_code: payload[:exit_code]}
      rescue Workspace::Error, SystemCallError => e
        @output.puts JSON.generate({"schema_version" => JSON_SCHEMA_VERSION, "error" => e.message})
        {exit_code: 1}
      end

      # @return [Hash] when quiet is true, +{exit_code:, json:}+; otherwise the
      #   launch result, or nil if branch selection was cancelled
      def start!(input_string, prompt:, prompt_timeout:, base:, yes:, headless:, quiet:)
        root = @git.root
        raise Workspace::Error, "Not inside a git repository." unless root

        interactive = !quiet && !yes && stdin_tty?
        @warnings = []

        project_name = WorkspaceLineage.name_from_path(root)
        parsed = @git.parse_start_input(input_string)

        branch_name = resolve_branch_name(parsed, quiet: quiet)
        worktree_dir_name = @git.sanitize_for_filesystem(branch_name)
        worktree_path = File.join(root, ".worktrees", worktree_dir_name)

        if @git.worktree_exists?(worktree_path)
          note_base_ignored(branch_name, quiet: quiet) if base
          return finish_worktree(project_name, worktree_dir_name, worktree_path, branch_name,
            base: nil, created: false, prompt: prompt, prompt_timeout: prompt_timeout, headless: headless, quiet: quiet, already_exists: true)
        end

        result = resolve_or_create_branch(branch_name, base: base, yes: yes, interactive: interactive, quiet: quiet)
        return if result == :cancelled

        branch_name = result[:branch_name]
        worktree_dir_name = @git.sanitize_for_filesystem(branch_name)
        worktree_path = File.join(root, ".worktrees", worktree_dir_name)

        # Check if a worktree for this branch exists at a non-standard location
        existing_path = @git.find_worktree_by_branch(branch_name, repo: root)
        if existing_path
          return finish_worktree(project_name, File.basename(existing_path), existing_path, branch_name,
            base: nil, created: false, prompt: prompt, prompt_timeout: prompt_timeout, headless: headless, quiet: quiet, adopted: true)
        end

        create_worktree_directory(root)
        begin
          @git.create_worktree(worktree_path, branch_name, base: result[:base_branch], quiet: quiet)
        rescue Errno::EEXIST
          # A concurrent `start` finished creating .worktrees/ at the same moment; harmless.
        end
        log(quiet, "Worktree created at: #{worktree_path}")

        ensure_gitignore(root, quiet: quiet)

        finish_worktree(project_name, worktree_dir_name, worktree_path, branch_name,
          base: result[:base_branch], created: true, prompt: prompt, prompt_timeout: prompt_timeout, headless: headless, quiet: quiet)
      end

      # Shared tail of every branch: config generation, hook seeding/installation,
      # marker, launch, and (when quiet) the JSON payload.
      def finish_worktree(project_name, worktree_dir_name, worktree_path, branch_name, base:, created:,
        prompt:, prompt_timeout:, headless:, quiet:, already_exists: false, adopted: false)
        log(quiet, "Worktree already exists at: #{worktree_path}") if already_exists
        log(quiet, "Adopting existing worktree at: #{worktree_path}") if adopted

        config_name = @project_config.create_worktree(project_name, worktree_dir_name, worktree_path, branch_name, quiet: quiet)
        @project_settings.ensure_exists(project_name)
        seed_worktree_hooks(project_name, config_name)
        install_agent_hooks(worktree_path, quiet: quiet)
        write_project_marker(worktree_path, config_name)
        log(quiet, "Launching #{config_name}...")
        prompts = prompt ? {config_name => prompt} : {}
        result = launch(config_name, prompts, prompt_timeout, headless: headless, quiet: quiet)
        @project_settings.ensure_exists(config_name)

        return result unless quiet

        exit_code = result ? result[:exit_code] : 0
        json = {
          "schema_version" => JSON_SCHEMA_VERSION,
          "project" => project_name,
          "workspace" => config_name,
          "path" => worktree_path,
          "branch" => branch_name,
          "base" => base,
          "created" => created,
          "headless" => headless
        }
        json["session_reused"] = result[:reused].include?(config_name) if result && result[:reused]
        if exit_code != 0
          prompt_failures = result && result[:prompt_failures]
          start_failure = result && result[:start_failures] && result[:start_failures][config_name]
          if start_failure
            json["error"] = "Could not start the workspace session: #{start_failure}"
          else
            json["error"] = "Prompt was not sent to every workspace."
            json["prompt_failures"] = prompt_failures || {}
          end
        end
        json["warnings"] = @warnings if @warnings&.any?

        {exit_code: exit_code, json: json}
      end

      def note_base_ignored(branch_name, quiet:)
        message = "Note: --base ignored; branch '#{branch_name}' already exists."
        if quiet
          @warnings << message
        else
          @error_output.puts message
        end
      end

      # @return [Boolean] false (never blocks on a prompt) for a non-TTY, or a
      #   closed, stdin -- rather than raising IOError from a closed stream.
      def stdin_tty?
        @input.respond_to?(:tty?) && @input.tty?
      rescue IOError
        false
      end

      def log(quiet, message)
        @output.puts message unless quiet
      end

      # @param prompt_timeout [Numeric, nil] nil defers to the launch command's own default
      def launch(config_name, prompts, prompt_timeout, headless:, quiet:)
        kwargs = {prompts: prompts}
        kwargs[:headless] = true if headless
        kwargs[:prompt_timeout] = prompt_timeout unless prompt_timeout.nil?
        kwargs[:quiet] = true if quiet
        @launch_command.call([config_name], **kwargs)
      end

      def resolve_branch_name(parsed, quiet:)
        case parsed[:type]
        when :pr_url
          log(quiet, "Fetching PR details...")
          branch = @git.resolve_branch_from_pr(parsed[:value])
          log(quiet, "PR branch: #{branch}")
          branch
        when :issue_url, :jira_key, :branch
          parsed[:value]
        end
      end

      def resolve_or_create_branch(branch_name, base:, yes:, interactive:, quiet:)
        if @git.branch_exists?(branch_name)
          note_base_ignored(branch_name, quiet: quiet) if base
          return {branch_name: branch_name, base_branch: nil}
        end

        matches = @git.find_matching_branches(branch_name)
        if matches.any?
          if matches.size == 1 && matches.first == branch_name
            return {branch_name: branch_name, base_branch: nil}
          end

          if interactive
            selected = @git.prompt_branch_selection(matches, branch_name)
            return {branch_name: selected, base_branch: nil} if selected
          elsif !base && !yes
            raise Workspace::UsageError,
              "Multiple remote branches match '#{branch_name}': #{matches.join(", ")}.\n" \
              "Pass --base <ref> or --yes to create '#{branch_name}' as a new branch instead, " \
              "or rerun with an unambiguous branch name."
          end
          # Non-interactive with --base or --yes, or interactive selection of
          # "none", both fall through to creating branch_name from a base below.
        end

        base_branch = resolve_base_branch(base: base, yes: yes, interactive: interactive)
        return :cancelled if base_branch == :cancelled

        {branch_name: branch_name, base_branch: base_branch}
      end

      def resolve_base_branch(base:, yes:, interactive:)
        return base if base
        return @git.default_branch if yes

        unless interactive
          raise Workspace::UsageError,
            "Branch does not exist and needs a base to create it from.\n" \
            "Pass --base <ref> or --yes to use the default branch."
        end

        @git.prompt_base_branch || :cancelled
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

      # Installs each detected, hook-capable agent's hooks (session monitoring
      # and edit lock enforcement) into a new or adopted worktree, the same way
      # `workspace init` does for the parent project. Silent, no prompt: a
      # worktree an agent will immediately be launched into should already be
      # enforcing the edit lock.
      def install_agent_hooks(worktree_path, quiet:)
        return unless @hook_installer

        AgentProvider.all.select { |p| p.supports_hooks? && @which.call(p.executable) }.each do |provider|
          @hook_installer.install(provider, worktree_path, Commands::Init::HOOK_COMMAND, quiet: quiet)
        end
      end

      def write_project_marker(worktree_path, config_name)
        @lineage.write_marker(worktree_path, config_name)
      end

      def create_worktree_directory(root)
        FileUtils.mkdir_p(File.join(root, ".worktrees"))
      rescue Errno::EEXIST
        # Another concurrent `start` created it between our check and mkdir; fine.
      end

      def ensure_gitignore(root, quiet:)
        gitignore = File.join(root, ".gitignore")
        if File.exist?(gitignore)
          unless File.read(gitignore).include?(".worktrees")
            File.open(gitignore, "a") { |f| f.puts ".worktrees" }
            log(quiet, "Added .worktrees to .gitignore")
          end
        end
      end
    end
  end
end
