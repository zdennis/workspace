require "json"

module Workspace
  module Commands
    # `projects group create|add|list|show`: named groups of repositories
    # ({Workspace::ProjectGroups}). Nothing here starts or stops a workspace;
    # `create`, `add` and `list` only read and write group files, and `show`
    # reads each repository the way `projects show` does.
    class Groups
      # @param groups [Workspace::ProjectGroups]
      # @param projects [Workspace::Commands::Projects, nil] gathers each repository's `show` document for `show`
      # @param output [IO]
      # @param error_output [IO] stream for the warnings of text `list`
      def initialize(groups:, projects: nil, output: $stdout, error_output: $stderr)
        @groups = groups
        @projects = projects
        @output = output
        @error_output = error_output
      end

      # @param name [String]
      # @param json [Boolean]
      # @return [Hash] `{exit_code:}`
      # @raise [Workspace::Error] unless +json+ is set
      def create(name:, json: false)
        guarded(json) do
          group = @groups.create(name)
          if json
            emit(json_document("create", "group" => group_hash(group)))
          else
            @output.puts "Created group #{group.name} (#{group.id}) at #{abbreviate(group.path)}"
          end
        end
      end

      # @param group [String] a group id, slug or name
      # @param path [String] a directory in the repository to add
      # @param json [Boolean]
      # @return [Hash] `{exit_code:}`
      # @raise [Workspace::Error] unless +json+ is set
      def add(group:, path:, json: false)
        guarded(json) do
          found, repository, added = @groups.add(group, path)
          if json
            emit(json_document("add", "outcome" => added ? "added" : "already_member",
              "group" => group_hash(found), "repository" => repository_hash(repository)))
          else
            verb = added ? "Added" : "Already in"
            @output.puts "#{verb} #{found.id}: #{repository.name} (#{abbreviate(repository.path)})"
          end
        end
      end

      # @param json [Boolean]
      # @return [Hash] `{exit_code:}`
      # @raise [Workspace::Error] unless +json+ is set
      def list(json: false)
        guarded(json) do
          groups = @groups.all
          unreadable = @groups.unreadable
          if json
            emit(json_document(nil, "groups" => groups.map { |group| group_hash(group) }, "warnings" => unreadable))
          else
            unreadable.each { |warning| @error_output.puts "warning: skipped #{warning["path"]}: #{warning["message"]}" }
            if groups.empty?
              @output.puts "No groups. Run 'workspace projects group create NAME'."
            else
              print_table(groups)
            end
          end
        end
      end

      # Each repository of a group as `projects show` would show it.
      #
      # @param group [String] a group id, slug or name
      # @param json [Boolean]
      # @param agents [Boolean] read agent states from the daemons
      # @param git [Boolean] read git facts
      # @param timeout [Numeric, nil] seconds for each daemon and for the git reads
      # @return [Hash] `{exit_code:}`
      # @raise [Workspace::Error] unless +json+ is set
      def show(group:, json: false, agents: true, git: true, timeout: nil)
        guarded(json) do
          raise Workspace::Error, "projects group show is not available: no projects command was wired" unless @projects
          found = @groups.find(group)
          entries = @projects.group_documents(found, agents: agents, git: git, timeout: timeout)
          if json
            emit(json_document(nil, "id" => found.id, "name" => found.name, "path" => found.path,
              "repositories" => entries.map { |entry| entry_hash(entry) }))
          else
            print_group(found, entries)
          end
        end
      end

      private

      def guarded(json)
        yield
        {exit_code: 0}
      rescue => e
        raise unless json
        emit(Workspace::JsonEnvelope.from_exception(Projects::JSON_SCHEMA_VERSION, e, message: e.message.lines.first.to_s.strip))
        {exit_code: 1}
      end

      def emit(document)
        @output.puts JSON.generate(document)
      end

      def json_document(action, extra)
        doc = {"schema_version" => Projects::JSON_SCHEMA_VERSION, "ok" => true}
        doc["action"] = action if action
        doc.merge(extra)
      end

      # A repository with a project is its `projects show` document; one
      # without is `{id, path, exists}`, `exists: false` when the directory is gone.
      def entry_hash(entry)
        repository = entry[:repository]
        return entry[:document] if entry[:document]
        {"id" => repository.id, "path" => repository.path, "exists" => repository.exists}
      end

      def print_group(group, entries)
        @output.puts "Group  #{group.name} (#{group.id})   #{abbreviate(group.path)}"
        @output.puts "No repositories. Run 'workspace projects group add #{group.id} PATH'." if entries.empty?
        entries.each do |entry|
          @output.puts
          repository = entry[:repository]
          if entry[:document]
            @projects.print_document(entry[:project], entry[:document])
          elsif repository.exists
            @output.puts "Project  #{repository.name}   #{abbreviate(repository.path)}   (no workspaces configured)"
          else
            @output.puts "Project  #{repository.name}   #{abbreviate(repository.path)}   MISSING (repository gone)"
          end
        end
      end

      def group_hash(group)
        {"id" => group.id, "name" => group.name, "path" => group.path,
         "repositories" => group.repositories.map { |repository| repository_hash(repository) }}
      end

      def repository_hash(repository)
        {"id" => repository.id, "name" => repository.name, "path" => repository.path, "exists" => repository.exists}
      end

      def print_table(groups)
        lines = groups.map do |group|
          missing = group.repositories.count { |r| !r.exists }
          note = missing.zero? ? "" : "(#{missing} missing)"
          [group.id, group.name, group.repositories.size.to_s, group.repositories.map(&:name).join(", "), note]
        end
        header = %w[GROUP NAME REPOSITORIES MEMBERS NOTE]
        widths = header.each_index.map { |i| ([header[i]] + lines.map { |line| line[i] }).map(&:length).max }
        ([header] + lines).each do |line|
          @output.puts line.each_with_index.map { |cell, i| cell.ljust(widths[i]) }.join("  ").rstrip
        end
      end

      def abbreviate(path)
        home = Dir.home
        path.start_with?("#{home}/") ? "~#{path.delete_prefix(home)}" : path
      end
    end
  end
end
