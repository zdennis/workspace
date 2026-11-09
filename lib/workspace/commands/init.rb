require "yaml"

require_relative "../core/atomic_file"

module Workspace
  module Commands
    # Sets up workspace by installing tmuxinator templates and creating
    # the config directory if it doesn't exist.
    class Init
      TEMPLATES = [
        "workspace.project-template.yml",
        "workspace.project-worktree-template.yml"
      ].freeze

      # @param config [Workspace::Config] configuration for path lookups
      # @param hook_installer [Workspace::HookInstaller] installs agent hooks
      # @param workflow_installer [Workspace::WorkflowSourceInstaller, nil] installs the
      #   workflows of the sources `--workflow-sources` adds; nil reports the entries
      #   without installing them
      # @param which [#call] returns true when an executable is on PATH
      # @param output [IO] output stream for user-facing messages
      # @param error_output [IO] error output stream for warnings
      # @param input [IO] input stream for interactive confirmation
      def initialize(config:, hook_installer:, workflow_installer: nil, which: nil, agent_commands: nil,
        output: $stdout, error_output: $stderr, input: $stdin)
        @config = config
        @hook_installer = hook_installer
        @workflow_installer = workflow_installer
        @agent_commands = agent_commands
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
      # @param workflow_sources [Array<String>] `workflows.sources` entries to append to the global config;
      #   each value may hold several, separated by commas or newlines
      # @return [void]
      def call(dry_run: false, force: false, project_root: Dir.pwd, hooks: nil, workflow_sources: [])
        @output.puts "workspace init#{" (dry run)" if dry_run}"
        @output.puts ""

        ensure_tmuxinator_dir(dry_run)
        install_templates(dry_run, force)
        ensure_workspace_config_dir(dry_run)
        install_global_config(dry_run)
        install_workflow_sources(dry_run, add_workflow_sources(dry_run, workflow_sources))
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

        detected, missing = AgentProvider.all.partition { |p| @which.call(executable_for(p)) }

        @output.puts ""
        @output.puts "Session monitoring agents (#{project_root}):"
        report_agents(detected, missing, project_root)

        installable = detected.select(&:supports_hooks?)
        return @output.puts "  No detected agent supports hooks; nothing to install." if installable.empty?

        @output.puts ""
        installable.each do |provider|
          @output.puts "  Would add: #{@hook_installer.summary(provider, HookInstaller::HOOK_COMMAND)}#{" to #{provider.label}" if installable.size > 1}"
        end

        return installable.each { |provider| install_hooks(provider, project_root, dry_run) } if hooks

        loop do
          case prompt_action(installable)
          when "v"
            installable.each { |provider| @hook_installer.preview(provider, HookInstaller::HOOK_COMMAND) }
          when "i"
            installable.each { |provider| install_hooks(provider, project_root, dry_run) }
            break
          else
            break
          end
        end
      end

      # A user-level hook file (Codex's) is not the project's: one that can't
      # be read is reported and the rest of init goes on.
      def install_hooks(provider, project_root, dry_run)
        @hook_installer.install(provider, project_root, HookInstaller::HOOK_COMMAND, dry_run: dry_run)
      rescue Workspace::Error => e
        raise unless provider.user_scoped?

        @error_output.puts "  warn    #{provider.label} hooks not installed: #{e.message}"
      end

      # The program to look for: the one the global `agent.commands.<kind>` starts, else the agent's own.
      def executable_for(provider)
        @agent_commands ? @agent_commands.executable_for(nil, provider.key) : provider.executable
      end

      def report_agents(detected, missing, project_root)
        detected.each do |provider|
          status = if provider.supports_hooks?
            path = @hook_installer.settings_path_for(provider, project_root)
            provider.user_scoped? ? "#{path} (user-level, for every project)" : path
          else
            "no hook support yet -- monitored by pane activity only"
          end
          @output.puts "  found   #{provider.label.ljust(12)} #{status}"
        end
        missing.each do |provider|
          @output.puts "  absent  #{provider.label.ljust(12)} (#{executable_for(provider)} not on PATH)"
        end
      end

      def prompt_action(providers)
        names = providers.map(&:label).join(", ")
        Prompt.ask(@input, @output, "  [v]iew, [i]nstall for #{names}, or [n]othing? [v/i/N] ")&.strip&.downcase
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
          AtomicFile.write(path, YAML.dump(DEFAULT_GLOBAL_CONFIG))
          @output.puts "  create  config.yml -> #{path}"
        end
      end

      # Appends the given entries to the global `workflows.sources`, skipping ones already listed. An
      # entry the schema refuses is reported and left out; the rest still go in.
      #
      # @return [Array<Integer>] the 1-based positions in the combined list of the entries it just added,
      #   the ones {#install_workflow_sources} installs; empty when nothing was added
      def add_workflow_sources(dry_run, values)
        wanted = Array(values).flat_map { |value| value.to_s.split(/[\n,]+/) }.map(&:strip).reject(&:empty?).uniq
        return [] if wanted.empty?

        path = File.join(@config.workspace_config_dir, "config.yml")
        data = File.exist?(path) ? YAML.safe_load_file(path) : nil
        data = DEFAULT_GLOBAL_CONFIG.dup unless data.is_a?(Hash)
        workflows = data["workflows"].is_a?(Hash) ? data["workflows"] : {}
        current = ConfigSchema.parse("workflows.sources", workflows["sources"] || [])

        accepted = wanted.select do |entry|
          ConfigSchema.parse("workflows.sources", [entry])
          true
        rescue ArgumentError => e
          @error_output.puts "  error   workflows.sources: #{e.message}"
          false
        end
        added = accepted - current
        if added.empty? && accepted.any?
          @output.puts "  skip    workflows.sources (already lists #{accepted.join(", ")})"
          return []
        end
        return [] if added.empty?

        combined = current + added
        ConfigSchema.parse("workflows.sources", combined)
        unless dry_run
          data["workflows"] = workflows
          data["workflows"]["sources"] = combined.join(", ")
          AtomicFile.write(path, YAML.dump(data))
        end
        @output.puts "  update  workflows.sources -> #{combined.join(", ")}"
        ((current.size + 1)..combined.size).to_a
      rescue ArgumentError, Workspace::ConfigParseError, Psych::Exception => e
        @error_output.puts "  error   workflows.sources: #{e.message}"
        []
      end

      # Installs the workflows of the sources just added, one `workflow install` source at a time.
      # A source that can't be installed (no `gh`, no network, a refused definition) is a warning;
      # init still succeeds and the entries stay listed, so `workspace workflow install` can be
      # re-run later.
      def install_workflow_sources(dry_run, positions)
        return if positions.empty?
        return @output.puts "  would install workflows from source #{positions.join(", ")} (run `workspace workflow install` after init)" if dry_run
        return @output.puts "  skip    workflows.sources install (installer not wired)" unless @workflow_installer

        positions.each do |position|
          result = @workflow_installer.install(only: position)
          row = (result["sources"] || []).find { |each| each["index"] == position }
          next unless row
          if (row["problems"] || []).any?
            row["problems"].each { |problem| @error_output.puts "  error   source:#{position} #{problem["file"]}: #{problem["message"]} (#{problem["code"]})" }
          else
            @output.puts "  install source:#{position} #{row["workflows"].join(", ")} (#{row["path"]})"
          end
        rescue Workspace::Error => e
          @error_output.puts "  warn    source:#{position} not installed: #{e.message}"
        end
        @output.puts "  re-run `workspace workflow install` to add, change or remove workflows from the sources."
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
