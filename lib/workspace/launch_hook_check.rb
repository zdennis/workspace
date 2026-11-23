module Workspace
  # The read-only warning `launch` prints when a launched checkout's coding
  # agents hold no current session hooks.
  #
  # `start` installs hooks into each new worktree, but a workspace created any
  # other way (a hand-written tmuxinator config, a pre-hooks-era checkout)
  # gets none and fails silently: session monitoring reads the wrong pane
  # states, `handoff check` cannot read context usage and edit locks go
  # unenforced. The check names each hook-capable agent whose executable is on
  # PATH and whose hooks are missing or stale, and tells the person the one
  # command that fixes it. It never installs or mutates a settings file.
  class LaunchHookCheck
    # The remedy the notes name. `init --install-hooks` from the checkout is
    # the one command that installs both a project-scoped agent's settings
    # hooks (Claude Code) and a user-scoped agent's user-level hook file
    # (Codex); `doctor --fix` only fixes the user-level ones.
    FIX_HINT = "run `workspace init --install-hooks` in this checkout to install them"

    # @param hook_installer [Workspace::HookInstaller] does the reads
    # @param hooks_config [Workspace::HooksConfig, nil] the global
    #   `codex.hooks.install` off-switch; nil skips nothing
    # @param which [#call] answers whether an agent's executable is on PATH
    def initialize(hook_installer:, hooks_config: nil, which: Which)
      @hook_installer = hook_installer
      @hooks_config = hooks_config
      @which = which
    end

    # Prints one Note line per hook-capable agent whose hooks are missing or
    # stale in the checkout at +root+, or none when every agent's hooks are
    # current. An unreadable settings file becomes a note, never a failure.
    #
    # @param root [String] the checkout to read the settings files in
    # @param io [IO] where the notes go (the run's error output)
    # @param only [Array<Workspace::AgentProvider>, nil] check exactly these
    #   providers and skip the PATH filter (the installer already chose them,
    #   through the configured agent command); nil checks every hook-capable
    #   provider whose executable is on PATH. An empty list checks none.
    # @return [void]
    def check(root, io:, only: nil)
      (only || AgentProvider.all.select(&:supports_hooks?)).each do |provider|
        next if only.nil? && !@which.call(provider.executable)
        next if @hooks_config && !@hooks_config.install_user_hooks?(provider)

        note = note_for(provider, root)
        io.puts "Note: #{note}" if note
      end
    end

    private

    def note_for(provider, root)
      installed = installed?(provider, root)
      return stale_note(provider, root) if installed && @hook_installer.stale_tracked_hooks?(provider, root, HookInstaller::HOOK_COMMAND)
      return nil if installed

      "#{provider.label} hooks missing or stale for this checkout's agents; #{FIX_HINT}."
    rescue Workspace::Error, SystemCallError
      # An unreadable settings file (bad JSON, wrong shape, no permission) is
      # a note, never a failed launch: the session is already up by now.
      "#{provider.label} hooks not installed: could not read the agent settings file; #{FIX_HINT}."
    end

    # Current hooks may sit in the untracked local settings file, where
    # `start` installs them (`local: true`), rather than in the tracked one
    # {HookInstaller#installed?} reads; Claude Code runs hooks from every
    # scope, so either file counts as installed. A user-scoped agent (Codex)
    # has no local file — `install` never writes one.
    def installed?(provider, root)
      return true if @hook_installer.installed?(provider, root, HookInstaller::HOOK_COMMAND)
      return false if provider.user_scoped?

      @hook_installer.installed_in?(@hook_installer.local_settings_path_for(provider, root), provider, HookInstaller::HOOK_COMMAND)
    end

    def stale_note(provider, root)
      @hook_installer.stale_message(provider, root, HookInstaller::HOOK_COMMAND)
    end
  end
end
