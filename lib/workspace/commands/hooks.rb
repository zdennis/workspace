module Workspace
  module Commands
    # `hooks uninstall --agent KIND`: takes workspace's hooks back out of a
    # coding agent's own settings file, leaving the person's own hooks and
    # every other key as they were.
    class Hooks
      # @param hook_installer [Workspace::HookInstaller] finds and edits the agent's settings file
      # @param working_dir [String] the project a per-project agent's (Claude Code's) file is in
      def initialize(hook_installer:, working_dir: Dir.pwd)
        @hook_installer = hook_installer
        @working_dir = working_dir
      end

      # @param agent [String] the agent's key (`codex`, `claude`), in any case
      # @param dry_run [Boolean] report what would be removed without writing
      # @return [Hash] `"agent"`, `"path"`, `"removed"` (hook handlers), `"backup"`, `"dry_run"`
      # @raise [Workspace::Error] `unknown_agent_kind` for an agent workspace installs no hooks for;
      #   `hook_settings_unreadable` for a file it can't parse
      def uninstall(agent:, dry_run: false)
        provider = AgentProvider.find(agent.to_s.downcase)
        unless provider&.supports_hooks?
          known = AgentProvider.all.select(&:supports_hooks?).map(&:key)
          raise Workspace::Error.new("No hooks to uninstall for --agent '#{agent}'. Known: #{known.join(", ")}.",
            code: "unknown_agent_kind", details: {"kind" => agent, "known" => known})
        end

        result = @hook_installer.uninstall(provider, @working_dir, Init::HOOK_COMMAND, dry_run: dry_run)
        {"agent" => provider.key, "path" => result[:path], "removed" => result[:removed],
         "backup" => result[:backup], "dry_run" => dry_run}
      end
    end
  end
end
