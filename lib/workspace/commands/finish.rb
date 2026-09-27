require "yaml"
require "json"
require "open3"

module Workspace
  module Commands
    # Finishes a worktree project: verifies its branch is clean and fully
    # pushed (optionally opening a PR with `gh`), then removes it the same
    # way Commands::Kill does. The local counterpart to a merge-and-cleanup
    # workflow, for agents that shouldn't depend on `gh` being configured.
    class Finish
      JSON_SCHEMA_VERSION = 1
      MARKER_FILE = ".workspace-project"

      # @param git [Workspace::Git] git operations
      # @param project_config [Workspace::ProjectConfig] config management
      # @param kill_command [Commands::Kill] kill command, reused for teardown
      # @param project_detector [Workspace::ProjectDetector] cwd-based project detection
      # @param output [IO] output stream for user-facing messages
      # @param error_output [IO] error output stream for warnings
      # @param input [IO] input stream (unused; accepted for interface symmetry with Kill)
      def initialize(git:, project_config:, kill_command:, project_detector:, output: $stdout, error_output: $stderr, input: $stdin)
        @git = git
        @project_config = project_config
        @kill_command = kill_command
        @project_detector = project_detector
        @output = output
        @error_output = error_output
        @input = input
      end

      # Finishes a worktree project: checks it is clean and pushed, optionally
      # opens a PR, then tears it down via Commands::Kill.
      #
      # @param project [String, nil] project/config name, or nil to detect from cwd
      # @param pr [Boolean] open (or look up) a PR with `gh` before cleanup
      # @param json [Boolean] emit the documented JSON schema instead of plain text
      # @param working_dir [String] cwd to detect the project from, when project is nil
      # @yieldparam project [String] passed through to Commands::Kill#call: runs after
      #   the worktree is removed and before the config and session go
      # @return [Hash] {exit_code:} when json is true; the finished project name otherwise
      # @raise [Workspace::Error] if the worktree isn't clean/pushed, gh fails, or it
      #   isn't a worktree project (unless json is true, where this is reported instead)
      def call(project = nil, pr: false, json: false, working_dir: Dir.pwd, &after_remove)
        return call_json(project, pr: pr, working_dir: working_dir, &after_remove) if json

        finish!(project, pr: pr, working_dir: working_dir, &after_remove)
      end

      private

      def call_json(project, pr:, working_dir:, &after_remove)
        finished = finish!(project, pr: pr, working_dir: working_dir, quiet: true, &after_remove)
        @output.puts JSON.generate({"schema_version" => JSON_SCHEMA_VERSION, "project" => finished})
        {exit_code: 0}
      rescue Workspace::Error => e
        @output.puts JSON.generate({"schema_version" => JSON_SCHEMA_VERSION, "error" => e.message})
        {exit_code: 1}
      end

      def finish!(project, pr:, working_dir:, quiet: false, &after_remove)
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
        unless worktree_path && @git.worktree_exists?(worktree_path)
          raise Workspace::Error, "'#{project}' does not appear to be a worktree project."
        end

        check_clean_and_pushed!(project, worktree_path)

        open_pr!(project, worktree_path, quiet: quiet) if pr

        @output.puts "Finishing #{project}..." unless quiet
        # confirm: false skips Kill's prompt but keeps its unsaved-work check,
        # which Git#remove_worktree repeats right before removing: anything
        # committed or edited since the check above is refused, not deleted.
        begin
          @kill_command.call(project, confirm: false, quiet: quiet, working_dir: working_dir, &after_remove)
        rescue Workspace::UnsavedWorkError => e
          raise Workspace::Error,
            "'#{project}' has unsaved work: #{e.summary}.\n" \
            "Not removing the worktree at #{worktree_path}. Commit and push, then rerun finish."
        end
        project
      end

      def check_clean_and_pushed!(project, worktree_path)
        changed = @git.changed_files_count(worktree_path)
        if changed.nil?
          raise Workspace::Error,
            "Could not check '#{project}' — git couldn't read its status.\n" \
            "Not touching the worktree at #{worktree_path}."
        end
        if changed > 0
          raise Workspace::Error,
            "'#{project}' has #{changed} changed file(s) at #{worktree_path}.\n" \
            "Commit or stash them before finishing."
        end

        branch = @git.worktree_branch(worktree_path)
        if branch.nil?
          raise Workspace::Error,
            "'#{project}' is on a detached HEAD at #{worktree_path}.\n" \
            "Check out a branch first (git -C #{worktree_path} switch -c <branch>), push it, then rerun finish."
        end

        upstream = @git.upstream_branch(worktree_path)
        if upstream.nil?
          raise Workspace::Error,
            "'#{project}' branch '#{branch}' has no upstream.\n" \
            "Push it first: git -C #{worktree_path} push -u origin #{branch}"
        end

        ahead = @git.commits_ahead_of_upstream(worktree_path)
        if ahead.nil?
          raise Workspace::Error, "Could not check '#{project}' — git couldn't compare '#{branch}' with #{upstream}."
        end
        if ahead > 0
          raise Workspace::Error,
            "'#{project}' branch '#{branch}' is #{ahead} commit(s) ahead of #{upstream}.\n" \
            "Push before finishing: git -C #{worktree_path} push"
        end
      end

      def open_pr!(project, worktree_path, quiet:)
        unless gh_available?
          @output.puts "gh is not installed; skipping PR creation." unless quiet
          return
        end

        branch = @git.worktree_branch(worktree_path)
        stdout, _, status = Open3.capture3("gh", "pr", "view", branch, "--json", "url", chdir: worktree_path)
        if status.success?
          url = begin
            JSON.parse(stdout)["url"]
          rescue JSON::ParserError
            stdout.strip
          end
          @output.puts "PR already exists: #{url}" unless quiet
          return
        end

        stdout, stderr, status = Open3.capture3("gh", "pr", "create", "--fill", chdir: worktree_path)
        unless status.success?
          raise Workspace::Error, "Could not open a PR for '#{project}': #{stderr.strip}"
        end
        @output.puts stdout.strip unless quiet
      end

      def gh_available?
        _, _, status = Open3.capture3("which", "gh")
        status.success?
      rescue Errno::ENOENT
        false
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
