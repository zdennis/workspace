module Workspace
  class CLI
    # The workspace-name and working-directory helpers every command family calls: settling a
    # typed name to its on-disk spelling, picking the one workspace a command was given, and the
    # directory a command acts from. A method whose answer depends on the run's flags, or that
    # prints the "Workspace 'x' is y." line, takes the {Invocation}.
    class Names
      # @param project_config [Workspace::ProjectConfig] answers which workspaces have a config and where their roots are
      # @param project_detector [Workspace::ProjectDetector] finds the workspace of a directory
      # @param lineage [Workspace::WorkspaceLineage] names the project of a directory no detector finds (a stopped main checkout)
      # @param working_dir [String] the directory the CLI runs from
      # @param workspace_name [Workspace::WorkspaceName, nil] settles a given workspace name to its on-disk spelling (nil asks the project config)
      def initialize(project_config:, project_detector:, lineage:, working_dir:, workspace_name: nil)
        @project_config = project_config
        @project_detector = project_detector
        @lineage = lineage
        @working_dir = working_dir
        @workspace_name = workspace_name
      end

      # The one place a typed workspace name is settled. Answers the on-disk name, or nil
      # when the name matches nothing. A short name (a worktree suffix) resolves through
      # WorkspaceName#for_input, and one stderr line says which workspace it reached, unless
      # `--json` is given. While help is asked for, only the exact name (ignoring case)
      # counts, so help never fails on an ambiguous name. Built with no WorkspaceName, it
      # asks the project config.
      #
      # @param invocation [Invocation]
      # @param name [String, nil]
      # @return [String, nil]
      # @raise [Workspace::Error] `ambiguous_workspace` when several workspaces share the suffix
      def given_name(invocation, name)
        return @project_config.existing_name(name) unless @workspace_name

        found = invocation.help_asked ? @workspace_name.match(name) : @workspace_name.for_input(name)
        if found && !WorkspaceName.same?(found, name) && !invocation.quiet
          invocation.error_output.puts TerminalText.escape("Workspace '#{name}' is #{found}.")
        end
        found
      end

      # @param invocation [Invocation]
      # @param name [String, nil] a workspace or project name as given
      # @return [String, nil] the on-disk name of the config it matches ignoring case, else the name as given
      def settle_name(invocation, name)
        (@workspace_name && name) ? (given_name(invocation, name) || name) : name
      end

      # Takes the first positional off +args+ as the workspace when a workspace of that name has a
      # config (ignoring case); otherwise leaves +args+ alone so the caller's own parsing and usage
      # error apply.
      #
      # @param invocation [Invocation]
      # @param args [Array<String>] positionals, modified in place
      # @return [String, nil] the workspace's on-disk name, or nil when the first is not one
      def take_known_workspace!(invocation, args)
        known = given_name(invocation, args.first)
        args.shift if known
        known
      end

      # The one workspace a command was given, by `--name` or by position.
      #
      # @param invocation [Invocation]
      # @param name_opt [String, nil] value of `--name`
      # @param positional [String, nil] the positional workspace argument
      # @return [String, nil] the name, or nil when neither was given
      # @raise [Workspace::UsageError] when both are given and differ
      def pick_workspace_name(invocation, name_opt, positional)
        positional = settle_name(invocation, positional)
        if positional && name_opt && positional != name_opt
          raise UsageError, "Give the workspace once: '#{positional}' and --name #{name_opt} differ."
        end

        name_opt || positional
      end

      # The one workspace a lifecycle command (`kill`, `finish`, `remove`, `dir`) was given: the
      # positional or `--name` (they must agree), settled to its on-disk spelling, else nil.
      #
      # @param invocation [Invocation]
      # @param args [Array<String>] the positionals left after parsing
      # @param name [String, nil] value of `--name`
      # @param command [String] the subcommand, for the usage message
      # @return [String, nil]
      # @raise [Workspace::UsageError] for more than one positional, or a positional and `--name` that differ
      def single_workspace_arg(invocation, args, name, command)
        raise UsageError, "workspace #{command} takes one workspace; got: #{args.join(" ")}. Run 'workspace #{command} --help'." if args.size > 1
        pick_workspace_name(invocation, name, args.first)
      end

      # @param name [String]
      # @return [void]
      # @raise [Workspace::Error] code `unknown_workspace` when no config exists for +name+ (ignoring case)
      def require_known_workspace!(name)
        return if @project_config.existing_name(name)

        raise Error.new("Unknown workspace '#{name}': it has no config. See `workspace list`, or create one with `workspace add PATH` (`workspace add .` for this directory).",
          code: "unknown_workspace", details: {"name" => name})
      end

      # The directory a per-workspace command acts from: the named workspace's
      # root for `--name`, else the detected working directory.
      #
      # @param name [String, nil] value of `--name`
      # @return [String]
      # @raise [Workspace::Error] code `unknown_workspace` when no such workspace exists
      def working_dir_for(name)
        return @working_dir unless name

        root = @project_config.project_root_for(name)
        raise Error.new("Unknown workspace '#{name}'", code: "unknown_workspace", details: {"name" => name}) unless root

        File.expand_path(root)
      end

      # The directory a `dev` subcommand acts from: the named workspace's root, else the working
      # directory when it is in a workspace (one the detector finds, or the checkout of a configured
      # workspace, so a stopped main checkout works).
      #
      # @param name [String, nil] the WS argument or `--name`
      # @return [String]
      # @raise [Workspace::Error] code `unknown_workspace` for a name with no config, `not_in_workspace` outside any workspace
      def dev_working_dir(name)
        return working_dir_for(name) if name
        return @working_dir if workspace_here

        raise Error.new("No workspace found for #{@working_dir}. Run from inside a workspace or pass the workspace name. A lock left by a checkout that is no longer a workspace can be released with `workspace lock clear`.",
          code: "not_in_workspace", details: {"path" => @working_dir})
      end

      # @param name [String, nil] the workspace given, if any
      # @return [String] +name+, else the workspace the working directory is in
      # @raise [Workspace::Error] code `not_in_workspace` when neither gives one
      def current_workspace!(name)
        name ||= workspace_here
        return name if name

        raise Error.new("No workspace found for #{@working_dir}. Run from inside a workspace or pass --name.", code: "not_in_workspace", details: {"path" => @working_dir})
      end

      # The workspace the working directory is in: the detector's answer (a marker or a running
      # workspace), else the directory's lineage name when a workspace of that name is configured,
      # so a stopped main checkout counts too.
      #
      # @return [String, nil]
      def workspace_here
        @project_detector.detect(@working_dir) || main_checkout_workspace
      end

      private

      # The configured workspace named like the main checkout the working directory is in; a linked
      # worktree or a directory outside git never resolves to one.
      def main_checkout_workspace
        lineage = @lineage.resolve(cwd: @working_dir)
        return nil unless lineage.git_common_dir && !lineage.is_worktree
        @project_config.existing_name(lineage.name)
      end
    end
  end
end
