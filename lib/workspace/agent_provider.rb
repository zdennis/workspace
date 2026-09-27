module Workspace
  # Describes one coding-agent CLI that workspace can monitor.
  #
  # A provider is data, not behaviour: it names the executable to look for, the
  # settings file that carries its hook configuration, and the hook events
  # workspace wants delivered. Adding support for a new agent means adding an
  # entry to {AgentProvider.all} — no other file changes.
  #
  # A provider with no hook support is still useful: the session monitor falls
  # back to pane activity for it, so it appears in the registry (and in
  # `workspace init` output) with its hook install skipped.
  class AgentProvider
    # Hook events workspace subscribes to, in the shape each agent's settings
    # file expects. The values are agent-specific; only the keys are ours.
    CLAUDE_EVENTS = {
      "SessionStart" => nil,
      "SessionEnd" => nil,
      "UserPromptSubmit" => nil,
      "Stop" => nil,
      "SubagentStop" => nil,
      # PreToolUse fires for every tool; workspace wants all of them (a tool
      # use of any kind marks the holder active again), so the matcher is
      # nil ("*" in Claude Code's own hook conventions). Sub-agent detection
      # (the Task tool starting a sub-agent) is done inside session-event by
      # inspecting the tool name, not by narrowing the matcher here. A
      # second PreToolUse matcher group (e.g. "Edit|Write|MultiEdit|NotebookEdit")
      # may be added later without disturbing this one.
      "PreToolUse" => nil
    }.freeze

    # Subcommands that mark a background helper rather than an interactive
    # session. Claude Code leaves a daemon and pty helpers in a pane's process
    # tree, and matching one would report the pane as busy long after the
    # session it served has exited. Each is matched against the words right
    # after the program name, and only for this provider's own processes.
    CLAUDE_BACKGROUND = ["daemon run", "bg-pty-host", "bg-spare"].freeze

    # @return [Array<AgentProvider>] every known provider
    def self.all
      @all ||= [
        new(
          key: "claude",
          label: "Claude Code",
          executable: "claude",
          settings_path: File.join(".claude", "settings.json"),
          events: CLAUDE_EVENTS,
          background_markers: CLAUDE_BACKGROUND
        ),
        new(
          key: "codex",
          label: "Codex",
          executable: "codex"
        ),
        new(
          key: "opencode",
          label: "OpenCode",
          executable: "opencode"
        ),
        new(
          key: "pi",
          label: "Pi",
          executable: "pi"
        )
      ].freeze
    end

    # @param key [String] stable identifier used in config and CLI flags
    # @return [AgentProvider, nil]
    def self.find(key)
      all.find { |provider| provider.key == key }
    end

    attr_reader :key, :label, :executable, :settings_path, :events, :background_markers

    # @param key [String] stable identifier
    # @param label [String] human-readable name
    # @param executable [String] binary name to detect on PATH
    # @param settings_path [String, nil] hook settings file, relative to project root
    # @param events [Hash, nil] event name => matcher (nil matcher means "all")
    # @param background_markers [Array<String>] leading subcommands that mark
    #   a background helper, not an interactive session
    def initialize(key:, label:, executable:, settings_path: nil, events: nil,
      background_markers: [])
      @key = key
      @label = label
      @executable = executable
      @settings_path = settings_path
      @events = events
      @background_markers = background_markers
    end

    # @return [Boolean] whether workspace can install hooks for this agent
    def supports_hooks?
      !settings_path.nil? && !events.nil?
    end

    # Builds the settings fragment that routes this agent's hook events to the
    # given command.
    #
    # @param command [String] shell command each hook should run
    # @return [Hash] a settings fragment ready to merge into the agent's config
    def hook_settings(command)
      entries = events.map do |event, matcher|
        hook = {"type" => "command", "command" => command}
        entry = matcher ? {"matcher" => matcher} : {}
        [event, [entry.merge("hooks" => [hook])]]
      end
      {"hooks" => entries.to_h}
    end
  end
end
