require "open3"

module Workspace
  # Resolves a workspace's parent project: the main checkout a worktree
  # belongs to, or the workspace's own project when it is not a worktree.
  #
  # This is the single resolver behind locks, `dev`, `config set`, and the
  # `parent` subcommand, so they can never disagree about parentage.
  #
  # Resolution order:
  #   1. The `.workspace-project` marker, walking up from cwd, split on
  #      `.worktree-` (written by Commands::Start via {#write_marker}) --
  #      unless git's own --git-dir/--git-common-dir comparison says cwd is
  #      definitely not a worktree, in which case the marker is stale and
  #      is ignored.
  #   2. `git rev-parse --git-common-dir`; its parent directory is the main
  #      checkout, named via {ProjectConfig.name_from_path}. Inside a git
  #      submodule, --git-common-dir resolves under the superproject's
  #      `.git/modules/<name>`, so the name is instead derived from the
  #      submodule's own `--show-toplevel`.
  #   3. {ProjectConfig.name_from_path} on cwd itself, for non-git projects.
  class WorkspaceLineage
    MARKER_FILE = ".workspace-project"
    WORKTREE_SEPARATOR = ".worktree-"

    # Splits a worktree config name into [parent_name, worktree_suffix], or
    # returns nil if the name isn't a worktree config.
    #
    # @param config_name [String] a project or worktree config name
    # @return [Array(String, String), nil]
    def self.split_worktree_name(config_name)
      return nil unless config_name&.include?(WORKTREE_SEPARATOR)
      config_name.split(WORKTREE_SEPARATOR, 2)
    end

    # Result of {#resolve}.
    #
    # @!attribute name [String] the parent project's name
    # @!attribute path [String] the parent project's root directory
    # @!attribute git_common_dir [String, nil] absolute path to the shared `.git` dir
    # @!attribute is_worktree [Boolean] whether cwd is inside a linked worktree
    # @!attribute worktree [String, nil] the worktree's own config name, if any
    Lineage = Struct.new(:name, :path, :git_common_dir, :is_worktree, :worktree, keyword_init: true)

    # @param cwd [String] directory to resolve lineage from
    # @return [Lineage]
    def resolve(cwd: Dir.pwd)
      cwd = File.expand_path(cwd)
      common_dir = git_common_dir(cwd)
      is_worktree = worktree?(cwd, common_dir)
      marker_dir, marker = find_marker(cwd)

      if marker && (split = self.class.split_worktree_name(marker)) && !stale_marker?(marker_dir)
        name, worktree = split[0], marker
        is_worktree = true
      elsif common_dir
        name = ProjectConfig.name_from_path(submodule_toplevel(cwd, common_dir) || File.dirname(common_dir))
        worktree = nil
      else
        name = ProjectConfig.name_from_path(cwd)
        worktree = nil
      end

      path = common_dir ? File.dirname(common_dir) : cwd

      Lineage.new(name: name, path: path, git_common_dir: common_dir, is_worktree: is_worktree, worktree: worktree)
    end

    # Writes the marker read back by {#resolve} and {#find_marker}.
    #
    # @param worktree_path [String] the worktree's root directory
    # @param config_name [String] the worktree's own config name
    # @return [void]
    def write_marker(worktree_path, config_name)
      return unless File.directory?(worktree_path)
      File.write(File.join(worktree_path, MARKER_FILE), config_name)
    end

    private

    def worktree?(cwd, common_dir)
      return false unless common_dir
      git_dir = git_rev_parse(cwd, "--git-dir")
      return false unless git_dir
      File.realpath(absolute(git_dir, cwd)) != File.realpath(common_dir)
    rescue Errno::ENOENT
      false
    end

    def git_common_dir(cwd)
      path = git_rev_parse(cwd, "--git-common-dir")
      path ? absolute(path, cwd) : nil
    end

    def git_rev_parse(cwd, arg)
      stdout, _, status = Open3.capture3("git", "-C", cwd, "rev-parse", arg)
      return nil unless status.success?
      stdout.strip
    rescue Errno::ENOENT
      nil
    end

    # A submodule's --git-common-dir lives under the superproject's
    # `.git/modules/<name>`, so naming from its dirname yields "modules".
    # Detect that case and use the submodule's own toplevel directory instead.
    def submodule_toplevel(cwd, common_dir)
      return nil unless common_dir.include?(File.join(".git", "modules") + File::SEPARATOR) ||
        common_dir.end_with?(File.join(".git", "modules"))
      toplevel = git_rev_parse(cwd, "--show-toplevel")
      toplevel ? absolute(toplevel, cwd) : nil
    end

    def absolute(path, cwd)
      File.absolute_path?(path) ? path : File.join(cwd, path)
    end

    # A marker is stale when it sits at the root of its own standalone git
    # repo (has its own `.git`, and git says --git-dir == --git-common-dir
    # there) — i.e. git itself considers that directory a plain checkout,
    # not a worktree, contradicting the marker's worktree claim. A marker
    # inside a plain subdirectory (no `.git` of its own) carries no such
    # ground truth to contradict, so it stays trusted.
    def stale_marker?(marker_dir)
      return false unless marker_dir && File.exist?(File.join(marker_dir, ".git"))
      marker_common_dir = git_common_dir(marker_dir)
      return false unless marker_common_dir
      !worktree?(marker_dir, marker_common_dir)
    end

    def find_marker(cwd)
      dir = cwd
      loop do
        marker_path = File.join(dir, MARKER_FILE)
        return [dir, File.read(marker_path).strip] if File.exist?(marker_path)
        parent = File.dirname(dir)
        break if parent == dir
        dir = parent
      end
      [nil, nil]
    end
  end
end
