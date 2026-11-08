require "shellwords"

module Workspace
  # The read-only half of `workspace rename WORKSPACE NEW`: resolves the workspace, works out what
  # `NEW` (the new branch name) makes of its directory, workspace name and tmux session, chooses what
  # happens to its notes, and refuses every case the rename cannot go through. It writes nothing, so
  # `--dry-run` can print the answer and the command can act on it.
  #
  # The names follow `start`: the directory is the sanitized branch beside the old one (an adopted
  # worktree stays in its own parent directory), the workspace name and the session come from
  # {ProjectConfig#settle_worktree_name} and {ProjectConfig#worktree_session_name}.
  #
  # The workspace must be stopped: a live tmux session or agent daemon is `workspace_running`.
  #
  # A re-run that finishes a half-done rename passes `resume: true` to {#call}. The names and the notes
  # decision come from the journal, since the rename's own steps change what they are worked out from.
  # It reads the checkout from wherever it is now, the old path or the new one, and skips only what those
  # steps would trip: `rename_no_change`, the journal that says a rename is in progress (when it is for
  # the same NEW), the target directory once the old path is gone, the branch checks once the branch is
  # already NEW, and a config, state key, state directory or left file under the new name once the old one is gone.
  # Both present is a real conflict. While the old path still exists the rest of `rename_target_taken` runs.
  class RenamePlan
    # What happens to the notes directory.
    #
    # @!attribute action [String] `move` (a directory of its own goes from +from+ to +to+),
    #   `with_checkout` (it is inside the checkout and goes with it) or `stays`
    # @!attribute from [String, nil] the notes directory now
    # @!attribute to [String, nil] where it is after (`stays`: where it stays)
    # @!attribute reason [String, nil] why it `stays`: `custom` (not where the rule puts it), `same`
    #   (the rule gives the same directory under the new names), `nested` (the new place is inside the
    #   old one or the other way round) or `unresolved`; nil for the other actions
    # @!attribute problem [String, nil] with `unresolved`, what the resolver said (not in {#to_h}; it
    #   becomes the `notes_unresolved` warning)
    NotesMove = Struct.new(:action, :from, :to, :reason, :problem, keyword_init: true) do
      # @return [Hash]
      def to_h
        {"action" => action, "from" => from, "to" => to, "reason" => reason}
      end
    end

    # The answer: old and new values side by side, the notes move and the warnings.
    #
    # @!attribute project [String] the main project's name
    # @!attribute workspace [String] the workspace now
    # @!attribute new_workspace [String] its name after
    # @!attribute branch [String] the branch now
    # @!attribute new_branch [String] the branch after
    # @!attribute path [String] the checkout now
    # @!attribute new_path [String] the checkout after (the same when only the branch changes)
    # @!attribute session [String] the tmux session now
    # @!attribute new_session [String] the tmux session after
    # @!attribute notes [NotesMove]
    # @!attribute warnings [Array<Hash>] `{"code", "message"}`
    # @!attribute resume [Boolean] whether the plan was made for a re-run
    Plan = Struct.new(:project, :workspace, :new_workspace, :branch, :new_branch, :path, :new_path,
      :session, :new_session, :notes, :warnings, :resume, keyword_init: true) do
      # @return [Boolean] whether the worktree directory moves
      def path_changes?
        path != new_path
      end

      # @return [Boolean] whether the workspace name changes
      def workspace_changes?
        workspace != new_workspace
      end

      # @return [Hash] the document `--dry-run --json` prints
      def to_h
        {"project" => project,
         "workspace" => {"from" => workspace, "to" => new_workspace},
         "branch" => {"from" => branch, "to" => new_branch},
         "path" => {"from" => path, "to" => new_path},
         "session" => {"from" => session, "to" => new_session},
         "notes" => notes.to_h,
         "warnings" => warnings,
         "resume" => resume}
      end
    end

    # A branch `gh pr checkout` made.
    PULL_REQUEST_BRANCH = /\Apr-\d+\z/

    # What the plan can name a delete for: the other files hold what a person wrote or was told.
    DISPOSABLE = %w[agent_log socket hook_events].freeze

    # The longest file name most file systems take, in bytes.
    NAME_MAX_BYTES = 255

    # Claude Code's conversations are kept under `~/.claude/projects/<path with each non-alphanumeric
    # character as a dash>`; a long path ends in a hash, so only the front of the name can be matched.
    ENCODED_PATH_LIMIT = 200

    # Whether Claude Code keeps conversations for a checkout path.
    #
    # @param path [String] the checkout
    # @param home [String]
    # @return [Boolean]
    def self.transcripts?(path, home: Dir.home)
      encoded = path.gsub(/[^A-Za-z0-9]/, "-")
      pattern = (encoded.length > ENCODED_PATH_LIMIT) ? "#{encoded[0, ENCODED_PATH_LIMIT]}*" : encoded
      Dir.glob(File.join(home, ".claude", "projects", pattern)).any?
    end

    # @param git [Workspace::Git]
    # @param project_config [Workspace::ProjectConfig] a workspace's checkout, the config names and the session name rule
    # @param config [Workspace::Config] the daemon's socket and the state directory of a name
    # @param tmux [Workspace::Tmux] says whether a session runs
    # @param state [Workspace::State] the state file whose keys are checked; the caller has loaded it
    # @param notes [Workspace::Commands::Notes] the notes directory now, and the rule's inputs
    # @param notes_dir [Workspace::NotesDir] the rule that places notes
    # @param workflow_engine [Workspace::WorkflowEngine] says whether a run is going on the checkout
    # @param dev_lock [#call] `(checkout_path)` to whether the checkout holds the `devenv` lock
    # @param journal [#call] `(workspace)` to the journal of a half-done rename of that workspace, a Hash
    #   with `"new_branch"` and the first run's `"path"`, `"new_workspace"`, `"session"`, `"new_session"` and
    #   `"notes"`, or nil
    # @param transcripts [#call] `(checkout_path)` to whether Claude Code keeps conversations for it
    # @param device [#call] `(path)` to the device number of the volume the path itself is on
    def initialize(git:, project_config:, config:, tmux:, state:, notes:, notes_dir:, workflow_engine:,
      dev_lock: ->(_path) { false }, journal: ->(_workspace) {}, transcripts: ->(path) { self.class.transcripts?(path) },
      device: ->(path) { File.lstat(path).dev })
      @git = git
      @project_config = project_config
      @config = config
      @tmux = tmux
      @state = state
      @notes = notes
      @notes_dir = notes_dir
      @workflow_engine = workflow_engine
      @dev_lock = dev_lock
      @journal = journal
      @transcripts = transcripts
      @device = device
    end

    # @param workspace [String] the workspace's full name, already settled by the caller
    # @param new [String] the new branch name
    # @param resume [Boolean] a re-run of a half-done rename (see the class comment)
    # @param old_branch [String, nil] with +resume+, the branch the rename started from (the journal knows it);
    #   the checkout's branch when nil
    # @return [Plan]
    # @raise [Workspace::Error] `unknown_workspace`, `checkout_missing`, `detached_head`, `rebase_in_progress`
    #   and the codes in {Workspace::ErrorCodes} that start with `rename_`, plus `workspace_running`,
    #   `run_active` and `dev_lock_held`; `workspace_name_case_conflict` from the name rule
    def call(workspace:, new:, resume: false, old_branch: nil)
      journal = check_journal(workspace, new, resume)
      recorded = resume ? journal.to_h : {}
      root = recorded["path"] || @project_config.project_root_for(workspace)
      raise refusal("unknown_workspace", "Unknown workspace '#{workspace}'. Run 'workspace list --all' to see the names.", "name" => workspace) unless root

      path = File.expand_path(root)
      dir = @git.sanitize_for_filesystem(new)
      new_path = File.join(File.dirname(path), dir)
      checkout = existing_checkout(path, new_path, workspace, resume)
      project = settle_kind(workspace, checkout)
      branch = current_branch(checkout, workspace)
      old_branch = (resume && old_branch) || branch
      check_names(old_branch, new, dir, path, resume)
      session = recorded["session"] || @tmux.session_name_for(workspace)
      check_state(workspace, session, checkout)

      new_workspace = recorded["new_workspace"] || @project_config.settle_worktree_name(project, dir, new_path)
      check_length(new, new_workspace)
      new_session = recorded["new_session"] || @project_config.worktree_session_name(project, dir)
      check_new_stopped(new_workspace, new_session) if resume
      check_taken(workspace, new_workspace, new, new_session, session, path, new_path, checkout, branch, old_branch, resume)
      notes = recorded["notes"] ? journaled_notes(recorded["notes"]) : notes_move(workspace, new_workspace, old_branch, new, path, new_path, checkout)
      check_notes_volume(workspace, new, notes)

      Plan.new(project: project, workspace: workspace, new_workspace: new_workspace, branch: old_branch, new_branch: new,
        path: path, new_path: new_path, session: session, new_session: new_session, notes: notes,
        warnings: warnings(checkout, branch, new, notes, path, workspace), resume: resume)
    end

    private

    # The checkout to read: where the workspace's config puts it; on a re-run, the new place when the
    # git move has already happened.
    def existing_checkout(path, new_path, workspace, resume)
      return path if Dir.exist?(path)
      return new_path if resume && Dir.exist?(new_path)
      raise refusal("checkout_missing", "The checkout of '#{workspace}' (#{path}) no longer exists.", "path" => path, "workspace" => workspace)
    end

    # @return [String] the project name
    def settle_kind(workspace, checkout)
      parts = WorkspaceName.split(workspace)
      linked = @git.linked_worktree?(checkout)
      unless linked || parts
        raise refusal("rename_main_checkout", "'#{workspace}' is a main checkout. Only a linked worktree's workspace can be renamed.", "workspace" => workspace, "path" => checkout)
      end
      unless linked && parts
        raise refusal("rename_not_worktree", "'#{workspace}' is not a workspace made for a worktree (its name has no '.worktree-' part), so its names can't be derived from a branch.", "workspace" => workspace, "path" => checkout)
      end
      parts.first
    end

    def current_branch(checkout, workspace)
      branch = @git.worktree_branch(checkout)
      return branch if branch
      raise refusal("detached_head", "The checkout at #{checkout} is on a detached HEAD. Check out a branch first.", "path" => checkout, "workspace" => workspace)
    end

    def check_names(old_branch, new, dir, path, resume)
      if old_branch.match?(PULL_REQUEST_BRANCH) || new.match?(PULL_REQUEST_BRANCH)
        raise refusal("rename_pull_request_branch", "A pull request branch (pr-N) can't be renamed or take the name of one: other commands read the number from it.", "branch" => old_branch, "new" => new)
      end
      unless !dir.empty? && !new.strip.empty? && @git.valid_branch_name?(path_for_git(path), new)
        raise refusal("rename_invalid_name", "'#{new}' is not a branch name git accepts, or leaves no directory name.", "new" => new)
      end
      if !resume && new == old_branch
        raise refusal("rename_no_change", "The branch is already '#{old_branch}'.", "branch" => old_branch)
      end
      if dir != File.basename(path) && dir.casecmp?(File.basename(path))
        raise refusal("rename_case_only", "'#{new}' changes the worktree directory '#{File.basename(path)}' only in case, which this file system may not move. Pick a name that differs in more than case.", "from" => File.basename(path), "to" => dir)
      end
    end

    # A directory git can run in: the old path while it exists, else the new one.
    def path_for_git(path)
      Dir.exist?(path) ? path : File.dirname(path)
    end

    # A journal for NEW is a rename to finish (a re-run with resume); one for another name, or any
    # journal without resume, is refused. This runs before every check that the rename's own steps could
    # trip, so a crashed rename is always reported as in progress.
    #
    # @return [Hash, nil] the journal to go on with
    def check_journal(workspace, new, resume)
      journal = @journal.call(workspace)
      return unless journal
      name = journal["workspace"] || workspace
      check_journal_checkout(journal, name)
      return journal if resume && journal["new_branch"] == new
      rerun = "workspace rename #{Shellwords.escape(name)} #{Shellwords.escape(journal["new_branch"].to_s)}"
      raise refusal("rename_in_progress", "A rename of '#{name}' to '#{journal["new_branch"]}' was started and not finished. Run `#{rerun}` to finish it.",
        "workspace" => name, "new_branch" => journal["new_branch"], "rerun" => true, "fix" => rerun)
    end

    # With neither checkout there no re-run can finish, and only deleting the journal lets go of the name.
    def check_journal_checkout(journal, workspace)
      paths = [journal["path"], journal["new_path"]].compact
      return if paths.empty? || paths.any? { |path| Dir.exist?(path) }
      file = @config.rename_journal_path(workspace)
      raise refusal("rename_in_progress", "A rename of '#{workspace}' was started, but its checkout is gone (#{paths.uniq.join(", ")}), so it can't finish. Delete #{file} to clear it.",
        "workspace" => workspace, "new_branch" => journal["new_branch"], "path" => file, "rerun" => false, "fix" => "rm #{Shellwords.escape(file)}")
    end

    def check_state(workspace, session, checkout)
      if @git.rebase_in_progress?(checkout)
        raise refusal("rebase_in_progress", "A rebase is stopped in #{checkout}. Finish or abort it first.", "path" => checkout, "workspace" => workspace)
      end
      if @git.worktree_locked?(checkout, checkout)
        unlock = "git worktree unlock #{Shellwords.escape(checkout)}"
        raise refusal("rename_locked_worktree", "The worktree at #{checkout} is locked (git worktree lock), and git won't move it. Run `#{unlock}` first.", "path" => checkout, "fix" => unlock)
      end
      stop = "workspace stop #{Shellwords.escape(workspace)}"
      if @tmux.session_exists?(session)
        raise refusal("workspace_running", "The tmux session of '#{workspace}' is running. Run `#{stop}` first.", "workspace" => workspace, "session" => session, "reason" => "session", "fix" => stop)
      end
      if @config.agent_running?(workspace)
        raise refusal("workspace_running", "The agent daemon of '#{workspace}' is running. Run `#{stop}` first.", "workspace" => workspace, "session" => session, "reason" => "agent", "fix" => stop)
      end
      run = @workflow_engine.run_on_checkout(checkout)
      if run
        raise refusal("run_active", "Workflow run #{run["id"]} is still going on this checkout; its files hold the path. Let it finish or cancel it first.", "run_id" => run["id"], "path" => checkout)
      end
      if @dev_lock.call(checkout)
        down = "workspace dev down #{Shellwords.escape(workspace)}"
        raise refusal("dev_lock_held", "This checkout holds the devenv lock. Run `#{down}` first.", "path" => checkout, "workspace" => workspace, "fix" => down)
      end
    end

    # Past the config step the workspace answers to the new name, and can be launched under it.
    def check_new_stopped(new_workspace, new_session)
      return unless @config.agent_running?(new_workspace)
      stop = "workspace stop #{Shellwords.escape(new_workspace)}"
      raise refusal("workspace_running", "The agent daemon of '#{new_workspace}' is running. Run `#{stop}` first.", "workspace" => new_workspace, "session" => new_session, "reason" => "agent", "fix" => stop)
    end

    # The tmuxinator config is `workspace.<name>.yml`, unhashed, and is the last file the rename writes,
    # by way of a longer temporary name.
    def check_length(new, new_workspace)
      file = WorkspaceStoreRename.staged_name(File.basename(@config.config_path_for(new_workspace)))
      return if file.bytesize <= NAME_MAX_BYTES
      raise refusal("rename_invalid_name", "'#{new}' makes a temporary workspace config file name of #{file.bytesize} bytes; the limit is #{NAME_MAX_BYTES}. Pick a shorter name.",
        "new" => new, "reason" => "too_long", "bytes" => file.bytesize, "limit" => NAME_MAX_BYTES)
    end

    # While the old path exists nothing of the rename has run that these checks could trip, so all of
    # them run. On a re-run past the git move the directory is the rename's own, and a branch already
    # named NEW is the rename's own too. So is a store under the new name once the old one is gone.
    # Files left under the new name are found here, before git moves anything: see {#leftovers}.
    def check_taken(workspace, new_workspace, new, new_session, session, path, new_path, checkout, branch, old_branch, resume)
      moved = resume && !Dir.exist?(path)
      taken = []
      details = {}
      unless resume && branch == new
        names = @git.local_branch_names(checkout)
        taken << "branch" if names.any? { |name| name.casecmp?(new) }
        conflicts = names.select { |name| name != branch && name != old_branch && ref_conflict?(name, new) }
        if conflicts.any?
          taken << "branch_conflict"
          details["conflicting_branch"] = conflicts.first
        end
      end
      taken << "directory" if !moved && new_path != path && (File.exist?(new_path) || File.symlink?(new_path))
      if new_workspace != workspace
        keys = @state.keys
        taken << "config" if @project_config.existing_name(new_workspace) && (!resume || @project_config.existing_name(workspace))
        taken << "state_key" if keys.any? { |key| key.casecmp?(new_workspace) } && (!resume || keys.include?(workspace))
        taken << "state_dir" if File.exist?(@config.pipeline_state_dir(new_workspace)) && (!resume || File.exist?(@config.pipeline_state_dir(workspace)))
        files = leftovers(workspace, new_workspace, resume)
        taken.concat(files.keys)
      end
      taken << "session" if new_session != session && @tmux.session_exists?(new_session)
      return if taken.empty?
      if files&.any?
        details["paths"] = files
        details["fix"] = "rm #{files.values.map { |file| Shellwords.escape(file) }.join(" ")}" if (taken - DISPOSABLE).empty?
      end
      raise refusal("rename_target_taken", "Can't rename '#{workspace}' to '#{new}': already taken (#{taken.join(", ")}).",
        {"taken" => taken, "new_workspace" => new_workspace, "new_branch" => new, "new_path" => new_path}.merge(details))
    end

    # What `kill` and a dead daemon leave under a name, and the store step would stop on. An event log
    # counts on a first run only: on a re-run the new one is a launch's, and the step joins the two.
    #
    # @return [Hash{String=>String}] what is taken to its path
    def leftovers(workspace, new_workspace, resume)
      stores = {"project_settings" => ->(name) { @config.project_config_path(name) }, "socket" => ->(name) { @config.agent_socket_path(name) },
                "agent_log" => ->(name) { @config.agent_log_path(name) }, "inbox" => ->(name) { @config.inbox_path("workspace", name) }}
      found = stores.select { |_, path| listed?(path.call(new_workspace)) && (!resume || listed?(path.call(workspace))) }.transform_values { |path| path.call(new_workspace) }
      events = HookEventLog.path_for(@config.hook_events_dir, new_workspace)
      found["hook_events"] = events if !resume && listed?(events)
      found
    end

    def listed?(path)
      WorkspaceStoreRename.listed?(path)
    end

    # Git keeps refs as files, so `a` and `a/b` can't both be branches.
    def ref_conflict?(existing, new)
      a = WorkspaceName.normalize(existing)
      b = WorkspaceName.normalize(new)
      b.start_with?("#{a}/") || a.start_with?("#{b}/")
    end

    # Notes move only when they sit where the rule put them for the old names. A directory inside the
    # checkout goes with it. A target that isn't free (see {NotesCarry.clash?}) is `rename_target_taken`
    # (`notes_target`). A re-run never comes here: it goes by what the journal recorded, {#journaled_notes}.
    def notes_move(workspace, new_workspace, old_branch, new, path, new_path, checkout)
      current = @notes.info(name: workspace, root: checkout)["dir"]
      return stays(current, "unresolved") unless current
      rule = @notes.location_rule(name: workspace)
      # Judged by the spelling first: a link inside the checkout moves with it, wherever it points.
      root = File.expand_path(checkout)
      if current.start_with?("#{root}/")
        return NotesMove.new(action: "with_checkout", from: current, to: File.join(new_path, current.delete_prefix("#{root}/")))
      end
      real_root = real(checkout)
      if real(current).start_with?("#{real_root}/")
        return NotesMove.new(action: "with_checkout", from: current, to: File.join(new_path, real(current).delete_prefix("#{real_root}/")))
      end

      old_default = @notes_dir.path_for(template: rule[:template], worktree: true, root: path, workspace: workspace, branch: old_branch, main_dir: rule[:main_dir])
      target = @notes_dir.path_for(template: rule[:template], worktree: true, root: new_path, workspace: new_workspace, branch: new, main_dir: rule[:main_dir])
      return stays(current, "custom") unless old_default && real(old_default) == real(current)

      return stays(current, "unresolved") unless target
      return stays(current, "same") if real(target) == real(current)
      return stays(current, "nested") if nested?(current, target)

      if NotesCarry.clash?(target, directory: true)
        raise refusal("rename_target_taken", "Can't rename '#{workspace}' to '#{new}': the notes directory #{target} already exists.",
          "taken" => ["notes_target"], "new_workspace" => new_workspace, "new_branch" => new, "new_path" => new_path, "notes_path" => target)
      end
      NotesMove.new(action: "move", from: current, to: target)
    rescue Workspace::Error => e
      raise if e.code == "rename_target_taken"
      stays(nil, "unresolved", "#{e.code}: #{e.message}")
    end

    # A rename can't cross volumes, and by the notes step git has already moved. A re-run whose notes
    # have gone has nothing to check.
    def check_notes_volume(workspace, new, notes)
      return unless notes.action == "move"
      from = @device.call(notes.from)
      target = notes.to
      target = File.dirname(target) until File.exist?(target)
      return if from == @device.call(real(target))
      raise refusal("rename_notes_other_volume", "Can't rename '#{workspace}' to '#{new}': the notes at #{notes.from} would move to #{notes.to}, on another volume. Change notes.default_dir so they stay, or move them to that volume first.",
        "workspace" => workspace, "new" => new, "from" => notes.from, "to" => notes.to)
    rescue SystemCallError
      nil
    end

    def journaled_notes(notes)
      NotesMove.new(action: notes["action"], from: notes["from"], to: notes["to"], reason: notes["reason"], problem: notes["problem"])
    end

    def stays(current, reason, problem = nil)
      NotesMove.new(action: "stays", from: current, to: current, reason: reason, problem: problem)
    end

    def nested?(from, to)
      a = real(from).downcase + "/"
      b = real(to).downcase + "/"
      a.start_with?(b) || b.start_with?(a)
    end

    def real(path)
      File.realpath(path)
    rescue SystemCallError
      parent = File.dirname(path)
      (parent == path) ? path : File.join(real(parent), File.basename(path))
    end

    def warnings(checkout, branch, new, notes, path, workspace)
      found = []
      tracking = @git.branch_tracking(checkout, branch)
      upstream = tracking["merge"]&.delete_prefix("refs/heads/")
      if upstream && upstream != new
        found << {"code" => "upstream_other_name", "message" => "The branch keeps tracking #{tracking["remote"]}/#{upstream}; the remote branch is not renamed, so `workspace push` will refuse (push_rejected, details.reason upstream_mismatch) until you rename or unset it.", "upstream" => "#{tracking["remote"]}/#{upstream}"}
        found << {"code" => "prune_pull_request", "message" => "`workspace prune` looks a pull request up by the local branch name, so it won't find one opened from #{upstream}.", "branch" => new}
      end
      if @transcripts.call(path)
        found << {"code" => "transcript_not_continued", "message" => "Claude Code keeps this checkout's conversations under its old path: `workspace launch` on the renamed workspace starts a new one, and `workspace restore` resumes the last.", "path" => path}
      end
      if notes.reason == "unresolved"
        detail = notes.problem ? " (#{notes.problem})" : ""
        found << {"code" => "notes_unresolved", "message" => "The notes directory of #{workspace} could not be worked out#{detail}; the rename leaves the notes where they are.", "problem" => notes.problem}
      end
      found << {"code" => "notes_nested", "message" => "The notes stay at #{notes.from}: the new location is inside it or the other way round.", "path" => notes.from} if notes.reason == "nested"
      found
    end

    def refusal(code, message, details = {})
      Workspace::Error.new(message, code: code, details: details)
    end
  end
end
