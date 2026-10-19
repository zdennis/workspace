require "securerandom"
require "shellwords"

module Workspace
  # Moves the work in a main checkout (staged, unstaged and untracked changes, and
  # the commits of its branch) into a new worktree at `.worktrees/<branch>`, and
  # leaves the main checkout clean on the default branch. The git half of
  # `workspace promote`.
  #
  # The changes travel in one `git stash push --include-untracked` under a unique
  # tag. The entry is found by its tag, pinned to `refs/workspace/promote/<id>` and
  # taken off the shared stash list at once, then applied with `--index` in the new
  # worktree and checked against trees recorded before the stash. The ref is
  # deleted only after a check passes, so at every step the work is in the main
  # checkout, in the worktree or under the ref. A failure before the worktree's
  # check passes undoes the steps in reverse; when undoing fails too, the ref is
  # kept and the error names the commands that recover the work.
  class CheckoutMove
    # Where the snapshot of the changes is kept while they move.
    REF_PREFIX = "refs/workspace/promote/"

    # Most paths a list in the report holds; the `*_count` beside it is the full count.
    LIST_LIMIT = 200

    # Most commands `details.recover` holds.
    RECOVER_LIMIT = 8

    # The error codes this class raises that `ErrorCodes` does not list yet;
    # `workspace promote` registers them with the command.
    NOT_MAIN_CHECKOUT = "not_main_checkout"
    DETACHED_HEAD = "detached_head"
    GIT_OPERATION_IN_PROGRESS = "git_operation_in_progress"
    UNMERGED_FILES = "unmerged_files"
    INTENT_TO_ADD = "intent_to_add"
    SUBMODULE_CHANGES = "submodule_changes"
    HIDDEN_FILES = "hidden_files"
    PATH_CONFLICTS = "path_conflicts"
    NO_DEFAULT_BRANCH = "no_default_branch"
    BRANCH_REQUIRED = "branch_required"
    BRANCH_EXISTS = "branch_exists"
    BRANCH_CHECKED_OUT = "branch_checked_out"
    WORKTREE_EXISTS = "worktree_exists"
    NOTHING_TO_MOVE = "nothing_to_move"
    STASH_FAILED = "stash_failed"
    MOVE_FAILED = "move_failed"
    MOVE_INCOMPLETE = "move_incomplete"
    CODES = [NOT_MAIN_CHECKOUT, DETACHED_HEAD, GIT_OPERATION_IN_PROGRESS, UNMERGED_FILES, INTENT_TO_ADD,
      SUBMODULE_CHANGES, HIDDEN_FILES, PATH_CONFLICTS, NO_DEFAULT_BRANCH, BRANCH_REQUIRED, BRANCH_EXISTS, BRANCH_CHECKED_OUT,
      WORKTREE_EXISTS, NOTHING_TO_MOVE, STASH_FAILED, MOVE_FAILED, MOVE_INCOMPLETE].freeze

    # A step that did not reach the state it should have.
    class StepFailed < StandardError; end

    # @param path [String]
    # @return [String] the real path, through the nearest directory that exists for a path that does not
    def self.real_path(path)
      File.realpath(path)
    rescue SystemCallError
      expanded = File.expand_path(path)
      parent = File.dirname(expanded)
      (parent == expanded) ? expanded : File.join(real_path(parent), File.basename(expanded))
    end

    # @param git [Workspace::Git]
    # @param git_exclude [Workspace::GitExclude] lists `.worktrees/` and the notes directory in `info/exclude`
    # @param workspace_name [#call] `(checkout_path)` to the workspace name of a checkout, or nil; names the
    #   worktree in a `branch_checked_out` refusal
    def initialize(git:, git_exclude:, workspace_name: ->(_path) {})
      @git = git
      @git_exclude = git_exclude
      @workspace_name = workspace_name
    end

    # What a move would do, read only: the refusals, the lists and the warnings.
    # With +branch+ nil on the default branch the result says `branch_required`
    # and the branch checks are skipped.
    #
    # @param path [String] the top of the main checkout
    # @param branch [String, nil] the branch to move to; nil moves the current branch
    # @param notes_dir [String, nil] the main checkout's notes directory, left behind
    # @return [Hash] `"branch_required"`, `"path"` (the worktree), `"moved"` and `"warnings"`, as
    #   `promote --dry-run --json` shows them
    # @raise [Workspace::Error] a refusal, coded
    def plan(path, branch, notes_dir: nil)
      facts = preflight(path, branch, notes_dir)
      report(facts, snapshot: nil, main_branch: facts[:switch] ? facts[:default] : facts[:from], main_clean: true, warnings: facts[:warnings])
    end

    # Moves the work.
    #
    # @param path [String] the top of the main checkout
    # @param branch [String, nil] the branch to move to; nil moves the current branch
    # @param notes_dir [String, nil] the main checkout's notes directory, left behind
    # @return [Hash] the {#plan} keys, with `moved.snapshot` and `moved.main` as they ended
    # @raise [Workspace::UsageError] `branch_required`
    # @raise [Workspace::Error] a refusal, `stash_failed` (nothing changed), `move_failed` (rolled back)
    #   or `move_incomplete` (the work is under the snapshot ref; `details.recover` says how to get it)
    def call(path, branch, notes_dir: nil)
      facts = preflight(path, branch, notes_dir)
      if facts[:required]
        raise UsageError.new("#{facts[:from]} is the default branch; name a branch to move the work to.",
          code: BRANCH_REQUIRED, details: {"from_branch" => facts[:from]})
      end
      write_excludes(facts)
      # Read again: with the exclude lines written, the lists and the recorded trees leave out
      # `.worktrees/` and the notes, as the stash will, and a change made meanwhile is seen.
      Attempt.new(git: @git, facts: preflight(path, branch, notes_dir), id: SecureRandom.hex(6)).call.then do |outcome|
        report(outcome[:facts], snapshot: outcome[:snapshot], main_branch: @git.worktree_branch(outcome[:facts][:root]),
          main_clean: outcome[:main_clean], warnings: outcome[:warnings])
      end
    end

    private

    def preflight(path, branch, notes_dir)
      root = main_checkout!(path)
      from = @git.worktree_branch(root)
      base = from && @git.rev_parse(root, "HEAD")
      refuse(DETACHED_HEAD, "#{root} is not on a branch with a commit.", "path" => root) unless base
      refuse("rebase_in_progress", "A rebase is stopped in #{root}; finish or abort it first.", "path" => root) if @git.rebase_in_progress?(root)
      if (operation = @git.operation_in_progress(root))
        refuse(GIT_OPERATION_IN_PROGRESS, "A #{operation.tr("_", "-")} is stopped in #{root}; finish or abort it first.",
          "path" => root, "operation" => operation)
      end
      entries = @git.status_entries(root) or raise Workspace::Error, "git could not read the status of #{root}."
      refuse_paths(UNMERGED_FILES, "has unmerged files; resolve them first", entries[:unmerged], root)
      refuse_paths(INTENT_TO_ADD, "has files added with git add -N, which a stash does not carry; add them or reset them first", entries[:intent_to_add], root)
      unless entries[:submodule].empty?
        refuse(SUBMODULE_CHANGES, "#{root} has submodules with changes, which a stash does not carry: #{entries[:submodule].first(5).join(", ")}.",
          "paths" => entries[:submodule].first(LIST_LIMIT))
      end
      hidden = @git.hidden_files(root) or raise Workspace::Error, "git could not list the files of #{root}."
      refuse_paths(HIDDEN_FILES, "has files marked --assume-unchanged or --skip-worktree, whose changes a stash would not carry " \
        "and could overwrite; clear the mark (git update-index --no-assume-unchanged / --no-skip-worktree) first", hidden, root)
      refuse_paths(PATH_CONFLICTS, "has untracked files where a deleted tracked file was (or inside it, or around it), " \
        "which a stash cannot apply back; commit or move them first", path_conflicts(entries), root)
      default = @git.default_branch_name(root)
      unless default && @git.rev_parse(root, "refs/heads/#{default}")
        refuse(NO_DEFAULT_BRANCH, "#{root} has no local default branch (main or master, or what origin/HEAD names).", "path" => root)
      end
      refuse_checked_out(root, default)
      target = target_branch(root, from, default, branch, base)
      worktree = target && File.join(root, ".worktrees", @git.sanitize_for_filesystem(target[:branch]))
      refuse(WORKTREE_EXISTS, "#{worktree} already exists.", "path" => worktree) if worktree && worktree_taken?(root, worktree)

      excluded = excluded_dirs(root, notes_dir)
      untracked = entries[:untracked].reject { |file| excluded.any? { |dir| file.start_with?(dir) } }
      left_behind, untracked = untracked.partition { |file| file.end_with?("/") }
      commits_ahead = @git.commits_ahead_of(root, "refs/heads/#{default}") || 0
      changes = {staged: entries[:staged].sort, unstaged: entries[:unstaged].sort, untracked: untracked.sort}
      if changes.values.all?(&:empty?) && commits_ahead.zero?
        name = target ? target[:branch] : "BRANCH"
        refuse(NOTHING_TO_MOVE, "#{root} has no changes and #{from} has no commits ahead of #{default}; " \
          "to start new work, run: workspace start #{name}", "branch" => target && target[:branch])
      end

      {root: root, from: from, default: default, base: base, branch: target && target[:branch],
       created: target && target[:created], required: target.nil?, switch: from != default,
       worktree: worktree, commits_ahead: commits_ahead, changes: changes, left_behind: left_behind.sort,
       excluded: excluded, warnings: plan_warnings(root, from, default, left_behind)}
    end

    # The top of a main checkout, never a subdirectory, a linked worktree or a bare repository.
    def main_checkout!(path)
      layout = @git.checkout_layout(path)
      unless layout && !layout[:linked] && real(layout[:toplevel]) == real(path)
        refuse(NOT_MAIN_CHECKOUT, "#{path} is not the top of a main checkout.", "path" => path)
      end
      layout[:toplevel]
    end

    def target_branch(root, from, default, branch, base)
      if branch.nil?
        return nil if from == default
        branch = from
      end
      raise UsageError, "#{default} is the default branch, which stays in the main checkout; name a new branch." if branch == default
      return {branch: branch, created: false} if branch == from
      raise UsageError, "#{branch.inspect} is not a valid branch name." unless @git.valid_branch_name?(root, branch)
      tip = @git.rev_parse(root, "refs/heads/#{branch}")
      return {branch: branch, created: true} unless tip
      unless tip == base
        refuse(BRANCH_EXISTS, "Branch #{branch} already exists at another commit; the changes are made on #{from}'s commit, " \
          "so name a new branch or one at #{base[0, 12]}.", "branch" => branch, "commit" => tip)
      end
      refuse_checked_out(root, branch)
      {branch: branch, created: false}
    end

    def refuse_checked_out(root, branch)
      where = @git.find_worktree_by_branch(branch, repo: root)
      return if where.nil? || real(where) == real(root)
      refuse(BRANCH_CHECKED_OUT, "#{branch} is checked out in #{where}; work on it there (workspace launch).",
        "branch" => branch, "path" => where, "workspace" => @workspace_name.call(where))
    end

    def worktree_taken?(root, worktree)
      File.exist?(worktree) || File.symlink?(worktree) ||
        @git.list_worktrees(repo: root).any? { |listed| real(listed) == real(worktree) }
    end

    # The directories, relative and with a trailing `/`, the stash must leave alone.
    def excluded_dirs(root, notes_dir)
      dirs = [".worktrees/"]
      return dirs unless notes_dir
      notes = real(notes_dir)
      top = real(root)
      dirs << "#{notes.delete_prefix("#{top}/")}/" if notes.start_with?("#{top}/")
      dirs
    end

    def write_excludes(facts)
      facts[:excluded].each { |dir| @git_exclude.add(facts[:root], "/#{dir}") }
    rescue SystemCallError => e
      raise Workspace::Error, "Could not write #{facts[:root]}'s info/exclude: #{e.message}. Nothing was moved."
    end

    def plan_warnings(root, from, default, left_behind)
      warnings = []
      unless left_behind.empty?
        warnings << {"code" => "left_behind", "message" => "Not moved, these are repositories of their own: #{left_behind.first(5).join(", ")}.",
                     "paths" => left_behind.sort.first(LIST_LIMIT)}
      end
      upstream = "origin/#{default}"
      if from == default && @git.rev_parse(root, "refs/remotes/#{upstream}")
        count = @git.commits_ahead_of(root, "refs/remotes/#{upstream}").to_i
        if count.positive?
          warnings << {"code" => "default_ahead", "message" => "#{default} is #{count} commit(s) ahead of #{upstream}; the new branch has them and #{default} is left as it is.",
                       "branch" => default, "upstream" => upstream, "count" => count,
                       "command" => "git -C #{Shellwords.escape(root)} reset --keep #{upstream}"}
        end
      end
      warnings
    end

    def report(facts, snapshot:, main_branch:, main_clean:, warnings:)
      lists = facts[:changes].flat_map { |kind, files| [[kind.to_s, files.first(LIST_LIMIT)], ["#{kind}_count", files.size]] }.to_h
      moved = {"from_branch" => facts[:from], "branch" => facts[:branch], "branch_created" => facts[:created],
               "base_commit" => facts[:base], "commits_ahead" => facts[:commits_ahead]}
        .merge(lists)
        .merge("left_behind" => facts[:left_behind].first(LIST_LIMIT), "snapshot" => snapshot,
          "main" => {"path" => facts[:root], "branch" => main_branch, "clean" => main_clean})
      {"branch_required" => facts[:required], "path" => facts[:worktree], "moved" => moved, "warnings" => warnings}
    end

    # Untracked paths at, under or above a deleted tracked path (`git rm --cached f`, a file
    # replaced by a directory): `git stash apply` refuses to put them back.
    def path_conflicts(entries)
      deleted = entries[:deleted]
      entries[:untracked].select do |file|
        parts = file.chomp("/").split("/")
        (1..parts.size).any? { |n| deleted.include?(parts.first(n).join("/")) } ||
          deleted.any? { |gone| gone.start_with?("#{parts.join("/")}/") }
      end
    end

    def refuse_paths(code, reason, paths, root)
      return if paths.empty?
      refuse(code, "#{root} #{reason}: #{paths.first(5).join(", ")}.", "paths" => paths.sort.first(LIST_LIMIT), "count" => paths.size)
    end

    def refuse(code, message, details)
      raise Workspace::Error.new(message, code: code, details: details)
    end

    def real(path)
      CheckoutMove.real_path(path)
    end

    # One run of the move, holding what has been done so it can be undone.
    class Attempt
      # @param git [Workspace::Git]
      # @param facts [Hash] the preflight's facts, read after the `info/exclude` lines were written
      # @param id [String] names the tag and the snapshot ref
      def initialize(git:, facts:, id:)
        @git = git
        @facts = facts
        @root = facts[:root]
        @worktree = facts[:worktree]
        @branch = facts[:branch]
        @ref = "#{REF_PREFIX}#{id}"
        @tag = "workspace promote: #{@branch} #{id}"
        @done = []
        @warnings = facts[:warnings].dup
      end

      # @return [Hash] `:facts`, `:snapshot`, `:main_clean`, `:warnings`
      # @raise [Workspace::Error] `stash_failed`, `move_failed` or `move_incomplete`
      def call
        @recorded = @git.snapshot_trees(@root, skip: @facts[:left_behind]) or
          raise Workspace::Error, "Could not record the state of #{@root} (git write-tree or git add failed). Nothing was moved."
        stash if changes?
        begin
          @step = "stash"
          check_stash_kept if @sha
          check_clean
          switch_main if @facts[:switch]
          add_worktree
          apply
          verify
        rescue => e
          raise roll_back(e)
        end
        {facts: @facts, snapshot: release, main_clean: main_clean?, warnings: @warnings}
      end

      private

      def changes?
        @facts[:changes].values.any? { |files| !files.empty? }
      end

      def stash
        @stash, pushed, stderr = @git.stash_push(@root, @tag, include_untracked: true)
        @sha = @stash&.sha
        unless @sha
          raise Workspace::Error.new("Could not stash the changes in #{@root}: #{first_line(stderr)}. Nothing was moved.",
            code: STASH_FAILED, details: {"path" => @root})
        end
        @pinned = quietly { @git.pin_ref(@root, @ref, @sha) }
        @listed = !(@pinned && quietly { @git.stash_drop(@root, @stash) })
        @done << "stash"
        return if pushed
        @step = "stash"
        incomplete("git stash stored the changes but failed while cleaning #{@root}: #{first_line(stderr)}")
      end

      def check_stash_kept
        raise StepFailed, "could not keep the stash under #{@ref}" unless @pinned
        raise StepFailed, "could not take the stash entry off the stash list" if @listed
      end

      def check_clean
        raise StepFailed, "#{@root} still had changes after the stash (did something write files meanwhile?)" unless main_clean?
      end

      def switch_main
        @step = "switch"
        ok, = @git.switch(@root, @facts[:default])
        raise StepFailed, "git switch #{@facts[:default]} failed in #{@root}" unless @git.worktree_branch(@root) == @facts[:default]
        hook_failed("switch") unless ok
        @done << "switch"
      end

      def add_worktree
        @step = "worktree_add"
        ok, = @git.create_worktree_at(@root, @worktree, @branch, start_point: @facts[:created] ? @facts[:base] : nil)
        unless worktree_registered? && @git.worktree_branch(@worktree) == @branch && @git.rev_parse(@worktree, "HEAD") == @facts[:base]
          raise StepFailed, "git worktree add #{@worktree} did not check out #{@branch} at #{@facts[:base][0, 12]}"
        end
        hook_failed("worktree_add") unless ok
        @done << "worktree_add"
        return unless File.exist?(File.join(@worktree, ".gitmodules"))
        command = "git -C #{Shellwords.escape(@worktree)} submodule update --init"
        @warnings << {"code" => "submodules_not_initialized", "message" => "The new worktree's submodules are empty; run: #{command}", "command" => command}
      end

      def apply
        return unless @sha
        @step = "apply"
        ok, stderr = @git.stash_apply(@worktree, @sha, index: true)
        raise StepFailed, "the changes did not apply in the new worktree: #{first_line(stderr)}" unless ok
        @done << "apply"
      end

      def verify
        @step = "verify"
        extra = compare(@worktree) or raise StepFailed, "the new worktree does not match the main checkout as it was"
        @done << "verify"
        return if extra.empty?
        @warnings << {"code" => "extra_untracked", "message" => "Files the main checkout did not have, likely written by a hook: #{extra.first(5).join(", ")}.",
                      "paths" => extra.sort.first(LIST_LIMIT)}
      end

      # @return [Array<String>, nil] the files only +dir+ has (nil when it does not match what was recorded)
      def compare(dir)
        now = @git.snapshot_trees(dir, skip: @facts[:left_behind])
        return nil unless now && now[:index] == @recorded[:index]
        diff = @git.tree_diff(dir, @recorded[:worktree], now[:worktree]) or return nil
        added, other = diff.partition { |status, _| status == "A" }
        other.empty? ? added.map(&:last) : nil
      end

      # Judged by the state of the checkouts, not by which steps said they were done:
      # a step that raised part way may have changed something all the same.
      # @return [Workspace::Error] `move_failed`, for the caller to raise; an undo that fails raises `move_incomplete`
      def roll_back(error)
        failed = @step
        reason = error.is_a?(StepFailed) ? error.message : "#{error.class}: #{error.message}"
        undo("worktree_remove") { @git.remove_worktree(@worktree, force: true) } if worktree_registered?
        if branch_made?
          undo("branch_delete") { @git.delete_ref(@root, "refs/heads/#{@branch}", @facts[:base]) or raise StepFailed, "could not delete #{@branch}" }
        end
        unless @git.worktree_branch(@root) == @facts[:from]
          undo("switch_back") do
            @git.switch(@root, @facts[:from])
            raise StepFailed, "git switch #{@facts[:from]} failed in #{@root}" unless @git.worktree_branch(@root) == @facts[:from]
          end
        end
        if @sha
          undo("rollback_apply") do
            ok, stderr = @git.stash_apply(@root, @sha, index: true)
            raise StepFailed, "the changes did not apply back in #{@root}: #{first_line(stderr)}" unless ok
          end
          @restored = true
        end
        undo("rollback_verify") { compare(@root) or raise StepFailed, "#{@root} does not match what it was before the move" }
        Workspace::Error.new("Could not move the work: #{reason}. Nothing moved: the main checkout is as it was.",
          code: MOVE_FAILED, details: {"step" => failed, "rolled_back" => true, "snapshot" => release})
      end

      # The preflight saw no such branch, so one at the base commit now is the one this move made.
      def branch_made?
        @facts[:created] && @git.rev_parse(@root, "refs/heads/#{@branch}") == @facts[:base]
      end

      def undo(step)
        @step = step
        yield
        @done << step
      rescue => e
        incomplete(e.is_a?(StepFailed) ? e.message : "#{e.class}: #{e.message}")
      end

      def incomplete(reason)
        holder = @pinned ? @ref : "stash commit #{@sha}"
        where = @sha ? " Your changes are safe in #{holder}; if git stash apply refuses because files are in the way, move them aside and run it again." : ""
        raise Workspace::Error.new("The move stopped part way and could not be undone (#{reason}).#{where}",
          code: MOVE_INCOMPLETE,
          details: {"step" => @step, "steps_done" => @done.dup, "snapshot" => snapshot_details(kept: true),
                    "main_branch" => @git.worktree_branch(@root), "worktree" => (@worktree if worktree_registered?),
                    "recover" => recover_commands})
      end

      def recover_commands
        git = "git -C #{Shellwords.escape(@root)}"
        commands = []
        commands << "#{git} worktree remove --force #{Shellwords.escape(@worktree)}" if worktree_registered?
        if branch_made?
          commands << "#{git} update-ref -d refs/heads/#{Shellwords.escape(@branch)} #{@facts[:base]}"
        end
        commands << "#{git} switch #{Shellwords.escape(@facts[:from])}" unless @git.worktree_branch(@root) == @facts[:from]
        if @sha && @restored
          # Applied back but not matching what was recorded: show what the snapshot holds, and keep it.
          commands << "#{git} stash show --include-untracked --stat #{@sha}"
        elsif @sha
          commands << "#{git} stash apply --index #{@sha}"
          commands << "#{git} update-ref -d #{@ref} #{@sha}" if @pinned
        end
        commands.first(RECOVER_LIMIT)
      end

      # Deletes the ref (and the stash entry, if it is still listed) once the work is safe elsewhere.
      def release
        return nil unless @sha
        deleted = !@pinned || quietly { @git.delete_ref(@root, @ref, @sha) }
        @listed = !quietly { @git.stash_drop(@root, @stash) } if @listed
        unless deleted
          command = "git -C #{Shellwords.escape(@root)} update-ref -d #{@ref}"
          @warnings << {"code" => "snapshot_not_deleted", "message" => "The work moved, but #{@ref} could not be deleted; run: #{command}",
                        "ref" => @ref, "command" => command}
        end
        snapshot_details(kept: !deleted)
      end

      # @return [Boolean] the block's answer; false when git failed outright (not installed, out of time)
      def quietly
        yield
      rescue Workspace::Error
        false
      end

      def snapshot_details(kept:)
        @sha && {"ref" => (@ref if @pinned), "id" => @sha, "kept" => kept}
      end

      def hook_failed(step)
        @warnings << {"code" => "hook_failed", "message" => "git exited with an error during #{step}, likely its post-checkout hook; the step itself worked.",
                      "hook" => "post-checkout", "step" => step}
      end

      def main_clean?
        entries = @git.status_entries(@root)
        return false unless entries
        untracked = entries[:untracked].reject { |file| (@facts[:excluded] + @facts[:left_behind]).any? { |dir| file.start_with?(dir) } }
        (entries.values_at(:staged, :unstaged, :unmerged, :intent_to_add, :submodule) + [untracked]).all?(&:empty?)
      end

      def worktree_registered?
        @git.list_worktrees(repo: @root).any? { |listed| real(listed) == real(@worktree) }
      end

      def real(path)
        CheckoutMove.real_path(path)
      end

      def first_line(text)
        text.to_s.strip.lines.first.to_s.strip
      end
    end
  end
end
