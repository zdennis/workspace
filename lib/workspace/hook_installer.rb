require "json"
require "fileutils"

module Workspace
  # Installs workspace's session-monitoring hooks into a coding agent's own
  # settings file.
  #
  # The settings belong to the agent, not to workspace, and often already hold
  # the user's own hooks. Installation therefore merges rather than overwrites,
  # is idempotent (a second run finds its own command already present and does
  # nothing), and always backs the file up first.
  class HookInstaller
    # @param backup [Workspace::FileBackup] writes the pre-edit copy
    # @param output [IO] stream for user-facing messages
    # @param input [IO] stream for interactive confirmation
    # @param user_settings_path [String] the coding agent's user-level
    #   settings file, read (never written) so a user-level statusLine
    #   command isn't silently shadowed by a project-level one; Claude Code
    #   deep-merges settings with the project file's keys taking precedence
    def initialize(backup:, output: $stdout, input: $stdin, user_settings_path: File.expand_path("~/.claude/settings.json"))
      @backup = backup
      @output = output
      @input = input
      @user_settings_path = user_settings_path
    end

    # @param provider [Workspace::AgentProvider]
    # @param project_root [String] directory holding the agent's settings file
    # @return [String] absolute path to the agent's settings file
    def settings_path_for(provider, project_root)
      File.join(project_root, provider.settings_path)
    end

    # @param provider [Workspace::AgentProvider]
    # @param project_root [String]
    # @return [String] absolute path to the agent's local settings file (e.g.
    #   `.claude/settings.local.json`). Claude Code deep-merges this on top
    #   of the project's own settings.json at runtime, with the local file's
    #   keys winning -- it is read-only here, never written, since it's the
    #   user's own file, not workspace's to edit.
    def local_settings_path_for(provider, project_root)
      File.join(File.dirname(settings_path_for(provider, project_root)), "settings.local.json")
    end

    # @param provider [Workspace::AgentProvider]
    # @param project_root [String]
    # @return [String, nil] the statusLine command found in the agent's
    #   settings.local.json, if any. Local settings win at runtime, so a
    #   command found here shadows whatever `install_statusline` puts in
    #   settings.json.
    def local_statusline_command(provider, project_root)
      local = read_settings(local_settings_path_for(provider, project_root))
      statusline_command_in(local["statusLine"])
    rescue Workspace::Error
      nil
    end

    # @param provider [Workspace::AgentProvider]
    # @param project_root [String]
    # @param command [String] the hook command to install
    # @return [Boolean] whether every wanted hook is already present
    def installed?(provider, project_root, command)
      existing = read_settings(settings_path_for(provider, project_root))
      merge(existing, provider.hook_settings(command)) == existing
    end

    # Prints the settings fragment workspace wants to add.
    #
    # @param provider [Workspace::AgentProvider]
    # @param command [String]
    # @return [void]
    def preview(provider, command)
      JSON.pretty_generate(provider.hook_settings(command)).each_line do |line|
        @output.puts "    #{line.chomp}"
      end
    end

    # One-line, human-readable summary of what would be added, e.g.
    # "PreToolUse, PostToolUse hooks running `workspace session-event`".
    #
    # @param provider [Workspace::AgentProvider]
    # @param command [String]
    # @return [String]
    def summary(provider, command)
      events = provider.hook_settings(command)["hooks"].keys.join(", ")
      "#{events} hooks running `#{command}`"
    end

    # Merges the hooks into the agent's settings file, backing it up first.
    #
    # @param provider [Workspace::AgentProvider]
    # @param project_root [String]
    # @param command [String]
    # @param dry_run [Boolean] report without writing
    # @param quiet [Boolean] suppress the "skip"/"update"/"create"/"backup" progress lines
    # @return [void]
    def install(provider, project_root, command, dry_run: false, quiet: false)
      path = settings_path_for(provider, project_root)
      existed = File.exist?(path)
      existing = read_settings(path)
      merged = merge(existing, provider.hook_settings(command))

      if merged == existing
        @output.puts "  skip    #{path} (hooks already installed)" unless quiet
        return
      end

      @backup.backup(path, dry_run: dry_run, quiet: quiet)
      unless dry_run
        FileUtils.mkdir_p(File.dirname(path))
        File.write(path, JSON.pretty_generate(merged) + "\n")
      end
      @output.puts "  #{existed ? "update" : "create"}  #{path}" unless quiet
    end

    # @param provider [Workspace::AgentProvider]
    # @param project_root [String]
    # @param command [String] the statusLine command workspace wants installed
    # @return [Boolean] whether the agent's settings already route statusLine through +command+
    def statusline_installed?(provider, project_root, command)
      existing = read_settings(settings_path_for(provider, project_root))
      status_line = existing["statusLine"]
      status_line.is_a?(Hash) && status_line["type"] == "command" && status_line["command"] == command
    end

    # Routes Claude's status line through workspace, backing the settings file
    # up first. A different command already configured there is preserved,
    # not dropped: it moves into the global `statusline.command` config key,
    # where {Commands::Statusline} reads it and delegates to it on every
    # render. Other statusLine keys (e.g. `padding`) are kept as-is.
    #
    # Idempotent: a second call finds `command` already installed and does
    # nothing.
    #
    # @param provider [Workspace::AgentProvider]
    # @param project_root [String]
    # @param command [String] the statusLine command to install (e.g. "workspace statusline")
    # @param project_settings [Workspace::ProjectSettings] reads/writes the
    #   global config that receives a displaced statusLine command
    # @param dry_run [Boolean] report without writing
    # @param quiet [Boolean] suppress progress lines
    # @return [Array<String>] the "save"/"warn" notices produced, with
    #   indentation stripped, so a quiet caller (e.g. `start --json`) can
    #   still surface them in its own warnings channel
    def install_statusline(provider, project_root, command:, project_settings:, dry_run: false, quiet: false)
      path = settings_path_for(provider, project_root)
      existed = File.exist?(path)
      existing = read_settings(path)
      current = existing["statusLine"]
      current_command = statusline_command_in(current)
      notices = []

      if current_command == command
        @output.puts "  skip    #{path} (statusLine already routed through #{command})" unless quiet
        return notices
      end

      if current_command && !current_command.to_s.empty?
        preserve_existing_statusline_command(current_command, project_settings, dry_run: dry_run, quiet: quiet, notices: notices)
      else
        local_command = local_statusline_command(provider, project_root)
        preserved = if local_command && !local_command.to_s.empty? && local_command != command
          local_command
        else
          user_command = user_level_statusline_command(path)
          (user_command && !user_command.to_s.empty? && user_command != command) ? user_command : nil
        end
        preserve_existing_statusline_command(preserved, project_settings, dry_run: dry_run, quiet: quiet, notices: notices) if preserved
      end

      merged = deep_dup(existing)
      merged["statusLine"] = (current.is_a?(Hash) ? current.dup : {}).merge("type" => "command", "command" => command)

      @backup.backup(path, dry_run: dry_run, quiet: quiet)
      unless dry_run
        FileUtils.mkdir_p(File.dirname(path))
        File.write(path, JSON.pretty_generate(merged) + "\n")
      end
      @output.puts "  #{existed ? "update" : "create"}  #{path}" unless quiet

      shadow_command = local_statusline_command(provider, project_root)
      if shadow_command && !shadow_command.to_s.empty? && shadow_command != command
        local_path = local_settings_path_for(provider, project_root)
        notice("warn", "#{local_path} still routes statusLine through \"#{shadow_command}\"; settings.json's statusLine is shadowed there until you remove that entry from #{local_path}", notices, quiet)
      end

      notices
    end

    private

    # Saves a status-line command workspace is about to displace, so it isn't
    # lost. Written under `statusline.command` only if that key isn't already
    # set, so a second `install_statusline` run (or one for a second worktree)
    # never overwrites a value the user has since edited. If a *different*
    # command is already saved there, this one is not overwritten -- it's
    # printed as a warning instead, naming both commands, so the user can
    # decide which one they actually want.
    def preserve_existing_statusline_command(existing_command, project_settings, dry_run:, quiet:, notices:)
      if dry_run
        current = project_settings.load_global.dig("statusline", "command")
        if current.nil? || current.to_s.empty? || current == existing_command
          notice("save", "(dry run) would save previous statusLine command -> statusline.command (#{existing_command})", notices, quiet)
        else
          notice("warn", "(dry run) statusline.command is already set to \"#{current}\"; would not overwrite it with the different command found here, \"#{existing_command}\"", notices, quiet)
        end
        return
      end

      saved_command = nil
      project_settings.with_global_lock do |data|
        data["statusline"] ||= {}
        data["statusline"]["command"] ||= existing_command
        saved_command = data["statusline"]["command"]
        data
      end

      if saved_command == existing_command
        notice("save", "previous statusLine command -> statusline.command (#{existing_command})", notices, quiet)
      else
        notice("warn", "statusline.command is already set to \"#{saved_command}\"; not overwriting it with the different command found here, \"#{existing_command}\" (set it by hand with 'workspace config set statusline.command' if you want to keep #{existing_command} instead)", notices, quiet)
      end
    end

    # Prints a "save"/"warn" notice unless quiet, and records it either way,
    # so a quiet caller can still surface it in its own warnings channel.
    # +verb+ is padded for the progress-line column; the recorded notice
    # carries the clean text.
    def notice(verb, text, notices, quiet)
      @output.puts "  #{verb.ljust(8)}#{text}" unless quiet
      notices << "#{verb} #{text}".strip
    end

    # The command in a statusLine value, whether it's the Hash form Claude
    # documents (`{"type" => "command", "command" => "..."}`) or the bare
    # String form it also accepts.
    def statusline_command_in(status_line)
      case status_line
      when Hash then status_line["command"]
      when String then status_line
      end
    end

    # A user-level settings file (e.g. `~/.claude/settings.json`) is read
    # read-only, never written: its own statusLine command is preserved into
    # `statusline.command` when the project-level file being edited has none
    # of its own, since Claude Code's project settings otherwise shadow it
    # key-by-key once workspace installs a project-level statusLine.
    #
    # Claude Code's precedence, highest first, is `settings.local.json` >
    # `settings.json` (project) > `~/.claude/settings.json` (user). All three
    # are read-only from workspace's side except the project `settings.json`
    # it installs into: `install_statusline` preserves whichever command a
    # higher-precedence file already has (local first, then user-level) into
    # `statusline.command` before writing its own, and warns if a
    # `settings.local.json` entry will keep shadowing the result.
    #
    # @param project_settings_path [String] the project-level settings file
    #   being installed into; skipped when it *is* the user-level file (e.g.
    #   a headless/no-project setup that edits `~/.claude/settings.json`
    #   directly), so it is never read as its own "user-level" fallback.
    def user_level_statusline_command(project_settings_path)
      return nil if File.expand_path(project_settings_path) == File.expand_path(@user_settings_path)

      user_settings = read_settings(@user_settings_path)
      statusline_command_in(user_settings["statusLine"])
    rescue Workspace::Error
      nil
    end

    # A settings file we cannot parse is left alone rather than replaced: the
    # user's own configuration is more valuable than our hooks.
    def read_settings(path)
      return {} unless File.exist?(path)

      JSON.parse(File.read(path))
    rescue JSON::ParserError
      raise Workspace::Error,
        "Cannot install hooks: #{path} is not valid JSON. Fix or move it, then re-run."
    end

    # Appends our entries to each event's list, matched on the command string so
    # a re-run is a no-op and the user's own hooks for the same event survive.
    #
    # An entry is identified by its command and matcher, so a second matcher
    # group for the same event and command (e.g. a future narrower
    # `PreToolUse` group alongside the wildcard one) stays distinct. But a
    # wildcard entry (nil matcher) subsumes any narrower entry we previously
    # installed for the same command, so upgrading `PreToolUse` from `Task`
    # to "all tools" replaces the old entry in place instead of leaving a
    # stale duplicate behind.
    def merge(existing, fragment)
      result = deep_dup(existing)
      hooks = result["hooks"] ||= {}

      fragment["hooks"].each do |event, entries|
        current = hooks[event] ||= []
        entries.each do |entry|
          if entry["matcher"].nil?
            current.reject! { |e| commands_in(e) == commands_in(entry) }
            current << entry
          else
            index = current.find_index { |e| same_command?(e, entry) }
            current[index] = entry if index
            current << entry unless index
          end
        end
      end
      result
    end

    def same_command?(a, b)
      a["matcher"] == b["matcher"] && commands_in(a) == commands_in(b)
    end

    def commands_in(entry)
      Array(entry["hooks"]).map { |h| h["command"] }
    end

    def deep_dup(value)
      case value
      when Hash then value.transform_values { |v| deep_dup(v) }
      when Array then value.map { |v| deep_dup(v) }
      else value
      end
    end
  end
end
