# frozen_string_literal: true

module Workspace
  # Compares branch names after following symrefs, without case, because neither a symref nor a
  # case alias is a branch of its own: on macOS `git checkout MAIN` leaves HEAD at
  # `refs/heads/MAIN`, and the commits of either land on `main`. {#call} says whether a branch is
  # the default branch or the main checkout's; {#same?} is the comparison alone.
  class ProtectedBranch
    # @param git [Workspace::Git]
    def initialize(git:)
      @git = git
    end

    # @param branch [String, nil]
    # @param project [#root] the project whose main checkout and default branch count
    # @return [Hash, nil] +reason+ and +path+, the checkout that holds the branch (nil when none does); nil when the branch is not protected
    def call(branch, project)
      return nil if branch.nil?

      name = resolved(branch, project)
      default = same_name?(name, resolved(@git.default_branch_name(project.root), project))
      main_checkout = same_name?(name, resolved(@git.worktree_branch(project.root), project))
      return nil unless default || main_checkout

      {reason: default ? "default_branch" : "main_checkout",
       path: main_checkout ? project.root : @git.find_worktree_by_branch(name, repo: project.root)}
    end

    # @return [Boolean] whether two names are the same branch once symrefs are followed, without case
    def same?(branch, other, project)
      same_name?(resolved(branch, project), resolved(other, project))
    end

    private

    def resolved(branch, project)
      branch && @git.branch_target(project.root, branch)
    end

    def same_name?(branch, other)
      !other.nil? && branch.casecmp?(other)
    end
  end
end
