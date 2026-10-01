require "json"

module Workspace
  module Commands
    # Lists projects: each repository's main checkout plus its linked
    # worktrees, with the workspaces (tmuxinator configs) that belong to it.
    #
    # The listing is cheap by design: config files, `.git` files and a single
    # `tmux list-sessions` call. Normally no git subprocesses, sockets or network.
    class Projects
      # Bumped whenever the `--json` payload's shape changes in a
      # backward-incompatible way.
      JSON_SCHEMA_VERSION = 1

      # @param catalog [Workspace::ProjectCatalog] groups workspaces into projects
      # @param tmux [Workspace::Tmux] lists running sessions and maps workspace names to them
      # @param output [IO] stream for the table or JSON
      # @param home [String] home directory, abbreviated to `~` in the table
      def initialize(catalog:, tmux:, output: $stdout, home: Dir.home)
        @catalog = catalog
        @tmux = tmux
        @output = output
        @home = home
      end

      # @param running_only [Boolean] only projects with at least one running workspace
      # @param json [Boolean] print the schema-versioned JSON payload instead of a table
      # @return [Hash] `{exit_code:}`; 1 only after a JSON error payload was printed
      # @raise [Workspace::Error] on failure, unless +json+ is set
      def list(running_only: false, json: false)
        sessions = running_sessions
        rows = @catalog.all.map { |project| row_for(project, sessions) }
        rows = rows.select { |row| row[:running].positive? } if running_only

        if json
          @output.puts JSON.generate({"schema_version" => JSON_SCHEMA_VERSION, "projects" => rows.map { |row| json_row(row) }})
        elsif rows.empty?
          @output.puts running_only ? "No projects with a running workspace." : "No projects. Run 'workspace add' to create one."
        else
          print_table(rows)
        end
        {exit_code: 0}
      rescue => e
        raise unless json
        @output.puts JSON.generate({"schema_version" => JSON_SCHEMA_VERSION, "error" => e.message.lines.first.to_s.strip})
        {exit_code: 1}
      end

      private

      # No tmux server (or one that doesn't answer) means nothing is running.
      def running_sessions
        @tmux.sessions
      rescue Workspace::Error
        []
      end

      def row_for(project, sessions)
        running = project.members.count { |member| member.exists && sessions.include?(@tmux.session_name_for(member.workspace)) }
        {project: project, running: running}
      end

      def json_row(row)
        project = row[:project]
        {
          "name" => project.name,
          "id" => project.id,
          "path" => project.path,
          "vcs" => project.vcs,
          "workspaces" => project.members.size,
          "running" => row[:running]
        }
      end

      def print_table(rows)
        name_counts = rows.map { |row| row[:project].name }.tally
        lines = rows.map do |row|
          project = row[:project]
          [project.name, project.members.size.to_s, row[:running].to_s, abbreviate(project.path), notes_for(project, name_counts)]
        end
        header = %w[PROJECT WORKSPACES RUNNING PATH NOTE]
        widths = header.each_index.map { |i| ([header[i]] + lines.map { |line| line[i] }).map(&:length).max }
        @output.puts format_line(header[0, 4], widths, note: header[4])
        lines.each { |line| @output.puts format_line(line[0, 4], widths, note: line[4]) }
      end

      def format_line(cells, widths, note: nil)
        "#{cells.each_with_index.map { |cell, i| cell.ljust(widths[i]) }.join("  ")}  #{note}".rstrip
      end

      def notes_for(project, name_counts)
        notes = []
        notes << "no git" if project.vcs == "none"
        notes << "broken checkout" if project.vcs == "broken"
        notes << "checkout missing" if project.members.none?(&:exists)
        notes << "same name" if name_counts[project.name] > 1
        notes.empty? ? "" : "(#{notes.join(", ")})"
      end

      def abbreviate(path)
        inside_home = !@home.to_s.empty? && (path == @home || path.start_with?("#{@home}/"))
        inside_home ? "~#{path.delete_prefix(@home)}" : path
      end
    end
  end
end
