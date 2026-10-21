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

    # Codex's hook events, in its `hooks.json` (the same shape as Claude
    # Code's settings). `PermissionRequest` fires when Codex is about to ask
    # for approval; it is what puts a Codex pane in the `waiting` state, and
    # the PostToolUse after it takes the pane out. `SubagentStart` names the
    # sub-agent itself, so no tool is watched for it. `Interrupt` ends a turn
    # the person stopped.
    CODEX_EVENTS = {
      "SessionStart" => nil,
      "SessionEnd" => nil,
      "UserPromptSubmit" => nil,
      "Stop" => nil,
      "Interrupt" => nil,
      "SubagentStart" => nil,
      "SubagentStop" => nil,
      "PreToolUse" => nil,
      "PermissionRequest" => nil,
      "PostToolUse" => nil
    }.freeze

    # Seconds Codex gives each workspace hook. Codex waits 600s by default,
    # far more than `session-event` needs; `SessionEnd` and `Interrupt`
    # accept at most 3.
    CODEX_HOOK_TIMEOUTS = {"SessionEnd" => 3, "Interrupt" => 3}.tap { |h| h.default = 10 }.freeze

    # What a pane can learn from an agent's hooks, in the names `sessions
    # --json` reports as `hook_events`: the events stream's types, plus
    # `turn_ended` (a Stop) and `waiting` (a permission prompt or a question).
    HOOK_EVENT_TYPES = %w[session_started session_ended prompt_submitted tool_started tool_finished
      subagent_started subagent_stopped turn_ended waiting].freeze

    # Subcommands that mark a background helper rather than an interactive
    # session. Claude Code leaves a daemon and pty helpers in a pane's process
    # tree, and matching one would report the pane as busy long after the
    # session it served has exited. Each is matched against the words right
    # after the program name, and only for this provider's own processes.
    CLAUDE_BACKGROUND = ["daemon run", "bg-pty-host", "bg-spare"].freeze

    # Matches Claude Code's input prompt: a `❯` marker on its own line,
    # directly under a horizontal rule made of box-drawing dashes (`─`), e.g.
    #   ────────────────────────
    #   ❯ Try "write a test..."
    # Confirmed against a live v2.1.283 pane (no side borders on this
    # prompt). Anchored to the rule+marker pair, not the rule's width, so it
    # survives terminal resizes. The character after `❯` is a plain space
    # when the prompt carries text (e.g. `❯ Try "write a test..."`) but a
    # non-breaking space (U+00A0) on an empty prompt, so both are accepted.
    # A modal dialog's own menu items (e.g. "Do you trust the files in this
    # folder?") also use `❯` to mark the selected option, but sit inside a
    # `│`-bordered box, not directly under a bare horizontal rule, so this
    # pattern does not match them.
    CLAUDE_READY_PATTERN = /─{3,}\n❯[ \t\u00A0]?/

    # Matches the context line of the current codex-cli status footer, e.g.
    #   Context 0% used · Context 100% left
    # The "used" half is matched, not the "left" half, so the capture is the
    # percent used directly (see `context_remaining`): both halves sit on the
    # same footer line, and the reader counts the last match on the screen,
    # which would otherwise be the "left" half. Older codex-cli (0.162.1)
    # printed "72% context left" instead; that format is gone.
    CODEX_CONTEXT_PATTERN = 'Context\s+(\d{1,3})% used'

    # The key Claude Code and Codex both stop a running turn on ("esc to interrupt" in their
    # footers). OpenCode and Pi have none listed until their keys are checked against a live pane.
    INTERRUPT_KEYS = ["Escape"].freeze

    # @return [Array<AgentProvider>] every known provider
    def self.all
      @all ||= [
        new(
          key: "claude",
          label: "Claude Code",
          executable: "claude",
          settings_path: File.join(".claude", "settings.json"),
          events: CLAUDE_EVENTS,
          background_markers: CLAUDE_BACKGROUND,
          ready_pattern: CLAUDE_READY_PATTERN,
          restartable: true,
          interrupt_keys: INTERRUPT_KEYS,
          hook_events: HOOK_EVENT_TYPES
        ),
        new(
          key: "codex",
          label: "Codex",
          executable: "codex",
          restartable: true,
          context_pattern: CODEX_CONTEXT_PATTERN,
          interrupt_keys: INTERRUPT_KEYS,
          # Codex trusts each hook by file path and hash, and loads a project's
          # `.codex/` only once the project is trusted, so a file per worktree
          # would need reviewing in every new worktree. One user-level file is
          # reviewed once, with `/hooks` in Codex.
          settings_path: "hooks.json",
          user_config_dir: ".codex",
          user_config_env: "CODEX_HOME",
          events: CODEX_EVENTS,
          hook_timeouts: CODEX_HOOK_TIMEOUTS,
          hook_events: HOOK_EVENT_TYPES,
          hook_trust_hint: "Codex skips new or changed hooks until you trust them: run /hooks in Codex and trust the `workspace session-event --agent codex` entries; `workspace hooks uninstall --agent codex` takes them out"
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

    # @return [Array<String>] the keys of the agents `handoff` and `restart_agent` may
    #   clear and resume: the ones whose provider is restartable, plus "unknown" for
    #   a pane the session monitor has not identified yet
    def self.restartable_kinds
      all.select(&:restartable?).map(&:key) + ["unknown"]
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
    # @param aliases [Hash{String => Array<String>}] extra program names per provider key (a configured
    #   `claude-dev` for "claude"); matched by exact basename only. The caller supplies them, the registry
    #   reads no config.
    # @return [Hash, nil] +{provider:, pid:}+ for the agent found, or nil
    def self.detect(command:, pid:, tree:, providers: all, aliases: {})
      basename = File.basename(command.to_s).downcase
      extras = ->(provider) { Array(aliases[provider.key]).map { |name| File.basename(name.to_s).downcase }.uniq - [provider.executable] }
      direct = providers.find { |p| p.executable == basename || extras.call(p).include?(basename) }
      return {provider: direct, pid: pid} if direct

      providers.each do |provider|
        extra = extras.call(provider)
        exact_only = (provider.path_segment_matching? ? [] : [provider.executable]) + extra
        match = tree.find_descendant(pid, [provider.executable, *extra],
          exclude: provider.background_markers, include_root: true, exact_only: exact_only)
        return {provider: provider, pid: match[:pid]} if match
      end
      nil
    end

    attr_reader :key, :label, :executable, :settings_path, :events, :background_markers, :ready_pattern,
      :clear_command, :context_pattern, :interrupt_keys, :hook_events, :hook_trust_hint

    # @return [Boolean] whether handoff may clear this agent and type a resume prompt into it
    def restartable?
      @restartable
    end

    # @return [Boolean] whether the one capture group of {#context_pattern} is the
    #   percent of the context window left, not the percent used
    def context_remaining?
      @context_remaining
    end

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
    #   (or to +user_config_dir+ when that is set)
    # @param events [Hash, nil] event name => matcher (nil matcher means "all")
    # @param background_markers [Array<String>] leading subcommands that mark
    #   a background helper, not an interactive session
    # @param path_segment_matching [Boolean] whether a "/#{executable}/" path
    #   segment also counts as a match (off for a short/generic executable
    #   name where that heuristic risks matching unrelated tools)
    # @param ready_pattern [Regexp, nil] matched against the pane's screen to
    #   confirm the agent is actually at its input prompt, not just quiet
    #   (e.g. sitting on a startup dialog). nil means quiet-only readiness.
    # @param restartable [Boolean] whether handoff may clear this agent and resume it
    # @param clear_command [String] text typed to start a fresh conversation
    # @param context_pattern [String, nil] regex source with one capture group, applied to the
    #   pane's screen to read context use when the agent has no status line workspace can route
    # @param context_remaining [Boolean] whether that capture is the percent left, not used
    # @param interrupt_keys [Array<String>] tmux key names that stop the agent mid-turn (`plan pause --interrupt`); empty when unknown
    # @param user_config_dir [String, nil] the agent's own config directory under the home
    #   directory; set, +settings_path+ is relative to it rather than to the project
    # @param user_config_env [String, nil] environment variable that moves that directory
    # @param hook_timeouts [Hash, nil] event name => seconds the agent gives the hook
    # @param hook_events [Array<String>] the {HOOK_EVENT_TYPES} this agent's hooks can report
    # @param hook_trust_hint [String, nil] what a person must do in the agent before
    #   newly installed hooks run, printed after an install
    def initialize(key:, label:, executable:, settings_path: nil, events: nil,
      background_markers: [], path_segment_matching: true, ready_pattern: nil,
      restartable: false, clear_command: "/clear", context_pattern: nil, context_remaining: false, interrupt_keys: [],
      user_config_dir: nil, user_config_env: nil, hook_timeouts: nil, hook_events: [], hook_trust_hint: nil)
      @hook_trust_hint = hook_trust_hint
      @user_config_dir = user_config_dir
      @user_config_env = user_config_env
      @hook_timeouts = hook_timeouts
      @hook_events = hook_events
      @key = key
      @label = label
      @executable = executable
      @settings_path = settings_path
      @events = events
      @background_markers = background_markers
      @path_segment_matching = path_segment_matching
      @ready_pattern = ready_pattern
      @restartable = restartable
      @clear_command = clear_command
      @context_pattern = context_pattern
      @context_remaining = context_remaining
      @interrupt_keys = interrupt_keys.freeze
    end

    # @return [Boolean] whether workspace can route this agent's statusLine
    #   through `workspace statusline`. Claude Code is the only agent that
    #   supports a `statusLine` settings key today; installing or checking for
    #   one on another agent would be meaningless.
    def supports_statusline?
      key == "claude"
    end

    # @return [Boolean] whether workspace can install hooks for this agent
    def supports_hooks?
      !settings_path.nil? && !events.nil?
    end

    # @return [Boolean] whether the hooks live in the agent's user-level config
    #   directory (see {#user_config_path}) rather than in each project
    def user_scoped?
      !@user_config_dir.nil?
    end

    # @param env [Hash] process environment
    # @param home [String] the home directory
    # @return [String, nil] the user-level hook file, or nil for a project-scoped agent
    def user_config_path(env:, home:)
      return nil unless user_scoped?

      moved = @user_config_env && env[@user_config_env]
      dir = (moved.is_a?(String) && !moved.empty?) ? File.expand_path(moved, home) : File.join(home, @user_config_dir)
      File.join(dir, settings_path)
    end

    # The command a hook runs. Claude Code's is +base+ itself, as installed
    # before other agents had hooks; any other agent's names itself, so
    # `session-event` reads the payload by that agent's event names.
    #
    # A user-level hook runs in every session of the agent on the machine,
    # so it is guarded in the shell: outside a tmux pane (no `$TMUX_PANE`,
    # where `session-event` would drop the event anyway) Ruby never starts,
    # and the payload is read and thrown away so the agent's write to the
    # hook's stdin doesn't fail.
    #
    # @param base [String] e.g. "workspace session-event"
    # @return [String]
    def hook_command(base)
      return base if key == "claude"
      return unguarded_hook_command(base) unless user_scoped?

      "if [ -n \"$TMUX_PANE\" ]; then #{unguarded_hook_command(base)}; else cat >/dev/null; fi"
    end

    # Every command this agent's hooks have run, the current one first, so an
    # upgrade replaces an older entry in place and an uninstall finds it.
    #
    # @param base [String] e.g. "workspace session-event"
    # @return [Array<String>]
    def hook_commands(base)
      [hook_command(base), unguarded_hook_command(base)].uniq
    end

    def unguarded_hook_command(base)
      (key == "claude") ? base : "#{base} --agent #{key}"
    end
    private :unguarded_hook_command

    # Builds the settings fragment that routes this agent's hook events to the
    # given command.
    #
    # @param command [String] shell command each hook should run
    # @return [Hash] a settings fragment ready to merge into the agent's config
    def hook_settings(command)
      entries = events.map do |event, matcher|
        hook = {"type" => "command", "command" => hook_command(command)}
        hook["timeout"] = @hook_timeouts[event] if @hook_timeouts
        entry = matcher ? {"matcher" => matcher} : {}
        [event, [entry.merge("hooks" => [hook])]]
      end
      {"hooks" => entries.to_h}
    end
  end
end
