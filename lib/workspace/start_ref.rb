module Workspace
  # What `start` and `ticket show` make of a ref: a JIRA key or URL, a pull
  # request URL or `#n`, an issue URL, or a branch name. Reads the input and
  # picks the branch `start` would work on and the project it would work in; it
  # creates nothing and runs no tool of its own.
  class StartRef
    # The resolved ref.
    #
    # @!attribute input [String] the ref as given
    # @!attribute parsed [Hash] {Git#parse_start_input}'s answer
    # @!attribute kind [String] "jira", "github_pr", "github_issue" or "branch"
    # @!attribute key [String] the ticket's own name: the JIRA key, `owner/repo#41` (`#41` with no repository), or the branch
    # @!attribute branch [String] the branch `start` works on: `pr-<n>` for a pull request, `issue-<n>` for an issue, else the input's value
    # @!attribute pr [Hash, nil] the parsed result when the ref is a pull request, which `start` checks out with gh
    Ref = Struct.new(:input, :parsed, :kind, :key, :branch, :pr, keyword_init: true)

    # The project a checkout belongs to.
    #
    # @!attribute root [String] the repository's root directory (the parent's, from inside a linked worktree)
    # @!attribute name [String] the project's name
    # @!attribute from_worktree [Boolean] whether the checkout was a linked worktree, so +root+ is its parent's
    Project = Struct.new(:root, :name, :from_worktree, keyword_init: true)

    # @param git [Workspace::Git] reads the input
    # @param lineage [Workspace::WorkspaceLineage] finds the parent repository of a linked worktree
    def initialize(git:, lineage: WorkspaceLineage.new)
      @git = git
      @lineage = lineage
    end

    # @param input [String] JIRA key or URL, pull request URL or ref, issue URL, or branch name
    # @return [Ref]
    def call(input)
      parsed = @git.parse_start_input(input)
      case parsed[:type]
      when :pr_url
        Ref.new(input: input, parsed: parsed, kind: "github_pr", key: github_key(parsed[:repo], parsed[:number]),
          branch: "pr-#{parsed[:number]}", pr: parsed)
      when :issue_url
        number = parsed[:number] || parsed[:value][/\d+/]
        Ref.new(input: input, parsed: parsed, kind: "github_issue", key: github_key(parsed[:repo], number), branch: parsed[:value])
      when :jira_key
        Ref.new(input: input, parsed: parsed, kind: "jira", key: parsed[:value], branch: parsed[:value])
      else
        Ref.new(input: input, parsed: parsed, kind: "branch", key: parsed[:value], branch: parsed[:value])
      end
    end

    # The project a worktree for the ref would be added to. Run from inside a
    # linked worktree, that is the parent repository, not the worktree.
    #
    # @param root [String] the git toplevel the command was run from
    # @return [Project]
    def project(root)
      info = @lineage.resolve(cwd: root)
      if parent_repo?(root, info)
        Project.new(root: info.path, name: info.name, from_worktree: true)
      else
        Project.new(root: root, name: WorkspaceLineage.name_from_path(root), from_worktree: false)
      end
    end

    private

    def github_key(repo, number)
      "#{repo}##{number}"
    end

    # A lineage result is only trusted when git's own common dir confirms it:
    # the common dir must be a normal ".git" directory (a bare repo's common
    # dir is the bare repo itself, whose parent directory is not a checkout),
    # and it must resolve somewhere other than cwd's own toplevel (a marker
    # found above a standalone repo nested inside a worktree would otherwise
    # claim a parent the repo's own git does not).
    def parent_repo?(root, info)
      info.is_worktree &&
        info.git_common_dir && File.basename(info.git_common_dir) == ".git" &&
        File.expand_path(info.path) != File.expand_path(root)
    end
  end
end
