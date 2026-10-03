require "json"
require "time"

module Workspace
  module Commands
    # Prints everything a UI polls for in one document: every project (or the
    # named workspaces), each member's running state, git facts, agent panes,
    # open questions and pipeline entries, plus the repo-wide locks and dev
    # environment.
    #
    # It composes readers the CLI already has ({Workspace::ProjectCatalog},
    # {Workspace::ProjectFacts}, the sessions pane annotations, the agent
    # snapshot client, `gh pr view` with `--pr`) and writes nothing. A source
    # that can't answer is reported as unavailable, never as clean or empty:
    # an unreadable tmux makes `running` null, a daemon that is down or slow
    # makes `panes` null and adds a `daemons_unavailable` row, and a git read
    # that fails is `unsaved: "unknown"`.
    #
    # The agent daemons are read in parallel, each bounded by its own timeout,
    # because a daemon serves one connection at a time and a serial fan-out
    # would cost a second per workspace.
    class Snapshot
      # Bumped whenever the `--json` payload's shape changes in a
      # backward-incompatible way.
      JSON_SCHEMA_VERSION = 1

      # Seconds each agent daemon may take to answer.
      DEFAULT_AGENT_TIMEOUT = 1.0

      # @param catalog [Workspace::ProjectCatalog] groups workspaces into projects
      # @param facts [Workspace::ProjectFacts] per-member, lock and dev facts and parallel git reads
      # @param tmux [Workspace::Tmux] lists running sessions and maps workspace names to them
      # @param state [Workspace::State] session state, read for each window id
      # @param config [Workspace::Config] event log and daemon log paths
      # @param snapshot_client [Workspace::AgentSnapshotClient] reads each daemon's pane states
      # @param sessions [Workspace::Commands::Sessions] stamps panes with their lock and open-question columns
      # @param git [Workspace::Git] base ref reads
      # @param pull_request_status [Workspace::PullRequestStatus] reads a branch's pull request, only with +pr+
      # @param ask_store_for [#call] given a workspace name, returns its {Workspace::AskStore}
      # @param output [IO] stream for the JSON document
      # @param error_output [IO] stream for warnings that must stay out of script-readable output
      # @param clock [#now] time source, injected for tests
      # @param agent_timeout [Numeric] seconds to wait for each agent daemon
      def initialize(catalog:, facts:, tmux:, state:, config:, snapshot_client:, sessions:, git:, pull_request_status:, ask_store_for:,
        output: $stdout, error_output: $stderr, clock: Time, agent_timeout: DEFAULT_AGENT_TIMEOUT)
        @catalog = catalog
        @facts = facts
        @tmux = tmux
        @state = state
        @config = config
        @snapshot_client = snapshot_client
        @sessions = sessions
        @git = git
        @pull_request_status = pull_request_status
        @ask_store_for = ask_store_for
        @output = output
        @error_output = error_output
        @clock = clock
        @agent_timeout = agent_timeout
      end

      # Prints the snapshot document.
      #
      # @param names [Array<String>] workspaces to include; empty means every project's workspaces.
      #   Each named workspace's project is included with only the named members.
      # @param pr [Boolean] read each checkout's pull request with `gh` (one read per member, in parallel)
      # @return [Hash] `{exit_code:}`; 1 only after a JSON error payload was printed
      def call(names: [], pr: false)
        cursor, cursor_warning = event_cursor
        warnings = []
        warnings << cursor_warning if cursor_warning
        projects = select_projects(names)
        sessions = running_sessions(warnings)
        @state.load
        gathered = projects.map { |project| [project, gather(project, sessions)] }
        daemons = read_daemons(gathered, sessions)
        pairs = gathered.flat_map { |_, g| g[:members].map { |m| [m, g[:git_by_workspace][m["workspace"]]] } }
        prs = pr ? read_pull_requests(pairs) : {}
        unavailable = []
        rows = gathered.map { |project, g| project_row(project, g, daemons, prs, sessions, unavailable, warnings) }
        @output.puts JSON.generate({
          "schema_version" => JSON_SCHEMA_VERSION, "ok" => true, "generated_at" => @clock.now.utc.iso8601(3), "cursor" => cursor,
          "projects" => rows, "daemons_unavailable" => unavailable, "warnings" => warnings
        })
        {exit_code: 0}
      rescue => e
        @output.puts JSON.generate(Workspace::JsonEnvelope.from_exception(JSON_SCHEMA_VERSION, e, message: e.message.lines.first.to_s.strip))
        {exit_code: 1}
      end

      private

      # Taken before anything else is read, so an event appended while the
      # snapshot is gathered lies after the cursor and a follower sees it.
      # An absent log is an empty one. Format: `ev:<inode>:<byte offset>`.
      def event_cursor
        stat = File.stat(@config.event_log_file)
        ["ev:#{stat.ino}:#{stat.size}", nil]
      rescue Errno::ENOENT
        ["ev:0:0", nil]
      rescue SystemCallError => e
        [nil, {"code" => "cursor_unavailable", "message" => "The event log could not be read: #{e.message}"}]
      end

      def select_projects(names)
        return @catalog.all if names.empty?
        all_members = @catalog.all.flat_map { |project| project.members.map { |m| [project, m] } }
        names.uniq.each do |name|
          next if all_members.any? { |_, m| m.workspace == name }
          raise Workspace::Error.new("Unknown workspace '#{name}'.", code: "unknown_workspace", details: {"name" => name})
        end
        @catalog.all.filter_map do |project|
          kept = project.members.select { |m| names.include?(m.workspace) }
          next if kept.empty?
          ProjectCatalog::Project.new(name: project.name, id: project.id, path: project.path, vcs: project.vcs, members: kept)
        end
      end

      # nil when tmux can't be asked, which makes `running` null rather than false.
      def running_sessions(warnings)
        @tmux.sessions(strict: true)
      rescue Workspace::Error, SystemCallError => e
        warnings << {"code" => "tmux_unavailable", "message" => "Running state is unknown: #{e.message.lines.first.to_s.strip}"}
        nil
      end

      def running?(workspace, sessions)
        return nil if sessions.nil? || @tmux.custom_socket_option(workspace)
        sessions.include?(@tmux.session_name_for(workspace))
      end

      # Configured members with a checkout; an unconfigured worktree is not a workspace.
      def gather(project, sessions)
        members = project.members.select { |m| m.configured && m.exists }
        gone = project.members.select { |m| m.configured && !m.exists }
        local = ProjectCatalog::Project.new(name: project.name, id: project.id, path: project.path, vcs: project.vcs, members: members)
        facts = @facts.for_project(local, sessions: sessions || [], agents: false, timeout: DEFAULT_AGENT_TIMEOUT, git: false)
        git = @facts.git_facts(local, members, deadline: @facts.git_deadline)
        {members: facts[:members], locks: facts[:locks], dev: facts[:dev], errors: facts[:errors], gone: gone,
         git_by_workspace: members.zip(git).to_h { |member, fact| [member.workspace, fact] }}
      end

      # One thread per workspace; each read is bounded by the client's timeout.
      def read_daemons(gathered, sessions)
        threads = gathered.flat_map { |_, g| g[:members] }.filter_map do |member|
          workspace = member["workspace"]
          next unless workspace && running?(workspace, sessions) != false
          [workspace, Thread.new do
            Thread.current.report_on_exception = false
            fetch_daemon(workspace)
          end]
        end
        threads.to_h { |workspace, thread| [workspace, thread.value] }
      end

      def fetch_daemon(workspace)
        snapshot = @snapshot_client.fetch(workspace, timeout: @agent_timeout)
        @sessions.annotate(workspace, snapshot)
        {snapshot: snapshot}
      rescue AgentSnapshotClient::Unavailable => e
        {code: (e.reason == :timeout) ? "timeout" : "no_daemon"}
      rescue => e
        {code: "unreadable_reply", detail: e.message.lines.first.to_s.strip}
      end

      def read_pull_requests(pairs)
        threads = pairs.filter_map do |member, git|
          next unless git
          next [member["workspace"], {"available" => false, "reason" => "git_unavailable"}] unless git["available"] && git["branch"]
          [member["workspace"], Thread.new do
            Thread.current.report_on_exception = false
            pull_request(member["path"])
          end]
        end
        threads.to_h { |workspace, thread| [workspace, thread.is_a?(Thread) ? thread.value : thread] }
      end

      def pull_request(path)
        pr = @pull_request_status.call(path)
        return {"available" => false, "reason" => pr["reason"]} unless pr["available"]
        return {"available" => true, "found" => false} unless pr["found"]
        {"available" => true, "found" => true, "number" => pr["number"], "url" => pr["url"], "state" => pr["state"].to_s.downcase,
         "draft" => pr["draft"], "review_decision" => pr["review_decision"], "checks" => checks_label(pr["checks"])}
      rescue => e
        {"available" => false, "reason" => "error", "detail" => e.message.lines.first.to_s.strip}
      end

      def checks_label(checks)
        return "none" if checks["total"].zero?
        return "failing" if checks["failing"].positive?
        checks["pending"].positive? ? "pending" : "passing"
      end

      def project_row(project, gathered, daemons, prs, sessions, unavailable, warnings)
        gathered[:errors].each { |source, message| warnings << {"code" => "#{source}_unavailable", "message" => message} }
        members = gathered[:members].map do |facts|
          member_row(facts, gathered, daemons[facts["workspace"]], prs[facts["workspace"]], sessions, unavailable, warnings)
        end
        gathered[:gone].each { |member| warnings << {"code" => "checkout_missing", "workspace" => member.workspace, "message" => "Checkout is gone: #{member.path}"} }
        {"id" => project.id, "name" => project.name, "members" => members, "locks" => lock_rows(gathered[:locks]), "dev" => gathered[:dev]}
      end

      def member_row(facts, gathered, daemon, pr, sessions, unavailable, warnings)
        workspace = facts["workspace"]
        running = running?(workspace, sessions)
        snapshot = daemon && daemon[:snapshot]
        unavailable << {"workspace" => workspace, "code" => daemon[:code]} if daemon && daemon[:code]
        row = {
          "workspace" => workspace, "kind" => facts["kind"], "path" => facts["path"], "tmux_session" => @tmux.session_name_for(workspace),
          "running" => running, "headless" => facts["headless"], "iterm_window_id" => iterm_window_id(workspace),
          "daemon" => {"up" => !snapshot.nil?, "pid" => nil, "log_path" => @config.agent_log_path(workspace)},
          "git" => git_block(facts["path"], gathered[:git_by_workspace][workspace], pr),
          "panes" => snapshot ? panes(snapshot) : nil,
          "questions" => questions(workspace, warnings),
          "pipeline" => facts["pipeline"]
        }
        row["task"] = snapshot["task"] if snapshot
        row
      end

      def iterm_window_id(workspace)
        info = @state[workspace]
        info.is_a?(Hash) ? info["iterm_window_id"] : nil
      end

      def git_block(path, fact, pr)
        return nil unless fact
        block = fact.slice("available", "reason", "branch", "changed_files", "ahead", "upstream", "unpushed_commits", "unsaved")
        block["base"] = fact["available"] ? base_ref(path) : nil
        block["pr"] = pr if pr
        block
      end

      def base_ref(path)
        @git.base_ref(path)
      rescue Workspace::Error, SystemCallError
        nil
      end

      def panes(snapshot)
        Array(snapshot["panes"]).map do |pane|
          {
            "pane_id" => pane["pane_id"], "index" => pane["index"], "kind" => pane["kind"], "title" => pane["title"],
            "display_label" => pane["display_label"], "state" => pane["state"], "state_since" => pane["state_since"],
            "stop_reason" => pane["stop_reason"], "waiting_message" => pane["waiting_message"], "context_pct" => pane["context_pct"],
            "agents" => Array(pane["agents"]).map { |agent| {"name" => agent["name"], "state" => agent["state"]} },
            "lock" => pane["lock_name"], "lock_state" => pane["lock_state"], "open_questions" => pane["open_questions"]
          }
        end
      end

      # nil, not empty, when the store can't be read.
      def questions(workspace, warnings)
        @ask_store_for.call(workspace).list(open_only: true).map do |record|
          {"id" => record["id"], "question" => record["question"], "default" => record["default"], "pane" => record["pane"],
           "asked_at" => record["asked_at"], "status" => record["status"]}
        end
      rescue => e
        warnings << {"code" => "questions_unavailable", "workspace" => workspace, "message" => e.message.lines.first.to_s.strip}
        nil
      end

      def lock_rows(locks)
        return nil if locks.nil?
        locks.map { |name, entry| {"name" => name, "holder" => entry["holder"], "queue" => entry["queue"]} }
      end
    end
  end
end
