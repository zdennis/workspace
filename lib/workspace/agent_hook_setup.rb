module Workspace
  # Installs a checkout's session hooks and status line for each coding agent
  # whose executable is on PATH, the work `start` does for a new worktree.
  #
  # It prints nothing itself: what a person should be told comes back in a
  # {Result}, so each caller says it where its own output belongs (a warning
  # list under `--json`, a stream otherwise). {HookInstaller}'s own progress
  # lines still go to its output when not quiet.
  class AgentHookSetup
    # One thing to tell the person.
    #
    # @!attribute provider [r] the {AgentProvider} the note is about
    # @!attribute text [r] the note, with its `Note: ` prefix
    # @!attribute kind [r] `:info`, `:refused` (the person's config says not to install), `:stale` (tracked hooks are out of date; the note names `workspace init --install-hooks`) or `:leftover` (an install failed)
    Note = Data.define(:provider, :text, :kind)

    # What one {#install} did.
    #
    # @!attribute notes [r] the {Note}s, in the order they arose
    # @!attribute leftovers [r] the {AgentProvider}s whose hooks are still not installed: an install that failed, or stale tracked hooks
    Result = Data.define(:notes, :leftovers) do
      # @return [Array<String>] every note's text, in order
      def texts
        notes.map(&:text)
      end
    end

    # @param hook_installer [Workspace::HookInstaller] writes the settings files
    # @param hooks_config [Workspace::HooksConfig, nil] reads `codex.hooks.install`; nil installs every agent's hooks
    # @param agent_commands [Workspace::AgentCommands, nil] names each agent's configured program; nil uses the provider's own
    # @param project_settings [Workspace::ProjectSettings] where the status line install reads its project's settings
    # @param which [#call] returns true when an executable is on PATH
    def initialize(hook_installer:, hooks_config: nil, agent_commands: nil, project_settings: nil, which: Which)
      @hook_installer = hook_installer
      @hooks_config = hooks_config
      @agent_commands = agent_commands
      @project_settings = project_settings
      @which = which
    end

    # Installs each detected, hook-capable agent's hooks into the checkout's
    # untracked local settings, then routes each status-line-capable agent's
    # status line through `workspace statusline`. Nothing is written for a file
    # that is already current. A settings file that cannot be read or written
    # becomes a leftover note, never an exception.
    #
    # @param checkout_path [String] the checkout to install into
    # @param config_name [String] the workspace whose agent commands are read
    # @param quiet [Boolean] whether {HookInstaller} stays silent
    # @return [Result]
    def install(checkout_path, config_name, quiet:)
      notes = []
      leftovers = []

      detected(:supports_hooks?, config_name).each do |provider|
        if @hooks_config && !@hooks_config.install_user_hooks?(provider)
          notes << Note.new(provider, "Note: #{provider.label} hooks not installed: codex.hooks.install is false (workspace config set codex.hooks.install true to change)", :refused)
          next
        end
        install_provider_hooks(provider, checkout_path, quiet, notes, leftovers)
      end

      detected(:supports_statusline?, config_name).each do |provider|
        install_status_line(provider, checkout_path, quiet, notes, leftovers)
      end

      Result.new(notes: notes.freeze, leftovers: leftovers.uniq.freeze).freeze
    end

    private

    def detected(capability, config_name)
      AgentProvider.all.select { |p| p.public_send(capability) && @which.call(agent_executable(p, config_name)) }
    end

    def agent_executable(provider, config_name)
      @agent_commands ? @agent_commands.executable_for(config_name, provider.key) : provider.executable
    end

    def install_provider_hooks(provider, path, quiet, notes, leftovers)
      changed = @hook_installer.install(provider, path, HookInstaller::HOOK_COMMAND, quiet: quiet, local: true)
      notes << Note.new(provider, "Note: #{provider.hook_trust_hint}.", :info) if changed && quiet && provider.hook_trust_hint
      if !changed && !provider.user_scoped? && @hook_installer.stale_tracked_hooks?(provider, path, HookInstaller::HOOK_COMMAND)
        notes << Note.new(provider, "Note: #{@hook_installer.stale_message(provider, path, HookInstaller::HOOK_COMMAND)}.", :stale)
        leftovers << provider
      end
    rescue Workspace::Error, SystemCallError => e
      notes << Note.new(provider, "Note: #{provider.label} hooks not installed: #{e.message}", :leftover)
      leftovers << provider
    end

    def install_status_line(provider, path, quiet, notes, leftovers)
      notices = @hook_installer.install_statusline(provider, path,
        command: HookInstaller::STATUSLINE_COMMAND, project_settings: @project_settings, quiet: quiet, local: true)
      return unless quiet
      notices.each { |notice| notes << Note.new(provider, "Note: #{notice}.", :info) }
    rescue Workspace::Error, SystemCallError => e
      notes << Note.new(provider, "Note: #{provider.label} statusLine not routed: #{e.message}", :leftover)
      leftovers << provider
    end
  end
end
