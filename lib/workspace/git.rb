require "open3"

module Workspace
  # Git and worktree operations for the workspace CLI.
  class Git
    # @param output [IO] output stream for user-facing messages
    # @param input [IO] input stream for interactive prompts
    # @param logger [Workspace::Logger] debug logger
    def initialize(output: $stdout, input: $stdin, logger: Workspace::Logger.new)
      @output = output
      @input = input
      @logger = logger
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
    # @return [Hash] parsed result with :type and :value keys; a +:pr_url+ result also has
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
        return {type: :issue_url, value: "issue-#{match[1]}"}
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
    def create_worktree(path, branch, base: nil, quiet: false)
      cmd = ["git", "worktree", "add"]
      if branch_exists?(branch)
        cmd += [path, branch]
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
