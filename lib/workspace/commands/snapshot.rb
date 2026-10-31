require "digest"
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
      # @param plan [Workspace::Commands::Plan] says where each workspace's plan file is
      # @param plan_state [Workspace::PlanState] works out each plan's state from the snapshot's own reads
      # @param plan_config [Workspace::PlanConfig] reads `plan.stall_seconds`
      # @param task_store [Workspace::TaskStore] read once per run for the task of a member whose daemon gave none
      # @param spine [Workspace::Commands::Spine] reads each workspace's `spine/` folder
      # @param spine_facts [Workspace::SpineFacts] maps the snapshot's own reads into the facts the stages are judged against
      # @param output [IO] stream for the JSON document
      # @param error_output [IO] stream for warnings that must stay out of script-readable output
      # @param clock [#now] time source, injected for tests
      # @param agent_timeout [Numeric] seconds to wait for each agent daemon
      # @param groups [Workspace::ProjectGroups, nil] says which group each project's repository is in; nil means none has one
      # @param spine_inferred [Workspace::SpineInferred, nil] works out the stage of a member with no `spine/`, for `document(inferred: true)`
      def initialize(catalog:, facts:, tmux:, state:, config:, snapshot_client:, sessions:, git:, pull_request_status:, ask_store_for:, plan:, plan_state:, plan_config:, task_store:, spine:, spine_facts:,
        output: $stdout, error_output: $stderr, clock: Time, agent_timeout: DEFAULT_AGENT_TIMEOUT, groups: nil, spine_inferred: nil)
        @groups = groups
        @spine_inferred = spine_inferred
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
        @plan = plan
        @plan_state = plan_state
        @plan_config = plan_config
        @task_store = task_store
        @spine = spine
        @spine_facts = spine_facts
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
        @output.puts JSON.generate(document(names: names, pr: pr))
        {exit_code: 0}
      rescue => e
        @output.puts JSON.generate(Workspace::JsonEnvelope.from_exception(JSON_SCHEMA_VERSION, e, message: e.message.lines.first.to_s.strip))
        {exit_code: 1}
      end

      # The snapshot document, as {#call} prints it.
      #
      # @param names [Array<String>] see {#call}
      # @param pr [Boolean] see {#call}
      # @param inferred [Boolean] give a member with no `spine/` its current inferred stage as `spine.inferred`
      #   (a `goal` stage hash, or nil); needs +spine_inferred+. Off, the document is as it always was.
      # @return [Hash]
      # @raise [Workspace::Error] `unknown_workspace` for a name nobody has
      def document(names: [], pr: false, inferred: false)
        @stored_tasks = nil
        @raw_prs = {}
        @plan_files = {}
        @with_inferred = inferred && !@spine_inferred.nil?
        @group_map = @groups ? @groups.groups_by_project_id : {}
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
        {
          "schema_version" => JSON_SCHEMA_VERSION, "ok" => true, "generated_at" => @clock.now.utc.iso8601(3), "cursor" => cursor,
          "projects" => rows, "daemons_unavailable" => unavailable, "warnings" => warnings
        }
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
          next [member["workspace"], [{"available" => false, "reason" => "git_unavailable"}, nil]] unless git["available"] && git["branch"]
          [member["workspace"], Thread.new do
            Thread.current.report_on_exception = false
            pull_request(member["path"])
          end]
        end
        results = threads.to_h { |workspace, thread| [workspace, thread.is_a?(Thread) ? thread.value : thread] }
        @raw_prs = results.transform_values(&:last)
        results.transform_values(&:first)
      end

      # @return [Array(Hash, Hash)] the block `git.pr` shows, and the answer as {PullRequestStatus} gave it
      #   (the error block when it raised)
      def pull_request(path)
        pr = @pull_request_status.call(path)
        return [{"available" => false, "reason" => pr["reason"]}, pr] unless pr["available"]
        return [{"available" => true, "found" => false}, pr] unless pr["found"]
        [{"available" => true, "found" => true, "number" => pr["number"], "url" => pr["url"], "state" => pr["state"].to_s.downcase,
          "draft" => pr["draft"], "review_decision" => pr["review_decision"], "checks" => checks_label(pr["checks"])}, pr]
      rescue => e
        failed = {"available" => false, "reason" => "error", "detail" => e.message.lines.first.to_s.strip}
        [failed, failed]
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
        group = @group_map[project.id]
        {"id" => project.id, "name" => project.name, "group" => group && {"id" => group.id, "name" => group.name}, "members" => members, "locks" => lock_rows(gathered[:locks]), "dev" => gathered[:dev]}
      end

      def member_row(facts, gathered, daemon, pr, sessions, unavailable, warnings)
        workspace = facts["workspace"]
        running = running?(workspace, sessions)
        snapshot = daemon && daemon[:snapshot]
        unavailable << {"workspace" => workspace, "code" => daemon[:code]} if daemon && daemon[:code]
        member_panes = snapshot ? panes(snapshot) : nil
        member_questions = questions(workspace, warnings)
        row = {
          "workspace" => workspace, "kind" => facts["kind"], "path" => facts["path"], "tmux_session" => @tmux.session_name_for(workspace),
          "running" => running, "headless" => facts["headless"], "iterm_window_id" => iterm_window_id(workspace),
          "daemon" => {"up" => !snapshot.nil?, "pid" => nil, "log_path" => @config.agent_log_path(workspace)},
          "git" => git_block(facts["path"], gathered[:git_by_workspace][workspace], pr),
          "panes" => member_panes,
          "questions" => member_questions,
          "pipeline" => facts["pipeline"],
          "plan" => plan_block(workspace, running, member_panes, member_questions, facts, warnings)
        }
        row["spine"] = spine_block(workspace, facts["path"], gathered[:git_by_workspace][workspace], daemon, snapshot, member_questions, warnings)
        row["task"] = snapshot ? snapshot["task"] : stored_task(workspace, warnings)
        row
      end

      # The task `start` recorded for a workspace whose daemon gave none, so a
      # stopped or ended workspace keeps its goal. Same keys as the daemon's
      # task plus `outcome`; `status` is "stopped" for an active task and
      # "archived" once `finish` or `kill` ended it. nil when none was
      # recorded or the store can't be read.
      def stored_task(workspace, warnings)
        record = stored_tasks(warnings)[workspace]
        return nil unless record
        {"id" => record["id"], "title" => record["title"], "ref" => record["ref"], "branch" => record["branch"],
         "status" => record["outcome"] ? "archived" : "stopped", "outcome" => record["outcome"]}
      end

      def stored_tasks(warnings)
        @stored_tasks ||= begin
          @task_store.latest_by_workspace
        rescue Workspace::Error, SystemCallError => e
          warnings << {"code" => "task_store_unavailable", "message" => e.message}
          {}
        end
      end

      # The member's plan without its tasks, worked out from reads the snapshot
      # already made (no second look at tmux, the daemon or the ask store).
      # nil when there is no plan file, or when the plan can't be located (with
      # a warning); a file that can't be read or parsed still gives a block,
      # with its `state` and `counts` as PlanFile reports them.
      def plan_block(workspace, running, member_panes, member_questions, facts, warnings)
        path = @plan.path_for(workspace)
        plan = plan_file(workspace, path)
        return nil unless plan
        open_asks = member_questions ? member_questions.size : facts["open_asks"].to_i
        row = @plan_state.row(workspace: workspace, project: nil, path: path, plan: plan, session_live: running, panes: member_panes,
          open_asks: open_asks, stall_seconds: @plan_config.stall_seconds_for(workspace))
        row.slice("state", "status", "signature", "counts", "percent", "current", "updated_at")
      rescue => e
        warnings << {"code" => "plan_unavailable", "workspace" => workspace, "message" => e.message.lines.first.to_s.strip}
        nil
      end

      # The parsed plan, read once per member whichever block asks first; nil when there is no plan file.
      def plan_file(workspace, path = @plan.path_for(workspace))
        @plan_files.fetch(workspace) { @plan_files[workspace] = PlanFile.read(path) }
      end

      # The stages of the member's `spine/`, judged by {SpineEvaluator} against the reads the snapshot
      # already made, through {SpineFacts#facts_from}: the plan file, the git block (plus one
      # `upstream_config` read for a branch with no upstream), the daemon panes (which give the review
      # agent's state too) and, with `--pr`, the pull request. Nothing here runs `gh` or asks a daemon (a review gate in a workspace with no daemon reads the event log, as `review show` does).
      # `{"exists" => false}` when there is no `spine/` folder; nil, with a `spine_unavailable` warning,
      # when it can't be looked for.
      def spine_block(workspace, path, git_fact, daemon, snapshot, member_questions, warnings)
        tree = @spine.read(workspace)
        unless tree.exists
          return {"exists" => false} unless @with_inferred
          readings = spine_readings(workspace, path, git_fact, daemon, snapshot, member_questions, false)
          result = @spine_facts.facts_from(workspace, readings)
          return {"exists" => false, "inferred" => @spine_inferred.current_stage(workspace: workspace, checkout: path, result: result)}
        end
        review = SpineFacts.gates_in(tree.stages).include?("review")
        readings = spine_readings(workspace, path, git_fact, daemon, snapshot, member_questions, review)
        result = @spine_facts.facts_from(workspace, readings)
        docs = SpineEvaluator.evaluate_stages(tree.stages, result.facts)
        spine_row(tree, docs, partial: spine_partial?(docs, result.facts, review))
      rescue Workspace::Error, SystemCallError => e
        warnings << {"code" => "spine_unavailable", "workspace" => workspace, "message" => e.message.lines.first.to_s.strip}
        nil
      end

      def spine_readings(workspace, path, git_fact, daemon, snapshot, member_questions, review)
        SpineFacts::Readings.new(
          plan: spine_plan(workspace), git: spine_git(path, git_fact), pull_request: @raw_prs[workspace],
          panes: snapshot && Array(snapshot["panes"]), daemon_reason: spine_daemon_reason(daemon), asks: member_questions,
          review_ahead: review ? @spine_facts.commits_ahead_of_base(path) : nil, review: review
        )
      end

      def spine_row(tree, docs, partial:)
        current = docs.find { |doc| doc["path"] == SpineEvaluator.current(docs) }
        counts = SpineRollup::STATES.to_h { |state| [state, 0] }
        docs.each { |doc| counts[counts.key?(doc["state"]) ? doc["state"] : "unknown"] += 1 }
        {"exists" => true, "current" => current&.fetch("path"), "title" => current&.fetch("title"), "state" => current&.fetch("state"),
         "status" => current&.fetch("status"), "owner" => current&.fetch("owner"), "owner_state" => current&.fetch("owner_state"),
         "stages" => docs.size, "counts" => counts, "signature" => spine_signature(tree), "partial" => partial}
      end

      # 8 hex of the SHA-256 over the goal file's and every stage file's revision, in tree order.
      def spine_signature(tree)
        revisions = [tree.goal&.revision]
        tree.each_stage { |stage| revisions << stage.file&.revision }
        Digest::SHA256.hexdigest(revisions.compact.join("\n"))[0, 8]
      end

      # Whether a declared gate went unjudged: a gate left `unchecked`, or a review gate decided
      # on the agent alone because the pull request wasn't read.
      def spine_partial?(docs, facts, review)
        return true if review && facts.review && facts.pr.nil?
        docs.any? { |doc| doc["gate_results"].any? { |gate| gate["result"] == "unchecked" } || spine_partial?(doc["children"], facts, false) }
      end

      # The plan as {SpineFacts::Readings} wants it: `:missing` without a file, nil when it can't be read.
      def spine_plan(workspace)
        plan = plan_file(workspace) || :missing
        plan unless plan != :missing && plan.warnings.any? { |warning| warning["code"] == "unreadable" }
      rescue Workspace::Error, SystemCallError
        nil
      end

      # The git block as {SpineFacts::Readings} wants it. A branch with no upstream costs one
      # `upstream_config` read, to tell a deleted remote branch from a branch never pushed.
      def spine_git(path, fact)
        return nil unless fact && fact["available"]
        branch = fact["branch"]
        return {"branch" => nil} unless branch
        upstream = fact["upstream"]
        {"branch" => branch, "upstream" => upstream, "ahead" => fact["ahead"],
         "upstream_configured" => upstream ? true : !@git.upstream_config(path, branch).nil?}
      rescue Workspace::Error, SystemCallError
        nil
      end

      def spine_daemon_reason(daemon)
        return "no_daemon" unless daemon
        code = daemon[:code]
        [nil, "timeout", "no_daemon"].include?(code) ? code : "error"
      end

      def iterm_window_id(workspace)
        info = @state[workspace]
        info.is_a?(Hash) ? info["iterm_window_id"] : nil
      end

      def git_block(path, fact, pr)
        return nil unless fact
        block = fact.slice("available", "reason", "branch", "changed_files", "ahead", "upstream", "unpushed_commits", "unsaved")
        block["base"] = fact["available"] ? base_ref(path) : nil
        block["ahead_of_base"] = block["base"] ? ahead_of_base(path, block["base"]) : nil
        block["pr"] = pr if pr
        block
      end

      # Commits the branch has that its base lacks; nil when git cannot answer, so a failure never reads as 0.
      def ahead_of_base(path, base)
        @git.commits_ahead_of(path, base)
      rescue Workspace::Error, SystemCallError
        nil
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
            "stop_reason" => pane["stop_reason"], "waiting_message" => pane["waiting_message"], "waiting_tool" => pane["waiting_tool"], "waiting_input" => pane["waiting_input"], "context_pct" => pane["context_pct"],
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
