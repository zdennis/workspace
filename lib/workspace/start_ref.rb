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
    # @!attribute branch [String] the branch `start` works on: `pr-<n>` for a pull request, `issue-<n>` for an issue, the key as written (or the existing branch it matches without case) for a JIRA ref, else the input's value
    # @!attribute pr [Hash, nil] the parsed result when the ref is a pull request, which `start` checks out with gh
    Ref = Struct.new(:input, :parsed, :kind, :key, :branch, :pr, keyword_init: true)

    # The project a checkout belongs to.
    #
    # @!attribute root [String] the repository's root directory (the parent's, from inside a linked worktree)
    # @!attribute name [String] the project's name
    # @!attribute from_worktree [Boolean] whether the checkout was a linked worktree, so +root+ is its parent's
    Project = Struct.new(:root, :name, :from_worktree, keyword_init: true)

    # The branch names a JIRA key is matched against.
    #
    # @!attribute local [Array<String>] local branch names
    # @!attribute all [Array<String>] local and origin branch names
    BranchNames = Struct.new(:local, :all, keyword_init: true)

    # No branches at all: a JIRA key then gets a branch named after the key as written, whatever the current directory holds.
    BranchNames::NONE = BranchNames.new(local: [].freeze, all: [].freeze).freeze

    # The kind of each type {Git#parse_start_input} answers; any other type is a "branch".
    KINDS = {pr_url: "github_pr", issue_url: "github_issue", jira_key: "jira"}.freeze

    # @param git [Workspace::Git] reads the input
    # @param lineage [Workspace::WorkspaceLineage] finds the parent repository of a linked worktree
    def initialize(git:, lineage:)
      @git = git
      @lineage = lineage
    end

    # @param input [String] JIRA key or URL, pull request URL or ref, issue URL, or branch name
    # @param root [String, nil] a checkout of the repository whose branches a JIRA key is matched against; nil means the current directory's
    # @param names [BranchNames, nil] the branch names, when the caller already has them; +root+ is ignored then
    # @return [Ref]
    def call(input, root: nil, names: nil)
      parsed = @git.parse_start_input(input)
      case KINDS.fetch(parsed[:type], "branch")
      when "github_pr"
        Ref.new(input: input, parsed: parsed, kind: "github_pr", key: github_key(parsed[:repo], parsed[:number]),
          branch: "pr-#{parsed[:number]}", pr: parsed)
      when "github_issue"
        number = parsed[:number] || parsed[:value][/\d+/]
        Ref.new(input: input, parsed: parsed, kind: "github_issue", key: github_key(parsed[:repo], number), branch: parsed[:value])
      when "jira"
        Ref.new(input: input, parsed: parsed, kind: "jira", key: parsed[:value],
          branch: jira_branch(parsed[:value], root, names))
      else
        Ref.new(input: input, parsed: parsed, kind: "branch", key: parsed[:value], branch: parsed[:value])
      end
    end

    # The kind of a ref, from parsing alone: no git is run and no branches are read.
    #
    # @param input [String]
    # @return [String] "jira", "github_pr", "github_issue" or "branch"
    def kind(input)
      KINDS.fetch(@git.parse_start_input(input)[:type], "branch")
    end

    # The longest slug, in characters.
    SLUG_MAX = 40

    # A title as a branch-name suffix: lowercase ASCII letters and digits joined
    # by single hyphens, cut at a word boundary, so any title gives a valid git ref.
    #
    # @param title [String, nil]
    # @return [String] empty when the title has no letters or digits
    def self.slug(title)
      text = title.to_s.scrub("").unicode_normalize(:nfkd).gsub(/\p{Mn}/, "").downcase.gsub(/[^a-z0-9]+/, "-").gsub(/\A-|-\z/, "")
      return text if text.length <= SLUG_MAX

      cut = text[0, SLUG_MAX]
      cut = cut.sub(/-[^-]*\z/, "") unless text[SLUG_MAX] == "-" || !cut.include?("-")
      cut.sub(/-\z/, "")
    end

    # Whether a branch is the ref's branch with a title's words added (`PROJ-123-fix-login` for
    # a JIRA ref whose branch is `PROJ-123`), ignoring case so a branch of either case counts.
    #
    # @param branch [String]
    # @param ref [Ref]
    # @return [Boolean]
    def slug_branch?(branch, ref)
      branch.downcase.start_with?("#{ref.branch.downcase}-")
    end

    # The ref with the title's words added to its branch (`PROJ-123-fix-login`,
    # `issue-42-fix-login`). A pull request or a plain branch, a missing title
    # and a title with no letters or digits all come back unchanged.
    #
    # @param ref [Ref]
    # @param title [String, nil]
    # @return [Ref]
    def slugged(ref, title)
      return ref unless %w[jira github_issue].include?(ref.kind)

      suffix = self.class.slug(title)
      return ref if suffix.empty?

      ref.dup.tap { |copy| copy.branch = "#{ref.branch}-#{suffix}" }
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

    # The key as written for a new branch, unless a branch that matches it without case exists, which is used by
    # its real name. Picked in order: the lowercase key among the local names, any-case match among them, the
    # lowercase key among all names, any-case match among them. A key that lowercases to `pr-<n>` or
    # `issue-<n>` keeps its case, since those names belong to pull requests and issues.
    def jira_branch(key, root, names)
      return key if key.downcase.match?(/\A(pr|issue)-\d+\z/)

      lower = key.downcase
      unless names
        root ||= @git.root
        return key unless root

        names = BranchNames.new(local: @git.local_branch_names(root), all: @git.branch_names(root))
      end
      [names.local, names.all].each do |list|
        return lower if list.include?(lower)

        match = list.select { |name| name.casecmp?(key) }.min
        return match if match
      end
      key
    end

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
