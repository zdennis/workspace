require "open3"
require "json"

module Workspace
  module Commands
    # Removes worktree-backed workspace projects whose associated GitHub PR is
    # closed or merged. Scans all tmuxinator configs and state entries, checks
    # each project's PR state via the `gh` CLI, and offers bulk removal with
    # optional dry-run and force modes.
    class Prune
      # PR states that make a project eligible for pruning.
      ELIGIBLE_PR_STATES = %w[CLOSED MERGED].freeze

      # @param state [Workspace::State] state persistence
      # @param project_config [Workspace::ProjectConfig] tmuxinator config management
      # @param project_settings [Workspace::ProjectSettings] per-project settings management
      # @param git [Workspace::Git] git operations
      # @param kill_command [Workspace::Commands::Kill] pre-built kill command for session teardown
      # @param output [IO] output stream for user-facing messages
      # @param input [IO] input stream for interactive prompts
      def initialize(state:, project_config:, project_settings:, git:, kill_command:, output: $stdout, input: $stdin)
        @state = state
        @project_config = project_config
        @project_settings = project_settings
        @git = git
        @kill_command = kill_command
        @output = output
        @input = input
      end

      # Detects projects eligible for pruning, prints a summary table, prompts
      # for confirmation (unless --force), and removes them.
      #
      # @param dry_run [Boolean] print table but make no changes
      # @param force [Boolean] skip confirmation prompt
      # @return [Array<String>] names of pruned (or would-be-pruned) projects
      def call(dry_run: false, force: false)
        @state.load

        candidates = detect_candidates

        if candidates.empty?
          @output.puts "No projects eligible for pruning found."
          return []
        end

        print_table(candidates)

        if dry_run
          @output.puts "\n(dry run — no changes made)"
          return candidates.map { |c| c[:project] }
        end

        unless force
          @output.print "\nRemove these #{candidates.size} project(s)? [y/N] "
          answer = @input.gets&.strip
          unless answer&.match?(/\Ay(es)?\z/i)
            @output.puts "Cancelled."
            return []
          end
        end

        candidates.each { |c| remove_candidate(c) }
        @state.save

        @output.puts "Pruned #{candidates.size} project(s)."
        candidates.map { |c| c[:project] }
      end

      private

      # Builds the list of projects eligible for pruning.
      #
      # @return [Array<Hash>] candidate hashes with keys :project, :worktree_path,
      #   :branch, :pr_number, :pr_url, :pr_state
      def detect_candidates
        all_projects = (@project_config.available_projects + @state.keys).uniq
        gh_checked = false
        gh_available = nil
        candidates = []

        @output.puts "Scanning #{all_projects.size} workspace(s)...\n\n"

        all_projects.each do |project|
          @output.print "  #{project}: "

          root = @project_config.project_root_for(project)

          if root.nil?
            @output.puts "skipped (no config root)"
            next
          end

          unless File.directory?(root)
            @output.puts "eligible (directory gone)"
            candidates << {project: project, worktree_path: root, branch: nil, pr_number: nil, pr_url: nil, pr_state: "GONE"}
            next
          end

          unless @git.linked_worktree?(root)
            @output.puts "skipped (not a worktree)"
            next
          end

          branch = @git.worktree_branch(root)
          if branch.nil?
            @output.puts "skipped (detached HEAD)"
            next
          end

          unless gh_checked
            gh_available = gh_usable?
            gh_checked = true
            unless gh_available
              @output.puts ""
              @output.puts "Warning: `gh` is not authenticated or not installed. Cannot check PR states. Skipping all worktree projects."
            end
          end

          unless gh_available
            @output.puts "skipped (gh unavailable)"
            next
          end

          pr = pr_status(branch, root)
          if pr.nil?
            @output.puts "skipped (no PR found for #{branch})"
            next
          end

          if ELIGIBLE_PR_STATES.include?(pr[:state])
            @output.puts "#{pr[:state]} — eligible"
            candidates << {
              project: project,
              worktree_path: root,
              branch: branch,
              pr_number: pr[:number],
              pr_url: pr[:url],
              pr_state: pr[:state]
            }
          else
            @output.puts "#{pr[:state]} — skipped"
          end
        end

        @output.puts ""
        candidates
      end

      # Checks whether the `gh` CLI is authenticated and available.
      #
      # @return [Boolean] true if `gh auth status` succeeds
      def gh_usable?
        _, _, status = Open3.capture3("gh", "auth", "status")
        status.success?
      end

      # Parses a GitHub remote URL and returns the owner/repo slug.
      #
      # @param remote_url [String] SSH or HTTPS GitHub remote URL
      # @return [String, nil] the "owner/repo" slug, or nil if not parseable
      def github_repo_slug(remote_url)
        m = remote_url.match(%r{github\.com[:/](.+?)(?:\.git)?\z})
        m ? m[1] : nil
      end

      # Looks up the PR for a branch in a given repo directory.
      #
      # @param branch [String] the branch name
      # @param repo_path [String] path to the worktree directory
      # @return [Hash, nil] hash with :number, :url, :state keys, or nil on failure
      def pr_status(branch, repo_path)
        remote_url, _, status = Open3.capture3("git", "-C", repo_path, "remote", "get-url", "origin")
        return nil unless status.success?

        slug = github_repo_slug(remote_url.strip)
        return nil unless slug

        stdout, _, gh_status = Open3.capture3(
          "gh", "pr", "view", branch,
          "--repo", slug,
          "--json", "number,url,state"
        )
        return nil unless gh_status.success?

        data = JSON.parse(stdout)
        {number: data["number"], url: data["url"], state: data["state"]}
      rescue JSON::ParserError
        nil
      end

      # Prints a candidate list showing what will be pruned.
      #
      # @param candidates [Array<Hash>] list of candidate hashes
      # @return [void]
      def print_table(candidates)
        @output.puts "The following #{candidates.size} workspace(s) will be pruned:\n"

        candidates.each do |c|
          @output.puts "  #{c[:project]}"

          if c[:branch]
            @output.puts "    branch:  #{c[:branch]}"
          else
            @output.puts "    branch:  —"
          end

          if c[:pr_number]
            @output.puts "    PR ##{c[:pr_number]}: #{c[:pr_state]}  (#{c[:pr_url]})"
          else
            @output.puts "    PR:      —"
          end

          path_note = File.directory?(c[:worktree_path]) ? "" : "  (directory gone)"
          @output.puts "    path:    #{c[:worktree_path]}#{path_note}"

          @output.puts ""
        end
      end

      # Removes a single candidate project: kills any live session, removes the
      # worktree, tmuxinator config, project settings, and state entry.
      #
      # @param candidate [Hash] a candidate hash from detect_candidates
      # @return [void]
      def remove_candidate(candidate)
        path = candidate[:worktree_path]
        project = candidate[:project]

        @kill_command.call([project]) if @state[project]
        @git.remove_worktree(path, force: true) if @git.worktree_exists?(path)
        @project_config.remove(project)
        @project_settings.remove(project)
        @state.delete(project)
      end
    end
  end
end
