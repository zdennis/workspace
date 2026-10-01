require "json"

module Workspace
  module Commands
    # Lists projects (each repository's main checkout plus its linked
    # worktrees, with the workspaces (tmuxinator configs) that belong to it)
    # and shows one project's local facts.
    #
    # Both are cheap by design: config files, `.git` files and a single
    # `tmux list-sessions` call. `list` runs no git subprocesses, sockets or
    # network; `show` adds state files, the lock store, the dev status and,
    # unless told not to, one bounded agent-daemon socket read per running
    # workspace.
    class Projects
      # Bumped whenever the `--json` payload's shape changes in a
      # backward-incompatible way.
      JSON_SCHEMA_VERSION = 1

      # Seconds `show` waits for each agent daemon unless told otherwise.
      DEFAULT_AGENT_TIMEOUT = 1.0

      UNAVAILABLE_LABELS = {"no_daemon" => "no daemon", "timeout" => "timed out", "error" => "bad reply"}.freeze
      private_constant :UNAVAILABLE_LABELS

      # @param catalog [Workspace::ProjectCatalog] groups workspaces into projects
      # @param tmux [Workspace::Tmux] lists running sessions and maps workspace names to them
      # @param facts [Workspace::ProjectFacts] gathers each workspace's and project's facts
      # @param output [IO] stream for the table or JSON
      # @param home [String] home directory, abbreviated to `~` in the table
      def initialize(catalog:, tmux:, facts:, output: $stdout, home: Dir.home)
        @catalog = catalog
        @tmux = tmux
        @facts = facts
        @output = output
        @home = home
      end

      # Prints everything the project's local files and processes say about
      # one project: each workspace's running state, headless flag, open asks
      # and pipeline entries, plus the repo-wide locks and the dev environment.
      # Reads files and one `tmux list-sessions`, and asks each running
      # workspace's agent daemon for its agent states (see +agents+). A daemon
      # that is down or too slow shows as unavailable; it never fails the command.
      #
      # @param name [String, nil] a project name, a member workspace name or a
      #   path; nil means the project containing +cwd+
      # @param json [Boolean] print the schema-versioned JSON payload instead of text
      # @param agents [Boolean] read agent states from the daemons; false skips every socket
      # @param timeout [Numeric, nil] seconds to wait for each daemon; nil means {DEFAULT_AGENT_TIMEOUT}
      # @param cwd [String] directory used when +name+ is nil
      # @return [Hash] `{exit_code:}`; 1 only after a JSON error payload was printed
      # @raise [Workspace::Error] if the project can't be found, unless +json+ is set
      # @raise [Workspace::UsageError] if +name+ matches several projects, unless +json+ is set
      def show(name: nil, json: false, agents: true, timeout: nil, cwd: Dir.pwd)
        project = name ? @catalog.find(name) : @catalog.for_cwd(cwd)
        payload = show_payload(project, agents: agents, timeout: timeout)
        if json
          @output.puts JSON.generate(payload)
        else
          print_show(project, payload)
        end
        {exit_code: 0}
      rescue => e
        raise unless json
        @output.puts JSON.generate({"schema_version" => JSON_SCHEMA_VERSION, "error" => e.message.lines.first.to_s.strip})
        {exit_code: 1}
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

      def show_payload(project, agents:, timeout:)
        gathered = @facts.for_project(project, sessions: running_sessions, agents: agents, timeout: timeout || DEFAULT_AGENT_TIMEOUT)
        members, locks, dev, errors = gathered.values_at(:members, :locks, :dev, :errors)
        payload = {
          "schema_version" => JSON_SCHEMA_VERSION,
          "project" => {"name" => project.name, "id" => project.id, "path" => project.path, "vcs" => project.vcs},
          "members" => members,
          "locks" => locks,
          "dev" => dev,
          "summary" => {
            "workspaces" => members.size,
            "running" => members.count { |m| m["running"] },
            "open_asks" => members.sum { |m| m["open_asks"].to_i },
            "pipeline_entries" => members.sum { |m| m.dig("pipeline", "entries").to_i }
          }
        }
        payload["summary"]["waiting_agents"] = agents ? members.sum { |m| m.dig("agents", "counts", "waiting").to_i } : nil
        payload["summary"]["agents_unavailable"] = agents ? members.count { |m| m.dig("agents", "reason").to_s.match?(/\A(no_daemon|timeout|error)\z/) } : nil
        payload["errors"] = errors unless errors.empty?
        payload
      end

      def print_show(project, payload)
        @output.puts "Project  #{project.name}   #{abbreviate(project.path)}   (#{vcs_label(project.vcs)})"
        @output.puts
        members = payload["members"]
        if members.empty?
          @output.puts "No workspaces are configured for this project."
        else
          print_members(members)
        end
        @output.puts
        print_locks(payload)
        print_dev(payload)
      end

      def vcs_label(vcs)
        (vcs == "none") ? "no git" : vcs
      end

      def print_members(members)
        with_agents = members.any? { |m| m["agents"] }
        header = ["WORKSPACE", "KIND", "RUN", ("AGENTS" if with_agents), "ASKS", "PIPE", "NOTE"].compact
        rows = members.map do |m|
          if m["exists"]
            [m["workspace"], m["kind"], run_label(m), (agents_label(m["agents"]) if with_agents), (m["open_asks"] || "?").to_s,
              (m.dig("pipeline", "entries") || "?").to_s, ""].compact
          else
            [m["workspace"], m["kind"], "-", ("-" if with_agents), "-", "-", "MISSING (checkout gone)"].compact
          end
        end
        widths = header.each_index.map { |i| ([header[i]] + rows.map { |row| row[i] }).map(&:length).max }
        ([header] + rows).each { |row| @output.puts row.each_with_index.map { |cell, i| cell.ljust(widths[i]) }.join("  ").rstrip }
      end

      # Waiting first, since that is the state that needs a person.
      def agents_label(agents)
        return "-" if agents.nil? || agents["reason"] == "not_running"
        return UNAVAILABLE_LABELS.fetch(agents["reason"], "unavailable") unless agents["available"]
        parts = %w[waiting working idle].filter_map do |state|
          count = agents.dig("counts", state).to_i
          "#{count} #{state}" if count.positive?
        end
        parts.empty? ? "none" : parts.join(", ")
      end

      def run_label(member)
        return "-" unless member["running"]
        member["headless"] ? "yes (headless)" : "yes"
      end

      def print_locks(payload)
        @output.puts "Locks (repo-wide)"
        if payload["locks"].nil?
          @output.puts "  unavailable (#{payload.dig("errors", "locks")})"
        elsif payload["locks"].empty?
          @output.puts "  none"
        else
          payload["locks"].each { |name, entry| @output.puts "  #{lock_line(name, entry)}" }
        end
      end

      def lock_line(name, entry)
        holder = entry["holder"]
        queue = entry["queue"].empty? ? "" : "   queue: #{entry["queue"].size}"
        return "#{name}   free#{queue}" unless holder
        who = "#{holder["workspace"] || File.basename(holder["path"].to_s)} (pid #{holder["pid"]})"
        holder["stale"] ? "#{name}   STALE holder #{who}#{queue}" : "#{name}   held by #{who}#{queue}"
      end

      def print_dev(payload)
        dev = payload["dev"]
        if dev.nil?
          @output.puts "Dev env   #{payload["errors"]&.key?("dev") ? "unavailable (#{payload.dig("errors", "dev")})" : "not available"}"
        elsif dev["running"]
          readiness = {true => ", ready", false => ", not ready"}.fetch(dev["ready"], "")
          @output.puts "Dev env   running in #{dev["holder_workspace"] || "an unconfigured worktree"}#{readiness}"
        else
          @output.puts "Dev env   not running"
        end
      end

      def abbreviate(path)
        inside_home = !@home.to_s.empty? && (path == @home || path.start_with?("#{@home}/"))
        inside_home ? "~#{path.delete_prefix(@home)}" : path
      end
    end
  end
end
