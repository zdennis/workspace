module Workspace
  module Commands
    # `hooks uninstall --agent KIND`: takes workspace's hooks back out of a
    # coding agent's own settings file, leaving the person's own hooks and
    # every other key as they were.
    class Hooks
      # @param hook_installer [Workspace::HookInstaller] finds and edits the agent's settings file
      # @param working_dir [String] the project a per-project agent's (Claude Code's) file is in
      # @param checkout [Workspace::WorkspaceCheckout, nil] finds a named workspace's checkout (`--name`)
      # @param catalog [Workspace::ProjectCatalog, nil] finds a project's checkouts (`--project`)
      def initialize(hook_installer:, working_dir: Dir.pwd, checkout: nil, catalog: nil)
        @hook_installer = hook_installer
        @working_dir = working_dir
        @checkout = checkout
        @catalog = catalog
      end

      # @param agent [String] the agent's key (`codex`, `claude`), in any case
      # @param dry_run [Boolean] report what would be removed without writing
      # @return [Hash] `"agent"`, `"path"`, `"removed"` (hook handlers), `"backup"`, `"dry_run"`
      # @raise [Workspace::Error] `unknown_agent_kind` for an agent workspace installs no hooks for;
      #   `hook_settings_unreadable` for a file it can't parse
      def uninstall(agent:, dry_run: false)
        uninstall_at(hooks_provider(agent), @working_dir, dry_run)
      end

      # {#uninstall} in the checkout of one workspace, or in every checkout of a project.
      # A checkout whose file can't be read is a `failed` row; the others still go.
      #
      # @param agent [String] a per-project agent (`claude`); a user-level one (`codex`) is a usage error
      # @param name [String, nil] a workspace name
      # @param project [String, true, nil] a project (name, path or member workspace), or true for the current directory's
      # @param dry_run [Boolean]
      # @return [Array<Hash>] one row per checkout: {#uninstall}'s keys plus `"workspace"` (nil when the
      #   checkout has no config), `"checkout"` and `"outcome"` (`removed`, `would_remove`, `not_installed`, `failed`, `skipped`)
      # @raise [Workspace::UsageError] for both `name` and `project`, or for a user-level agent
      # @raise [Workspace::Error] `unknown_workspace`, `not_in_workspace`, or a project that isn't found
      def uninstall_in(agent:, name: nil, project: nil, dry_run: false)
        provider = hooks_provider(agent)
        raise UsageError, "--name and --project can't be combined." if name && project
        if provider.user_scoped?
          raise UsageError, "--name and --project don't apply to --agent #{provider.key}: its hooks are user-level, not per checkout."
        end

        targets(name, project).map { |workspace, path, exists| row(provider, workspace, path, exists, dry_run) }
      end

      private

      def hooks_provider(agent)
        provider = AgentProvider.find(agent.to_s.downcase)
        unless provider&.supports_hooks?
          known = AgentProvider.all.select(&:supports_hooks?).map(&:key)
          raise Workspace::Error.new("No hooks to uninstall for --agent '#{agent}'. Known: #{known.join(", ")}.",
            code: "unknown_agent_kind", details: {"kind" => agent, "known" => known})
        end
        provider
      end

      def uninstall_at(provider, dir, dry_run)
        result = @hook_installer.uninstall(provider, dir, Init::HOOK_COMMAND, dry_run: dry_run)
        {"agent" => provider.key, "path" => result[:path], "removed" => result[:removed],
         "backup" => result[:backup], "dry_run" => dry_run}
      end

      # @return [Array<Array>] `[workspace, path, exists]` per checkout
      def targets(name, project)
        if name
          found = @checkout.resolve(name, working_dir: @working_dir, allow_detached: true)
          [[found["workspace"], found["path"], File.directory?(found["path"])]]
        else
          found = (project == true) ? @catalog.for_cwd(@working_dir) : @catalog.find(project)
          @catalog.members(found, include_unconfigured: true).map { |m| [m.workspace, m.path, m.exists] }
        end
      end

      def row(provider, workspace, path, exists, dry_run)
        base = {"workspace" => workspace, "checkout" => path}
        unless exists
          return base.merge("outcome" => "skipped", "reason" => "checkout_missing", "message" => "#{path} does not exist",
            "agent" => provider.key, "path" => nil, "removed" => 0, "backup" => nil, "dry_run" => dry_run)
        end

        result = uninstall_at(provider, path, dry_run)
        outcome = if result["removed"].zero? then "not_installed"
        else
          dry_run ? "would_remove" : "removed"
        end
        base.merge(result).merge("outcome" => outcome)
      rescue Workspace::Error => e
        base.merge("outcome" => "failed", "reason" => e.code, "message" => e.message, "agent" => provider.key,
          "path" => File.join(path, provider.settings_path), "removed" => 0, "backup" => nil, "dry_run" => dry_run)
      end
    end
  end
end
