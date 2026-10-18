require "json"

module Workspace
  module Commands
    # `projects group create|add|list`: named groups of repositories
    # ({Workspace::ProjectGroups}). Nothing here starts, stops or reads a
    # workspace; it only reads and writes group files.
    class Groups
      # @param groups [Workspace::ProjectGroups]
      # @param output [IO]
      def initialize(groups:, output: $stdout)
        @groups = groups
        @output = output
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
          if json
            emit(json_document(nil, "groups" => groups.map { |group| group_hash(group) }))
          elsif groups.empty?
            @output.puts "No groups. Run 'workspace projects group create NAME'."
          else
            print_table(groups)
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
