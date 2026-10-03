require "yaml"
require "stringio"

module Workspace
  module Commands
    # Kills a worktree-based workspace project by stopping its session,
    # removing its git worktree, and cleaning up its tmuxinator config.
    # The inverse of Commands::Start.
    class Kill
      # @param git [Workspace::Git] git operations
      # @param project_config [Workspace::ProjectConfig] config management
      # @param stop_command [Commands::Stop] stop command for session teardown
      # @param output [IO] output stream for user-facing messages
      # @param task_store [Workspace::TaskStore, nil] archives the project's task
      #   once its worktree is removed; nil leaves tasks alone
      # @param input [IO] input stream for interactive prompts
      def initialize(git:, project_config:, project_settings:, stop_command:, project_detector:, task_store: nil, output: $stdout, input: $stdin)
        @git = git
        @project_config = project_config
        @project_settings = project_settings
        @stop_command = stop_command
        @project_detector = project_detector
        @task_store = task_store
        @output = output
        @input = input
      end

      MARKER_FILE = ".workspace-project"

      # Kills a worktree project. The order is chosen so nothing is lost and
      # nothing is left half-removed:
      #
      # 1. check for unsaved work (unless force), before prompting
      # 2. confirm (unless force or confirm: false)
      # 3. remove the worktree; Git#remove_worktree re-checks for unsaved work
      #    right before removing (unless force), so an edit made while the
      #    prompt waited is refused rather than deleted
      # 4. archive the project's task, then yield to the caller's block (the post_kill hook), then remove the
      #    config and settings
      # 5. stop the session last: this may run inside the very session it
      #    kills, which ends this process before any later statement runs
      #
      # @param project [String, nil] project/config name, or nil to detect from cwd
      # @param force [Boolean] skip confirmation, and skip the unsaved-work refusal
      # @param confirm [Boolean] ask before removing; false skips the prompt but
      #   (unlike force) still refuses unsaved work
      # @param quiet [Boolean] print nothing to the output stream, including the
      #   config removal and session stop messages
      # @param working_dir [String] cwd to detect the project from, when project is nil
      # @param missing_ok [Boolean] when the checkout directory is already gone,
      #   skip the worktree removal (git's own metadata for it is left for
      #   `git worktree prune`) and still remove the config, settings, state
      #   entry and session; false treats a gone checkout as not a worktree
      #   project and raises
      # @param warn_inactive [Boolean] warn on the error stream when the project
      #   is not active, so there is no session to stop
      # @param outcome [String, nil] the outcome the project's task is archived with
      #   (`merged`, `discarded`, `abandoned`); nil is `discarded` with force, else `abandoned`
      # @yieldparam project [String] the project, after its worktree is removed and
      #   before its config, settings and session go
      # @return [String, nil] the project name, or nil if the user cancelled
      # @raise [Workspace::UnsavedWorkError] if it has unsaved work and force is false
      # @raise [Workspace::Error] if the project config is not a worktree project
      def call(project = nil, force: false, confirm: true, quiet: false, working_dir: Dir.pwd, missing_ok: false, warn_inactive: true, outcome: nil)
        out = quiet ? StringIO.new : @output
        project ||= @project_detector.detect_from_marker(working_dir)
        unless project
          raise Workspace::Error,
            "No project specified and no #{MARKER_FILE} found in current directory.\n" \
            "Run from inside a worktree, or specify the project name."
        end
        config_path = @project_config.config_path_for(project)
        unless File.exist?(config_path)
          raise Workspace::Error, "No config found for '#{project}'.\nRun 'workspace list' to see active projects."
        end

        worktree_path = read_worktree_path(config_path)
        missing = missing_ok && worktree_path && !File.directory?(worktree_path)
        if !missing && !(worktree_path && @git.worktree_exists?(worktree_path))
          raise Workspace::Error, "'#{project}' does not appear to be a worktree project.\nUse 'workspace stop #{project}' to stop non-worktree projects."
        end

        unless force || missing
          unsaved = @git.unsaved_work(worktree_path)
          raise_unsaved_work!(project, worktree_path, unsaved) if unsaved
        end

        out.puts "Stopping #{project}..."
        out.puts "  Worktree: #{worktree_path}"

        if confirm && !force
          answer = Prompt.ask(@input, out, "Remove worktree and kill session? [y/N] ", retry_flags: ["--force"], destructive: true)&.strip
          unless answer&.match?(/\Ay(es)?\z/i)
            out.puts "Cancelled."
            return
          end
        end

        if missing
          out.puts "Checkout already gone; skipping worktree removal."
        else
          out.puts "Removing worktree..."
          begin
            @git.remove_worktree(worktree_path, force: force)
          rescue Workspace::UnsavedWorkError => e
            raise_unsaved_work!(project, worktree_path, e.unsaved)
          end
        end

        @task_store&.archive(project, outcome: outcome || (force ? "discarded" : "abandoned"))
        yield project if block_given?
        @project_config.remove(project, quiet: quiet)
        @project_settings.remove(project)

        out.puts "Killing session..."
        @stop_command.call([project], quiet: quiet, warn_inactive: warn_inactive)
        project
      end

      private

      def raise_unsaved_work!(project, worktree_path, unsaved)
        message = if unsaved == :unknown
          "Could not check '#{project}' for unsaved work (git couldn't answer).\n" \
            "Not removing the worktree at #{worktree_path}.\n"
        else
          "'#{project}' has unsaved work at #{worktree_path}: #{Workspace::UnsavedWorkError.describe(unsaved)}.\n"
        end
        raise Workspace::UnsavedWorkError.new("#{message}Commit/push, or rerun with --force.", unsaved: unsaved)
      end

      def read_worktree_path(config_path)
        config = YAML.safe_load_file(config_path)
        config&.dig("root")
      rescue Psych::Exception
        raise Workspace::Error, "Corrupt config file: #{config_path}"
      end
    end
  end
end
