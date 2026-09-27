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

    # Returns the current branch name for a worktree directory.
    # Returns nil if the HEAD is detached or an error occurs.
    #
    # @param path [String] worktree directory path
    # @return [String, nil] the branch name, or nil if detached or error
    def worktree_branch(path)
      stdout, _, status = Open3.capture3("git", "-C", path, "rev-parse", "--abbrev-ref", "HEAD")
      return nil unless status.success?
      result = stdout.strip
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
    # @return [Array<String>] absolute worktree paths
    def list_worktrees(repo: Dir.pwd)
      stdout, _ = Open3.capture3("git", "-C", repo, "worktree", "list", "--porcelain")
      stdout.lines.select { |line| line.start_with?("worktree ") }.map { |line| line.sub("worktree ", "").strip }
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

    # @param input [String] user input (JIRA URL, PR URL, JIRA key, or branch name)
    # @return [Hash] parsed result with :type and :value keys
    def parse_start_input(input)
      if input.match?(%r{https?://.*atlassian\.net/browse/([A-Z]+-\d+)})
        key = input.match(%r{/browse/([A-Z]+-\d+)})[1]
        return {type: :jira_key, value: key}
      end

      if input.match?(%r{https?://github\.com/.+/.+/pull/\d+})
        return {type: :pr_url, value: input}
      end

      if (match = input.match(%r{https?://github\.com/.+/.+/issues/(\d+)}))
        return {type: :issue_url, value: "issue-#{match[1]}"}
      end

      if input.match?(/\A[A-Z]+-\d+\z/)
        return {type: :jira_key, value: input}
      end

      {type: :branch, value: input}
    end

    # @param pr_url [String] GitHub pull request URL
    # @return [String] the head branch name
    # @raise [Workspace::Error] if the PR URL cannot be parsed or fetched
    def resolve_branch_from_pr(pr_url)
      match = pr_url.match(%r{github\.com/([^/]+/[^/]+)/pull/(\d+)})
      unless match
        raise Workspace::Error, "Could not parse PR URL: #{pr_url}"
      end
      repo = match[1]
      pr_number = match[2]

      @logger.debug { "git: fetching PR ##{pr_number} from #{repo} via gh" }
      begin
        stdout, _, status = Open3.capture3("gh", "pr", "view", pr_number, "--repo", repo, "--json", "headRefName", "--jq", ".headRefName")
      rescue Errno::ENOENT
        raise Workspace::Error, "`gh` is not installed, but is required to resolve a PR URL. " \
          "Install it, or pass the branch name directly instead of the PR URL."
      end
      output = status.success? ? stdout.strip : ""
      if output.empty?
        raise Workspace::Error, "Could not fetch PR ##{pr_number} from #{repo}\nMake sure you have access and `gh` is authenticated."
      end
      @logger.debug { "git: PR branch resolved to #{output}" }
      output
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
      @output.print "Choose [1-#{matches.size}, 0]: "
      choice = @input.gets&.strip&.to_i
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
      @output.print "Choose [1/2/3]: "
      choice = @input.gets&.strip
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
      stdout, _, status = Open3.capture3("git", "-C", path, "status", "--porcelain", "--untracked-files=no")
      return nil unless status.success?
      stdout.lines.count { |l| !l.strip.empty? }
    end

    # @param path [String] worktree directory path
    # @return [Boolean, nil] true if the repository has any remotes, or nil if
    #   git could not answer
    def remotes?(path)
      stdout, _, status = Open3.capture3("git", "-C", path, "remote")
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
        stdout, _, status = Open3.capture3("git", "-C", path, "rev-list", "--count", "HEAD", "--not", "--remotes")
      else
        # --exclude takes the name without refs/heads/ when it applies to --branches.
        exclude = (branch = worktree_branch(path)) ? ["--exclude=#{branch}"] : []
        stdout, _, status = Open3.capture3("git", "-C", path, "rev-list", "--count", "HEAD", "--not", *exclude, "--branches")
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
      stdout, _, status = Open3.capture3("git", "-C", path, "rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{u}")
      status.success? ? stdout.strip : nil
    end

    # @param path [String] worktree directory path
    # @return [Integer, nil] number of commits on HEAD not in its upstream, or
    #   nil if there is no upstream or git could not answer
    def commits_ahead_of_upstream(path)
      stdout, _, status = Open3.capture3("git", "-C", path, "rev-list", "--count", "@{u}..HEAD")
      status.success? ? stdout.strip.to_i : nil
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
  end
end
