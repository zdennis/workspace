require "open3"

module Workspace
  # Git and worktree operations for the workspace CLI.
  class Git
    # @param output [IO] output stream for user-facing messages
    # @param input [IO] input stream for interactive prompts
    def initialize(output: $stdout, input: $stdin)
      @output = output
      @input = input
    end

    # @return [String, nil] the root of the current git repository
    def root
      result = `git rev-parse --show-toplevel 2>/dev/null`.strip
      result.empty? ? nil : result
    end

    # @return [String] the default branch name (main or master)
    def default_branch
      ref = `git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null`.strip
      return ref.sub("refs/remotes/origin/", "") unless ref.empty?
      `git rev-parse --verify --quiet refs/heads/main >/dev/null 2>&1 && echo main || echo master`.strip
    end

    # @return [String] the current branch name
    def current_branch
      `git rev-parse --abbrev-ref HEAD 2>/dev/null`.strip
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
      `git fetch --prune 2>/dev/null`
      `git branch -r 2>/dev/null`.lines.map { |l| l.strip.sub("origin/", "") }.reject { |b| b.include?("->") }
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

    # @param path [String] worktree path
    # @return [Boolean] true if a worktree exists at the given path
    def worktree_exists?(path)
      worktrees = `git worktree list --porcelain 2>/dev/null`
      worktrees.include?("worktree #{path}")
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

      output = `gh pr view #{pr_number} --repo #{repo} --json headRefName --jq .headRefName 2>/dev/null`.strip
      if output.empty?
        raise Workspace::Error, "Could not fetch PR ##{pr_number} from #{repo}. Make sure you have access and `gh` is authenticated."
      end
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

    # @param path [String] worktree path
    # @param branch [String] branch name
    # @param base [String, nil] base branch for new branch creation
    # @return [void]
    # @raise [Workspace::Error] if worktree creation fails
    def create_worktree(path, branch, base: nil)
      cmd = ["git", "worktree", "add"]
      if branch_exists?(branch)
        cmd += [path, branch]
      else
        cmd += ["-b", branch, path]
        cmd << base if base
      end

      @output.puts "Running: #{cmd.join(" ")}"
      _, stderr, status = Open3.capture3(*cmd)
      unless status.success?
        raise Workspace::Error, "Error creating worktree: #{stderr}"
      end
    end
  end
end
