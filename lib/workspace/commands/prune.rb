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
      # @param stop_command [Workspace::Commands::Stop] pre-built stop command for session teardown
      # @param event_log [Workspace::EventLog, nil] records `worktree_finished` (outcome `pruned`) for each removed project
      # @param output [IO] output stream for user-facing messages
      # @param input [IO] input stream for interactive prompts
      def initialize(state:, project_config:, project_settings:, git:, stop_command:, event_log: nil, output: $stdout, input: $stdin)
        @state = state
        @project_config = project_config
        @project_settings = project_settings
        @git = git
        @stop_command = stop_command
        @event_log = event_log
        @output = output
        @input = input
      end

      # Detects projects eligible for pruning, prints a summary table, prompts
      # for confirmation (unless --force), and removes them.
      #
      # @param dry_run [Boolean] print table but make no changes
      # @param force [Boolean] skip confirmation prompt, and remove a candidate's
      #   worktree even if it has unsaved work
      # @return [Array<String>] names of pruned (or would-be-pruned) projects
      def call(dry_run: false, force: false, names: [])
        @state.load

        candidates = detect_candidates
        candidates = select_named(candidates, names) if names.any?

        if candidates.empty?
          @output.puts "No projects eligible for pruning found."
          return []
        end

        print_table(candidates)

        if dry_run
          skips = candidates.map { |c| [c, preview_skip(c, force: force)] }.select { |_, r| r }
          skips.each { |_, r| @output.puts "  #{r[:message]}" }
          @output.puts "\n(dry run — no changes made)"
          return candidates.map { |c| c[:project] } - skips.map { |c, _| c[:project] }
        end

        unless force
          answer = Prompt.ask(@input, @output, "\nRemove these #{candidates.size} project(s)? [y/N] ", retry_flags: ["--force"], destructive: true)&.strip
          unless answer&.match?(/\Ay(es)?\z/i)
            @output.puts "Cancelled."
            return []
          end
        end

        removed = []
        skipped = []
        candidates.each do |c|
          if remove_candidate(c, force: force)
            removed << c[:project]
          else
            skipped << c[:project]
          end
        end
        @state.save

        summary = "Pruned #{removed.size} project(s)."
        summary += " Skipped #{skipped.size}: #{skipped.join(", ")}." if skipped.any?
        @output.puts summary

        if skipped.any?
          raise Workspace::Error,
            "#{skipped.size} project(s) were skipped: #{skipped.join(", ")}.\n" \
            "Commit/push their unsaved work, or rerun with --force."
        end

        removed
      end

      # The structured form of {#call} for `--json`: scans, then removes the
      # selected candidates (all of them when `names` is empty) without asking
      # for confirmation. The unsaved-work check still runs unless `force`.
      #
      # @param dry_run [Boolean] report `would_remove` rows and change nothing
      # @param force [Boolean] remove a candidate even if it has unsaved work
      # @param names [Array<String>] workspaces to prune; empty selects every candidate
      # @return [Array<Hash>] one row per candidate, plus a failed row per name that is no
      #   candidate; keys "name", "branch", "reason", "outcome", "error", "message",
      #   "pr_number", "pr_url"
      def call_structured(dry_run: false, force: false, names: [])
        @state.load
        candidates = detect_candidates
        names = names.uniq { |n| n.downcase }
        wanted = names.map(&:downcase)
        selected = candidates.select { |c| wanted.empty? || wanted.include?(c[:project].downcase) }

        rows = []
        begin
          candidates.each do |c|
            rows << if !selected.include?(c)
              structured_row(c, "not_selected")
            elsif dry_run
              skip = preview_skip(c, force: force)
              skip ? structured_row(c, skip[:outcome], error: skip[:error], message: skip[:message]) : structured_row(c, "would_remove")
            else
              result = try_remove(c, force: force)
              structured_row(c, result[:outcome], error: result[:error], message: result[:message])
            end
          end
        ensure
          @state.save unless dry_run
        end
        known = candidates.map { |c| c[:project].downcase }
        names.reject { |n| known.include?(n.downcase) }.each do |missing|
          rows << {"name" => missing, "branch" => nil, "reason" => nil, "outcome" => "failed", "error" => "not_prunable",
                   "message" => "#{missing} is not a prune candidate.", "pr_number" => nil, "pr_url" => nil}
        end
        rows
      end

      private

      # @param candidates [Array<Hash>]
      # @param names [Array<String>]
      # @return [Array<Hash>] the candidates named, ignoring case
      def select_named(candidates, names)
        wanted = names.map(&:downcase)
        missing = wanted - candidates.map { |c| c[:project].downcase }
        if missing.any?
          raise Workspace::Error.new("Not a prune candidate: #{missing.join(", ")}", code: "not_prunable", details: {names: missing})
        end
        candidates.select { |c| wanted.include?(c[:project].downcase) }
      end

      def structured_row(candidate, outcome, error: nil, message: nil)
        reason = (candidate[:pr_state] == "GONE") ? "directory_gone" : candidate[:pr_state].to_s.downcase
        {"name" => candidate[:project], "branch" => candidate[:branch], "reason" => reason, "outcome" => outcome,
         "error" => error, "message" => message, "pr_number" => candidate[:pr_number], "pr_url" => candidate[:pr_url]}
      end

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

      # The unsaved-work check a removal would run, without removing anything.
      #
      # @param candidate [Hash] a candidate hash from detect_candidates
      # @param force [Boolean] when true the check is skipped, as in removal
      # @return [Hash, nil] the skip result {:outcome, :error, :message}, or nil when a removal would proceed
      def preview_skip(candidate, force:)
        return nil if force || !@git.worktree_exists?(candidate[:worktree_path])
        unsaved = @git.unsaved_work(candidate[:worktree_path])
        return nil unless unsaved
        {outcome: "skipped_unsaved", error: (unsaved == :unknown) ? "unsaved_unknown" : "unsaved_work",
         message: skip_message(candidate, unsaved)}
      end

      # Removes a single candidate project and prints a line when it is skipped.
      #
      # @param candidate [Hash] a candidate hash from detect_candidates
      # @param force [Boolean] remove even if the worktree has unsaved work
      # @return [Boolean] true if the candidate was removed, false if it was skipped
      def remove_candidate(candidate, force:)
        result = try_remove(candidate, force: force)
        @output.puts "  #{result[:message]}" if result[:message]
        result[:outcome] == "removed"
      end

      # Removes a candidate project: its worktree, tmuxinator config,
      # project settings and state entry, then stops its session last (see
      # Commands::Kill#call for why). Git#remove_worktree checks for unsaved
      # work right before removing, unless force is set; a candidate with
      # unsaved work, or whose removal git refuses, is skipped and reported,
      # and nothing else of it is touched.
      #
      # @param candidate [Hash] a candidate hash from detect_candidates
      # @param force [Boolean] remove even if the worktree has unsaved work
      # @return [Hash] :outcome ("removed", "skipped_unsaved" or "failed"); for a
      #   skip also :error (a code) and :message
      def try_remove(candidate, force:)
        path = candidate[:worktree_path]
        project = candidate[:project]

        if @git.worktree_exists?(path)
          begin
            @git.remove_worktree(path, force: force)
          rescue Workspace::UnsavedWorkError => e
            return {outcome: "skipped_unsaved", error: (e.unsaved == :unknown) ? "unsaved_unknown" : "unsaved_work",
                    message: skip_message(candidate, e.unsaved)}
          rescue Workspace::Error => e
            return {outcome: "failed", error: "prune_remove_failed", message: "Skipped #{project}: #{e.message}"}
          end
        end

        @project_config.remove(project)
        @project_settings.remove(project)
        # EventLog#record never raises.
        @event_log&.record(type: "worktree_finished", project: project, data: {"workspace" => project, "outcome" => "pruned"})
        @stop_command.call([project]) if @state[project]
        # Stop already removed a live entry; deleting again would log a second state_removed.
        @state.delete(project) if @state[project]
        {outcome: "removed"}
      end

      # @param candidate [Hash] the skipped candidate hash
      # @param unsaved [Hash, Symbol] the :unsaved_work result (a Hash, or :unknown)
      # @return [String] a one-line notice that a candidate was skipped due to unsaved work
      def skip_message(candidate, unsaved)
        if unsaved == :unknown
          "Skipped #{candidate[:project]}: git couldn't check #{candidate[:worktree_path]} for unsaved work."
        else
          branch = unsaved[:branch] || "HEAD"
          "Skipped #{candidate[:project]}: #{unsaved[:changed_files]} changed file(s) and " \
            "#{unsaved[:unpushed_commits]} unpushed commit(s) on #{branch}. Commit/push, or rerun with --force."
        end
      end
    end
  end
end
