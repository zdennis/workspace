require "open3"

module Workspace
  # Checks that all required dependencies are installed and configured.
  #
  # Every check adds rows through {#add_row}; {#run} prints them and
  # {#report} / {.document} hand them to `doctor --json`, so a new check
  # appears in both by adding a row with a stable `id`.
  class Doctor
    SYMBOLS = {"ok" => "✓", "warn" => "⚠", "fail" => "✗", "skipped" => "⊘"}.freeze

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
    # @param plan [Workspace::Commands::Plan, nil] reads the plans of the current project's workspaces; nil skips the plan check
    # @param snapshot_client [Workspace::AgentSnapshotClient, nil] reads the session
    #   monitor's snapshot, to diagnose the context readability of panes whose
    #   agent workspace reads by scraping the pane itself (Codex); nil skips that check
    # @param working_dir [String] directory to detect the current project from
    # @param output [IO] output stream for results
    def initialize(config:, state:, hook_installer:, project_detector:, which: nil, git: nil,
      pipeline_config: nil, launch_mode: nil, project_settings: nil, plan: nil, snapshot_client: nil, working_dir: Dir.pwd, output: $stdout)
      @launch_mode = launch_mode || LaunchMode.new(project_settings: ProjectSettings.new(config: config), which: which)
      @config = config
      @state = state
      @hook_installer = hook_installer
      @project_detector = project_detector
      @which = which || Workspace::Which
      @git = git
      @pipeline_config = pipeline_config || PipelineConfig.new(config: config)
      @project_settings = project_settings || ProjectSettings.new(config: config)
      @plan = plan
      @snapshot_client = snapshot_client
      @working_dir = working_dir
      @output = output
      @rows = []
    end

    # @param headless [Boolean, nil] the `--[no-]headless` flag; nil lets
    #   {LaunchMode} decide. Headless skips the iTerm2 and window-tool checks.
    # @param fix [Boolean] install the statusLine entry (via {HookInstaller},
    #   with a backup) before running checks, so this run reports the fixed
    #   state. The only fix `doctor --fix` performs today.
    # @return [void]
    # @raise [Workspace::Error] if any issues are found
    def run(headless: nil, fix: false)
      result = report(headless: headless, fix: fix)
      @output.puts "workspace doctor"
      @output.puts ""
      @output.puts "  mode: #{result[:mode]["headless"] ? "headless" : "iTerm2"} (#{result[:mode]["reason"]})"
      result[:rows].each do |row|
        @output.puts "  #{SYMBOLS.fetch(row[:status])}  #{row[:message]}"
        row[:hints].each { |hint| @output.puts "     ↳ #{hint.gsub("\n", "\n     ")}" }
      end
      @output.puts ""
      raise Workspace::Error, "#{result[:issues]} issue(s) found." if result[:issues] > 0
      @output.puts "Everything looks good!"
    end

    # Runs every check and returns the findings without printing them (a
    # `--fix` still prints what it did).
    #
    # @param headless [Boolean, nil] see {#run}
    # @param fix [Boolean] see {#run}
    # @return [Hash] `:mode` (`headless`, `reason`), `:rows` and `:issues`
    def report(headless: nil, fix: false)
      @rows = []
      apply_fixes if fix
      mode = @launch_mode.resolve(headless)

      dependency_checks.each { |entry| run_dependency_check(entry, mode) }
      check_templates
      check_duplicate_window_ids
      check_session_monitoring
      # A failed --fix is a `fix` row, so `doctor --fix` still exits non-zero
      # when there was nothing it could actually do.
      issues = @rows.count { |row| row[:status] == "fail" }
      {mode: {"headless" => mode.headless?, "reason" => mode.reason}, rows: @rows, issues: issues}
    end

    # The document `doctor --json` prints.
    #
    # @param result [Hash] what {#report} returned
    # @return [Hash] `schema_version`, `ok`, `healthy`, `mode`, `checks`, `summary`
    def self.document(result)
      checks = result[:rows].map do |row|
        {"id" => row[:id], "ok" => row[:status] != "fail", "status" => row[:status],
         "message" => row[:message], "fix" => row[:fix], "fix_command" => row[:fix_command],
         "project" => row[:project]}
      end
      counts = Hash.new(0)
      checks.each { |check| counts[check["status"]] += 1 }
      summary = SYMBOLS.keys.to_h { |status| [status, counts[status]] }.merge("issues" => result[:issues])
      {"schema_version" => 1, "ok" => true, "healthy" => result[:issues].zero?, "mode" => result[:mode],
       "checks" => checks, "summary" => summary}
    end

    private

    # Adds one finding.
    #
    # @param id [String] stable machine name, e.g. "tmux" or "hooks"
    # @param status [String] ok, warn, fail or skipped; only fail is an issue
    # @param message [String] what a person reads after the symbol
    # @param fix [String, nil] how to fix it, printed as "label: fix"
    # @param fix_label [String] "fix" or "install"
    # @param fix_command [String, nil] the fix as a command to run, when it is one
    # @param hints [Array<String>] lines printed after the row, instead of the fix line
    # @param project [String, nil] the project the row is about
    def add_row(id, status, message, fix: nil, fix_label: "fix", fix_command: nil, hints: nil, project: nil)
      hints ||= fix ? ["#{fix_label}: #{fix}"] : []
      @rows << {id: id, status: status, message: message, hints: hints, fix: fix, fix_command: fix_command, project: project}
    end

    def dependency_checks
      [
        {id: "ruby", name: "ruby",
         check: -> { check_command("ruby", version_pattern: /(\d+)/, min_major: 3, install_hint: "Install via rbenv, asdf, or https://www.ruby-lang.org/en/downloads/") }},
        {id: "tmux", name: "tmux",
         check: -> { check_command("tmux", version_flag: "-V", version_pattern: /(\d+)/, min_major: 3, install_hint: "brew install tmux", install_command: "brew install tmux") }},
        {id: "tmuxinator", name: "tmuxinator",
         check: -> { check_command("tmuxinator", version_flag: "version", version_pattern: /(\d+)/, install_hint: "brew install tmuxinator", install_command: "brew install tmuxinator") }},
        {id: "iterm2", name: "iTerm2", gui: true,
         check: -> { check_app("iTerm2", bundle_id: "com.googlecode.iterm2", install_hint: "https://iterm2.com/") }},
        {id: "window-tool", name: "window-tool", gui: true,
         check: -> { check_command("window-tool", version_flag: nil, install_hint: "https://github.com/zdennis/window-tool") }},
        {id: "git", name: "git",
         check: -> { check_command("git", version_pattern: /(\d+)/, min_major: 2, install_hint: "brew install git", install_command: "brew install git") }},
        {id: "gh", name: "gh",
         check: -> { check_command("gh", version_pattern: /(\d+)/, min_major: 2, install_hint: "brew install gh", install_command: "brew install gh") }},
        {id: "ascii-banner", name: "ascii-banner",
         check: -> { check_command("ascii-banner", version_flag: nil, install_hint: "https://github.com/zdennis/homebrew-bin/blob/main/docs/README.ascii-banner.md") }}
      ]
    end

    def run_dependency_check(entry, mode)
      name = entry[:name]
      if entry[:gui] && mode.headless?
        add_row(entry[:id], "skipped", "#{name} (not needed headless, skipped)")
        return
      end
      result = entry[:check].call
      install = {fix: result[:install_hint], fix_label: "install", fix_command: result[:install_command]}
      if !result[:found]
        add_row(entry[:id], "fail", "#{name} (not found)", **install)
      elsif result[:outdated]
        add_row(entry[:id], "fail", "#{name} (found #{result[:version]}, need #{result[:min_version]})", **install)
      elsif result[:version]
        add_row(entry[:id], "ok", "#{name} (#{result[:version]})")
      else
        add_row(entry[:id], "ok", name)
      end
    end

    def check_templates
      templates = ["workspace.project-template.yml", "workspace.project-worktree-template.yml"]
      missing = templates.reject { |t| File.exist?(File.join(@config.tmuxinator_dir, t)) }
      if missing.empty?
        add_row("templates", "ok", "templates installed")
      else
        add_row("templates", "fail", "templates (missing: #{missing.join(", ")})",
          fix: "run 'workspace init' to install them", fix_command: "workspace init")
      end
    end

    # `--fix` is limited to one thing today: routing Claude's statusLine
    # through `workspace statusline`, via the same {HookInstaller} used by
    # `workspace init`. Applied before the checks run, so this same call
    # reports the fixed state rather than requiring a second `doctor` run.
    # An agent whose context workspace reads by scraping its own pane (Codex)
    # needs no routing, so a machine with only that agent on PATH has nothing
    # to fix -- and no failure counted for it.
    def apply_fixes
      project = @project_detector.detect(@working_dir)
      unless project
        add_row("fix", "fail", "--fix: not inside a workspace project here, so there's nothing to fix")
        return
      end

      capable = AgentProvider.all.select { |p| p.supports_hooks? && @which.call(p.executable) }
      statusline_capable = capable.select(&:supports_statusline?)
      if statusline_capable.empty?
        scraped = scraped_context_providers
        if scraped.any?
          @output.puts "--fix: nothing to fix: #{scraped.map(&:label).join(", ")} " \
            "read context usage from their own panes (no statusLine to route)"
        else
          add_row("fix", "fail", "--fix: no statusLine-capable agent detected on PATH, so there's nothing to fix")
        end
        return
      end

      statusline_capable.each do |provider|
        @hook_installer.install_statusline(provider, @working_dir, command: Commands::Init::STATUSLINE_COMMAND,
          project_settings: @project_settings)
      end
      @output.puts "Restart any running Claude Code sessions for the statusLine change to take effect."
    end

    # The providers on PATH whose context usage workspace reads by scraping
    # the pane itself (Codex), rather than through a routed status line.
    def scraped_context_providers
      AgentProvider.all.select { |p| p.context_pattern && @which.call(p.executable) }
    end

    def check_duplicate_window_ids
      @state.load
      return if @state.empty?

      ids_to_projects = {}
      @state.each do |project, data|
        wid = data["iterm_window_id"]
        next unless wid
        (ids_to_projects[wid] ||= []) << project
      end

      duplicates = ids_to_projects.select { |_, projects| projects.size > 1 }
      if duplicates.any?
        fix = "run 'workspace stop' then 'workspace launch' for affected projects"
        hints = duplicates.map { |wid, projects| "window #{wid} claimed by: #{projects.join(", ")}" } + ["fix: #{fix}"]
        add_row("state-window-ids", "fail", "state: duplicate window IDs detected", fix: fix, hints: hints)
      else
        add_row("state-window-ids", "ok", "state: no duplicate window IDs")
      end
    end

    def check_session_monitoring
      project = @project_detector.detect(@working_dir)
      unless project
        add_row("session-monitoring", "skipped", "session monitoring (not inside a workspace project, skipped)")
        return
      end

      capable = AgentProvider.all.select { |p| p.supports_hooks? && @which.call(p.executable) }
      if capable.empty?
        add_row("hooks", "skipped", "session monitoring hooks (no hook-capable agent detected, skipped)", project: project)
      elsif capable.any? { |p| @hook_installer.installed?(p, @working_dir, Commands::Init::HOOK_COMMAND) }
        add_row("hooks", "ok", "session monitoring hooks installed for #{project}", project: project)
      else
        add_row("hooks", "fail", "session monitoring hooks not installed for #{project}",
          fix: "run 'workspace init' from the project directory", fix_command: "workspace init", project: project)
      end

      agent_running = @config.agent_running?(project)
      if agent_running
        add_row("agent", "ok", "session monitor agent running for #{project}", project: project)
      else
        command = "workspace agentd --name #{project}"
        add_row("agent", "fail", "session monitor agent not running for #{project}",
          fix: "run '#{command}' (workspace launch now does this automatically)", fix_command: command, project: project)
      end

      check_worktree_lock_hooks(capable, project) unless capable.empty?
      check_statusline(capable, project)
      check_scraped_pane_context(project) if agent_running
      check_pipeline_config(project)
      check_plans(project)
    end

    # Warns rather than counting as an issue: a status line not routed
    # through workspace only means context usage can't be read (`handoff
    # check`, `sessions --json` report the reason and this same fix), not
    # that anything else is broken. Providers whose context is scraped from
    # their own panes (Codex) have no status line to route, so when no
    # statusLine-capable agent is on PATH they are reported as read instead
    # of warned about with the Claude-centric routing fix.
    def check_statusline(capable, project)
      statusline_capable = capable.select(&:supports_statusline?)
      if statusline_capable.empty?
        scraped_context_providers.each do |provider|
          add_row("statusline", "ok", "#{provider.label} context usage read from its own pane (no statusLine to route)", project: project)
        end
        return
      end

      shadow = statusline_capable.each_with_object([]) do |provider, shadows|
        command = @hook_installer.local_statusline_command(provider, @working_dir)
        shadows << [provider, command] if command && !command.to_s.empty? && command != Commands::Init::STATUSLINE_COMMAND
      end.first
      if shadow
        provider, command = shadow
        local_path = @hook_installer.local_settings_path_for(provider, @working_dir)
        add_row("statusline", "warn", "statusLine shadowed by #{local_path} (routes through \"#{command}\" there)",
          fix: "remove the statusLine entry from #{local_path}", project: project)
        return
      end

      if statusline_capable.any? { |p| @hook_installer.statusline_installed?(p, @working_dir, Commands::Init::STATUSLINE_COMMAND) }
        add_row("statusline", "ok", "statusLine routed through workspace", project: project)
      else
        add_row("statusline", "warn", "statusLine not routed through workspace (context usage can't be read)",
          fix: "run 'workspace doctor --fix'", fix_command: "workspace doctor --fix", project: project)
      end
    end

    # Diagnoses the context readability of each pane whose agent workspace
    # reads by scraping the pane itself (Codex), from the session monitor's
    # own readings, so a pane whose footer no longer matches the pattern is
    # found here rather than only surfacing in `sessions --json`. The
    # statusLine check above covers the agents workspace routes (Claude
    # Code); this covers the rest. Warns rather than counting as an issue,
    # like the statusLine check; a daemon that can't be asked (not running,
    # not answering) is already reported by the agent check above.
    def check_scraped_pane_context(project)
      return unless @snapshot_client

      snapshot = begin
        @snapshot_client.fetch(project)
      rescue Workspace::Error
        return
      end
      scraped = (snapshot["panes"] || []).filter_map do |pane|
        provider = pane["kind"] && AgentProvider.find(pane["kind"])
        next unless provider&.context_pattern
        next unless pane.key?("context_pct") || pane.key?("context_error")
        [provider, pane]
      end
      scraped.group_by(&:first).each do |provider, pairs|
        panes = pairs.map(&:last)
        readable = panes.select { |pane| pane["context_error"].nil? && !pane["context_pct"].nil? }
        if readable.any?
          detail = readable.map { |pane| "pane #{pane["index"]} (#{pane["context_pct"]}% used)" }.join(", ")
          add_row("context-#{provider.key}", "ok", "#{provider.label} context usage read from #{detail}", project: project)
        end
        panes.reject { |pane| pane["context_error"].nil? }.each do |pane|
          hint = ContextReasons.fix_hint(pane["kind"])
          add_row("context-#{provider.key}", "warn", "#{provider.label} context usage unreadable on pane #{pane["index"]} (#{pane["context_error"]})",
            fix: hint, hints: [hint], project: project)
        end
      end
    end

    # A bad `timeout:` in the project's pipeline config would otherwise only
    # surface as the agent daemon silently exiting at startup (launch already
    # warns about that); doctor gives an operator a standing check for it.
    def check_pipeline_config(project)
      path = @config.project_config_path(project)
      return unless File.exist?(path)

      stages = @pipeline_config.stages_for(project)
      if stages
        add_row("pipeline-config", "ok", "pipeline config valid for #{project}", project: project)
        add_row("pipeline-deprecated", "warn", "pipeline is deprecated and will be removed in a later release; use `workspace workflow` (see `workspace workflow --help`)", project: project)
      elsif @pipeline_config.declared_but_empty?(project)
        add_row("pipeline-config", "warn", "pipeline config for #{project} has no panes; it won't start a pipeline", project: project)
      end
      @pipeline_config.literal_sentinel_warnings(project).each do |warning|
        add_row("pipeline-sentinel", "warn", warning, project: project)
      end
    rescue Workspace::Error => e
      add_row("pipeline-config", "fail", "pipeline config invalid for #{project}", hints: [e.message], project: project)
    end

    # Warns, and adds nothing when all is well. Two states of a plan point at a session that
    # disagrees with it: a paused plan whose owner pane is still working, and a `[~]` task in a
    # workspace with no session (the plan's `stopped` state; a paused plan reads `paused` instead).
    # A plan that can't be read is not worth failing doctor over.
    def check_plans(project)
      return unless @plan

      @plan.rows(all: true).select { |row| row["project"] == project && row["exists"] }.each do |row|
        if row["status"] == "paused" && row["pane_state"] == "working"
          add_row("plan", "warn", "plan for #{row["workspace"]} is paused, but its owner pane #{row["owner_pane"]} is working",
            fix: "tell that agent to stop, or run 'workspace plan start --name #{row["workspace"]}' to let it go on", project: project)
        elsif row["state"] == "stopped" && row.dig("counts", "in_progress").to_i.positive?
          add_row("plan", "warn", "plan for #{row["workspace"]} has a task in progress ([~]) but the workspace has no session",
            fix: "run 'workspace plan start --name #{row["workspace"]}' to resume the plan, or change the task back to [ ] in #{row["path"]}",
            project: project)
        end
      end
    rescue
      nil
    end

    # A worktree without hooks only loses edit-lock enforcement (advisory
    # elsewhere still applies via `workspace lock`), so this warns rather than
    # failing doctor.
    def check_worktree_lock_hooks(capable, project)
      return unless @git

      worktrees = @git.list_worktrees(repo: @working_dir).select { |path| File.directory?(path) }
      return if worktrees.empty?

      missing = worktrees.reject { |path| capable.any? { |p| @hook_installer.installed?(p, path, Commands::Init::HOOK_COMMAND) } }
      if missing.empty?
        add_row("edit-lock-hooks", "ok", "edit lock hooks installed in every worktree", project: project)
      else
        add_row("edit-lock-hooks", "warn", "edit lock hooks missing in #{missing.size} worktree(s): #{missing.map { |path| short_worktree_label(path, worktrees) }.join(", ")}",
          fix: "run 'workspace init' from each worktree listed above", fix_command: "workspace init", project: project)
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

    def check_command(name, version_flag: "--version", version_pattern: /(\d+)/, min_major: nil, install_hint: nil, install_command: nil)
      stdout, _, status = Open3.capture3("which", name)
      if !status.success? || stdout.strip.empty?
        return {found: false, install_hint: install_hint, install_command: install_command}
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
        return {found: true, version: version_str, outdated: true, min_version: "#{min_major}+", install_hint: install_hint, install_command: install_command}
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
