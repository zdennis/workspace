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
      # @param event_log [Workspace::EventLog, nil] records `worktree_finished` once the
      #   worktree is removed; nil records nothing
      # @param workflow_runs [#workspace_killed, nil] ends the project's workflow runs once its
      #   worktree is removed, so none goes on holding a lock; nil leaves runs alone
      # @param window_positions [Workspace::WindowPositions, nil] deletes the project's saved window position
      #   once its worktree is removed; nil leaves it alone
      # @param notes [Workspace::Commands::Notes, nil] says whether the project's notes directory sits inside its
      #   worktree with files in it, so removing the worktree can warn first; nil never warns
      # @param dev [Workspace::Commands::Dev, nil] stops the worktree's dev environment before the worktree
      #   is removed, when the worktree holds the `devenv` lock; nil leaves it alone
      # @param pr_status [#call, nil] reads a checkout's pull request (`PullRequestStatus`); `delete_remote` asks it
      #   before anything is removed. nil reads as no answer, which refuses without force.
      # @param tmux [Workspace::Tmux, nil] reads the project's tmux session name from its config before the config
      #   is removed, so stop can still kill a session whose name differs from the config name; nil uses the config name
      # @param input [IO] input stream for interactive prompts
      def initialize(git:, project_config:, project_settings:, stop_command:, project_detector:, pr_status: nil, window_positions: nil, task_store: nil, event_log: nil, workflow_runs: nil, notes: nil, dev: nil, tmux: nil, output: $stdout, input: $stdin)
        @tmux = tmux
        @dev = dev
        @pr_status = pr_status
        @dev_stopped = false
        @git = git
        @project_config = project_config
        @project_settings = project_settings
        @stop_command = stop_command
        @project_detector = project_detector
        @window_positions = window_positions
        @task_store = task_store
        @event_log = event_log
        @workflow_runs = workflow_runs
        @notes = notes
        @notes_inside_worktree = nil
        @branch_result = nil
        @remote_branch_result = nil
        @output = output
        @input = input
      end

      MARKER_FILE = ".workspace-project"

      # What the last {#call} found: the notes directory of the project, when it was
      # inside the worktree and held files, so removing the worktree deleted them.
      # Reset at the start of every call.
      #
      # @return [Hash, nil] `{"dir" => absolute path, "files" => count}`, or nil
      attr_reader :notes_inside_worktree

      # Whether the last {#call} stopped the worktree's dev environment first. Reset at the start of every call.
      #
      # @return [Boolean]
      attr_reader :dev_stopped

      # What the last {#call} did with the workspace's branch when asked to delete it. Reset at the start
      # of every call.
      #
      # @return [Hash, nil] `{"name" => branch, "deleted" => Boolean, "kept_reason" => String or nil}` where
      #   `kept_reason` is `existed_before_start`, `not_merged`, `detached_head`, `checkout_missing` or
      #   `error`; nil when no deletion was asked for
      attr_reader :branch_result

      # What the last {#call} did with the branch's remote copy when asked to delete it. Reset at the start
      # of every call.
      #
      # @return [Hash, nil] `{"name" => branch name on the remote, "remote" => remote name, "deleted" => Boolean,
      #   "kept_reason" => String or nil}` where `kept_reason` is `no_remote`, `no_upstream`, `upstream_mismatch`,
      #   `default_branch`, `existed_before_start`, `not_merged`, `not_found`, `detached_head`, `checkout_missing`, `timeout` or
      #   `error`; nil when no remote deletion was asked for
      attr_reader :remote_branch_result

      # @param held [Hash] a {#notes_inside_worktree} answer
      # @return [String] the sentence for `warnings` and the text warning
      def self.notes_sentence(held)
        count = held["files"]
        "The notes directory #{held["dir"]} holds #{count} #{(count == 1) ? "file" : "files"} and is inside the worktree; removing the worktree deletes them."
      end

      # Kills a worktree project. The order is chosen so nothing is lost and
      # nothing is left half-removed:
      #
      # 1. check for unsaved work (unless force), before prompting
      # 2. confirm (unless force or confirm: false)
      # 3. stop the worktree's dev environment when it holds the `devenv` lock, so no server is left
      #    running in a directory that is about to go
      # 4. remove the worktree; Git#remove_worktree re-checks for unsaved work
      #    right before removing (unless force), so an edit made while the
      #    prompt waited is refused rather than deleted
      # 5. end the project's workflow runs, archive its task, then yield to the caller's block (the
      #    post_kill hook), then remove the config and settings
      # 6. stop the session last: this may run inside the very session it
      #    kills, which ends this process before any later statement runs
      #
      # @param project [String, nil] project/config name, or nil for the workspace +working_dir+ is in (its
      #   worktree marker, else the active workspace whose root holds it)
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
      # @param delete_branch [Boolean] after the worktree is removed, delete its branch when `start` made it
      #   (never one that existed before); a branch git refuses to delete is kept with a warning, and never
      #   fails the kill. Force makes it `-D`. A checkout already gone (+missing_ok+), a detached HEAD or
      #   an unreadable repository keeps the branch and says why in {#branch_result}.
      # @param delete_remote [Boolean] with +delete_branch+, also delete the branch's upstream branch on its remote
      #   after the local step, only when the upstream has the same name, is not the default branch, and (unless
      #   force) `start` made the branch. Without force, an open pull request for the branch refuses
      #   (`open_pull_request`), and so does a pull request state that cannot be read or a checkout already gone
      #   (`pull_request_status_unknown`), before anything is removed; it is asked only when a delete would
      #   run. A remote that cannot delete it is a warning, never a failed kill.
      # @yieldparam project [String] the project, after its worktree is removed and
      #   before its config, settings and session go
      # @return [String, nil] the project name, or nil if the user cancelled
      # @raise [Workspace::UnsavedWorkError] if it has unsaved work and force is false
      # @raise [Workspace::Error] `not_in_workspace` when no project is given and none holds +working_dir+,
      #   or when the project config is not a worktree project
      def call(project = nil, force: false, confirm: true, quiet: false, working_dir: Dir.pwd, missing_ok: false, warn_inactive: true, outcome: nil, delete_branch: false, delete_remote: false)
        out = quiet ? StringIO.new : @output
        @notes_inside_worktree = nil
        @dev_stopped = false
        @branch_result = nil
        @remote_branch_result = nil
        project ||= @project_detector.detect(working_dir)
        unless project
          raise Workspace::Error.new("No workspace found for #{working_dir}. Run from inside a worktree workspace or name one (--name WS).",
            code: "not_in_workspace", details: {"path" => working_dir})
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

        delete_remote &&= delete_branch
        branch_plan = plan_branch_deletion(worktree_path) if delete_branch && !missing
        remote_plan = plan_remote_deletion(worktree_path, branch_plan, force) if delete_remote && branch_plan
        check_pull_request!(worktree_path) if remote_plan && !remote_plan[:kept_reason] && !force

        out.puts "Stopping #{project}..."
        out.puts "  Worktree: #{worktree_path}"
        warn_about_notes(project, missing, out)

        if confirm && !force
          answer = Prompt.ask(@input, out, confirmation_question(branch_plan, remote_plan), retry_flags: ["--force"], destructive: true)&.strip
          unless answer&.match?(/\Ay(es)?\z/i)
            out.puts "Cancelled."
            return
          end
        end

        if missing
          out.puts "Checkout already gone; skipping worktree removal."
        else
          stop_dev(worktree_path, out)
          out.puts "Removing worktree..."
          begin
            @git.remove_worktree(worktree_path, force: force)
          rescue Workspace::UnsavedWorkError => e
            raise_unsaved_work!(project, worktree_path, e.unsaved)
          end
        end

        finish_branch(branch_plan, force, out) if branch_plan
        finish_remote_branch(remote_plan, out) if remote_plan
        keep_missing_branch(project, out) if delete_branch && missing
        keep_remote_branch({}, "checkout_missing", "Kept remote branch: the checkout was already gone, so its upstream could not be read", out) if delete_remote && missing

        outcome ||= force ? "discarded" : "abandoned"
        # The session name lives in the config's `name:`, so read it before the config is removed.
        session_name = @tmux&.session_name_for(project)
        socket = @tmux&.socket_arguments(project)
        end_workflow_runs(project, out)
        archive_task(project, outcome, out)
        yield project if block_given?
        @project_config.remove(project, quiet: quiet)
        @project_settings.remove(project)
        @window_positions&.delete(project)
        # EventLog#record never raises.
        @event_log&.record(type: "worktree_finished", project: project, data: {"workspace" => project, "outcome" => outcome})

        out.puts "Killing session..."
        @stop_command.call([project], quiet: quiet, warn_inactive: warn_inactive, save_position: false, session_names: {project => session_name}.compact, socket_arguments: {project => socket}.compact)
        project
      end

      private

      # Names the branches the kill is set to delete, so the person sees them before saying yes.
      def confirmation_question(branch_plan, remote_plan)
        branches = []
        branches << "branch #{branch_plan[:branch]}" if branch_plan && branch_plan[:created] && !branch_plan[:kept_reason]
        branches << "remote branch #{remote_plan[:remote]}/#{remote_plan[:name]}" if remote_plan && !remote_plan[:kept_reason]
        return "Remove worktree and kill session? [y/N] " if branches.empty?
        "Remove worktree, delete #{branches.join(" and ")}, and kill session? [y/N] "
      end

      # Read before the worktree goes: its branch, the shared git directory to run git in (it works as the
      # repository for any layout, bare included), and whether `start` made the branch.
      def plan_branch_deletion(worktree_path)
        branch = @git.worktree_branch(worktree_path)
        return {kept_reason: "detached_head"} unless branch
        common_dir = @git.common_dir_from_files(worktree_path)
        return {branch: branch, kept_reason: "error"} unless common_dir
        {branch: branch, root: common_dir, created: @git.workspace_created_branch?(common_dir, branch)}
      end

      # Refuses before anything is removed: a branch with an open pull request, or one whose pull request
      # state cannot be read, keeps its remote copy unless the person forces. A checkout already gone is
      # not asked, as there is no upstream to read.
      def check_pull_request!(worktree_path)
        retry_with = {"flags" => ["--force"], "destructive" => true}
        branch = @git.worktree_branch(worktree_path)
        status = @pr_status&.call(worktree_path) || {"available" => false, "reason" => "unavailable"}
        if status["state"] == "OPEN"
          raise Workspace::Error.new("Branch #{branch} has an open pull request (#{status["url"] || "##{status["number"]}"}); not deleting its remote branch.\nClose or merge it, or rerun with --force (this also skips the unsaved-work check).",
            code: "open_pull_request", details: {"branch" => branch, "number" => status["number"], "url" => status["url"]}, retry_with: retry_with)
        elsif status["available"] == false
          details = {"branch" => branch, "reason" => status["reason"]}
          details["detail"] = status["detail"] if status["detail"]
          timeout = status["reason"] == "timeout"
          retry_with = {"flags" => [], "destructive" => false} if timeout
          message = if timeout
            "gh did not answer in time, so kill could not tell whether branch #{branch} has an open pull request; not deleting its remote branch.\nRun the same command again to retry, or rerun with --force (this also skips the unsaved-work check) to delete it anyway."
          else
            "Could not tell whether branch #{branch} has an open pull request (#{status["reason"]}); not deleting its remote branch.\nRerun with --force (this also skips the unsaved-work check) to delete it anyway."
          end
          raise Workspace::Error.new(message,
            code: "pull_request_status_unknown", details: details, retry_with: retry_with)
        end
      end

      # Read before the worktree goes and before the local delete drops the branch's config. Only an
      # upstream of the same name is deleted (a branch made from `--base origin/main` tracks main), never
      # the default branch, and only a branch start made unless the person forces.
      def plan_remote_deletion(worktree_path, branch_plan, force)
        branch = branch_plan[:branch]
        return {kept_reason: "detached_head"} unless branch
        return {name: branch, kept_reason: "error"} unless branch_plan[:root]
        return {name: branch, kept_reason: "no_remote"} if @git.remotes?(worktree_path) == false
        remote, merge = @git.upstream_config(worktree_path, branch)
        return {name: branch, kept_reason: "no_upstream"} if remote.nil? || remote == "." || merge.nil?
        name = merge.sub(%r{\Arefs/heads/}, "")
        return {name: name, remote: remote, kept_reason: "upstream_mismatch", branch: branch} unless name == branch
        return {name: name, remote: remote, kept_reason: "default_branch"} if name == @git.default_branch_name(worktree_path)
        return {name: name, remote: remote, kept_reason: "existed_before_start"} unless branch_plan[:created] || force
        # `git branch -d` checks a branch with an upstream against that upstream, so it can delete a pushed,
        # unmerged branch locally; deleting the remote copy too would lose the commits. The remote copy must
        # also hold nothing the local branch lacks, as commits pushed from elsewhere would go with it.
        return {name: name, remote: remote, kept_reason: "not_merged"} unless force || remote_merged?(worktree_path, branch, remote)
        {name: name, remote: remote, root: branch_plan[:root]}
      end

      def remote_merged?(worktree_path, branch, remote)
        @git.merged_into_base?(worktree_path, branch) == true &&
          @git.ancestor?(worktree_path, "refs/remotes/#{remote}/#{branch}", "refs/heads/#{branch}")
      end

      def keep_remote_branch(plan, reason, line, out)
        @remote_branch_result = {"name" => plan[:name], "remote" => plan[:remote], "deleted" => false, "kept_reason" => reason}
        out.puts line
      end

      # A remote that will not delete is a warning, never a failed kill.
      def finish_remote_branch(plan, out)
        name = plan[:name]
        case plan[:kept_reason]
        when "detached_head"
          return keep_remote_branch(plan, "detached_head", "Kept remote branch: the worktree's HEAD is detached", out)
        when "no_remote"
          return keep_remote_branch(plan, "no_remote", "Warning: kept remote branch #{name}: the repository has no remote", out)
        when "error"
          return keep_remote_branch(plan, "error", "Warning: could not find the repository of branch #{name}, so its remote branch was kept", out)
        when "no_upstream"
          return keep_remote_branch(plan, "no_upstream", "Warning: kept remote branch #{name}: it has no upstream", out)
        when "upstream_mismatch"
          return keep_remote_branch(plan, "upstream_mismatch", "Warning: kept remote branch #{plan[:remote]}/#{name}: it is the upstream of #{plan[:branch]}, not a branch of the same name", out)
        when "default_branch"
          return keep_remote_branch(plan, "default_branch", "Warning: kept remote branch #{plan[:remote]}/#{name}: it is the default branch", out)
        when "existed_before_start"
          return keep_remote_branch(plan, "existed_before_start", "Kept remote branch #{plan[:remote]}/#{name} (the branch existed before start; rerun with --force to delete it)", out)
        when "not_merged"
          return keep_remote_branch(plan, "not_merged", "Warning: kept remote branch #{plan[:remote]}/#{name}: it is not merged into the default branch, or has commits the local branch lacks (rerun with --force to delete it)", out)
        end
        remote = plan[:remote]
        status, message = @git.delete_remote_branch(plan[:root], remote, name)
        case status
        when :deleted
          @remote_branch_result = {"name" => name, "remote" => remote, "deleted" => true, "kept_reason" => nil}
          out.puts "Deleted remote branch #{remote}/#{name}"
        when :not_found
          keep_remote_branch(plan, "not_found", "Remote branch #{remote}/#{name} was already gone (nothing to delete)", out)
        else
          detail = (status == :timeout) ? "the remote did not answer in time" : message.to_s.strip
          keep_remote_branch(plan, (status == :timeout) ? "timeout" : "error", "Warning: could not delete remote branch #{remote}/#{name}: #{detail}", out)
        end
      end

      def keep_branch(name, reason, line, out, warning: false)
        @branch_result = {"name" => name, "deleted" => false, "kept_reason" => reason}
        out.puts "#{"Warning: " if warning}#{line}"
      end

      def keep_missing_branch(project, out)
        name = @task_store&.active_for(project)&.dig("branch")
        line = name ? "Kept branch #{name}: the checkout was already gone" : "Kept branch: the checkout was already gone"
        keep_branch(name, "checkout_missing", line, out)
      end

      # Runs against the shared git directory, as the worktree is gone. A refusal is a warning, never a failed kill.
      def finish_branch(plan, force, out)
        branch = plan[:branch]
        case plan[:kept_reason]
        when "detached_head"
          return keep_branch(nil, "detached_head", "Kept branch: the worktree's HEAD is detached", out)
        when "error"
          return keep_branch(branch, "error", "could not find the repository of branch #{branch}, so it was kept", out, warning: true)
        end
        return keep_branch(branch, "existed_before_start", "Kept branch #{branch} (it existed before start)", out) unless plan[:created]
        deleted, stderr = @git.delete_branch(plan[:root], branch, force: force)
        if deleted
          @branch_result = {"name" => branch, "deleted" => true, "kept_reason" => nil}
          out.puts "Deleted branch #{branch}"
        elsif stderr.to_s.match?(/not fully merged/i)
          @branch_result = {"name" => branch, "deleted" => false, "kept_reason" => "not_merged"}
          out.puts "Warning: kept branch #{branch}: not fully merged. Delete it with: git branch -D #{branch} (or rerun kill with --force)"
        else
          @branch_result = {"name" => branch, "deleted" => false, "kept_reason" => "error"}
          out.puts "Warning: kept branch #{branch}: git could not delete it: #{stderr.to_s.strip}"
        end
      end

      # Stops the dev environment this worktree holds, before its directory goes. One that cannot
      # be stopped is reported and the removal goes on, as the person asked for it.
      def stop_dev(worktree_path, out)
        return unless @dev
        result = @dev.down_when_held(working_dir: worktree_path)
        if result[:stopped]
          @dev_stopped = true
        elsif !result[:exit_code].zero?
          out.puts "Warning: the dev environment could not be stopped; it is still running. See: workspace dev status"
        end
      end

      # Before the worktree goes: afterwards its notes can no longer be counted.
      def warn_about_notes(project, missing, out)
        return if missing || !@notes
        @notes_inside_worktree = @notes.files_inside_worktree(name: project)
        out.puts "Warning: #{self.class.notes_sentence(@notes_inside_worktree)}" if @notes_inside_worktree
      end

      # The worktree is already gone, so a task store that can't be written
      # must not stop the config, settings and session from being cleaned up.
      # WorkflowEngine#workspace_killed never raises.
      def end_workflow_runs(project, out)
        ended = @workflow_runs&.workspace_killed(project)
        return unless ended
        ended["cancelled"].each { |run| out.puts "Cancelled workflow run #{run}." }
        ended["failed"].each do |run|
          out.puts "Warning: workflow run #{run} could not be ended (its run file may be malformed). " \
            "If it holds a lock, free it with `workspace lock clear NAME`."
        end
      end

      def archive_task(project, outcome, out)
        @task_store&.archive(project, outcome: outcome)
      rescue Workspace::Error => e
        out.puts "Warning: could not archive the task for #{project}: #{e.message}"
      end

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
