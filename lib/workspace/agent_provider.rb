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
      "PreToolUse" => nil,
      # Notification fires when the agent needs permission or has sat waiting
      # for input; it is what puts a pane in the `waiting` state.
      "Notification" => nil,
      # PostToolUse is the first event after a person approves a permission
      # prompt, so it is what takes the pane out of `waiting`.
      "PostToolUse" => nil
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
          executable: "pi",
          # "pi" is two letters: the versioned-install path-segment heuristic
          # (matching "/pi/" anywhere in argv0 or comm) would also catch
          # unrelated tools that happen to live under a "pi" directory (a
          # Raspberry Pi toolchain, an "/opt/pi/bin/..." install). Exact
          # basename matching still has a residual collision risk — any
          # other binary literally named "pi" on PATH is indistinguishable
          # from this provider — but that is a much narrower target than the
          # path-segment heuristic.
          path_segment_matching: false
        )
      ].freeze
    end

    # @param key [String] stable identifier used in config and CLI flags
    # @return [AgentProvider, nil]
    def self.find(key)
      all.find { |provider| provider.key == key }
    end

    # Finds the coding agent running in a pane. The agent may be the pane's
    # foreground command or buried under a shell wrapper, so the pane's own
    # command is checked before its process tree is walked.
    #
    # @param command [String] the pane's current command (tmux pane_current_command)
    # @param pid [Integer] the pane's process id
    # @param tree [Workspace::ProcessTree::Snapshot] process table snapshot
    # @param providers [Array<AgentProvider>] agents to recognize
    # @return [Hash, nil] +{provider:, pid:}+ for the agent found, or nil
    def self.detect(command:, pid:, tree:, providers: all)
      basename = File.basename(command.to_s).downcase
      direct = providers.find { |p| p.executable == basename }
      return {provider: direct, pid: pid} if direct

      providers.each do |provider|
        exact_only = provider.path_segment_matching? ? [] : [provider.executable]
        match = tree.find_descendant(pid, [provider.executable],
          exclude: provider.background_markers, include_root: true, exact_only: exact_only)
        return {provider: provider, pid: match[:pid]} if match
      end
      nil
    end

    attr_reader :key, :label, :executable, :settings_path, :events, :background_markers

    # @return [Boolean] whether a versioned install of this executable may be
    #   recognized by a "/#{executable}/" path segment, in addition to an
    #   exact basename match
    def path_segment_matching?
      @path_segment_matching
    end

    # @param key [String] stable identifier
    # @param label [String] human-readable name
    # @param executable [String] binary name to detect on PATH
    # @param settings_path [String, nil] hook settings file, relative to project root
    # @param events [Hash, nil] event name => matcher (nil matcher means "all")
    # @param background_markers [Array<String>] leading subcommands that mark
    #   a background helper, not an interactive session
    # @param path_segment_matching [Boolean] whether a "/#{executable}/" path
    #   segment also counts as a match (off for a short/generic executable
    #   name where that heuristic risks matching unrelated tools)
    def initialize(key:, label:, executable:, settings_path: nil, events: nil,
      background_markers: [], path_segment_matching: true)
      @key = key
      @label = label
      @executable = executable
      @settings_path = settings_path
      @events = events
      @background_markers = background_markers
      @path_segment_matching = path_segment_matching
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
