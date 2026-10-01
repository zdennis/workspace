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
      # @param state [Workspace::State] session state, read for each workspace's headless flag
      # @param config [Workspace::Config] locates each workspace's ask and pipeline state files
      # @param lock_namespace [Workspace::LockNamespace] locates the project's lock store
      # @param lock_holder [Workspace::LockHolder] tells live lock holders from stale ones
      # @param dev [Workspace::Commands::Dev] reports the dev environment's state
      # @param agents [Workspace::ProjectAgents] reads each running workspace's agent states from its daemon
      # @param output [IO] stream for the table or JSON
      # @param error_output [IO] stream for warnings about unreadable ask stores
      # @param home [String] home directory, abbreviated to `~` in the table
      def initialize(catalog:, tmux:, state:, config:, lock_namespace:, lock_holder:, dev:, agents:, output: $stdout, error_output: $stderr,
        home: Dir.home)
        @catalog = catalog
        @tmux = tmux
        @state = state
        @config = config
        @lock_namespace = lock_namespace
        @lock_holder = lock_holder
        @dev = dev
        @agents = agents
        @output = output
        @error_output = error_output
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
        sessions = running_sessions
        @state.load
        members = project.members.map { |member| member_facts(member, sessions, agents: agents, timeout: timeout) }
        errors = {}
        locks = lock_facts(project, errors)
        dev = dev_facts(project, errors)
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
        payload["summary"]["waiting_agents"] = members.sum { |m| m.dig("agents", "counts", "waiting").to_i } if agents
        payload["errors"] = errors unless errors.empty?
        payload
      end

      # A missing checkout has no sessions or state worth reading, so its
      # counts are nil (unknown) rather than 0.
      def member_facts(member, sessions, agents:, timeout:)
        workspace = member.workspace
        running = member.exists && sessions.include?(@tmux.session_name_for(workspace))
        entries = member.exists ? pipeline_entries(workspace) : nil
        {
          "workspace" => workspace,
          "path" => member.path,
          "kind" => member.kind,
          "configured" => member.configured,
          "exists" => member.exists,
          "running" => running ? true : false,
          "headless" => headless?(workspace),
          "open_asks" => member.exists ? open_asks(workspace) : nil,
          "pipeline" => entries && {"entries" => entries},
          "agents" => agent_facts(workspace, running, agents: agents, timeout: timeout)
        }
      end

      # nil with --no-agents; a workspace that isn't running has no daemon to ask.
      def agent_facts(workspace, running, agents:, timeout:)
        return nil unless agents
        return {"available" => false, "reason" => "not_running"} unless running
        @agents.facts(workspace, timeout: timeout || DEFAULT_AGENT_TIMEOUT)
      end

      def headless?(workspace)
        info = @state[workspace]
        (info.is_a?(Hash) && info["headless"]) ? true : false
      end

      def open_asks(workspace)
        AskStore.new(path: @config.ask_state_path(workspace), error_output: @error_output).list(open_only: true).size
      rescue Workspace::Error => e
        @error_output.puts "workspace projects: not counting open questions for #{workspace}: #{e.message}"
        nil
      end

      def pipeline_entries(workspace)
        path = @config.pipeline_state_path(workspace)
        return 0 unless File.exist?(path)
        entries = JSON.parse(File.read(path))
        entries.is_a?(Hash) ? entries.size : 0
      rescue JSON::ParserError, SystemCallError
        @error_output.puts "workspace projects: could not read #{workspace}'s pipeline state at #{path}"
        nil
      end

      # Locks and the dev environment live in the repository's shared lock
      # store, so they are read once for the project, from its main checkout.
      def lock_facts(project, errors)
        return {} unless project_dir?(project)
        store = LockStore.new(dir: @lock_namespace.resolve(cwd: project.path)[:dir], liveness: @lock_holder)
        store.status.each_with_object({}) do |(name, entry), locks|
          locks[name] = {
            "holder" => entry["holder"] && lock_record(entry["holder"], project),
            "queue" => (entry["queue"] || []).map { |waiter| lock_record(waiter, project) }
          }
        end
      rescue Workspace::Error => e
        errors["locks"] = e.message
        nil
      end

      def dev_facts(project, errors)
        return nil unless project_dir?(project)
        payload = @dev.status_payload(working_dir: project.path)
        holder = payload["holder"]
        {
          "running" => payload["running"],
          "ready" => payload["ready"],
          "holder_workspace" => payload["running"] ? workspace_at(holder["worktree"], project) : nil
        }
      rescue Workspace::Error => e
        errors["dev"] = e.message
        nil
      end

      def project_dir?(project)
        !project.path.to_s.empty? && File.directory?(project.path)
      end

      def lock_record(record, project)
        {
          "workspace" => workspace_at(record["worktree"], project),
          "path" => record["worktree"],
          "pid" => record["pid"] || record["waiter_pid"],
          "stale" => record["stale"] ? true : false
        }
      end

      # The member whose checkout contains +path+ (the deepest one wins, since
      # worktrees can sit inside the main checkout), or nil for a path that
      # belongs to no configured member.
      def workspace_at(path, project)
        return nil if path.to_s.empty?
        target = begin
          File.realpath(path)
        rescue SystemCallError
          File.expand_path(path)
        end
        member = project.members
          .select { |m| !m.path.empty? && (target == m.path || target.start_with?("#{m.path}/")) }
          .max_by { |m| m.path.length }
        member&.workspace
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
