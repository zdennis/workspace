require "fileutils"
require "shellwords"

module Workspace
  module Commands
    # `workspace rename WORKSPACE NEW`: gives a stopped worktree workspace a new branch, and with it
    # a new directory, workspace name and tmux session. {RenamePlan} decides what happens and what is
    # refused; this class does it.
    #
    # The two git steps come first and are undone in reverse on a failure, which ends in `rename_failed`
    # with nothing changed. Every step after them can only go forward: a failure there keeps the
    # journal and raises `rename_incomplete`, and the same command run again finishes, skipping what
    # is done. Each step is safe to run twice, and judges what is done by the state it finds.
    #
    # INT, TERM and HUP wait for the step under way, then stop the rename the same two ways.
    class Rename
      # A step that did not reach the state it should have.
      class StepFailed < StandardError
        # @return [Array<String>, nil] the steps that failed, when one piece of work holds several
        attr_reader :steps

        # @param message [String]
        # @param steps [Array<String>, nil]
        def initialize(message, steps: nil)
          super(message)
          @steps = steps
        end
      end

      # @param plan [Workspace::RenamePlan] built with +journal+'s {RenameJournal#read} as its `journal:`
      # @param journal [Workspace::RenameJournal]
      # @param git [Workspace::Git]
      # @param config [Workspace::Config]
      # @param project_config [Workspace::ProjectConfig] the banner text; {WorkspaceStoreRename} reads it too
      # @param project_settings [Workspace::ProjectSettings] the workspace's own `notes.dir`
      # @param tmux [Workspace::Tmux]
      # @param state [Workspace::State]
      # @param notes [Workspace::Commands::Notes] lists moved notes in `info/exclude`
      # @param name_migration [Workspace::NameMigration] holds the startup locks
      # @param task_store [Workspace::TaskStore]
      # @param inbox_store_factory [#call] `(path:, scope:, error_output:)` to an {InboxStore}
      # @param session_ledger [Workspace::SessionLedger]
      # @param pane_bindings [Workspace::PaneBindings]
      # @param event_log [Workspace::EventLog]
      # @param project_catalog_factory [#call] builds a fresh {ProjectCatalog}
      # @param error_output [IO]
      # @param writer [Workspace::TmuxinatorConfigWriter, nil] carries the config's render record; nil builds one over +config+
      def initialize(plan:, journal:, git:, config:, project_config:, project_settings:, tmux:, state:, notes:, name_migration:,
        task_store:, inbox_store_factory:, session_ledger:, pane_bindings:, event_log:, project_catalog_factory:, error_output: $stderr,
        writer: nil)
        @plan = plan
        @journal = journal
        @git = git
        @config = config
        @project_config = project_config
        @project_settings = project_settings
        @tmux = tmux
        @state = state
        @notes = notes
        @name_migration = name_migration
        @task_store = task_store
        @inbox_store_factory = inbox_store_factory
        @session_ledger = session_ledger
        @pane_bindings = pane_bindings
        @event_log = event_log
        @project_catalog_factory = project_catalog_factory
        @error_output = error_output
        @writer = writer || TmuxinatorConfigWriter.new(config: config)
      end

      # @param workspace [String] the workspace's full name, settled by the caller; once the config has
      #   moved, the new name finds the rename to finish as well as the old one
      # @param new [String] the new branch name
      # @param dry_run [Boolean] stop after the plan, having written nothing
      # @return [Hash] {RenamePlan::Plan#to_h} plus `dry_run` and `next` (what to run to resume the
      #   conversation; nil with +dry_run+)
      # @raise [Workspace::Error] a refusal from {RenamePlan}, `rename_failed` (undone, nothing changed)
      #   or `rename_incomplete` (run the same command again to finish)
      def call(workspace:, new:, dry_run: false)
        @state.load
        started = @journal.read(workspace)
        workspace = started["workspace"] if started
        plan = plan_for(workspace, new)
        return report(plan, [], dry_run: true) if dry_run

        with_startup_locks(plan) do
          # Read again: a daemon or another rename may have got in before the locks did.
          @state.load
          plan = plan_for(workspace, new)
          signals = DeferredSignals.new
          signals.hold { run(plan, signals) }
        end
      end

      private

      def plan_for(workspace, new)
        journal = @journal.read(workspace)
        resume = !journal.nil? && journal["new_branch"] == new
        @plan.call(workspace: workspace, new: new, resume: resume, old_branch: journal && journal["branch"])
      end

      # Each holder of one of these starts a daemon and lets go, so waiting is short; the plan made under
      # them sees the daemon. On a re-run a journal and the work so far are there to finish.
      def with_startup_locks(plan, &block)
        @name_migration.with_locks(plan.workspace, plan.new_workspace, &block)
      rescue NameMigration::LockUnavailable => e
        reason = "could not take the startup lock: #{e.message}"
        raise incomplete(plan, ["startup_lock"], [reason], {}) if plan.resume
        raise failed(plan, "startup_lock", reason, {})
      end

      def run(plan, signals)
        begin
          @journal.write(plan) unless plan.resume
        rescue SystemCallError => e
          raise failed(plan, "journal", "could not write the journal: #{e.message}", signals.report)
        end
        git_steps(plan, signals) unless git_done?(plan)

        progress = {renamed: [], warnings: []}
        later_steps(plan, progress).each do |name, work|
          if signals.caught
            raise incomplete(plan, [name], ["stopped by SIG#{signals.caught} before #{name}"], signals.report)
          end
          attempt(plan, name, work, signals)
        end
        finish(plan, progress, signals)
        report(plan, progress[:warnings], dry_run: false)
      end

      def git_done?(plan)
        Dir.exist?(plan.new_path) && (!plan.path_changes? || !Dir.exist?(plan.path)) && @git.worktree_branch(plan.new_path) == plan.new_branch
      end

      # Nothing after these has run, so undoing them leaves the workspace as it was, on a re-run too.
      def git_steps(plan, signals)
        step = nil
        [["worktree_move", -> { move_worktree(plan) }], ["branch_rename", -> { rename_branch(plan) }]].each do |name, work|
          step = name
          halt_if_signalled(signals)
          work.call
        end
        halt_if_signalled(signals)
      rescue StepFailed, Workspace::Error => e
        undo_git(plan, signals)
        begin
          @journal.delete(plan.workspace)
        rescue SystemCallError => undo_error
          raise incomplete(plan, ["journal"], ["the git steps were undone, but #{undo_error.message}"], signals.report)
        end
        raise failed(plan, step, e.message, signals.report)
      end

      def halt_if_signalled(signals)
        raise StepFailed, "interrupted by SIG#{signals.caught}" if signals.caught
      end

      def move_worktree(plan)
        return unless plan.path_changes? && Dir.exist?(plan.path)
        _, stderr = @git.move_worktree(git_dir(plan.path), plan.path, plan.new_path)
        return if Dir.exist?(plan.new_path) && !Dir.exist?(plan.path)
        raise StepFailed, "git worktree move failed: #{first_line(stderr)}"
      end

      def rename_branch(plan)
        return if @git.worktree_branch(plan.new_path) == plan.new_branch
        _, stderr = @git.rename_branch(plan.new_path, plan.branch, plan.new_branch)
        return if @git.worktree_branch(plan.new_path) == plan.new_branch
        raise StepFailed, "git branch -m failed: #{first_line(stderr)}"
      end

      # The repository's own directory: it holds still while the worktree moves, whatever the layout.
      def git_dir(checkout)
        @git.common_dir_from_files(checkout) or raise StepFailed, "#{checkout} is not a git checkout"
      end

      # Judged by the state of the checkout: a step that failed may have done its work all the same.
      def undo_git(plan, signals)
        checkout = Dir.exist?(plan.new_path) ? plan.new_path : plan.path
        if plan.branch != plan.new_branch && @git.worktree_branch(checkout) == plan.new_branch
          _, stderr = @git.rename_branch(checkout, plan.new_branch, plan.branch)
          raise StepFailed, "git branch -m back failed: #{first_line(stderr)}" unless @git.worktree_branch(checkout) == plan.branch
        end
        if plan.path_changes? && !Dir.exist?(plan.path) && Dir.exist?(plan.new_path)
          _, stderr = @git.move_worktree(git_dir(plan.new_path), plan.new_path, plan.path)
          raise StepFailed, "git worktree move back failed: #{first_line(stderr)}" unless Dir.exist?(plan.path)
        end
      rescue StepFailed, Workspace::Error => e
        raise incomplete(plan, ["undo"], [e.message], signals.report)
      end

      # @return [Array<Array(String, Proc)>]
      def later_steps(plan, progress)
        [["notes", -> { move_notes(plan) }],
          ["notes_dir", -> { write_notes_dir(plan) }],
          ["stores", -> { rename_stores(plan, progress) }],
          ["notes_exclude", -> { exclude_notes(plan) }],
          ["task", -> { update_task(plan) }],
          ["inbox", -> { rescope_inbox(plan) }],
          ["hook_events", -> { move_hook_events(plan) }],
          ["ledger", -> { carry_ledger(plan) }],
          ["bindings", -> { @pane_bindings.rename_workspace(from: plan.workspace, to: plan.new_workspace, from_session: plan.session, to_session: plan.new_session) }]]
      end

      def attempt(plan, name, work, signals)
        work.call
      rescue StepFailed => e
        raise incomplete(plan, e.steps || [name], [e.message], signals.report)
      rescue => e
        raise incomplete(plan, [name], ["#{e.class}: #{e.message}"], signals.report)
      end

      def move_notes(plan)
        return unless plan.notes.action == "move"
        from = plan.notes.from
        to = plan.notes.to
        return unless File.exist?(from) || File.symlink?(from)
        if NotesCarry.clash?(to, directory: true)
          raise StepFailed, "both #{from} and #{to} exist and the target holds files; move what you want to keep out of one of them, then run the rename again"
        end
        FileUtils.mkdir_p(File.dirname(to))
        File.rename(from, to)
      end

      # A worktree's `notes.dir` is its own value, as {NotesSetup} pins it, so notes that moved are
      # pinned where they went. A value naming neither end is the person's and stays.
      def write_notes_dir(plan)
        return if plan.notes.action == "stays"
        name = settings_name(plan)
        data = @project_settings.load(name)
        notes = data["notes"]
        return unless notes.nil? || notes.is_a?(Hash)
        stored = notes && notes["dir"]
        return if !stored.nil? && !(stored.is_a?(String) && File.expand_path(stored) == plan.notes.from)
        data["notes"] = (notes || {}).merge("dir" => plan.notes.to)
        @project_settings.save(name, data)
      end

      # The settings file moves with the stores, and a re-run may come after that.
      def settings_name(plan)
        old_there = WorkspaceStoreRename.listed?(@config.project_config_path(plan.workspace))
        new_there = WorkspaceStoreRename.listed?(@config.project_config_path(plan.new_workspace))
        (new_there && !old_there) ? plan.new_workspace : plan.workspace
      end

      def rename_stores(plan, progress)
        outcome = WorkspaceStoreRename.new(config: @config, project_config: @project_config, tmux: @tmux, state: @state,
          project_catalog_factory: @project_catalog_factory, old: plan.workspace, new: plan.new_workspace,
          session: plan.session, new_session: plan.new_session, root: plan.new_path, branch: plan.branch, new_branch: plan.new_branch,
          display: banner(plan.project, plan.path), new_display: banner(plan.project, plan.new_path),
          retry_hint: "run `#{rerun(plan)}` again", writer: @writer).call
        progress[:renamed].concat(outcome.renamed.map { |entry| entry["what"] })
        raise StepFailed.new(outcome.warnings.join("; "), steps: outcome.failed) unless outcome.failed.empty?
        progress[:warnings].concat(outcome.warnings.map { |line| {"code" => "store_warning", "message" => line} })
      end

      def banner(project, checkout)
        @project_config.banner_text("#{project}/#{File.basename(checkout)}")
      end

      # Notes in the main checkout get their own `info/exclude` line, so the moved ones need a new one.
      def exclude_notes(plan)
        @notes.info(name: plan.new_workspace, create: true, root: plan.new_path) if plan.notes.action == "move"
      end

      def update_task(plan)
        task = @task_store.active_for(plan.workspace) or return
        @task_store.update(task["id"], workspace: plan.new_workspace, branch: plan.new_branch, path: plan.new_path)
      end

      def rescope_inbox(plan)
        name = plan.new_workspace
        @inbox_store_factory.call(path: @config.inbox_path("workspace", name), scope: "workspace:#{name}", error_output: @error_output)
          .rescope(key: name, name: name)
      end

      # A launch under the new name during the rename may have written the new file, so the two are joined.
      def move_hook_events(plan)
        return unless plan.workspace_changes?
        from = HookEventLog.path_for(@config.hook_events_dir, plan.workspace)
        to = HookEventLog.path_for(@config.hook_events_dir, plan.new_workspace)
        [[from, to], ["#{from}.1", "#{to}.1"]].each do |source, target|
          next unless File.exist?(source)
          File.exist?(target) ? append_log(source, target) : File.rename(source, target)
        end
      end

      # The joined file replaces the target whole, and a target already ending in the source is one a
      # killed run joined and did not get to delete the source of, so a re-run never doubles a line.
      # The plan has refused a daemon under the new name, so nothing writes to the target meanwhile.
      def append_log(source, target)
        old = File.binread(source)
        current = File.binread(target)
        unless current.end_with?(old)
          temp = "#{target}.#{Process.pid}.tmp"
          File.binwrite(temp, current + old)
          File.chmod(File.stat(target).mode & 0o7777, temp)
          File.rename(temp, target)
        end
        File.delete(source)
      ensure
        File.delete(temp) if temp && File.exist?(temp)
      end

      def carry_ledger(plan)
        return unless plan.workspace_changes? || plan.session != plan.new_session
        @session_ledger.carry(from: plan.workspace, to: plan.new_workspace, cwd: plan.new_path, from_session: plan.session, to_session: plan.new_session)
      end

      # A config under the new name is what says the stores are done, so the journal stays without one.
      # The event has names only, never paths or messages, like every lifecycle event.
      def finish(plan, progress, signals)
        path = @config.config_path_for(plan.new_workspace)
        unless WorkspaceStoreRename.listed?(path)
          journal = Shellwords.escape(@config.rename_journal_path(plan.workspace))
          raise Workspace::Error.new("The rename of #{plan.workspace} moved its checkout to #{plan.new_path}, but no tmuxinator config is left under either name, and a re-run can not make one. Delete the journal with `rm #{journal}`, then remake the workspace with `workspace start`.",
            code: "rename_incomplete",
            details: {"workspace" => plan.workspace, "new_workspace" => plan.new_workspace, "new_branch" => plan.new_branch,
                      "failed" => ["tmuxinator_config"], "problems" => ["#{path} is missing"], "rerun" => false, "fix" => "rm #{journal}"}.merge(signals.report))
        end
        attempt(plan, "journal", -> { @journal.delete(plan.workspace) }, signals)
        @event_log&.record(type: "workspace_renamed", project: plan.new_workspace,
          data: {"workspace" => plan.new_workspace, "from" => plan.workspace, "branch" => plan.new_branch, "from_branch" => plan.branch,
                 "session" => plan.new_session, "from_session" => plan.session, "renamed" => progress[:renamed], "failed" => []})
      end

      def report(plan, warnings, dry_run:)
        plan.to_h.merge("warnings" => plan.warnings + warnings, "dry_run" => dry_run,
          "next" => dry_run ? nil : "Run `workspace restore #{Shellwords.escape(plan.new_workspace)}` to resume the conversation; a plain `workspace launch #{Shellwords.escape(plan.new_workspace)}` starts a new one.")
      end

      def rerun(plan)
        "workspace rename #{Shellwords.escape(plan.workspace)} #{Shellwords.escape(plan.new_branch)}"
      end

      def failed(plan, step, reason, signal)
        Workspace::Error.new("Could not rename #{plan.workspace}: #{reason}. Nothing changed.", code: "rename_failed",
          details: {"workspace" => plan.workspace, "new_branch" => plan.new_branch, "step" => step, "rolled_back" => true}.merge(signal))
      end

      def incomplete(plan, steps, problems, signal)
        Workspace::Error.new("The rename of #{plan.workspace} stopped at #{steps.join(", ")}: #{problems.join("; ")}. Run `#{rerun(plan)}` again to finish it.",
          code: "rename_incomplete",
          details: {"workspace" => plan.workspace, "new_workspace" => plan.new_workspace, "new_branch" => plan.new_branch,
                    "failed" => steps, "problems" => problems, "rerun" => true, "fix" => rerun(plan)}.merge(signal))
      end

      def first_line(text)
        text.to_s.strip.lines.first.to_s.strip
      end
    end
  end
end
