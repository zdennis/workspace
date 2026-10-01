module Workspace
  # Groups workspaces (tmuxinator configs) into projects.
  #
  # A project is one repository's main checkout plus its linked git worktrees.
  # A workspace is one tmuxinator config; a workspace that belongs to a
  # project is one of its members.
  #
  # Membership is decided by the realpath of the git common dir of each
  # workspace's checkout (the same key {Workspace::LockNamespace} uses), read
  # from `.git` files without running git:
  #
  # 1. The root exists and is in a git repo: keyed by its common dir.
  # 2. The root exists and isn't in git: its own single-member project, keyed
  #    by the realpath of the root, with vcs "none". A `.git` file pointing at
  #    a missing git dir (a broken checkout) is the same but with vcs "broken".
  # 3. The root is gone: attached by config-name prefix
  #    ({Workspace::WorkspaceLineage.split_worktree_name}) to the project whose
  #    name matches the prefix, else its own project (vcs "unknown"). The
  #    member has +exists+ false.
  class ProjectCatalog
    # @!attribute name [String] display name (not unique across clones)
    # @!attribute id [String] realpath of the shared git dir, or of the
    #   checkout for a non-git project; the stable identifier
    # @!attribute path [String] the main checkout (the git dir itself for a bare repo)
    # @!attribute vcs [String] "git", "none", "broken" or "unknown"
    # @!attribute members [Array<Member>] main member first, then by workspace name
    Project = Struct.new(:name, :id, :path, :vcs, :members, keyword_init: true)

    # @!attribute workspace [String, nil] the tmuxinator config name
    # @!attribute path [String] the checkout directory
    # @!attribute kind [String] "main" or "worktree"
    # @!attribute configured [Boolean] whether the member has a tmuxinator config
    # @!attribute exists [Boolean] whether the checkout directory exists
    Member = Struct.new(:workspace, :path, :kind, :configured, :exists, keyword_init: true)

    # @param project_config [Workspace::ProjectConfig] lists configs and their roots
    # @param git [Workspace::Git] reads checkout layouts from `.git` files
    def initialize(project_config:, git:)
      @project_config = project_config
      @git = git
    end

    # @return [Array<Project>] every project, sorted by name then path
    def all
      @all ||= build
    end

    # Finds one project by a path, a project name, or a member workspace name.
    #
    # @param token [String] a path to a project or member checkout, a project
    #   name, or a member workspace name
    # @return [Project]
    # @raise [Workspace::UsageError] if several projects share the name
    # @raise [Workspace::Error] if nothing matches
    def find(token)
      token = token.to_s
      by_path = find_by_path(token)
      return by_path if by_path

      named = all.select { |project| project.name == token }
      if named.size > 1
        raise UsageError, "Ambiguous project '#{token}': #{named.map(&:path).join(", ")} (pass a path to choose one)"
      end
      return named.first if named.size == 1

      by_workspace = all.find { |project| project.members.any? { |member| member.workspace == token } }
      return by_workspace if by_workspace

      by_directory = token.start_with?("/", "~", ".") && File.directory?(File.expand_path(token)) && for_directory(token)
      return by_directory if by_directory

      raise Error, "Unknown project '#{token}'"
    end

    # Finds the project a directory belongs to. A directory inside a git
    # checkout belongs to the project with that checkout's git common dir; if
    # no workspace is configured for that repository, a project with no
    # members stands in for it. Otherwise the directory must be inside a
    # configured member's checkout.
    #
    # @param cwd [String] a directory, usually the working directory
    # @return [Project]
    # @raise [Workspace::Error] if the directory belongs to no project
    def for_cwd(cwd)
      path = real(File.expand_path(cwd))
      layout = @git.checkout_layout(path)
      if layout && !layout[:broken]
        id = real(layout[:common_dir])
        return all.find { |project| project.id == id } || unconfigured_project(id)
      end

      inside = all.select do |project|
        project.members.any? { |member| member.exists && (path == member.path || path.start_with?("#{member.path}/")) }
      end
      return inside.first if inside.size == 1
      raise UsageError, "Ambiguous project for #{path}: #{inside.map(&:path).join(", ")}" if inside.size > 1
      raise Error, "No project found for #{path}"
    end

    private

    # {#for_cwd} for a path that may belong to no project: nil, not an error.
    def for_directory(path)
      for_cwd(path)
    rescue UsageError
      raise
    rescue Error
      nil
    end

    def unconfigured_project(id)
      main = (File.basename(id) == ".git") ? File.dirname(id) : id
      Project.new(name: derive_name(main), id: id, path: main, vcs: "git", members: [])
    end

    def derive_name(main)
      if File.basename(main).end_with?(".git") && File.basename(main) != ".git"
        File.basename(main).delete_suffix(".git")
      else
        WorkspaceLineage.name_from_path(main)
      end
    end

    def find_by_path(token)
      return nil unless token.start_with?("/", "~", ".")
      expanded = File.expand_path(token)
      return nil unless File.exist?(expanded)
      target = real(expanded)
      all.find do |project|
        project.id == target || project.path == target || project.members.any? { |member| member.path == target }
      end
    end

    def build
      entries = @project_config.available_projects.map { |name| entry_for(name) }
      existing, missing = entries.partition { |entry| entry[:exists] }
      groups = {}

      existing.each do |entry|
        layout = entry[:layout]
        broken = layout && layout[:broken]
        git = layout && !broken
        id = git ? real(layout[:common_dir]) : entry[:path]
        vcs = if git
          "git"
        elsif broken
          "broken"
        else
          "none"
        end
        group = (groups[id] ||= {id: id, vcs: vcs, common_dir: id, members: [], main_path: nil})
        linked = git && layout[:linked]
        group[:main_path] ||= real(layout[:toplevel]) if git && !linked
        group[:main_path] ||= entry[:path] unless git
        group[:members] << member_for(entry, linked ? "worktree" : "main")
      end
      groups.each_value { |group| name_group(group) }

      # Standalone configs first, so worktree-named configs can attach to them.
      missing.sort_by { |entry| [WorkspaceLineage.split_worktree_name(entry[:name]) ? 1 : 0, entry[:name]] }.each do |entry|
        split = WorkspaceLineage.split_worktree_name(entry[:name])
        group = split && group_for_missing(groups.values, split.first, entry[:path])
        if group
          group[:members] << member_for(entry, "worktree")
        else
          # No path to key on (no root:), or the path is already taken by
          # another missing config: key on the config name so none is dropped.
          key = (entry[:path].empty? || groups.key?(entry[:path])) ? "workspace:#{entry[:name]}" : entry[:path]
          groups[key] = {id: key, vcs: "unknown", name: entry[:name], main_path: entry[:path],
                         members: [member_for(entry, split ? "worktree" : "main")]}
        end
      end

      groups.values.map { |group| project_for(group) }.sort_by { |project| [project.name, project.path] }
    end

    # The one group a missing-root worktree config belongs to: the sole group
    # named +name+, or, when several share the name, the sole one whose main
    # checkout contains +path+. Ambiguous means standalone (nil).
    def group_for_missing(groups, name, path)
      named = groups.select { |g| g[:name] == name }
      return named.first if named.size == 1
      inside = named.select { |g| !path.empty? && g[:main_path] && path.start_with?("#{g[:main_path]}/") }
      (inside.size == 1) ? inside.first : nil
    end

    def entry_for(name)
      root = @project_config.project_root_for(name)
      path = (root.is_a?(String) && !root.empty?) ? File.expand_path(root) : nil
      exists = !path.nil? && File.directory?(path)
      path = real(path) if exists
      {name: name, path: path || "", exists: exists, layout: exists ? @git.checkout_layout(path) : nil}
    end

    def member_for(entry, kind)
      Member.new(workspace: entry[:name], path: entry[:path], kind: kind, configured: true, exists: entry[:exists])
    end

    # Project name: the workspace configured at the main checkout (matching
    # what `workspace parent` prints), else derived from the checkout path.
    def name_group(group)
      if group[:vcs] == "git"
        main = group[:main_path]
        if main.nil?
          common = group[:common_dir]
          main = (File.basename(common) == ".git") ? File.dirname(common) : common
          group[:main_path] = main
        end
        configured = group[:members].find { |member| member.path == real(main) }
        group[:name] = configured ? configured.workspace : derive_name(main)
      else
        group[:name] = group[:members].first.workspace
      end
    end

    def project_for(group)
      members = group[:members].sort_by { |member| [(member.kind == "main") ? 0 : 1, member.workspace.to_s] }
      Project.new(name: group[:name], id: group[:id], path: group[:main_path], vcs: group[:vcs], members: members)
    end

    def real(path)
      File.realpath(path)
    rescue SystemCallError
      File.expand_path(path)
    end
  end
end
