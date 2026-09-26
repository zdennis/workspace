require "digest/sha1"

module Workspace
  # Resolves the shared lock namespace for a working directory.
  #
  # Every worktree of one repository shares its locks: the namespace key is
  # the realpath of `git rev-parse --git-common-dir`, which is identical no
  # matter which worktree it is read from. Non-git projects fall back to the
  # project name derived from the path. Parentage itself is resolved by
  # {WorkspaceLineage}, so this class never disagrees with `dev`, `config
  # set`, or `workspace parent`.
  class LockNamespace
    # @param config [Workspace::Config] path configuration
    # @param lineage [Workspace::WorkspaceLineage] parent resolver
    def initialize(config:, lineage: WorkspaceLineage.new)
      @config = config
      @lineage = lineage
    end

    # @param cwd [String] directory to resolve the namespace from
    # @return [Hash] :key (unique namespace identity), :display (human name),
    #   :dir (this namespace's lock store directory)
    def resolve(cwd: Dir.pwd)
      info = @lineage.resolve(cwd: cwd)
      display = info.name
      # The common dir is the *original* repo's .git directory, shared by
      # every linked worktree, so its realpath is a stable namespace key no
      # matter which worktree resolve is called from.
      key = info.git_common_dir ? File.realpath(info.git_common_dir) : display
      {key: key, display: display, dir: store_dir(key, display)}
    end

    private

    def store_dir(key, display)
      slug = display.gsub(/[^A-Za-z0-9_-]+/, "-").gsub(/-{2,}/, "-").gsub(/^-|-$/, "")
      slug = "namespace" if slug.empty?
      File.join(@config.lock_dir, "#{slug}-#{Digest::SHA1.hexdigest(key)[0, 12]}")
    end
  end
end
