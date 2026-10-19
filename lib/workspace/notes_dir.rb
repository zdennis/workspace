module Workspace
  # The one resolver for where a workspace's notes go: the workspace's own
  # `notes.dir` (a worktree's own value, or the project's for a main checkout),
  # else the directory the project's `notes.default_dir` rule computes for it,
  # else, for a linked worktree, the main checkout's notes directory with the
  # worktree's branch added, else `tmp/workspace-notes` inside the checkout.
  #
  # It does not read config. Callers pass the stored values, so it works the
  # same for `config show --json` and for any command that wants the path.
  class NotesDir
    # The rule used when a project sets no `notes.default_dir`, relative to the checkout root.
    FALLBACK = "tmp/workspace-notes".freeze

    # @!attribute path [String, nil] absolute directory, nil when nothing can be computed
    # @!attribute source [String] "worktree", "project" or "default"
    Result = Struct.new(:path, :source, keyword_init: true)

    # @param git [Workspace::Git] sanitizes placeholder values and reads a checkout's branch
    # @param home [String] what `~/` expands to
    def initialize(git:, home: Dir.home)
      @git = git
      @home = home
    end

    # @param stored [String, nil] the workspace's valid `notes.dir` from the file it reads
    # @param template [String, nil] the project's valid `notes.default_dir`
    # @param worktree [Boolean] whether the workspace is a worktree
    # @param root [String, nil] the checkout root
    # @param workspace [String] the workspace name
    # @param main_dir [String, nil] the main checkout workspace's notes directory (see {#main_dir});
    #   a worktree with no rule of its own gets it with its branch added
    # @return [Result]
    def resolve(stored:, template:, worktree:, root:, workspace:, main_dir: nil)
      return Result.new(path: File.expand_path(stored), source: worktree ? "worktree" : "project") if stored
      inherited = template.nil? && worktree && inherited_path(main_dir, root)
      Result.new(path: inherited || default_path(template, root: root, workspace: workspace), source: "default")
    end

    # @param stored [String, nil] the main checkout workspace's valid `notes.dir`
    # @param root [String, nil] the main checkout's root
    # @return [String, nil] its notes directory: the stored one, else `tmp/workspace-notes` in it; nil without a root
    def main_dir(stored:, root:)
      return File.expand_path(stored) if stored
      File.expand_path(FALLBACK, root) if root
    end

    # @param template [String, nil] a `notes.default_dir` value; nil for the built-in rule
    # @param root [String, nil] the checkout root
    # @param workspace [String] the workspace name
    # @return [String, nil] the absolute directory; nil when the rule needs a root or a branch that isn't known
    def default_path(template, root:, workspace:)
      rule = template || FALLBACK
      if rule.include?("{branch}")
        branch = root && @git.worktree_branch(root)
        return nil unless branch
      end
      filled = rule
        .gsub("{workspace}") { @git.sanitize_for_filesystem(workspace) }
        .gsub("{branch}") { @git.sanitize_for_filesystem(branch) }
      if filled.start_with?("/")
        File.expand_path(filled)
      elsif filled.start_with?("~/")
        File.expand_path(filled.delete_prefix("~/"), @home)
      elsif root
        File.expand_path(filled, root)
      end
    end

    private

    def inherited_path(main_dir, root)
      branch = main_dir && root && @git.worktree_branch(root)
      name = branch && @git.sanitize_for_filesystem(branch)
      File.join(main_dir, name) if name && !name.empty?
    end
  end
end
