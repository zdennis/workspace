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
      # @param error_output [IO] stream for notes that must stay out of script-readable output
      # @param home [String] home directory, abbreviated to `~` in the table
      def initialize(catalog:, tmux:, facts:, output: $stdout, error_output: $stderr, home: Dir.home)
        @catalog = catalog
        @tmux = tmux
        @facts = facts
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
      # Unless +git+ is false it also reads each checkout's branch, changed
      # files, upstream and unsaved-work state (a few git subprocesses per
      # checkout, run in parallel and bounded by +timeout+, see
      # {ProjectFacts#git_facts}) and lists worktrees that have no workspace
      # config. A checkout git can't answer for shows as unsaved `unknown`.
      #
      # @param name [String, nil] a project name, a member workspace name or a
      #   path; nil means the project containing +cwd+
      # @param json [Boolean] print the schema-versioned JSON payload instead of text
      # @param agents [Boolean] read agent states from the daemons; false skips every socket
      # @param git [Boolean] read git facts and list unconfigured worktrees; false leaves each member's `git` nil
      # @param timeout [Numeric, nil] seconds to wait for each daemon and for all the git reads; nil means
      #   {DEFAULT_AGENT_TIMEOUT} for daemons and {ProjectFacts::DEFAULT_GIT_TIMEOUT} for git (the worktree listing included)
      # @param cwd [String] directory used when +name+ is nil
      # @return [Hash] `{exit_code:}`; 1 only after a JSON error payload was printed
      # @raise [Workspace::Error] if the project can't be found, unless +json+ is set
      # @raise [Workspace::UsageError] if +name+ matches several projects, unless +json+ is set
      def show(name: nil, json: false, agents: true, git: true, timeout: nil, cwd: Dir.pwd)
        project = name ? @catalog.find(name) : @catalog.for_cwd(cwd)
        payload = show_payload(project, agents: agents, git: git, timeout: timeout)
        if json
          @output.puts JSON.generate(payload)
        else
          print_show(project, payload)
        end
        {exit_code: 0}
      rescue => e
        raise unless json
        @output.puts JSON.generate(Workspace::JsonEnvelope.from_exception(JSON_SCHEMA_VERSION, e, message: e.message.lines.first.to_s.strip))
        {exit_code: 1}
      end

      # Prints the project's member workspaces for scripts: one per line,
      # main checkout first, so `for ws in $(workspace projects members)` works.
      # Reads only config and `.git` files, with no git subprocess, unless
      # +all+ is set.
      #
      # Text output is one workspace name per line, or one checkout path per
      # line with +path+. Name mode never prints a path: with +all+ the
      # worktrees that have no workspace config are left out, with a note on
      # stderr counting them; +path+ and +json+ include them. An empty result
      # prints a note on stderr and nothing on stdout. Members whose checkout
      # is gone are still listed.
      #
      # @param name [String, nil] a project name, a member workspace name or a
      #   path; nil means the project containing +cwd+
      # @param path [Boolean] print checkout paths instead of workspace names
      # @param all [Boolean] also list worktrees that have no workspace config
      #   (one bounded `git worktree list`)
      # @param timeout [Numeric, nil] seconds to wait for that listing; nil means {ProjectFacts::DEFAULT_GIT_TIMEOUT}
      # @param json [Boolean] print the schema-versioned JSON payload instead of text
      # @param cwd [String] directory used when +name+ is nil
      # @return [Hash] `{exit_code:}`; 1 only after a JSON error payload was printed
      # @raise [Workspace::Error] if the project can't be found or the worktree listing times out, unless +json+ is set
      # @raise [Workspace::UsageError] if +name+ matches several projects, unless +json+ is set
      def members(name: nil, path: false, all: false, json: false, timeout: nil, cwd: Dir.pwd)
        project = name ? @catalog.find(name) : @catalog.for_cwd(cwd)
        members = project_members(project, all: all, timeout: timeout)
        if json
          @output.puts JSON.generate({
            "schema_version" => JSON_SCHEMA_VERSION, "ok" => true,
            "project" => {"name" => project.name, "id" => project.id, "path" => project.path, "vcs" => project.vcs},
            "members" => members.map { |m| {"workspace" => m.workspace, "path" => m.path, "kind" => m.kind, "configured" => m.configured, "exists" => m.exists} }
          })
        else
          print_member_names(project, members, path: path)
        end
        {exit_code: 0}
      rescue => e
        raise unless json
        @output.puts JSON.generate(Workspace::JsonEnvelope.from_exception(JSON_SCHEMA_VERSION, e, message: e.message.lines.first.to_s.strip))
        {exit_code: 1}
      end

      # @param running_only [Boolean] only projects with at least one running workspace
      # @param json [Boolean] print the schema-versioned JSON payload instead of a table
      # @param git [Boolean] add each project's unsaved-work count, which costs
      #   git subprocesses per checkout and counts unconfigured worktrees too
      # @return [Hash] `{exit_code:}`; 1 only after a JSON error payload was printed
      # @raise [Workspace::Error] on failure, unless +json+ is set
      def list(running_only: false, json: false, git: false)
        sessions = running_sessions
        rows = @catalog.all.map { |project| row_for(project, sessions) }
        rows = rows.select { |row| row[:running].positive? } if running_only
        if git
          deadline = @facts.git_deadline
          rows.each { |row| row.merge!(unsaved_for(row[:project], deadline)) }
        end

        if json
          @output.puts JSON.generate({"schema_version" => JSON_SCHEMA_VERSION, "ok" => true, "projects" => rows.map { |row| json_row(row, git: git) }})
        elsif rows.empty?
          @output.puts running_only ? "No projects with a running workspace." : "No projects. Run 'workspace add' to create one."
        else
          print_table(rows, git: git)
        end
        {exit_code: 0}
      rescue => e
        raise unless json
        @output.puts JSON.generate(Workspace::JsonEnvelope.from_exception(JSON_SCHEMA_VERSION, e, message: e.message.lines.first.to_s.strip))
        {exit_code: 1}
      end

      private

      # The configured members; with +all+ also the unconfigured worktrees,
      # whose listing is one git subprocess bounded by the default git timeout.
      def project_members(project, all:, timeout: nil)
        return @catalog.members(project) unless all
        thread = Thread.new do
          Thread.current.report_on_exception = false
          @catalog.members(project, include_unconfigured: true)
        end
        return thread.value if thread.join(timeout || ProjectFacts::DEFAULT_GIT_TIMEOUT)
        thread.kill
        raise Workspace::Error, "Timed out listing the worktrees of project '#{project.name}'. Run without --all to list configured workspaces only."
      end

      def print_member_names(project, members, path:)
        unless path
          omitted = members.count { |m| m.workspace.nil? }
          members = members.reject { |m| m.workspace.nil? }
          if omitted.positive?
            @error_output.puts "#{omitted} unconfigured worktree(s) omitted; use --path or --json to include them"
          end
        end
        @error_output.puts "no workspaces in project #{project.name}" if members.empty?
        members.each { |m| @output.puts(path ? m.path : m.workspace) }
      end

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

      # Unsaved-work counts over every checkout of a git project, unconfigured
      # worktrees included; `unsaved` is nil for a project with no git
      # repository to ask. Checkouts that are gone are counted as `missing`,
      # not in `total`, so a gone checkout never reads as clean. All projects
      # share +deadline+. When the worktree listing ran out of time the
      # unconfigured worktrees are unknown: `unconfigured` is nil and the
      # counts are marked `incomplete`, so they never read as clean.
      def unsaved_for(project, deadline)
        checkouts = @facts.git_checkouts(project, deadline: deadline)
        unconfigured = checkouts[:members].count { |member| !member.configured } if checkouts[:listed]
        facts = checkouts[:facts].compact
        return {unsaved: nil, unconfigured: unconfigured} if facts.empty?
        unsaved = facts.map { |fact| fact["unsaved"] }
        present = unsaved.size - unsaved.count("missing")
        {unsaved: {"members" => unsaved.count { |u| %w[yes unknown].include?(u) }, "unknown" => unsaved.count("unknown"),
                   "missing" => unsaved.count("missing"), "total" => present, "incomplete" => !checkouts[:listed]},
         unconfigured: unconfigured}
      end

      def json_row(row, git:)
        project = row[:project]
        json = {
          "name" => project.name,
          "id" => project.id,
          "path" => project.path,
          "vcs" => project.vcs,
          "workspaces" => project.members.size,
          "running" => row[:running]
        }
        if git
          json["unsaved"] = row[:unsaved]&.slice("members", "unknown", "missing", "total", "incomplete")
          json["unconfigured_worktrees"] = row[:unconfigured]
        end
        json
      end

      def print_table(rows, git: false)
        name_counts = rows.map { |row| row[:project].name }.tally
        lines = rows.map do |row|
          project = row[:project]
          [project.name, project.members.size.to_s, row[:running].to_s, (unsaved_label(row[:unsaved]) if git), abbreviate(project.path),
            notes_for(project, name_counts, row[:unconfigured], unlisted: git && row[:unconfigured].nil? && !row[:unsaved].nil?)].compact
        end
        header = ["PROJECT", "WORKSPACES", "RUNNING", ("UNSAVED" if git), "PATH", "NOTE"].compact
        widths = header.each_index.map { |i| ([header[i]] + lines.map { |line| line[i] }).map(&:length).max }
        ([header] + lines).each { |line| @output.puts format_line(line[0...-1], widths, note: line.last) }
      end

      # "2 of 3" checkouts unsaved, "unknown" when git couldn't answer for any of them,
      # "missing" when every checkout is gone, "-" without git. Gone checkouts are
      # left out of the total and named at the end: "2 of 3 (1 missing)".
      def unsaved_label(unsaved)
        return "-" unless unsaved
        return "missing" if unsaved["total"].zero? && !unsaved["incomplete"]
        return "unknown" if unsaved["unknown"] == unsaved["total"] && !unsaved["incomplete"]
        notes = []
        notes << "worktrees not listed" if unsaved["incomplete"]
        notes << "#{unsaved["unknown"]} unknown" if unsaved["unknown"].positive?
        notes << "#{unsaved["missing"]} missing" if unsaved["missing"].positive?
        label = "#{unsaved["members"]} of #{unsaved["total"]}"
        notes.empty? ? label : "#{label} (#{notes.join(", ")})"
      end

      def format_line(cells, widths, note: nil)
        "#{cells.each_with_index.map { |cell, i| cell.ljust(widths[i]) }.join("  ")}  #{note}".rstrip
      end

      def notes_for(project, name_counts, unconfigured = 0, unlisted: false)
        unconfigured = unconfigured.to_i
        notes = []
        notes << "no git" if project.vcs == "none"
        notes << "broken checkout" if project.vcs == "broken"
        notes << "checkout missing" if project.members.none?(&:exists)
        notes << "same name" if name_counts[project.name] > 1
        notes << "unconfigured worktrees unknown" if unlisted
        notes << "#{unconfigured} unconfigured #{(unconfigured == 1) ? "worktree" : "worktrees"}" if unconfigured.positive?
        notes.empty? ? "" : "(#{notes.join(", ")})"
      end

      def show_payload(project, agents:, git:, timeout:)
        gathered = @facts.for_project(project, sessions: running_sessions, agents: agents, timeout: timeout || DEFAULT_AGENT_TIMEOUT,
          git: git, git_timeout: timeout)
        members, locks, dev, errors = gathered.values_at(:members, :locks, :dev, :errors)
        payload = {
          "schema_version" => JSON_SCHEMA_VERSION, "ok" => true,
          "project" => {"name" => project.name, "id" => project.id, "path" => project.path, "vcs" => project.vcs},
          "members" => members,
          "locks" => locks,
          "dev" => dev,
          "summary" => {
            "workspaces" => members.count { |m| m["configured"] },
            "running" => members.count { |m| m["running"] },
            "open_asks" => members.sum { |m| m["open_asks"].to_i },
            "pipeline_entries" => members.sum { |m| m.dig("pipeline", "entries").to_i }
          }
        }
        git_facts = members.filter_map { |m| m["git"] }
        payload["summary"]["unsaved_members"] = git_facts.empty? ? nil : git_facts.count { |g| %w[yes unknown].include?(g["unsaved"]) }
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
        with_git = members.any? { |m| m["git"] }
        header = ["WORKSPACE", "KIND", ("BRANCH" if with_git), "RUN", ("AGENTS" if with_agents), "ASKS", "PIPE", ("GIT" if with_git), "NOTE"].compact
        rows = members.map do |m|
          name = m["workspace"] || "(no config)"
          branch = with_git ? (m.dig("git", "branch") || "-") : nil
          if !m["exists"]
            [name, m["kind"], branch, "-", ("-" if with_agents), "-", "-", ("-" if with_git), "MISSING (checkout gone)"].compact
          elsif !m["configured"]
            [name, m["kind"], branch, "-", ("-" if with_agents), "-", "-", (git_label(m["git"]) if with_git), ""].compact
          else
            [name, m["kind"], branch, run_label(m), (agents_label(m["agents"]) if with_agents), (m["open_asks"] || "?").to_s,
              (m.dig("pipeline", "entries") || "?").to_s, (git_label(m["git"]) if with_git), ""].compact
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

      # Unknown is shown as unsaved, since that is how kill and prune treat it.
      def git_label(git)
        return "-" if git.nil?
        return "#{(git["reason"] == "timeout") ? "timed out" : "unknown"} (treated as unsaved)" if git["unsaved"] == "unknown"
        return "-" if git["unsaved"] == "missing"
        parts = []
        parts << "#{git["changed_files"]} changed" if git["changed_files"].to_i.positive?
        parts << "#{git["unpushed_commits"]} unpushed" if git["unpushed_commits"].to_i.positive?
        parts.empty? ? "clean" : parts.join(", ")
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
