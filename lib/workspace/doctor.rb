require "open3"

module Workspace
  # Checks that all required dependencies are installed and configured.
  class Doctor
    # @param config [Workspace::Config] configuration for path lookups
    # @param state [Workspace::State] state persistence for health checks
    # @param hook_installer [Workspace::HookInstaller] checks agent hook installation
    # @param project_detector [Workspace::ProjectDetector] detects the current project
    # @param which [#call] returns true when an executable is on PATH
    # @param git [Workspace::Git, nil] lists worktrees to check for lock hooks; nil skips that check
    # @param pipeline_config [Workspace::PipelineConfig, nil] validates the current project's pipeline config
    # @param launch_mode [Workspace::LaunchMode, nil] decides whether iTerm2 and
    #   window-tool are needed; nil builds one from +config+
    # @param project_settings [Workspace::ProjectSettings, nil] reads/writes the
    #   global config for the statusLine check and `--fix`; nil builds one from +config+
    # @param working_dir [String] directory to detect the current project from
    # @param output [IO] output stream for results
    def initialize(config:, state:, hook_installer:, project_detector:, which: nil, git: nil,
      pipeline_config: nil, launch_mode: nil, project_settings: nil, working_dir: Dir.pwd, output: $stdout)
      @launch_mode = launch_mode || LaunchMode.new(project_settings: ProjectSettings.new(config: config), which: which)
      @config = config
      @state = state
      @hook_installer = hook_installer
      @project_detector = project_detector
      @which = which || Workspace::Which
      @git = git
      @pipeline_config = pipeline_config || PipelineConfig.new(config: config)
      @project_settings = project_settings || ProjectSettings.new(config: config)
      @working_dir = working_dir
      @output = output
    end

    # @param headless [Boolean, nil] the `--[no-]headless` flag; nil lets
    #   {LaunchMode} decide. Headless skips the iTerm2 and window-tool checks.
    # @param fix [Boolean] install the statusLine entry (via {HookInstaller},
    #   with a backup) before running checks, so this run reports the fixed
    #   state. The only fix `doctor --fix` performs today.
    # @return [void]
    # @raise [Workspace::Error] if any issues are found
    def run(headless: nil, fix: false)
      @fix_failed = false
      apply_fixes if fix
      mode = @launch_mode.resolve(headless)
      @output.puts "workspace doctor"
      @output.puts ""
      @output.puts "  mode: #{mode.headless? ? "headless" : "iTerm2"} (#{mode.reason})"

      issues = 0

      checks = [
        {
          name: "ruby",
          check: -> { check_command("ruby", version_pattern: /(\d+)/, min_major: 3, install_hint: "Install via rbenv, asdf, or https://www.ruby-lang.org/en/downloads/") }
        },
        {
          name: "tmux",
          check: -> { check_command("tmux", version_flag: "-V", version_pattern: /(\d+)/, min_major: 3, install_hint: "brew install tmux") }
        },
        {
          name: "tmuxinator",
          check: -> { check_command("tmuxinator", version_flag: "version", version_pattern: /(\d+)/, install_hint: "brew install tmuxinator") }
        },
        {
          name: "iTerm2",
          gui: true,
          check: -> { check_app("iTerm2", bundle_id: "com.googlecode.iterm2", install_hint: "https://iterm2.com/") }
        },
        {
          name: "window-tool",
          gui: true,
          check: -> { check_command("window-tool", version_flag: nil, install_hint: "https://github.com/zdennis/window-tool") }
        },
        {
          name: "git",
          check: -> { check_command("git", version_pattern: /(\d+)/, min_major: 2, install_hint: "brew install git") }
        },
        {
          name: "gh",
          check: -> { check_command("gh", version_pattern: /(\d+)/, min_major: 2, install_hint: "brew install gh") }
        },
        {
          name: "ascii-banner",
          check: -> { check_command("ascii-banner", version_flag: nil, install_hint: "https://github.com/zdennis/homebrew-bin/blob/main/docs/README.ascii-banner.md") }
        }
      ]

      checks.each do |entry|
        if entry[:gui] && mode.headless?
          @output.puts "  ⊘  #{entry[:name]} (not needed headless, skipped)"
          next
        end
        result = entry[:check].call
        if result[:found]
          if result[:outdated]
            @output.puts "  ✗  #{entry[:name]} (found #{result[:version]}, need #{result[:min_version]})"
            @output.puts "     ↳ install: #{result[:install_hint]}"
            issues += 1
          elsif result[:version]
            @output.puts "  ✓  #{entry[:name]} (#{result[:version]})"
          else
            @output.puts "  ✓  #{entry[:name]}"
          end
        else
          @output.puts "  ✗  #{entry[:name]} (not found)"
          @output.puts "     ↳ install: #{result[:install_hint]}"
          issues += 1
        end
      end

      templates = ["workspace.project-template.yml", "workspace.project-worktree-template.yml"]
      all_installed = templates.all? { |t| File.exist?(File.join(@config.tmuxinator_dir, t)) }

      if all_installed
        @output.puts "  ✓  templates installed"
      else
        missing = templates.reject { |t| File.exist?(File.join(@config.tmuxinator_dir, t)) }
        @output.puts "  ✗  templates (missing: #{missing.join(", ")})"
        @output.puts "     ↳ fix: run 'workspace init' to install them"
        issues += 1
      end

      issues += check_duplicate_window_ids
      issues += check_session_monitoring
      # A failed --fix (printed above, with its own reason) counts as an
      # issue so `doctor --fix` still exits non-zero when there was nothing
      # it could actually do.
      issues += 1 if @fix_failed

      @output.puts ""
      if issues > 0
        raise Workspace::Error, "#{issues} issue(s) found."
      else
        @output.puts "Everything looks good!"
      end
    end

    private

    # `--fix` is limited to one thing today: routing Claude's statusLine
    # through `workspace statusline`, via the same {HookInstaller} used by
    # `workspace init`. Applied before the checks run, so this same call
    # reports the fixed state rather than requiring a second `doctor` run.
    def apply_fixes
      project = @project_detector.detect(@working_dir)
      unless project
        @output.puts "--fix: not inside a workspace project here, so there's nothing to fix"
        @fix_failed = true
        return
      end

      capable = AgentProvider.all.select { |p| p.supports_hooks? && @which.call(p.executable) }
      if capable.empty?
        @output.puts "--fix: no hook-capable agent detected on PATH, so there's nothing to fix"
        @fix_failed = true
        return
      end

      statusline_capable = capable.select(&:supports_statusline?)
      if statusline_capable.empty?
        @output.puts "--fix: no statusLine-capable agent detected on PATH, so there's nothing to fix"
        @fix_failed = true
        return
      end

      statusline_capable.each do |provider|
        @hook_installer.install_statusline(provider, @working_dir, command: Commands::Init::STATUSLINE_COMMAND,
          project_settings: @project_settings)
      end
      @output.puts "Restart any running Claude Code sessions for the statusLine change to take effect."
    end

    def check_duplicate_window_ids
      @state.load
      return 0 if @state.empty?

      ids_to_projects = {}
      @state.each do |project, data|
        wid = data["iterm_window_id"]
        next unless wid
        (ids_to_projects[wid] ||= []) << project
      end

      duplicates = ids_to_projects.select { |_, projects| projects.size > 1 }
      if duplicates.any?
        @output.puts "  ✗  state: duplicate window IDs detected"
        duplicates.each do |wid, projects|
          @output.puts "     ↳ window #{wid} claimed by: #{projects.join(", ")}"
        end
        @output.puts "     ↳ fix: run 'workspace stop' then 'workspace launch' for affected projects"
        1
      else
        @output.puts "  ✓  state: no duplicate window IDs"
        0
      end
    end

    def check_session_monitoring
      project = @project_detector.detect(@working_dir)
      unless project
        @output.puts "  ⊘  session monitoring (not inside a workspace project, skipped)"
        return 0
      end

      issues = 0
      capable = AgentProvider.all.select { |p| p.supports_hooks? && @which.call(p.executable) }
      if capable.empty?
        @output.puts "  ⊘  session monitoring hooks (no hook-capable agent detected, skipped)"
      elsif capable.any? { |p| @hook_installer.installed?(p, @working_dir, Commands::Init::HOOK_COMMAND) }
        @output.puts "  ✓  session monitoring hooks installed for #{project}"
      else
        @output.puts "  ✗  session monitoring hooks not installed for #{project}"
        @output.puts "     ↳ fix: run 'workspace init' from the project directory"
        issues += 1
      end

      if @config.agent_running?(project)
        @output.puts "  ✓  session monitor agent running for #{project}"
      else
        @output.puts "  ✗  session monitor agent not running for #{project}"
        @output.puts "     ↳ fix: run 'workspace agent --name #{project}' (workspace launch now does this automatically)"
        issues += 1
      end

      check_worktree_lock_hooks(capable) unless capable.empty?
      check_statusline(capable)
      issues += check_pipeline_config(project)

      issues
    end

    # Warns rather than counting as an issue: a status line not routed
    # through workspace only means context usage can't be read (`handoff
    # check`, `sessions --json` report the reason and this same fix), not
    # that anything else is broken.
    def check_statusline(capable)
      statusline_capable = capable.select(&:supports_statusline?)
      return if statusline_capable.empty?

      shadow = statusline_capable.each_with_object([]) do |provider, shadows|
        command = @hook_installer.local_statusline_command(provider, @working_dir)
        shadows << [provider, command] if command && !command.to_s.empty? && command != Commands::Init::STATUSLINE_COMMAND
      end.first
      if shadow
        provider, command = shadow
        local_path = @hook_installer.local_settings_path_for(provider, @working_dir)
        @output.puts "  ⚠  statusLine shadowed by #{local_path} (routes through \"#{command}\" there)"
        @output.puts "     ↳ fix: remove the statusLine entry from #{local_path}"
        return
      end

      if statusline_capable.any? { |p| @hook_installer.statusline_installed?(p, @working_dir, Commands::Init::STATUSLINE_COMMAND) }
        @output.puts "  ✓  statusLine routed through workspace"
      else
        @output.puts "  ⚠  statusLine not routed through workspace (context usage can't be read)"
        @output.puts "     ↳ fix: run 'workspace doctor --fix'"
      end
    end

    # A bad `timeout:` in the project's pipeline config would otherwise only
    # surface as the agent daemon silently exiting at startup (launch already
    # warns about that); doctor gives an operator a standing check for it.
    def check_pipeline_config(project)
      path = @config.project_config_path(project)
      return 0 unless File.exist?(path)

      stages = @pipeline_config.stages_for(project)
      if stages
        @output.puts "  ✓  pipeline config valid for #{project}"
      elsif @pipeline_config.declared_but_empty?(project)
        @output.puts "  ⚠  pipeline config for #{project} has no panes; it won't start a pipeline"
      end
      @pipeline_config.literal_sentinel_warnings(project).each { |warning| @output.puts "  ⚠  #{warning}" }
      0
    rescue Workspace::Error => e
      @output.puts "  ✗  pipeline config invalid for #{project}"
      @output.puts "     ↳ #{e.message}"
      1
    end

    # A worktree without hooks only loses edit-lock enforcement (advisory
    # elsewhere still applies via `workspace lock`), so this warns rather than
    # failing doctor.
    def check_worktree_lock_hooks(capable)
      return unless @git

      worktrees = @git.list_worktrees(repo: @working_dir).select { |path| File.directory?(path) }
      return if worktrees.empty?

      missing = worktrees.reject { |path| capable.any? { |p| @hook_installer.installed?(p, path, Commands::Init::HOOK_COMMAND) } }
      if missing.empty?
        @output.puts "  ✓  edit lock hooks installed in every worktree"
      else
        @output.puts "  ⚠  edit lock hooks missing in #{missing.size} worktree(s): #{missing.map { |path| short_worktree_label(path, worktrees) }.join(", ")}"
        @output.puts "     ↳ fix: run 'workspace init' from each worktree listed above"
      end
    rescue Workspace::Error, SystemCallError
      # git unavailable or not a repo here; the hooks check above already
      # covers @working_dir, so skipping the rest is not worth failing over.
    end

    # Shortens a worktree path to its basename for display, unless another
    # worktree in the list shares that basename, in which case the full path
    # is kept to avoid ambiguity.
    def short_worktree_label(path, all_worktrees)
      basename = File.basename(path)
      collides = all_worktrees.any? { |other| other != path && File.basename(other) == basename }
      collides ? path : basename
    end

    def check_command(name, version_flag: "--version", version_pattern: /(\d+)/, min_major: nil, install_hint: nil)
      stdout, _, status = Open3.capture3("which", name)
      if !status.success? || stdout.strip.empty?
        return {found: false, install_hint: install_hint}
      end

      version_str = nil
      major = nil
      if version_flag
        stdout, _ = Open3.capture3(name, version_flag)
        match = stdout.strip.match(version_pattern)
        if match
          major = match[1].to_i
          version_str = "#{major}+"
        end
      end

      if min_major && major && major < min_major
        return {found: true, version: version_str, outdated: true, min_version: "#{min_major}+", install_hint: install_hint}
      end

      {found: true, version: version_str}
    end

    def check_app(name, bundle_id:, install_hint:)
      stdout, _, status = Open3.capture3("mdfind", "kMDItemCFBundleIdentifier == '#{bundle_id}'")
      if !status.success? || stdout.strip.empty?
        {found: false, install_hint: install_hint}
      else
        {found: true}
      end
    end
  end
end
