require "yaml"

module Workspace
  module Commands
    # Sets up workspace by installing tmuxinator templates and creating
    # the config directory if it doesn't exist.
    class Init
      TEMPLATES = [
        "workspace.project-template.yml",
        "workspace.project-worktree-template.yml"
      ].freeze

      # Hooks route agent events to this command, which the agent daemon reads.
      HOOK_COMMAND = "workspace session-event".freeze

      # The statusLine command Claude Code runs so `workspace statusline` can
      # read and store `context_window.used_percentage` for the pane.
      STATUSLINE_COMMAND = "workspace statusline".freeze

      # @param config [Workspace::Config] configuration for path lookups
      # @param hook_installer [Workspace::HookInstaller] installs agent hooks
      # @param which [#call] returns true when an executable is on PATH
      # @param output [IO] output stream for user-facing messages
      # @param error_output [IO] error output stream for warnings
      # @param input [IO] input stream for interactive confirmation
      def initialize(config:, hook_installer:, which: nil,
        output: $stdout, error_output: $stderr, input: $stdin)
        @config = config
        @hook_installer = hook_installer
        @which = which || ->(exe) { system("command", "-v", exe, out: File::NULL, err: File::NULL) }
        @output = output
        @error_output = error_output
        @input = input
      end

      DEFAULT_GLOBAL_CONFIG = {"hooks" => {}, "layouts" => {}}.freeze

      # @param dry_run [Boolean] show what would be done without making changes
      # @param force [Boolean] overwrite existing templates even if they differ
      # @param project_root [String] project whose agent settings receive hooks
      # @param hooks [Boolean, nil] true installs without asking, false skips the
      #   phase entirely, nil (the default) prompts
      # @return [void]
      def call(dry_run: false, force: false, project_root: Dir.pwd, hooks: nil)
        @output.puts "workspace init#{" (dry run)" if dry_run}"
        @output.puts ""

        ensure_tmuxinator_dir(dry_run)
        install_templates(dry_run, force)
        ensure_workspace_config_dir(dry_run)
        install_global_config(dry_run)
        install_agent_hooks(dry_run, project_root, hooks)

        @output.puts ""
        if dry_run
          @output.puts "No changes made (dry run)."
        else
          @output.puts "Done! Workspace is ready to use."
        end
      end

      private

      # Agent hooks are per-project, unlike everything else init installs, so
      # this phase is announced separately and always names the directory it
      # would touch.
      def install_agent_hooks(dry_run, project_root, hooks)
        return if hooks == false

        detected, missing = AgentProvider.all.partition { |p| @which.call(p.executable) }

        @output.puts ""
        @output.puts "Session monitoring agents (#{project_root}):"
        report_agents(detected, missing, project_root)

        installable = detected.select(&:supports_hooks?)
        return @output.puts "  No detected agent supports hooks; nothing to install." if installable.empty?

        @output.puts ""
        @output.puts "  Would add: #{@hook_installer.summary(installable.first, HOOK_COMMAND)}"

        return installable.each { |provider| @hook_installer.install(provider, project_root, HOOK_COMMAND, dry_run: dry_run) } if hooks

        loop do
          case prompt_action(installable)
          when "v"
            @hook_installer.preview(installable.first, HOOK_COMMAND)
          when "i"
            installable.each { |provider| @hook_installer.install(provider, project_root, HOOK_COMMAND, dry_run: dry_run) }
            break
          else
            break
          end
        end
      end

      def report_agents(detected, missing, project_root)
        detected.each do |provider|
          status = if provider.supports_hooks?
            @hook_installer.settings_path_for(provider, project_root)
          else
            "no hook support yet -- monitored by pane activity only"
          end
          @output.puts "  found   #{provider.label.ljust(12)} #{status}"
        end
        missing.each do |provider|
          @output.puts "  absent  #{provider.label.ljust(12)} (#{provider.executable} not on PATH)"
        end
      end

      def prompt_action(providers)
        names = providers.map(&:label).join(", ")
        @output.print "  [v]iew, [i]nstall for #{names}, or [n]othing? [v/i/N] "
        @input.gets&.strip&.downcase
      end

      def ensure_tmuxinator_dir(dry_run)
        tmuxinator_dir = @config.tmuxinator_dir

        if File.directory?(tmuxinator_dir)
          @output.puts "  exists  #{tmuxinator_dir}"
        elsif dry_run
          @output.puts "  create  #{tmuxinator_dir}"
        else
          FileUtils.mkdir_p(tmuxinator_dir)
          @output.puts "  create  #{tmuxinator_dir}"
        end
      end

      def install_templates(dry_run, force)
        TEMPLATES.each do |template|
          src = File.join(@config.templates_dir, template)
          dest = File.join(@config.tmuxinator_dir, template)

          unless File.exist?(src)
            @error_output.puts "  error   #{template} not found in #{@config.templates_dir}"
            next
          end

          install_template(src, dest, template, dry_run, force)
        end
      end

      def ensure_workspace_config_dir(dry_run)
        workspace_dir = @config.workspace_config_dir
        projects_dir = File.join(workspace_dir, "projects")

        [workspace_dir, projects_dir].each do |dir|
          if File.directory?(dir)
            @output.puts "  exists  #{dir}"
          elsif dry_run
            @output.puts "  create  #{dir}"
          else
            FileUtils.mkdir_p(dir)
            @output.puts "  create  #{dir}"
          end
        end
      end

      def install_global_config(dry_run)
        path = File.join(@config.workspace_config_dir, "config.yml")

        if File.exist?(path)
          @output.puts "  skip    config.yml (already exists)"
        elsif dry_run
          @output.puts "  create  config.yml -> #{path}"
        else
          File.write(path, YAML.dump(DEFAULT_GLOBAL_CONFIG))
          @output.puts "  create  config.yml -> #{path}"
        end
      end

      def install_template(src, dest, template, dry_run, force)
        if File.exist?(dest)
          if FileUtils.identical?(src, dest)
            @output.puts "  skip    #{template} (already up to date)"
          elsif force
            FileUtils.cp(src, dest) unless dry_run
            @output.puts "  update  #{template} -> #{dest}"
          else
            @output.puts "  skip    #{template} (already exists, use --force to overwrite)"
          end
        elsif dry_run
          @output.puts "  copy    #{template} -> #{dest}"
        else
          FileUtils.cp(src, dest)
          @output.puts "  copy    #{template} -> #{dest}"
        end
      end
    end
  end
end
