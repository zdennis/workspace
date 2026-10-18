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
      # @param error_output [IO] where `list` prints a source's warning when it is not asked for `--json`
      def initialize(git:, project_config:, start_ref:, source:, output: $stdout, error_output: $stderr)
        @git = git
        @project_config = project_config
        @start_ref = start_ref
        @source = source
        @output = output
        @error_output = error_output
      end

      # Default and largest number of tickets `list` returns.
      DEFAULT_LIMIT = 20
      MAX_LIMIT = 100
      FILTERS = %w[assigned recent].freeze

      # `ticket list`: tickets to pick from, newest change first, from `gh` (issues
      # and pull requests) and `jira`. Reads only. A source that is missing, slow
      # or failing is a warning and the others still answer.
      #
      # @param name [String, nil] a workspace whose project to look in; nil means the project of the current directory
      # @param filter [String] `assigned` (open, assigned to me) or `recent` (changed lately, anyone's)
      # @param limit [Integer] 1 to {MAX_LIMIT}
      # @param sources [Array<String>] any of `gh`, `jira`; empty means both
      # @param json [Boolean] print the document documented in docs/README.ticket.md
      # @return [void]
      # @raise [Workspace::UsageError] an unknown filter or source, or a limit out of range
      # @raise [Workspace::Error] `unknown_workspace`, or not in a git repository
      def list(name: nil, filter: "assigned", limit: DEFAULT_LIMIT, sources: [], json: false)
        raise Workspace::UsageError, "Unknown filter '#{filter}': use #{FILTERS.join(" or ")}." unless FILTERS.include?(filter)
        raise Workspace::UsageError, "--limit must be a whole number from 1 to #{MAX_LIMIT}." unless limit.is_a?(Integer) && limit.between?(1, MAX_LIMIT)
        unknown = sources - Workspace::TicketSource::SOURCES
        raise Workspace::UsageError, "Unknown source '#{unknown.first}': use #{Workspace::TicketSource::SOURCES.join(" or ")}." if unknown.any?

        project = @start_ref.project(checkout_root(name))
        found = @source.list(filter: filter, limit: limit, chdir: project.root, sources: sources.empty? ? Workspace::TicketSource::SOURCES : sources.uniq)
        branches = @git.worktree_branches(repo: project.root)
        tickets = found["rows"].map { |row| list_row(row, project, branches) }

        document = {"schema_version" => JSON_SCHEMA_VERSION, "ok" => true, "filter" => filter, "limit" => limit,
                    "tickets" => tickets, "warnings" => found["warnings"]}
        if json
          @output.puts JSON.generate(document)
        else
          print_list(document)
        end
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

      # A `show` document without the body, plus where the ticket came from and when it changed.
      def list_row(row, project, branches)
        ref = @start_ref.call(row["ref"])
        slug_branch = @start_ref.slugged(ref, row["title"]).branch
        candidates = [slug_branch, ref.branch]
        candidates += branches.select { |branch| branch.start_with?("#{ref.branch}-") } if %w[jira github_issue].include?(ref.kind)
        workspace = candidates.uniq.filter_map { |branch| existing_workspace(project, branch) }.first
        {"ref" => row["ref"], "kind" => ref.kind, "key" => ref.key, "title" => row["title"], "url" => row["url"],
         "source" => row["source"], "state" => row["state"], "updated_at" => row["updated_at"], "branch" => ref.branch,
         "slug_branch" => slug_branch, "workspace" => workspace}
      end

      def print_list(document)
        document["tickets"].each do |ticket|
          marker = ticket["workspace"] ? "  [workspace: #{ticket["workspace"]}]" : ""
          kind = (ticket["kind"] == "github_pr") ? " (pull request)" : ""
          @output.puts "#{ticket["key"]}#{kind}  #{ticket["state"]}  #{ticket["title"]}#{marker}".rstrip
        end
        @output.puts "No tickets." if document["tickets"].empty?
        document["warnings"].each { |warning| @error_output.puts "Warning: #{warning["message"]}" }
      end

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
