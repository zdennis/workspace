require "json"

module Workspace
  module Commands
    # `ticket show REF`: what `start` would make of a ref, without starting
    # anything. Reads the ref with {StartRef}, looks up the ticket's title and
    # body with {TicketSource}, and says whether a worktree for the ref's
    # branch already exists. It writes nothing and fetches nothing from git.
    class Ticket
      # Bumped whenever the `--json` payload's shape changes in a backward-incompatible way.
      JSON_SCHEMA_VERSION = 1

      # @param git [Workspace::Git]
      # @param project_config [Workspace::ProjectConfig] names workspaces and finds a named one's checkout
      # @param start_ref [Workspace::StartRef] the resolution `start` uses
      # @param source [Workspace::TicketSource] reads the ticket
      # @param output [IO]
      def initialize(git:, project_config:, start_ref:, source:, output: $stdout)
        @git = git
        @project_config = project_config
        @start_ref = start_ref
        @source = source
        @output = output
      end

      # @param input [String] JIRA key or URL, pull request URL or ref, issue URL, or branch name
      # @param name [String, nil] a workspace whose project to look in; nil means the project of the current directory
      # @param json [Boolean] print the document documented in docs/README.ticket.md
      # @return [void]
      # @raise [Workspace::Error] `unknown_workspace`, not in a git repository, `ticket_not_found`,
      #   or `ticket_source_unavailable`
      def show(input, name: nil, json: false)
        ref = @start_ref.call(input)
        project = @start_ref.project(checkout_root(name))
        workspace = existing_workspace(project, ref.branch)
        ticket = @source.fetch(ref, chdir: project.root)

        document = {"schema_version" => JSON_SCHEMA_VERSION, "ok" => true, "ref" => input, "kind" => ref.kind, "key" => ref.key,
                    "title" => ticket["title"], "body" => ticket["body"], "url" => ticket["url"], "branch" => ref.branch,
                    "workspace" => workspace}
        if json
          @output.puts JSON.generate(document)
        else
          print_text(document)
        end
      end

      private

      def checkout_root(name)
        root = name ? @project_config.project_root_for(name) : @git.root
        if name && root.nil?
          raise Workspace::Error.new("Unknown workspace '#{name}'. Run 'workspace list --all' to see the names.", code: "unknown_workspace", details: {"name" => name})
        end
        raise Workspace::Error, "Not inside a git repository." unless root

        File.expand_path(root)
      end

      # The config name `start` would reuse: the worktree at the standard path, else the one that holds the branch.
      def existing_workspace(project, branch)
        dir = @git.sanitize_for_filesystem(branch)
        path = File.join(project.root, ".worktrees", dir)
        unless @git.worktree_exists?(path)
          path = @git.find_worktree_by_branch(branch, repo: project.root)
          return nil if path.nil? || File.expand_path(path) == File.expand_path(project.root)
          dir = File.basename(path)
        end
        name = @project_config.worktree_config_name(project.name, dir)
        @project_config.existing_name(name) || name
      end

      def print_text(document)
        if document["title"]
          @output.puts "#{document["key"]}  #{document["title"]}"
        else
          @output.puts "#{document["key"]}  (#{document["kind"]})"
        end
        @output.puts document["url"] if document["url"]
        @output.puts "Workspace: #{document["workspace"]} (already exists)" if document["workspace"]
        @output.puts "", document["body"] if document["body"]
      end
    end
  end
end
