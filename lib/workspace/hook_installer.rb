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
    def initialize(backup:, output: $stdout, input: $stdin)
      @backup = backup
      @output = output
      @input = input
    end

    # @param provider [Workspace::AgentProvider]
    # @param project_root [String] directory holding the agent's settings file
    # @return [String] absolute path to the agent's settings file
    def settings_path_for(provider, project_root)
      File.join(project_root, provider.settings_path)
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
    # @return [void]
    def install(provider, project_root, command, dry_run: false)
      path = settings_path_for(provider, project_root)
      existed = File.exist?(path)
      existing = read_settings(path)
      merged = merge(existing, provider.hook_settings(command))

      if merged == existing
        @output.puts "  skip    #{path} (hooks already installed)"
        return
      end

      @backup.backup(path, dry_run: dry_run)
      unless dry_run
        FileUtils.mkdir_p(File.dirname(path))
        File.write(path, JSON.pretty_generate(merged) + "\n")
      end
      @output.puts "  #{existed ? "update" : "create"}  #{path}"
    end

    private

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
