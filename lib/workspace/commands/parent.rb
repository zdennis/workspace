require "json"

module Workspace
  module Commands
    # Prints the parent workspace of the current (or given) workspace.
    #
    # In a non-worktree workspace, its own name is the parent, so scripts can
    # always run `$(workspace parent)`.
    class Parent
      # @param lineage [Workspace::WorkspaceLineage] parent resolver
      # @param project_config [Workspace::ProjectConfig] resolves a project name to its root
      # @param output [IO] output stream for user-facing messages
      def initialize(lineage:, project_config:, output: $stdout)
        @lineage = lineage
        @project_config = project_config
        @output = output
      end

      # @param name [String, nil] a project or worktree config name; defaults to the cwd
      # @param path [Boolean] print the parent's root path instead of its name
      # @param json [Boolean] print name, path, git_common_dir, is_worktree, worktree as JSON
      # @return [void]
      # @raise [Workspace::Error] if the name can't be resolved to a project, or nothing resolves
      def call(name = nil, path: false, json: false)
        cwd = resolve_cwd(name)
        info = @lineage.resolve(cwd: cwd)

        raise Workspace::Error, "Could not resolve a parent workspace for '#{cwd}'" if info.name.nil? || info.name.empty?

        if json
          @output.puts JSON.generate(
            name: info.name,
            path: info.path,
            git_common_dir: info.git_common_dir,
            is_worktree: info.is_worktree,
            worktree: info.worktree
          )
        elsif path
          @output.puts info.path
        else
          @output.puts info.name
        end
      end

      private

      def resolve_cwd(name)
        return Dir.pwd if name.nil?

        root = @project_config.project_root_for(name)
        raise Workspace::Error.new("Unknown project '#{name}'", code: "unknown_workspace", details: {"name" => name}) unless root
        root
      end
    end
  end
end
