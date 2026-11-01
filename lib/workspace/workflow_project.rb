module Workspace
  # The one answer to which project's workflow definitions a command reads first, shared by every
  # reader (`show`, `validate`, `render`, `run`, `start`, `add`, `update`, `remove`).
  #
  # A name written in a repository (the `.workspace-project` marker) is a claim by whoever made the
  # repository, so it is used only when the user's own config ties that project to this checkout: the
  # project's stored root has the same git common dir (or root) as the directory. Any other marker is
  # ignored with a warning on stderr and the directory has no project, so a branch or fork can't pick
  # which definitions, and so which shell commands, run on the machine.
  class WorkflowProject
    # The project of a directory.
    #
    # @!attribute project [String] the project name (a worktree workspace's parent)
    # @!attribute registered [Boolean] whether the project has a config of its own (always true for an answer)
    Resolved = Struct.new(:project, :registered, keyword_init: true)

    # @param project_detector [Workspace::ProjectDetector] reads the marker and the active roots
    # @param project_config [Workspace::ProjectConfig] the user's configs: which names exist, and their roots
    # @param git [Workspace::Git] reads checkouts from `.git` files
    # @param start_ref [Workspace::StartRef] names the project a checkout would join
    # @param config [Workspace::Config] says which names can be a directory under `projects/`
    # @param error_output [IO] where a warning goes
    def initialize(project_detector:, project_config:, git:, start_ref:, config:, error_output: $stderr)
      @project_detector = project_detector
      @project_config = project_config
      @git = git
      @start_ref = start_ref
      @config = config
      @error_output = error_output
    end

    # A project is named only when the user's config ties it to the checkout, whether the name comes from a
    # marker file or from the checkout's directory name: both are content a repository brings along.
    #
    # @param dir [String] a directory
    # @return [Resolved, nil] nil when the directory is in no project the user's config vouches for
    def for_directory(dir)
      marker = @project_detector.detect_from_marker(dir)
      if marker
        return resolved(WorkflowCatalog.project_of(marker)) if tied?(marker, dir)
        if own_marker?(dir)
          unless targets_self?(marker, dir)
            @error_output.puts "warning: the .workspace-project file near #{dir} names #{marker.to_s[0, 60].inspect}, but your config does not put that workspace at this checkout; no project's workflow definitions are read."
          end
          return nil
        end
      end

      active = @project_detector.detect_from_roots(dir)
      return resolved(WorkflowCatalog.project_of(active)) if active && tied?(active, dir)

      layout = @git.checkout_layout(dir)
      name = layout ? @start_ref.project(layout.fetch(:toplevel)).name : WorkspaceLineage.name_from_path(dir)
      existing = @project_config.existing_name(name)
      return nil unless existing && tied?(existing, dir)
      resolved(WorkflowCatalog.project_of(existing))
    end

    # The workspace a command works in when none is named: what the detector finds for the directory, unless a
    # `.workspace-project` file there names a workspace whose own config is not rooted at the checkout. That is the
    # question of which workspace this is; whether the project's definitions may be read is {#for_directory}'s.
    #
    # @param dir [String]
    # @return [String, nil] the workspace, or nil outside any (a marker above this checkout's own root belongs to an outer checkout: none)
    # @raise [Workspace::Error] code `not_in_workspace` when the marker at this checkout's own root is not the user's own
    def workspace(dir)
      marker = @project_detector.detect_from_marker(dir)
      if marker && !targets_self?(marker, dir)
        return nil unless own_marker?(dir)
        raise Workspace::Error.new("The .workspace-project file near #{dir} names #{marker.to_s[0, 60].inspect}, but your config does not put that workspace at this checkout, so it is not acted on. Pass --name to choose a workspace.",
          code: "not_in_workspace", details: {"path" => dir, "marker" => marker.to_s[0, 60]})
      end
      @project_detector.detect(dir)
    end

    # @param name [String] a workspace (`--name`)
    # @return [Resolved]
    # @raise [Workspace::Error] code `unknown_workspace` when no config has that name
    def for_workspace(name)
      existing = @project_config.existing_name(name)
      unless existing
        raise Workspace::Error.new("Unknown workspace '#{name}': it has no config. See `workspace list`.",
          code: "unknown_workspace", details: {"name" => name})
      end
      resolved(WorkflowCatalog.project_of(existing))
    end

    private

    # Whether the checkout's own root (the directory itself outside a checkout) holds a marker file, as against one
    # found above it, which belongs to an outer checkout.
    def own_marker?(dir)
      root = @git.checkout_layout(dir)&.fetch(:toplevel) || dir
      File.file?(File.join(root, ProjectDetector::MARKER_FILE))
    end

    # Whether the user's config ties +name+ to the checkout at +dir+: the project's own main config (never a
    # worktree config, which `start` writes for whatever checkout it runs in) has a root in a checkout with the
    # same git common dir. No main config means no tie.
    def tied?(name, dir)
      return false unless name.is_a?(String) && Config::PROJECT_DIR_NAME.match?(name)
      main = WorkflowCatalog.project_of(name)
      root = @project_config.project_root_for(main)
      return false unless root
      here = @git.checkout_layout(dir)
      there = @git.checkout_layout(File.expand_path(root))
      return within?(dir, root) if here.nil? && there.nil?
      return false unless here && there
      return real(here[:common_dir]) == real(there[:common_dir]) if here[:common_dir] && there[:common_dir]
      real(here[:toplevel]) == real(there[:toplevel])
    rescue SystemCallError
      false
    end

    # Whether +name+'s OWN config (a worktree's, not the project's main one) is rooted at this checkout: the
    # question of which workspace a directory is, as against {#tied?}'s whether it may read the project's definitions.
    def targets_self?(name, dir)
      return false unless name.is_a?(String) && Config::PROJECT_DIR_NAME.match?(name)
      root = @project_config.project_root_for(name)
      return false unless root
      checkout = @git.checkout_layout(dir)&.fetch(:toplevel) || dir
      real(root) == real(checkout)
    rescue SystemCallError
      false
    end

    # Whether +dir+ is +root+ or below it, by path segments (`/a/nongit2` is not under `/a/nongit`).
    def within?(dir, root)
      inside = real(dir).split("/")
      base = real(root).split("/")
      inside.first(base.size) == base
    end

    def real(path)
      File.realpath(path)
    rescue SystemCallError
      File.expand_path(path.to_s)
    end

    def resolved(project, registered: true)
      return nil if project.nil?
      if @config.project_workflows_dir(project).nil?
        @error_output.puts "warning: the project name #{project[0, 60].inspect} can't be a directory under #{@config.workspace_projects_dir}/ (start with a letter, digit or _; use letters, digits, ., _ and -); only the user's and the shipped definitions are read."
      end
      Resolved.new(project: project, registered: registered)
    end
  end
end
