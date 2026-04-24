module Workspace
  module Commands
    # Finds workspace project names by worktree path or branch name.
    class Lookup
      # @param project_config [Workspace::ProjectConfig] project config management
      # @param output [IO] output stream for user-facing messages
      def initialize(project_config:, output: $stdout)
        @project_config = project_config
        @output = output
      end

      # Looks up a workspace project by worktree path, project root directory,
      # branch name, or project key. Returns the project name if found, or nil if not found.
      #
      # @param query [String] worktree path, project root, branch name, or project key
      # @return [String, nil] the project name, or nil if not found
      def call(query)
        # If it's a directory path, check if it's a project root or worktree
        if File.directory?(query)
          expanded = File.expand_path(query)
          # First check if it's a project root
          result = find_by_project_root(expanded)
          return result if result
          # Otherwise try as a worktree path
          return find_by_worktree_path(query)
        end

        # Try as a project name first (exact match)
        return query if @project_config.exists?(query)

        # Try as a worktree name or branch name
        find_by_name(query)
      end

      private

      def find_by_project_root(expanded_path)
        @project_config.available_projects.each do |project|
          root = @project_config.project_root_for(project)
          next unless root
          expanded_root = File.expand_path(root)
          # Check for exact match or if query is a subdirectory of the root
          if expanded_path == expanded_root || expanded_path.start_with?(expanded_root + "/")
            return project
          end
        end
        nil
      end

      def find_by_worktree_path(path)
        expanded = File.expand_path(path)
        worktree_name = File.basename(expanded)
        find_by_name(worktree_name)
      end

      def find_by_name(name)
        # Search all available projects for one matching the name
        @project_config.available_projects.each do |project|
          # Check if this is a worktree config (format: "parent.worktree-name")
          if project.include?(".worktree-")
            # Extract the worktree part
            parts = project.split(".worktree-", 2)
            base_name = parts[0]
            worktree_part = parts[1]

            # Check for exact match with worktree part
            return project if worktree_part == name

            # Check if name matches the worktree part (for branch names with special chars)
            return project if matches_worktree?(worktree_part, name)

            # Check if name matches the base project
            return project if base_name == name
          elsif project == name
            # For non-worktree projects, check direct match
            return project
          end
        end

        nil
      end

      # Checks if a worktree filesystem name could match a branch name.
      # Branch names with special characters are sanitized by Git for filesystem safety.
      #
      # @param worktree_name [String] the sanitized worktree directory name
      # @param search_term [String] the search query (may be a branch name)
      # @return [Boolean] true if they likely match
      def matches_worktree?(worktree_name, search_term)
        # Normalize both by replacing hyphens/underscores for fuzzy matching
        norm_worktree = worktree_name.tr("-_", "")
        norm_search = search_term.tr("-_", "")

        norm_worktree == norm_search
      end
    end
  end
end
