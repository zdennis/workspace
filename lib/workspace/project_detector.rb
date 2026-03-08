module Workspace
  # Detects the current workspace project from the working directory.
  # First walks up the directory tree looking for .workspace-project marker files
  # (used by worktree projects), then falls back to matching against active project roots.
  class ProjectDetector
    MARKER_FILE = ".workspace-project"

    # @param state [Workspace::State] state persistence for active project lookup
    # @param project_config [Workspace::ProjectConfig] project config for root path resolution
    def initialize(state:, project_config:)
      @state = state
      @project_config = project_config
    end

    # Detects the project for the given working directory.
    #
    # @param working_dir [String] the directory to detect from
    # @return [String, nil] the detected project name, or nil if not found
    def detect(working_dir)
      detect_from_marker(working_dir) || detect_from_active_roots(working_dir)
    end

    # Detects a project from marker files only (no state lookup).
    # Used by commands that only need marker-based detection.
    #
    # @param working_dir [String] the directory to detect from
    # @return [String, nil] the detected project name, or nil if not found
    def detect_from_marker(working_dir)
      dir = resolve_real_path(working_dir)
      loop do
        marker = File.join(dir, MARKER_FILE)
        return File.read(marker).strip if File.exist?(marker)
        parent = File.dirname(dir)
        break if parent == dir
        dir = parent
      end
      nil
    end

    private

    def detect_from_active_roots(working_dir)
      @state.load
      cwd = resolve_real_path(working_dir)
      best_match = nil
      best_length = -1
      @state.keys.each do |project|
        root = @project_config.project_root_for(project)
        next unless root
        expanded = resolve_real_path(root)
        prefix = "#{expanded}/"
        if cwd == expanded || cwd.start_with?(prefix)
          if expanded.length > best_length
            best_match = project
            best_length = expanded.length
          end
        end
      end
      best_match
    end

    def resolve_real_path(path)
      File.realpath(path)
    rescue Errno::ENOENT
      File.expand_path(path)
    end
  end
end
