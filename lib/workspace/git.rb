require "open3"
require "timeout"

module Workspace
  # Git and worktree operations for the workspace CLI.
  class Git
    # @param output [IO] output stream for user-facing messages
    # @param input [IO] input stream for interactive prompts
    # @param logger [Workspace::Logger] debug logger
    # @param runner [#call] `(argv, chdir:, timeout:)` returning `[stdout, stderr, success]`; runs the
    #   time-limited, prompt-free git calls of {#push}, {#fetch}, {#rebase} and the other write operations
    def initialize(output: $stdout, input: $stdin, logger: Workspace::Logger.new, runner: TimedProcess.method(:run))
      @output = output
      @input = input
      @logger = logger
      @runner = runner
    end

    # Seconds `git push` may take.
    PUSH_TIMEOUT = 120

    # Seconds `git fetch` may take.
    FETCH_TIMEOUT = 60

    # Seconds `git rebase` may take.
    REBASE_TIMEOUT = 300

    # Seconds any other git call that changes a checkout may take.
    QUICK_TIMEOUT = 30

    # Pushes a branch to origin.
    #
    # @param path [String] the checkout
    # @param branch [String]
    # @param set_upstream [Boolean] pass `-u`
    # @param force_with_lease [Boolean] pass `--force-with-lease`
    # @return [Array(Boolean, String)] success and git's stderr
    # @raise [Workspace::Error] git is not installed, or the push ran past {PUSH_TIMEOUT} (uncoded)
    def push(path, branch, set_upstream: false, force_with_lease: false)
      argv = ["push"]
      argv << "-u" if set_upstream
      argv << "--force-with-lease" if force_with_lease
      argv.push("origin", branch)
      _, stderr, success = run_git(path, *argv, timeout: PUSH_TIMEOUT)
      [success, stderr]
    end

    # Fetches from origin.
    #
    # @param path [String] the checkout
    # @param refs [Array<String>] branches to fetch; none fetches everything origin has
    # @param remote [String]
    # @return [Array(Boolean, String)] success and git's stderr
    def fetch(path, *refs, remote: "origin")
      _, stderr, success = run_git(path, "fetch", remote, *refs, timeout: FETCH_TIMEOUT)
      [success, stderr]
    end

    # Whether +remote+ still has +ref+, asked with `ls-remote` so the answer
    # does not depend on the wording of git's messages in the user's locale.
    #
    # @param path [String] the checkout
    # @param remote [String]
    # @param ref [String] a full ref, such as `refs/heads/main`
    # @return [Boolean, nil] nil when the remote could not be asked
    def remote_ref_exists?(path, remote, ref)
      stdout, _, success = run_git(path, "ls-remote", remote, ref, timeout: FETCH_TIMEOUT)
      return nil unless success

      !stdout.strip.empty?
    end

    # The name of the repository's default branch as a local branch: what
    # `origin/HEAD` points at, else the first of `main` and `master` that exists.
    #
    # @param path [String] any checkout of the repository
    # @return [String, nil]
    def default_branch_name(path)
      stdout, _, status = capture_git("-C", path, "symbolic-ref", "--quiet", "--short", "refs/remotes/origin/HEAD")
      head = stdout.scrub.strip.delete_prefix("origin/")
      exists = ->(name) { ref_exists?(path, "refs/heads/#{name}") || ref_exists?(path, "refs/remotes/origin/#{name}") }
      return head if status.success? && !head.empty? && exists.call(head)
      %w[main master].find(&exists)
    end

    # @param path [String] the checkout
    # @param ref [String]
    # @return [Boolean] whether +ref+ names a commit
    def commit_exists?(path, ref)
      ref_exists?(path, ref)
    end

    # @param path [String] the checkout
    # @param ancestor [String] a ref
    # @param descendant [String] a ref
    # @return [Boolean] whether +ancestor+ is reachable from +descendant+ (a ref is its own ancestor)
    def ancestor?(path, ancestor, descendant)
      _, _, status = capture_git("-C", path, "merge-base", "--is-ancestor", ancestor, descendant)
      status.success?
    end

    # @param path [String] the checkout
    # @return [Array<String>, nil] tracked files with staged or unstaged changes (untracked files do not
    #   count), or nil if git could not answer
    def dirty_tracked_files(path)
      stdout, _, status = capture_git("-C", path, "status", "--porcelain", "--untracked-files=no", "--no-renames", "-z")
      return nil unless status.success?
      stdout.scrub.split("\0").reject(&:empty?).map { |entry| entry[3..] }
    end

    # @param path [String] the checkout
    # @return [Boolean] whether a rebase has stopped in it
    def rebase_in_progress?(path)
      %w[rebase-merge rebase-apply].any? do |dir|
        stdout, _, status = capture_git("-C", path, "rev-parse", "--git-path", dir)
        status.success? && File.exist?(File.expand_path(stdout.strip, path))
      end
    end

    # @param path [String] the checkout
    # @param onto [String] a ref
    # @return [Array(Boolean, String)] success and git's stderr
    def rebase(path, onto)
      _, stderr, success = run_git(path, "rebase", onto, timeout: REBASE_TIMEOUT)
      [success, stderr]
    end

    # @param path [String] the checkout
    # @return [Boolean] whether `git rebase --abort` worked
    def rebase_abort(path)
      _, _, success = run_git(path, "rebase", "--abort", timeout: QUICK_TIMEOUT)
      success
    end

    # @param path [String] the checkout
    # @return [Array<String>] the files a stopped rebase has unmerged
    def conflicted_files(path)
      stdout, _, status = capture_git("-C", path, "diff", "--name-only", "--diff-filter=U", "-z")
      status.success? ? stdout.scrub.split("\0").reject(&:empty?) : []
    end

    # Moves a local branch that is not checked out anywhere to +target+. The
    # caller has checked that it is a fast-forward.
    #
    # @param path [String] any checkout of the repository
    # @param branch [String]
    # @param target [String] a ref
    # @return [Boolean]
    def advance_branch(path, branch, target)
      _, _, success = run_git(path, "update-ref", "refs/heads/#{branch}", target, timeout: QUICK_TIMEOUT)
      success
    end

    # `git merge --ff-only` in a checkout of the branch to move.
    #
    # @param path [String] a checkout whose current branch is the one to move
    # @param target [String] a ref
    # @return [Boolean]
    def fast_forward(path, target)
      _, _, success = run_git(path, "merge", "--ff-only", "--quiet", target, timeout: QUICK_TIMEOUT)
      success
    end

    # @param path [String] the checkout
    # @param message [String]
    # @return [Boolean] whether the changes to tracked files were stashed
    def stash_push(path, message)
      _, _, success = run_git(path, "stash", "push", "--quiet", "-m", message, timeout: QUICK_TIMEOUT)
      success
    end

    # @param path [String] the checkout
    # @return [Array(Boolean, String)] whether the newest stash applied cleanly, and git's stderr
    def stash_pop(path)
      _, stderr, success = run_git(path, "stash", "pop", "--quiet", timeout: QUICK_TIMEOUT)
      [success, stderr]
    end

    # Whether the branch's own history once held every commit that +upstream+
    # has and +branch+ lacks, judged by the branch's reflog: true after a
    # rebase of commits already pushed, false when someone else added commits.
    #
    # @param path [String] the checkout
    # @param branch [String] the local branch
    # @param upstream [String] its upstream ref
    # @return [Boolean]
    def upstream_commits_replaced?(path, branch, upstream)
      stdout, _, status = capture_git("-C", path, "reflog", "show", "--format=%H", "-n", "200", "refs/heads/#{branch}")
      return false unless status.success?
      old_tips = stdout.lines.map(&:strip).reject(&:empty?).uniq
      stdout, _, status = capture_git("-C", path, "rev-list", upstream, "--not", "refs/heads/#{branch}", *old_tips)
      status.success? && stdout.strip.empty?
    end

    # @param path [String] the checkout
    # @param upstream [String] a ref
    # @return [Array(Integer, Integer), nil] commits only upstream has, then commits only HEAD has; nil if git could not answer
    def behind_ahead(path, upstream)
      stdout, _, status = capture_git("-C", path, "rev-list", "--left-right", "--count", "#{upstream}...HEAD")
      return nil unless status.success?
      behind, ahead = stdout.split.map(&:to_i)
      [behind, ahead]
    end

    # @return [String, nil] the root of the current git repository
    def root
      stdout, _, status = Open3.capture3("git", "rev-parse", "--show-toplevel")
      status.success? ? stdout.strip : nil
    end

    # @return [String] the default branch name (main or master)
    def default_branch
      stdout, _, status = Open3.capture3("git", "symbolic-ref", "refs/remotes/origin/HEAD")
      return stdout.strip.sub("refs/remotes/origin/", "") if status.success? && !stdout.strip.empty?
      system("git", "show-ref", "--verify", "--quiet", "refs/heads/main") ? "main" : "master"
    end

    # @return [String] the current branch name
    def current_branch
      stdout, _, status = Open3.capture3("git", "rev-parse", "--abbrev-ref", "HEAD")
      status.success? ? stdout.strip : ""
    end

    # @param name [String] branch name
    # @return [Boolean] true if branch exists locally or remotely
    def branch_exists?(name)
      local_branch_exists?(name) || remote_branch_exists?(name)
    end

    # @param name [String] branch name
    # @return [Boolean] true if branch exists locally
    def local_branch_exists?(name)
      system("git", "show-ref", "--verify", "--quiet", "refs/heads/#{name}")
    end

    # @param name [String] branch name
    # @return [Boolean] true if branch exists on origin
    def remote_branch_exists?(name)
      system("git", "show-ref", "--verify", "--quiet", "refs/remotes/origin/#{name}")
    end

    # @return [Array<String>] list of remote branch names (without origin/ prefix)
    def fetch_remote_branches
      Open3.capture3("git", "fetch", "--prune")
      stdout, _ = Open3.capture3("git", "branch", "-r")
      stdout.lines.map { |l| l.strip.sub("origin/", "") }.reject { |b| b.include?("->") }
    end

    # @param pattern [String] search pattern
    # @param branches [Array<String>, nil] optional branch list (falls back to fetch_remote_branches)
    # @return [Array<String>] matching branches ordered by priority (exact > contains > case-insensitive)
    def find_matching_branches(pattern, branches: nil)
      remote_branches = branches || fetch_remote_branches

      exact = remote_branches.select { |b| b == pattern }
      return exact unless exact.empty?

      contains = remote_branches.select { |b| b.include?(pattern) }
      return contains unless contains.empty?

      remote_branches.select { |b| b.downcase.include?(pattern.downcase) }
    end

    # Returns the origin remote URL for a git repository at the given path.
    # Works for both main worktrees and linked worktrees.
    #
    # @param path [String] directory path of the git repository
    # @return [String, nil] the remote URL, or nil if not a git repo or no origin remote
    def remote_url(path)
      stdout, _, status = Open3.capture3("git", "-C", path, "remote", "get-url", "origin")
      status.success? ? stdout.strip : nil
    rescue
      nil
    end

    # Returns true if the given path is a linked git worktree (not the main worktree).
    # Linked worktrees have a `.git` file (not directory) starting with "gitdir:".
    #
    # @param path [String] directory path to check
    # @return [Boolean] true if path is a linked git worktree
    def linked_worktree?(path)
      gitdir = File.join(path, ".git")
      File.file?(gitdir) && File.read(gitdir).start_with?("gitdir:")
    rescue
      false
    end

    # Describes the git checkout containing +path+ by reading `.git` files
    # directly, with no subprocess. Walks up from +path+ to the first `.git`:
    # a directory is a main checkout; a file holds `gitdir: X`, and when
    # `X/commondir` exists the checkout is a linked worktree whose common dir
    # is that `commondir` resolved against X (otherwise, as for a submodule,
    # X itself is the common dir). When a `.git` file can't be parsed, falls
    # back to `git rev-parse`.
    #
    # @param path [String] a directory inside (or at the root of) a checkout
    # @return [Hash, nil] `{toplevel:, common_dir:, linked:}` with absolute
    #   paths, or nil when +path+ isn't inside a git checkout. A `.git` file
    #   whose `gitdir:` target is missing (a broken checkout) gives
    #   `{toplevel:, common_dir: nil, linked: true, broken: true}`.
    def checkout_layout(path)
      dir = File.expand_path(path)
      loop do
        dot_git = File.join(dir, ".git")
        return {toplevel: dir, common_dir: dot_git, linked: false} if File.directory?(dot_git)
        return layout_from_git_file(dir, dot_git) if File.file?(dot_git)
        parent = File.dirname(dir)
        return nil if parent == dir
        dir = parent
      end
    end

    # @param path [String] a directory inside (or at the root of) a checkout
    # @return [String, nil] the absolute shared git directory, or nil when
    #   +path+ isn't inside a git checkout or its checkout is broken; see {#checkout_layout}
    def common_dir_from_files(path)
      checkout_layout(path)&.fetch(:common_dir)
    end

    # Whether the index of the checkout at +dir+ holds +path+, or any file
    # under it when +path+ is a directory, whether or not it is on disk.
    # Case is ignored, so it errs toward "tracked".
    #
    # @param dir [String] the checkout
    # @param path [String] relative to +dir+
    # @return [Boolean]
    # @raise [Workspace::Error] when git can't answer, so a caller never overwrites a file on a guess
    def tracked?(dir, path)
      # A case-insensitive volume (the macOS default) puts `Reviewer.md` at
      # the path of `reviewer.md`, so match the way the file system does.
      # GIT_LITERAL_PATHSPECS=1 in the environment would read `:(icase)` as part of
      # the file name and answer "not tracked" for every path.
      stdout, stderr, status = capture_git("--no-literal-pathspecs", "-C", dir, "ls-files", "-z", "--", ":(icase)#{path}")
      raise Workspace::Error, "Can't tell whether git tracks #{path} in #{dir}: #{stderr.strip}" unless status.success?
      !stdout.empty?
    end

    # Returns the current branch name for a worktree directory.
    # Returns nil if the HEAD is detached or an error occurs.
    #
    # @param path [String] worktree directory path
    # @return [String, nil] the branch name, or nil if detached or error
    def worktree_branch(path)
      stdout, _, status = capture_git("-C", path, "rev-parse", "--abbrev-ref", "HEAD")
      return nil unless status.success?
      result = stdout.scrub.strip
      (result == "HEAD") ? nil : result
    end

    # @param path [String] worktree path
    # @return [Boolean] true if a worktree exists at the given path
    def worktree_exists?(path)
      stdout, _ = Open3.capture3("git", "-C", path, "worktree", "list", "--porcelain")
      stdout.each_line.any? { |line| line.chomp == "worktree #{path}" }
    end

    # Lists every worktree of the repository containing +repo+, including the
    # main one.
    #
    # @param repo [String] path to any directory inside the repo (defaults to Dir.pwd)
    # @return [Array<String>] absolute worktree paths; a bare repository's own
    #   entry is not a worktree and is left out
    def list_worktrees(repo: Dir.pwd)
      stdout, _ = capture_git("-C", repo, "worktree", "list", "--porcelain")
      stdout.split(/\n\n+/).filter_map do |block|
        lines = block.lines.map(&:strip)
        next if lines.include?("bare")
        lines.find { |line| line.start_with?("worktree ") }&.delete_prefix("worktree ")
      end
    end

    # @param repo [String] path to any directory inside the repo (defaults to Dir.pwd)
    # @return [Array<String>] the branch each worktree has checked out, the main one included; a detached one has none
    def worktree_branches(repo: Dir.pwd)
      stdout, _ = capture_git("-C", repo, "worktree", "list", "--porcelain")
      stdout.each_line.filter_map { |line| line.strip.delete_prefix("branch refs/heads/") if line.start_with?("branch refs/heads/") }
    end

    # Returns the worktree path for a branch, if one exists anywhere.
    #
    # @param branch_name [String] the branch name to search for
    # @param repo [String] path to any directory inside the owning repo (defaults to Dir.pwd)
    # @return [String, nil] the worktree path or nil if no worktree exists for that branch
    def find_worktree_by_branch(branch_name, repo: Dir.pwd)
      stdout, _ = Open3.capture3("git", "-C", repo, "worktree", "list", "--porcelain")
      current_path = nil
      stdout.each_line do |line|
        if line.start_with?("worktree ")
          current_path = line.sub("worktree ", "").strip
        elsif line.strip == "branch refs/heads/#{branch_name}"
          return current_path
        end
      end
      nil
    end

    # @param name [String] input to sanitize
    # @return [String] filesystem-safe version of the name
    def sanitize_for_filesystem(name)
      name.gsub(%r{[/\\:*?"<>|]}, "-").gsub(/-{2,}/, "-").gsub(/^-|-$/, "")
    end

    # @param input [String] user input (JIRA URL, PR URL, +#n+ or +owner/repo#n+ PR ref, JIRA key, or branch name)
    # @return [Hash] parsed result with :type and :value keys; a +:pr_url+ or +:issue_url+ result also has
    #   +:repo+ (+"owner/repo"+, or nil for a bare +#n+) and +:number+
    def parse_start_input(input)
      if input.match?(%r{https?://.*atlassian\.net/browse/([A-Z]+-\d+)})
        key = input.match(%r{/browse/([A-Z]+-\d+)})[1]
        return {type: :jira_key, value: key}
      end

      if (match = input.match(%r{https?://github\.com/([^/]+/[^/]+)/pull/(\d+)}))
        return {type: :pr_url, value: input, repo: match[1], number: match[2]}
      end

      if (match = input.match(/\A([\w.-]+\/[\w.-]+)?#(\d+)\z/))
        return {type: :pr_url, value: input, repo: match[1], number: match[2]}
      end

      if (match = input.match(%r{https?://github\.com/.+/.+/issues/(\d+)}))
        repo = input.match(%r{https?://github\.com/([^/]+/[^/]+)/issues/})&.[](1)
        return {type: :issue_url, value: "issue-#{match[1]}", repo: repo, number: match[1]}
      end

      if input.match?(/\A[A-Z]+-\d+\z/)
        return {type: :jira_key, value: input}
      end

      {type: :branch, value: input}
    end

    # Checks a pull request out into a new worktree with `gh pr checkout`, which
    # fetches the PR's own head, so it works for PRs from forks as well as
    # same-repo branches.
    #
    # @param path [String] directory for the new worktree
    # @param number [String] pull request number
    # @param repo [String, nil] "owner/repo" the PR belongs to; nil lets gh use the repo in +chdir+
    # @param branch [String] local branch name for the checkout
    # @param chdir [String] directory gh runs in (the repo the worktree is added to)
    # @param quiet [Boolean] suppress the echoed command
    # @return [void] (gh never prompts: GH_PROMPT_DISABLED is set)
    # @raise [Workspace::Error] if gh is missing, too old for `--worktree`, or the checkout fails
    def checkout_pr_worktree(path, number:, repo:, branch:, chdir:, quiet: false)
      cmd = ["gh", "pr", "checkout", number]
      cmd += ["--repo", repo] if repo
      cmd += ["--worktree", path, "--branch", branch]

      @logger.debug { "git: #{cmd.join(" ")} (in #{chdir})" }
      @output.puts "Running: #{cmd.join(" ")}" unless quiet
      begin
        _, stderr, status = Open3.capture3({"GH_PROMPT_DISABLED" => "1"}, *cmd, chdir: chdir)
      rescue Errno::ENOENT
        raise Workspace::Error, "`gh` is not installed, but is required to check out a PR. " \
          "Install it, or pass the branch name directly instead of the PR."
      end
      return if status.success?

      if stderr.include?("unknown flag: --worktree")
        raise Workspace::Error, "Your `gh` is too old: it has no `gh pr checkout --worktree`. " \
          "Upgrade it (brew upgrade gh)."
      end
      raise Workspace::Error, "Could not check out PR ##{number}#{" from #{repo}" if repo}\n#{stderr.strip}\n" \
        "Make sure you have access and `gh` is authenticated."
    end

    # @param matches [Array<String>] matching branch names
    # @param pattern [String] the original search pattern
    # @return [String, nil] the selected branch or nil if user chose "none"
    def prompt_branch_selection(matches, pattern)
      @output.puts ""
      @output.puts "Multiple remote branches match '#{pattern}':"
      @output.puts ""
      matches.each_with_index do |branch, i|
        @output.puts "  #{i + 1}) #{branch}"
      end
      @output.puts "  0) None — create a new branch instead"
      @output.puts ""
      choice = Prompt.ask(@input, @output, "Choose [1-#{matches.size}, 0]: ")&.strip&.to_i
      if choice && choice > 0 && choice <= matches.size
        matches[choice - 1]
      end
    end

    # @return [String, nil] the chosen base branch or nil if cancelled
    def prompt_base_branch
      db = default_branch
      cur = current_branch

      if cur == db
        return db
      end

      @output.puts ""
      @output.puts "Branch does not exist. Create from:"
      @output.puts ""
      @output.puts "  1) #{db} (default branch)"
      @output.puts "  2) #{cur} (current branch)"
      @output.puts "  3) Cancel"
      @output.puts ""
      choice = Prompt.ask(@input, @output, "Choose [1/2/3]: ")&.strip
      case choice
      when "1", ""
        db
      when "2"
        cur
      end
    end

    # @param path [String] worktree directory path
    # @return [Integer, nil] count of changed tracked files (staged or
    #   unstaged); untracked files are never counted, or nil if git could not answer
    def changed_files_count(path)
      stdout, _, status = capture_git("-C", path, "status", "--porcelain", "--untracked-files=no")
      return nil unless status.success?
      stdout.lines.count { |l| !l.strip.empty? }
    end

    # @param path [String] worktree directory path
    # @return [Boolean, nil] true if the repository has any remotes, or nil if
    #   git could not answer
    def remotes?(path)
      stdout, _, status = capture_git("-C", path, "remote")
      return nil unless status.success?
      !stdout.strip.empty?
    end

    # Counts commits reachable from the worktree's HEAD that are not pushed
    # anywhere: not reachable from any remote-tracking ref, or (when the
    # repository has no remotes) not reachable from any other local branch.
    #
    # @param path [String] worktree directory path
    # @return [Integer, nil] unpushed commit count, or nil if git could not answer
    def unpushed_commit_count(path)
      has_remotes = remotes?(path)
      return nil if has_remotes.nil?

      if has_remotes
        stdout, _, status = capture_git("-C", path, "rev-list", "--count", "HEAD", "--not", "--remotes")
      else
        # --exclude takes the name without refs/heads/ when it applies to --branches.
        exclude = (branch = worktree_branch(path)) ? ["--exclude=#{branch}"] : []
        stdout, _, status = capture_git("-C", path, "rev-list", "--count", "HEAD", "--not", *exclude, "--branches")
      end
      return nil unless status.success?
      stdout.strip.to_i
    rescue SystemCallError
      nil
    end

    # Checks whether a worktree has unsaved work: uncommitted changes to
    # tracked files (untracked files don't count), or commits not pushed anywhere.
    # A worktree whose directory no longer exists has nothing to check for
    # (git can't answer for a path that isn't there) and is treated as having
    # no unsaved work.
    #
    # @param path [String] worktree directory path
    # @return [Hash, Symbol, nil] nil if there is nothing unsaved, :unknown if
    #   git could not answer, or a hash with :changed_files, :unpushed_commits,
    #   and :branch when there is unsaved work
    def unsaved_work(path)
      return nil unless File.directory?(path)

      changed = changed_files_count(path)
      return :unknown if changed.nil?

      unpushed = unpushed_commit_count(path)
      return :unknown if unpushed.nil?

      return nil if changed.zero? && unpushed.zero?

      {changed_files: changed, unpushed_commits: unpushed, branch: worktree_branch(path)}
    end

    # @param path [String] worktree directory path
    # @return [String, nil] the upstream branch's full name (e.g. "origin/main"),
    #   or nil if there is none
    def upstream_branch(path)
      stdout, _, status = capture_git("-C", path, "rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{u}")
      status.success? ? stdout.strip : nil
    end

    # The upstream a branch is configured with, whether or not its remote branch still exists.
    #
    # @param path [String] the checkout
    # @param branch [String]
    # @return [Array(String, String), nil] the remote name (or ".") and the full ref on it
    #   (`refs/heads/x`), or nil when the branch has no upstream configured
    def upstream_config(path, branch)
      remote, _, remote_status = capture_git("-C", path, "config", "--get", "branch.#{branch}.remote")
      merge, _, merge_status = capture_git("-C", path, "config", "--get", "branch.#{branch}.merge")
      return nil unless remote_status.success? && merge_status.success?

      [remote.strip, merge.strip]
    end

    # @param path [String] worktree directory path
    # @return [Integer, nil] number of commits on HEAD not in its upstream, or
    #   nil if there is no upstream or git could not answer
    def commits_ahead_of_upstream(path)
      stdout, _, status = capture_git("-C", path, "rev-list", "--count", "@{u}..HEAD")
      status.success? ? stdout.strip.to_i : nil
    end

    # The ref a checkout is measured against for review: the remote default
    # branch (`origin/HEAD`), else the first of `origin/main`, `main`,
    # `origin/master`, `master` that exists.
    #
    # @param path [String] worktree directory path
    # @return [String, nil] a ref name such as "origin/main", or nil when none exists
    def base_ref(path)
      stdout, _, status = capture_git("-C", path, "symbolic-ref", "--quiet", "--short", "refs/remotes/origin/HEAD")
      head = stdout.scrub.strip
      return head if status.success? && !head.empty? && ref_exists?(path, head)
      %w[origin/main main origin/master master].find { |ref| ref_exists?(path, ref) }
    end

    # @param path [String] worktree directory path
    # @param base [String] a ref, see {#base_ref}
    # @return [Integer, nil] commits on HEAD that are not on +base+, or nil if git could not answer
    def commits_ahead_of(path, base)
      stdout, _, status = capture_git("-C", path, "rev-list", "--count", "#{base}..HEAD")
      status.success? ? stdout.strip.to_i : nil
    end

    # @param path [String] worktree directory path
    # @param base [String] a ref, see {#base_ref}
    # @param limit [Integer] most commits returned
    # @return [Array<Hash>, nil] newest first, each `{"sha" =>, "subject" =>}`, or nil if git could not answer
    def commits_since(path, base, limit:)
      stdout, _, status = capture_git("-C", path, "log", "--no-color", "--format=%h%x09%s", "-n", limit.to_s, "#{base}..HEAD")
      return nil unless status.success?
      stdout.scrub.lines.map { |line| line.chomp.split("\t", 2) }.map { |sha, subject| {"sha" => sha, "subject" => subject.to_s} }
    end

    # Per-file changes from the merge base of +base+ and HEAD to HEAD (what a
    # pull request shows). Committed work only.
    #
    # @param path [String] worktree directory path
    # @param base [String] a ref, see {#base_ref}
    # @return [Array<Hash>, nil] `{"path" =>, "added" =>, "removed" =>}` per file, the counts nil for a
    #   binary file; nil if git could not answer
    def diff_stat(path, base)
      stdout, _, status = capture_git("-C", path, "diff", "--numstat", "--no-renames", "-z", "#{base}...HEAD")
      return nil unless status.success?
      stdout.scrub.split("\0").filter_map do |entry|
        added, removed, file = entry.split("\t", 3)
        next unless file
        {"path" => file, "added" => count_or_nil(added), "removed" => count_or_nil(removed)}
      end
    end

    # Removes a worktree, untracked files included. Unless force is set, it
    # first re-checks for unsaved work (see #unsaved_work) and refuses, so the
    # check sits right next to the removal rather than minutes before it.
    #
    # @param path [String] worktree path
    # @param force [Boolean] skip workspace's own unsaved-work re-check; git's
    #   own `--force` is passed to `worktree remove` either way
    # @return [void]
    # @raise [Workspace::UnsavedWorkError] if force is false and the worktree has
    #   unsaved work, or git couldn't tell
    # @raise [Workspace::Error] if worktree removal fails
    def remove_worktree(path, force: false)
      unless force
        unsaved = unsaved_work(path)
        if unsaved
          raise UnsavedWorkError.new("Not removing #{path}: #{UnsavedWorkError.describe(unsaved)}.", unsaved: unsaved)
        end
      end

      cmd = ["git", "-C", path, "worktree", "remove", "--force", path]

      @logger.debug { "git: #{cmd.join(" ")}" }
      _, stderr, status = Open3.capture3(*cmd)
      unless status.success?
        raise Workspace::Error, "Error removing worktree: #{stderr.strip}"
      end
    end

    # @param path [String] worktree path
    # @param branch [String] branch name
    # @param base [String, nil] base branch for new branch creation
    # @return [void]
    # @raise [Workspace::Error] if worktree creation fails
    # @note A branch that exists only on origin is created locally tracking
    #   +origin/<branch>+.
    def create_worktree(path, branch, base: nil, quiet: false)
      cmd = ["git", "worktree", "add"]
      if local_branch_exists?(branch)
        cmd += [path, branch]
      elsif remote_branch_exists?(branch)
        # Named outright: git only guesses the upstream when exactly one remote
        # has the branch, and refuses the checkout when several do.
        cmd += ["--track", "-b", branch, path, "origin/#{branch}"]
      else
        cmd += ["-b", branch, path]
        cmd << base if base
      end

      @logger.debug { "git: #{cmd.join(" ")}" }
      @output.puts "Running: #{cmd.join(" ")}" unless quiet
      _, stderr, status = Open3.capture3(*cmd)
      unless status.success?
        raise Workspace::Error, "Error creating worktree: #{stderr}"
      end
    end

    private

    # Runs git in +path+ through the runner, turning a missing git and a
    # timeout into errors.
    def run_git(path, *args, timeout:)
      @runner.call(["git", *args], chdir: path, timeout: timeout)
    rescue Errno::ENOENT
      raise Workspace::Error, "git is not installed."
    rescue Timeout::Error
      raise Workspace::Error, "git #{args.first} did not finish within #{timeout} seconds."
    end

    def ref_exists?(path, ref)
      _, _, status = capture_git("-C", path, "rev-parse", "--verify", "--quiet", "#{ref}^{commit}")
      status.success?
    end

    # numstat prints "-" for a binary file.
    def count_or_nil(text)
      text.match?(/\A\d+\z/) ? text.to_i : nil
    end

    def layout_from_git_file(dir, dot_git)
      gitdir = File.read(dot_git)[/\Agitdir:\s*(.+?)\s*\z/, 1]
      return layout_from_rev_parse(dir) unless gitdir
      gitdir = File.expand_path(gitdir, dir)
      return {toplevel: dir, common_dir: nil, linked: true, broken: true} unless File.directory?(gitdir)
      commondir_file = File.join(gitdir, "commondir")
      if File.file?(commondir_file)
        common = File.expand_path(File.read(commondir_file).strip, gitdir)
        {toplevel: dir, common_dir: common, linked: true}
      else
        {toplevel: dir, common_dir: gitdir, linked: false}
      end
    rescue SystemCallError
      layout_from_rev_parse(dir)
    end

    # Runs git in a process group of its own and, if the calling thread is
    # killed while waiting (a read that ran out of time), stops that group:
    # SIGTERM, then SIGKILL after a second.
    #
    # @return [Array(String, String, Process::Status)] stdout, stderr, status
    def capture_git(*args)
      Open3.popen3("git", *args, pgroup: true) do |stdin, stdout, stderr, waiter|
        stdin.close
        errors = Thread.new { stderr.read }
        begin
          [stdout.read, errors.value, waiter.value]
        ensure
          stop_group(waiter) if waiter.alive?
        end
      end
    end

    def stop_group(waiter)
      Process.kill("TERM", -waiter.pid)
      Process.kill("KILL", -waiter.pid) unless waiter.join(1)
    rescue Errno::ESRCH, Errno::EPERM
      nil
    end

    def layout_from_rev_parse(dir)
      stdout, _, status = capture_git("-C", dir, "rev-parse", "--show-toplevel", "--git-common-dir", "--absolute-git-dir")
      return nil unless status.success?
      toplevel, common, git_dir = stdout.lines.map(&:strip)
      return nil unless toplevel && common && git_dir
      common = File.expand_path(common, dir)
      {toplevel: toplevel, common_dir: common, linked: File.realpath(common) != File.realpath(git_dir)}
    rescue SystemCallError
      nil
    end
  end
end
