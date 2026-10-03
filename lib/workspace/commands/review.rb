require "json"
require "time"

module Workspace
  module Commands
    # Collects what a person needs to review a coding agent's finished work:
    # `show` for one workspace, `list` for the workspaces of a project that
    # are ready.
    #
    # A workspace is ready when its agent is `done` (the Stop hook fired and no
    # pane is working or waiting) and its branch has commits the base branch
    # lacks. Everything is composed from facts the CLI already holds: the agent
    # daemon's pane states, the task store, git, the question store, the
    # session ledger, the transcript's last assistant message and, read-only,
    # `gh pr view`. Nothing is written, and every source that can't answer is
    # reported as unavailable, never as clean.
    class Review
      # Bumped whenever the `--json` payload's shape changes in a
      # backward-incompatible way.
      JSON_SCHEMA_VERSION = 1

      # Seconds `show` and `list` wait for each agent daemon.
      DEFAULT_AGENT_TIMEOUT = 2.0

      # Seconds each workspace's git reads may take in total.
      DEFAULT_GIT_TIMEOUT = 10.0

      # Most files and commits listed in a packet; totals always cover all of them.
      MAX_FILES = 200
      MAX_COMMITS = 50

      # Longest question, default or context copied into a packet.
      MAX_ASK_TEXT = 500

      # Pane states in the order that decides a workspace's state: the first
      # one any agent pane is in wins.
      STATE_PRECEDENCE = %w[waiting working done idle].freeze

      # @param catalog [Workspace::ProjectCatalog] finds workspaces and a project's members
      # @param git [Workspace::Git] base ref, commit and diff reads
      # @param snapshot_client [Workspace::AgentSnapshotClient] reads each daemon's pane states
      # @param task_store [Workspace::TaskStore] the workspace's active task
      # @param ask_store_for [#call] given a workspace name, returns its {Workspace::AskStore}
      # @param session_ledger [Workspace::SessionLedger] sessions and transcripts per workspace
      # @param transcript_summary [Workspace::TranscriptSummary] reads the last assistant message
      # @param pull_request_status [Workspace::PullRequestStatus] reads the branch's pull request
      # @param output [IO] stream for the packet, list or JSON
      # @param error_output [IO] stream for warnings that must stay out of script-readable output
      # @param agent_timeout [Numeric] seconds to wait for each agent daemon
      # @param git_timeout [Numeric] seconds each workspace's git reads may take
      def initialize(catalog:, git:, snapshot_client:, task_store:, ask_store_for:, session_ledger:, transcript_summary:, pull_request_status:,
        output: $stdout, error_output: $stderr, agent_timeout: DEFAULT_AGENT_TIMEOUT, git_timeout: DEFAULT_GIT_TIMEOUT)
        @catalog = catalog
        @git = git
        @snapshot_client = snapshot_client
        @task_store = task_store
        @ask_store_for = ask_store_for
        @session_ledger = session_ledger
        @transcript_summary = transcript_summary
        @pull_request_status = pull_request_status
        @output = output
        @error_output = error_output
        @agent_timeout = agent_timeout
        @git_timeout = git_timeout
      end

      # Prints one workspace's review packet.
      #
      # @param name [String] a workspace (tmuxinator config) name
      # @param json [Boolean] print the schema-versioned JSON payload instead of text
      # @return [Hash] `{exit_code:}`; 1 only after a JSON error payload was printed
      # @raise [Workspace::Error] if the workspace or its checkout can't be found, unless +json+ is set
      def show(name:, json: false)
        member = find_member(name)
        payload = packet(member)
        if json
          @output.puts JSON.generate(payload)
        else
          print_packet(payload)
        end
        {exit_code: 0}
      rescue => e
        raise unless json
        @output.puts JSON.generate(Workspace::JsonEnvelope.from_exception(JSON_SCHEMA_VERSION, e, message: e.message.lines.first.to_s.strip))
        {exit_code: 1}
      end

      # Prints the workspaces of a project that are ready for review. Reads
      # each configured checkout's agent daemon and, only for workspaces whose
      # agent is done, git; no `gh` call is made.
      #
      # @param project [String, nil] a project name, a member workspace name or a path;
      #   nil means the project containing +cwd+
      # @param json [Boolean] print the schema-versioned JSON payload instead of a table
      # @param cwd [String] directory used when +project+ is nil
      # @return [Hash] `{exit_code:}`; 1 only after a JSON error payload was printed
      # @raise [Workspace::Error] if the project can't be found, unless +json+ is set
      # @raise [Workspace::UsageError] if +project+ matches several projects, unless +json+ is set
      def list(project: nil, json: false, cwd: Dir.pwd)
        found = project ? @catalog.find(project) : @catalog.for_cwd(cwd)
        payload = list_payload(found)
        if json
          @output.puts JSON.generate(payload)
        else
          print_list(payload)
        end
        {exit_code: 0}
      rescue => e
        raise unless json
        @output.puts JSON.generate(Workspace::JsonEnvelope.from_exception(JSON_SCHEMA_VERSION, e, message: e.message.lines.first.to_s.strip))
        {exit_code: 1}
      end

      private

      def find_member(name)
        member = @catalog.all.flat_map(&:members).find { |m| m.workspace == name }
        unless member
          raise Workspace::Error.new("Unknown workspace '#{name}'. `workspace review list` shows the ready ones.",
            code: "unknown_workspace", details: {"name" => name})
        end
        unless member.exists
          raise Workspace::Error.new("The checkout for workspace '#{name}' is gone: #{member.path}", code: "checkout_missing",
            details: {"name" => name, "path" => member.path})
        end
        member
      end

      def list_payload(project)
        rows = []
        unavailable = []
        not_running = 0
        members = project.members.select { |m| m.configured && m.exists }
        members.each do |member|
          agent = agent_facts(member.workspace)
          if !agent["available"]
            (agent["reason"] == "no_daemon") ? not_running += 1 : unavailable << unavailable_row(member, agent["reason"])
            next
          end
          next unless agent["state"] == "done"

          git = git_facts(member.path)
          if git["available"]
            rows << ready_row(member, agent, git) if git["ahead"].to_i.positive?
          else
            unavailable << unavailable_row(member, git["reason"])
          end
        end
        {
          "schema_version" => JSON_SCHEMA_VERSION, "ok" => true,
          "project" => {"name" => project.name, "id" => project.id, "path" => project.path},
          "reviews" => rows,
          "unavailable" => unavailable,
          "summary" => {"checked" => members.size, "ready" => rows.size, "not_running" => not_running, "unavailable" => unavailable.size}
        }
      end

      def unavailable_row(member, reason)
        {"workspace" => member.workspace, "reason" => reason}
      end

      def ready_row(member, agent, git)
        task, task_unavailable = task_state(member.workspace)
        asks = asks_facts(member.workspace)
        {
          "workspace" => member.workspace, "path" => member.path, "branch" => git["branch"], "base" => git["base"],
          "ahead" => git["ahead"], "changed_files" => git["changed_files"],
          "agent" => agent.slice("state", "stop_reason", "state_since"),
          "task" => task,
          "open_asks" => asks["unavailable"] ? nil : asks["open"].size
        }.merge(task_unavailable ? {"task_unavailable" => true} : {}).merge(asks["unavailable"] ? {"asks_unavailable" => true} : {})
      end

      def packet(member)
        workspace = member.workspace
        agent = agent_facts(workspace)
        task, task_unavailable = task_state(workspace)
        git = git_facts(member.path, detail: true)
        ledger = ledger_facts(workspace, task, agent)
        {
          "schema_version" => JSON_SCHEMA_VERSION, "ok" => true,
          "workspace" => workspace, "path" => member.path, "kind" => member.kind,
          "ready" => agent["state"] == "done" && git["ahead"].to_i.positive?,
          "task" => task,
          "agent" => agent,
          "git" => git,
          "pull_request" => @pull_request_status.call(member.path),
          "asks" => asks_facts(workspace),
          "sessions" => ledger[:unavailable] ? {"count" => nil, "unavailable" => true} : {"count" => ledger[:session_count]},
          "last_message" => ledger[:last_message]
        }.merge(task_unavailable ? {"task_unavailable" => true} : {})
      end

      def agent_facts(workspace)
        snapshot = @snapshot_client.fetch(workspace, timeout: @agent_timeout)
        panes = Array(snapshot["panes"]).select { |pane| pane["kind"] != "shell" }
        pane_facts = panes.map do |pane|
          {"pane_id" => pane["pane_id"], "kind" => pane["kind"], "state" => pane["state"], "stop_reason" => pane["stop_reason"],
           "state_since" => pane["state_since"]}
        end
        state = STATE_PRECEDENCE.find { |s| pane_facts.any? { |p| p["state"] == s } }
        done = pane_facts.select { |p| p["state"] == "done" }.max_by { |p| p["state_since"].to_s }
        {"available" => true, "state" => state, "stop_reason" => (state == "done") ? done["stop_reason"] : nil,
         "state_since" => (state == "done") ? done["state_since"] : nil, "done_pane_id" => (state == "done") ? done["pane_id"] : nil,
         "panes" => pane_facts}
      rescue AgentSnapshotClient::Unavailable => e
        {"available" => false, "reason" => e.reason.to_s}
      rescue Workspace::Error => e
        {"available" => false, "reason" => "error", "detail" => e.message.lines.first.to_s.strip[0, MAX_ASK_TEXT]}
      end

      # The active task and whether the store couldn't be read: an unreadable store
      # is `[nil, true]`, never a plain nil, so it can't read as "no task".
      def task_state(workspace)
        task = @task_store.active_for(workspace)
        [task && {"id" => task["id"], "title" => task["title"], "ref" => task["ref"], "created_at" => task["created_at"]}, false]
      rescue Workspace::Error, SystemCallError
        [nil, true]
      end

      # Facts from git, read together under one time limit. Without +detail+
      # only what a list row needs.
      def git_facts(path, detail: false)
        bounded { collect_git(path, detail) }
      rescue Workspace::Error, SystemCallError
        {"available" => false, "reason" => "error"}
      end

      def collect_git(path, detail)
        base = @git.base_ref(path)
        return {"available" => false, "reason" => "no_base"} unless base

        ahead = @git.commits_ahead_of(path, base)
        return {"available" => false, "reason" => "error"} if ahead.nil?

        changed = @git.changed_files_count(path)
        unpushed = @git.unpushed_commit_count(path)
        return {"available" => false, "reason" => "error"} if changed.nil? || unpushed.nil?

        facts = {"available" => true, "branch" => @git.worktree_branch(path), "base" => base, "ahead" => ahead,
                 "changed_files" => changed, "unpushed_commits" => unpushed}
        return facts unless detail

        extra = diff_and_commits(path, base)
        return {"available" => false, "reason" => "error"} if extra["diffstat"].nil? || extra["commits"].nil?

        facts.merge(extra)
      end

      def diff_and_commits(path, base)
        stat = @git.diff_stat(path, base)
        commits = @git.commits_since(path, base, limit: MAX_COMMITS)
        {
          "diffstat" => stat && {
            "files" => stat.size, "added" => stat.sum { |e| e["added"].to_i }, "removed" => stat.sum { |e| e["removed"].to_i },
            "entries" => stat.first(MAX_FILES), "truncated" => stat.size > MAX_FILES
          },
          "commits" => commits
        }
      end

      def bounded
        thread = Thread.new do
          Thread.current.report_on_exception = false
          yield
        end
        return thread.value if thread.join(@git_timeout)
        thread.kill
        {"available" => false, "reason" => "timeout"}
      end

      # Open questions are the ones the agent answered with its own default
      # and a person hasn't resolved yet.
      def asks_facts(workspace)
        records = @ask_store_for.call(workspace).list
        open, answered = records.partition { |r| r["status"] == "open" }
        {"open" => open.map { |r| ask_facts(r) }, "answered" => answered.size}
      rescue Workspace::Error => e
        warn_line "workspace review: not reading questions for #{workspace}: #{e.message}"
        {"open" => [], "answered" => 0, "unavailable" => true}
      end

      def ask_facts(record)
        {"id" => record["id"], "question" => cut(record["question"]), "default" => cut(record["default"]),
         "context" => cut(record["context"]), "asked_at" => record["asked_at"]}
      end

      def cut(value)
        value.is_a?(String) ? value[0, MAX_ASK_TEXT] : nil
      end

      # Session count and the last assistant message, both from the ledger's
      # entries for this workspace since its task began (all of them when it
      # has no task). A transcript belongs to the done pane when the ledger
      # knows that pane, else to the latest session.
      def ledger_facts(workspace, task, agent)
        compose_ledger_facts(workspace, task, agent)
      rescue SystemCallError
        {unavailable: true, last_message: nil}
      end

      def compose_ledger_facts(workspace, task, agent)
        since = parse_time(task && task["created_at"])
        entries_for_workspace = @session_ledger.entries_for(workspace)
        entries = entries_for_workspace.select { |e| since.nil? || (parse_time(e["at"]) || Time.at(0)) >= since }
        started = entries.select { |e| e["event"] == "session_start" }
        with_transcript = entries.select { |e| e["transcript_path"].is_a?(String) }
        mine = agent["done_pane_id"] ? with_transcript.select { |e| e["pane_id"] == agent["done_pane_id"] } : []
        chosen = (mine.empty? ? with_transcript : mine).last
        {session_count: started.filter_map { |e| e["session_id"] }.uniq.size,
         last_message: chosen && @transcript_summary.last_assistant_message(chosen["transcript_path"])&.merge("session_id" => chosen["session_id"])}
      end

      def parse_time(text)
        text.is_a?(String) ? Time.parse(text) : nil
      rescue ArgumentError
        nil
      end

      # Text output may carry what an agent or a commit author wrote, so control
      # characters other than newline and tab (terminal escapes) are dropped.
      def say(text = "")
        @output.puts text.to_s.gsub(/[^[:print:]\n\t]/, "")
      end

      def warn_line(text)
        @error_output.puts text.to_s.gsub(/[^[:print:]\t]/, "")
      end

      def print_packet(payload)
        git = payload["git"]
        say "Review  #{payload["workspace"]}   #{payload["path"]}"
        task = payload["task"]
        say "Task    #{task["title"] || task["ref"] || task["id"]}" if task
        say "Task    unavailable (task store unreadable)" if payload["task_unavailable"]
        say "Agent   #{agent_line(payload["agent"])}"
        say "Ready   #{payload["ready"] ? "yes" : "no"}"
        say "Branch  #{git_line(git)}"
        print_diffstat(git["diffstat"])
        say "PR      #{pr_line(payload["pull_request"])}"
        asks = payload["asks"]
        say "Asks    #{asks["open"].size} open, #{asks["answered"]} answered#{" (unreadable)" if asks["unavailable"]}"
        asks["open"].each { |ask| say "  #{ask["question"]}  (took: #{ask["default"]})" }
        say "Sessions  #{payload["sessions"]["count"] || "unavailable (ledger unreadable)"}"
        message = payload["last_message"]
        return say("Last message  none found") unless message
        say "Last message#{" (cut)" if message["truncated"]}"
        message["text"].each_line { |line| say "  #{line.chomp}" }
      end

      def agent_line(agent)
        return "unavailable (#{agent["reason"]})" unless agent["available"]
        return "no agent panes" unless agent["state"]
        reason = agent["stop_reason"] ? " (#{agent["stop_reason"]})" : ""
        since = agent["state_since"] ? " since #{agent["state_since"]}" : ""
        "#{agent["state"]}#{reason}#{since}"
      end

      def git_line(git)
        return "unavailable (#{git["reason"]})" unless git["available"]
        parts = ["#{git["branch"] || "(detached)"} is #{git["ahead"]} ahead of #{git["base"]}"]
        parts << "#{git["changed_files"]} uncommitted" if git["changed_files"].to_i.positive?
        parts << "#{git["unpushed_commits"]} unpushed" if git["unpushed_commits"].to_i.positive?
        parts.join(", ")
      end

      def print_diffstat(stat)
        return unless stat
        say "Diff    #{stat["files"]} files, +#{stat["added"]} -#{stat["removed"]}"
        stat["entries"].first(10).each { |e| say "  #{"+#{e["added"] || "bin"}".ljust(7)}#{"-#{e["removed"] || "bin"}".ljust(7)}#{e["path"]}" }
        say "  ... #{stat["files"] - 10} more" if stat["files"] > 10
      end

      def pr_line(pr)
        return "unavailable (#{pr["reason"]})" unless pr["available"]
        return "none for this branch" unless pr["found"]
        checks = pr["checks"]
        summary = "#{checks["passing"]} passing, #{checks["failing"]} failing, #{checks["pending"]} pending"
        "##{pr["number"]} #{pr["state"]}#{" (draft)" if pr["draft"]}  checks: #{summary}  #{pr["url"]}"
      end

      def print_list(payload)
        rows = payload["reviews"]
        if rows.empty?
          say "Nothing ready for review in #{payload["project"]["name"]}."
        else
          header = %w[WORKSPACE BRANCH AHEAD ASKS TASK]
          lines = rows.map { |r| [r["workspace"], r["branch"].to_s, r["ahead"].to_s, r["open_asks"].to_s, (r.dig("task", "title") || "").to_s] }
          widths = header.each_index.map { |i| ([header[i]] + lines.map { |l| l[i] }).map(&:length).max }
          ([header] + lines).each { |line| say line.each_with_index.map { |cell, i| cell.ljust(widths[i]) }.join("  ").rstrip }
        end
        payload["unavailable"].each { |u| warn_line "workspace review: could not check #{u["workspace"]} (#{u["reason"]})" }
      end
    end
  end
end
