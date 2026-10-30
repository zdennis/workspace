require "digest/sha1"
require "stringio"
require "time"

module Workspace
  # The inbox rows the CLI works out from state it already owns, for
  # `inbox list --include-derived`: open questions, agent panes waiting on a
  # person, blocked or stalled plans, workflow gates waiting for approval, and
  # held locks someone waits on whose holder is dead or idle past the grace.
  # The rules follow workspace-ui's needs-you queue (`queue.ts`) and its
  # `staleLocks`, so the app can read these rows instead.
  #
  # Every row has `"derived": true`, `state` `open`, a stable `id` naming what
  # it is about, and a `fingerprint` that changes with each new episode (a
  # new question, a new wait, a new holder). Nothing is written. A source that
  # can't be read adds a warning and no rows, never an empty answer: an agent
  # daemon that does not answer is `daemons_unavailable`, a plan that can't be
  # located `plan_unreadable`, and so on.
  #
  # The agent daemons are read in parallel, each bounded by its own timeout,
  # beside the workflow read (whose own daemon reads are bounded too).
  class InboxDerived
    # Seconds each agent daemon may take to answer.
    DEFAULT_AGENT_TIMEOUT = 1.0

    # The plan states that need a person on their own (`waiting` is its pane's wait or question, already a row).
    PLAN_STATES = %w[blocked stalled].freeze

    # The longest derived title, as for a posted item.
    TITLE_MAX = 200

    # @param snapshot_client [Workspace::AgentSnapshotClient] reads each daemon's pane states
    # @param tmux [Workspace::Tmux] says which sessions run, so a stopped workspace's daemon is not asked
    # @param ask_store_for [#call] given a workspace name and the stream its warnings go to, returns its
    #   {Workspace::AskStore}; a warning (an unreadable file reads as empty) makes the store unreadable here
    # @param plan [Workspace::Commands::Plan] says where each workspace's plan file is
    # @param plan_state [Workspace::PlanState] works out each plan's state from these reads
    # @param plan_config [Workspace::PlanConfig] reads `plan.stall_seconds`
    # @param workflow_status [Workspace::WorkflowStatus] the runs and the reason each one waits
    # @param lock_namespace [Workspace::LockNamespace] locates a project's lock store
    # @param lock_store_for [#call] given a lock store directory, returns its {Workspace::LockStore}
    # @param lock_config [Workspace::LockConfig] reads `locks.idle_grace`
    # @param clock [#call] returns the current Time
    # @param agent_timeout [Numeric] seconds to wait for each agent daemon
    def initialize(snapshot_client:, tmux:, ask_store_for:, plan:, plan_state:, plan_config:, workflow_status:, lock_namespace:,
      lock_store_for:, lock_config:, clock: -> { Time.now }, agent_timeout: DEFAULT_AGENT_TIMEOUT)
      @snapshot_client = snapshot_client
      @tmux = tmux
      @ask_store_for = ask_store_for
      @plan = plan
      @plan_state = plan_state
      @plan_config = plan_config
      @workflow_status = workflow_status
      @lock_namespace = lock_namespace
      @lock_store_for = lock_store_for
      @lock_config = lock_config
      @clock = clock
      @agent_timeout = agent_timeout
    end

    # @param workspaces [Array<String>] workspaces whose questions, panes, plans and workflow runs to read
    # @param projects [Array<Workspace::ProjectCatalog::Project>] projects whose locks to read
    # @return [Hash] `rows:` (derived items) and `warnings:` (`{"code", "message"}`, some with `"workspace"`)
    def rows(workspaces:, projects:)
      workspaces = workspaces.uniq
      warnings = []
      sessions = running_sessions(warnings) unless workspaces.empty?
      daemons = workspaces.filter_map do |workspace|
        live = running?(workspace, sessions)
        next if live == false
        [workspace, Thread.new do
          Thread.current.report_on_exception = false
          fetch_daemon(workspace)
        end]
      end
      workflow = workspaces.empty? ? nil : Thread.new do
        Thread.current.report_on_exception = false
        read_workflows
      end

      rows = []
      asks = workspaces.to_h { |workspace| [workspace, open_asks(workspace, warnings)] }
      asks.each { |workspace, records| rows.concat(Array(records).map { |record| ask_row(workspace, record) }) }
      panes = daemons.to_h do |workspace, thread|
        reply = thread.value
        if reply[:panes]
          rows.concat(reply[:panes].select { |pane| pane["state"] == "waiting" }.map { |pane| pane_row(workspace, pane) })
        else
          warnings << {"code" => "daemons_unavailable", "workspace" => workspace,
                       "message" => "The agent daemon for '#{workspace}' did not answer (#{reply[:code]}), so its waiting panes are not shown."}
        end
        [workspace, reply[:panes]]
      end
      workspaces.each do |workspace|
        row = plan_row(workspace, running?(workspace, sessions), panes[workspace], asks[workspace], warnings)
        rows << row if row
      end
      rows.concat(workflow_rows(workflow&.value, workspaces, warnings))
      projects.each { |project| rows.concat(lock_rows(project, warnings)) }
      {rows: rows, warnings: warnings}
    end

    private

    def running_sessions(warnings)
      @tmux.sessions(strict: true)
    rescue Workspace::Error, SystemCallError => e
      warnings << {"code" => "tmux_unavailable", "message" => "Running sessions are unknown, so every workspace's daemon is asked: #{first_line(e)}"}
      nil
    end

    # nil when unknown, which still asks the daemon.
    def running?(workspace, sessions)
      return nil if sessions.nil? || @tmux.custom_socket_option(workspace)
      sessions.include?(@tmux.session_name_for(workspace))
    end

    def fetch_daemon(workspace)
      {panes: Array(@snapshot_client.fetch(workspace, timeout: @agent_timeout)["panes"])}
    rescue AgentSnapshotClient::Unavailable => e
      {code: (e.reason == :timeout) ? "timeout" : "no_daemon"}
    rescue => e
      {code: "unreadable_reply", detail: first_line(e)}
    end

    # nil, with a warning, when the store can't be read: it raises, or reads as empty after a warning.
    def open_asks(workspace, warnings)
      sink = StringIO.new
      records = @ask_store_for.call(workspace, sink).list(open_only: true)
      raise Workspace::Error, sink.string.lines.first.to_s.strip unless sink.string.empty?
      records
    rescue => e
      warnings << {"code" => "questions_unreadable", "workspace" => workspace,
                   "message" => "The questions of '#{workspace}' could not be read, so they are not shown: #{first_line(e)}"}
      nil
    end

    def ask_row(workspace, record)
      question = record["question"].to_s
      row(id: "ask:#{workspace}:#{record["id"]}", kind: "ask", fingerprint: record["asked_at"], scope: workspace_scope(workspace),
        title: one_line(question), body: question, since: record["asked_at"], links: {"pane" => record["pane"]})
    end

    def pane_row(workspace, pane)
      row(id: "pane:waiting:#{workspace}:#{pane["pane_id"]}", kind: "pane_waiting", fingerprint: pane["state_since"],
        scope: workspace_scope(workspace), title: "An agent is waiting in #{workspace} (#{pane["pane_id"]})",
        body: pane["waiting_message"], since: pane["state_since"], links: {"pane" => pane["pane_id"]})
    end

    # Worked out from the reads already made (no second look at tmux, the daemon or the questions);
    # an unknown fact never decides the state.
    def plan_row(workspace, live, panes, asks, warnings)
      path = @plan.path_for(workspace)
      plan = PlanFile.read(path)
      return nil unless plan
      state = @plan_state.row(workspace: workspace, project: nil, path: path, plan: plan, session_live: live, panes: panes,
        open_asks: Array(asks).size, stall_seconds: @plan_config.stall_seconds_for(workspace))
      return nil unless PLAN_STATES.include?(state["state"])
      current = state["current"]
      row(id: "plan:#{state["state"]}:#{workspace}", kind: "plan_#{state["state"]}",
        fingerprint: state["updated_at"] || current&.fetch("id", nil), scope: workspace_scope(workspace),
        title: "Plan #{state["state"]} in #{workspace}", body: state["title"], since: state["updated_at"],
        links: {"plan_task" => current&.fetch("id", nil)})
    rescue => e
      warnings << {"code" => "plan_unreadable", "workspace" => workspace,
                   "message" => "The plan of '#{workspace}' could not be read, so its state is not shown: #{first_line(e)}"}
      nil
    end

    def read_workflows
      {runs: @workflow_status.runs}
    rescue => e
      {error: first_line(e)}
    end

    # A gate waiting for approval, as workspace-ui's `gateOf`: a prompt or a
    # question that holds a run is already the pane's or the question's row.
    def workflow_rows(reply, workspaces, warnings)
      return [] unless reply
      if reply[:error]
        warnings << {"code" => "workflow_unreadable", "message" => "Workflow runs could not be read, so their gates are not shown: #{reply[:error]}"}
        return []
      end
      reply[:runs]["warnings"].each { |message| warnings << {"code" => "workflow_unreadable", "message" => message} }
      reply[:runs]["runs"].filter_map do |run|
        next unless workspaces.include?(run["workspace"])
        current = run["current"] || {}
        reason = current["reason"]
        next unless reason && reason["code"] == "waiting_you" && reason.dig("details", "kind") == "gate"
        step = Array(run["steps"]).find { |each| each["id"] == current["step"] }
        next unless step && step["gate"] == "waiting"
        row(id: "workflow:waiting_you:#{run["id"]}", kind: "workflow_waiting_you", fingerprint: "#{current["step"]}:#{reason["since"]}",
          scope: workspace_scope(run["workspace"]), title: "Workflow #{run["title"] || run["workflow"]} waits for approval at #{current["step"]}",
          body: nil, since: reason["since"],
          links: {"run_id" => run["id"], "step" => current["step"], "attempt" => current["attempt"]})
      end
    end

    # As workspace-ui's `staleLocks`: a held lock with a live waiter whose holder is dead, or an
    # agent holder idle past `locks.idle_grace`; a holder being cleared is already handled.
    def lock_rows(project, warnings)
      namespace = @lock_namespace.resolve(cwd: project.path)
      return [] unless File.directory?(namespace[:dir])
      entries = @lock_store_for.call(namespace[:dir]).status
      grace = @lock_config.idle_grace_for(namespace[:display])
      now = @clock.call.to_i
      sha = Digest::SHA1.hexdigest(namespace[:key])[0, 12]
      entries.filter_map do |name, entry|
        holder = entry["holder"]
        waiting = Array(entry["queue"]).count { |waiter| !waiter["stale"] }
        next if holder.nil? || holder["clearing"] || waiting.zero?
        idle = holder["kind"] != "process" && holder["idle_since"].is_a?(Numeric) && now - holder["idle_since"] >= grace
        next unless holder["stale"] || idle
        reason = holder["stale"] ? "its holder is gone" : "its holder has been idle"
        # A new idle spell of the same holder is a new episode, as the app's `holderSince` is.
        fingerprint = [holder["acquired_at"], holder["idle_since"]].compact.join(":")
        row(id: "lock:stale:#{sha}:#{name}", kind: "lock_stale", fingerprint: fingerprint,
          scope: {"kind" => "project", "key" => project.id, "name" => project.name},
          title: "Lock #{name} in #{project.name} is stuck: #{reason} and #{waiting} waiting", body: nil, since: holder["acquired_at"],
          links: {"pane" => holder["pane"]})
      end
    rescue => e
      warnings << {"code" => "locks_unreadable", "project" => project.name,
                   "message" => "The locks of '#{project.name}' could not be read, so stuck locks are not shown: #{first_line(e)}"}
      []
    end

    def row(id:, kind:, fingerprint:, scope:, title:, body:, since:, links:)
      {
        "id" => id, "derived" => true, "kind" => kind, "fingerprint" => fingerprint.to_s, "type" => "alert", "state" => "open",
        "scope" => scope, "title" => title, "body" => body,
        "links" => {"pane" => nil, "plan_task" => nil, "pr" => nil, "run_id" => nil}.merge(links),
        "created_at" => since, "updated_at" => since
      }
    end

    def workspace_scope(workspace)
      {"kind" => "workspace", "key" => workspace, "name" => workspace}
    end

    def one_line(text)
      line = text.lines.first.to_s.strip
      (line.length > TITLE_MAX) ? "#{line[0, TITLE_MAX - 3]}..." : line
    end

    def first_line(error)
      error.message.lines.first.to_s.strip
    end
  end
end
