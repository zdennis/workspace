require "json"

module Workspace
  module Commands
    # `goal show [REF]` and `goal list`: where a goal is at each level (the goal,
    # its journey stage, its workflow step, the agent's turn, the tool call), what
    # it waits for and on whom. A goal is a workspace; a run id, task id, ticket
    # key, URL or branch resolves to the workspace that holds it.
    #
    # It only combines reads that exist: the snapshot's member row (plan, spine,
    # panes, task, git, questions), {Workspace::WorkflowStatus#runs}, {Workspace::SpineInferred}
    # for a workspace with no `spine/`, and the daemon's panes for the tool call.
    # It writes nothing and makes no `gh` call. A level with nothing to show is
    # null; a source that can't answer is null and a warning, never an error.
    class Goal
      # Bumped whenever the `--json` payload's shape changes in a backward-incompatible way.
      JSON_SCHEMA_VERSION = 1

      # What `unknown_goal` lists as tried, in order.
      TRIED = %w[workspace run task ref branch].freeze

      # Seconds the daemon may take to give the tool call.
      DAEMON_TIMEOUT = 1.0

      WAITING_REASONS = %w[waiting_you failed_check turn_ended_incomplete].freeze
      private_constant :WAITING_REASONS

      # @param snapshot_reader [#call] given an Array of workspace names (empty for all), returns the parsed
      #   `snapshot --json` document
      # @param catalog [Workspace::ProjectCatalog] knows every workspace's name
      # @param task_store [Workspace::TaskStore] resolves a task id, ref or branch
      # @param workflow_status [Workspace::WorkflowStatus] the workspace's runs
      # @param start_ref [Workspace::StartRef] reads a ticket key, URL or branch
      # @param plan [Workspace::Commands::Plan] says where a workspace's plan file is
      # @param spine_facts [Workspace::SpineFacts] maps reads into the facts inferred stages are judged against
      # @param spine_inferred [Workspace::SpineInferred] the stages of a workspace with no `spine/`
      # @param snapshot_client [Workspace::AgentSnapshotClient] reads the daemon's panes for the tool call
      # @param output [IO]
      def initialize(snapshot_reader:, catalog:, task_store:, workflow_status:, start_ref:, plan:, spine_facts:, spine_inferred:, snapshot_client:, output: $stdout)
        @snapshot_reader = snapshot_reader
        @catalog = catalog
        @task_store = task_store
        @workflow_status = workflow_status
        @start_ref = start_ref
        @plan = plan
        @spine_facts = spine_facts
        @spine_inferred = spine_inferred
        @snapshot_client = snapshot_client
        @output = output
      end

      # @param ref [String] workspace name, run id, task id, ticket key or URL, or branch
      # @param json [Boolean] print the document documented in docs/README.goal.md
      # @return [void]
      # @raise [Workspace::Error] `unknown_goal` or `ambiguous_goal`
      def show(ref, json: false)
        warnings = []
        name, document = resolve(ref, warnings)
        document ||= @snapshot_reader.call([name])
        runs = runs_for(name, warnings)
        goal = build(name, document, runs, warnings, detail: true)
        out = {"schema_version" => JSON_SCHEMA_VERSION, "ok" => true, "goal" => goal,
               "warnings" => warnings + Array(document["warnings"])}
        json ? @output.puts(JSON.generate(out)) : print_show(out)
      end

      # @param all [Boolean] include workspaces whose goal `state` is `none`
      # @param json [Boolean]
      # @return [void]
      def list(all: false, json: false)
        warnings = []
        document = @snapshot_reader.call([])
        by_workspace = runs_by_workspace(warnings)
        goals = members(document).map do |project, member|
          build(member["workspace"], {"projects" => [project.merge("members" => [member])]}, by_workspace.fetch(member["workspace"], []), warnings, detail: false)
        end
        goals = goals.reject { |goal| goal["state"] == "none" } unless all
        out = {"schema_version" => JSON_SCHEMA_VERSION, "ok" => true, "goals" => goals, "warnings" => warnings + Array(document["warnings"])}
        json ? @output.puts(JSON.generate(out)) : print_list(out)
      end

      private

      # --- resolution -------------------------------------------------------

      # @return [Array(String, Hash|nil)] the workspace and, when the lookup already read it, the snapshot document
      def resolve(ref, warnings)
        names = @catalog.all.flat_map { |project| project.members.map(&:workspace) }
        return [ref, nil] if names.include?(ref)
        run_workspace = workspace_of_run(ref, warnings)
        return [run_workspace, nil] if run_workspace
        tasks = @task_store.latest_by_workspace.values.reject { |record| record["outcome"] }
        by_id = tasks.select { |record| record["id"] == ref }.map { |record| record["workspace"] }.uniq
        return single(ref, by_id, nil) if by_id.any?
        parsed = parse_ref(ref)
        by_ref = tasks.select { |record| task_matches?(record, ref, parsed) }.map { |record| record["workspace"] }.uniq
        return single(ref, by_ref, nil) if by_ref.any?
        document = @snapshot_reader.call([])
        matches = members(document).select { |_, member| parsed && member.dig("git", "branch") == parsed[:branch] }
        single(ref, matches.map { |_, member| member["workspace"] }.uniq, document, matches)
      end

      def single(ref, workspaces, document, matches = nil)
        return [workspaces.first, document] if workspaces.size == 1
        if workspaces.empty?
          raise Workspace::Error.new("No goal matches '#{ref}'. Tried: #{TRIED.join(", ")}.", code: "unknown_goal",
            details: {"ref" => ref, "tried" => TRIED})
        end
        found = (matches || []).map { |project, member| {"workspace" => member["workspace"], "project" => project["name"], "branch" => member.dig("git", "branch")} }
        found = workspaces.map { |name| {"workspace" => name} } if found.empty?
        raise Workspace::Error.new("'#{ref}' matches more than one goal: #{workspaces.join(", ")}. Name the workspace.", code: "ambiguous_goal",
          details: {"ref" => ref, "matches" => found})
      end

      def workspace_of_run(ref, warnings)
        found = @workflow_status.runs["runs"].find { |run| run["id"] == ref }
        archived = false
        unless found
          found = @workflow_status.runs(all: true)["runs"].find { |run| run["id"] == ref }
          archived = !found.nil?
        end
        return nil unless found
        warnings << {"code" => "run_archived", "message" => "Run #{ref} is finished; showing the goal of its workspace, '#{found["workspace"]}'."} if archived
        found["workspace"]
      end

      def parse_ref(ref)
        parsed = @start_ref.call(ref)
        {branch: parsed.branch, key: parsed.key}
      rescue Workspace::Error, ArgumentError
        nil
      end

      def task_matches?(record, ref, parsed)
        return true if record["ref"] == ref || record["branch"] == ref
        parsed && (record["ref"] == parsed[:key] || record["branch"] == parsed[:branch])
      end

      def members(document)
        document["projects"].flat_map { |project| project["members"].map { |member| [project, member] } }
      end

      # --- reads ------------------------------------------------------------

      def runs_for(name, warnings)
        result = @workflow_status.runs(workspace: name)
        result["warnings"].each { |message| warnings << {"code" => "workflow_runs_unavailable", "message" => message} }
        sort_runs(result["runs"])
      end

      def runs_by_workspace(warnings)
        result = @workflow_status.runs
        result["warnings"].each { |message| warnings << {"code" => "workflow_runs_unavailable", "message" => message} }
        sort_runs(result["runs"]).group_by { |run| run["workspace"] }
      end

      def sort_runs(runs)
        runs.sort_by { |run| run["created_at"].to_s }.reverse
      end

      # --- the goal ---------------------------------------------------------

      def build(name, document, runs, warnings, detail:)
        project, member = members(document).find { |_, each| each["workspace"] == name }
        unless member
          raise Workspace::Error.new("No goal matches '#{name}'. Tried: #{TRIED.join(", ")}.", code: "unknown_goal", details: {"ref" => name, "tried" => TRIED})
        end
        plan = read_plan(name, warnings)
        panes = member["panes"]
        run = runs.first
        stage = stage_of(name, member, plan, panes, warnings)
        step = step_of(run, plan)
        pane = pane_for(run, stage, plan, panes)
        turn = turn_of(pane)
        tool = detail ? tool_of(name, pane, member, warnings) : nil
        state = state_of(member, run, plan_state(member), pane, turn)
        warn_no_daemon(name, member, run, warnings)
        task = member["task"] || {}
        goal = {
          "workspace" => name, "project" => project["name"], "title" => task["title"] || name, "ref" => task["ref"],
          "branch" => task["branch"] || member.dig("git", "branch"), "task_id" => task["id"],
          "state" => state, "waiting_on" => nil, "next" => nil, "stage" => stage, "step" => step,
          "runs" => runs.map { |each| {"id" => each["id"], "workflow" => each["workflow"], "step" => each.dig("current", "step"), "state" => each["state"]} },
          "turn" => turn
        }
        goal["tool"] = tool if detail
        goal["waiting_on"], goal["next"] = expect(state, name, member, run, pane, plan)
        goal
      end

      def read_plan(name, warnings)
        PlanFile.read(@plan.path_for(name)) || :missing
      rescue Workspace::Error, SystemCallError => e
        warnings << {"code" => "plan_unavailable", "workspace" => name, "message" => e.message.lines.first.to_s.strip}
        nil
      end

      def plan_state(member)
        member.dig("plan", "state")
      end

      # The spine's current stage, else the one inferred from the plan, runs and panes.
      def stage_of(name, member, plan, panes, warnings)
        spine = member["spine"]
        if spine && spine["exists"]
          return nil unless spine["current"]
          return {"path" => spine["current"], "title" => spine["title"], "status" => spine["status"], "owner" => spine["owner"], "source" => "spine"}
        end
        inferred_stage(name, member, plan, panes, warnings)
      rescue Workspace::Error, SystemCallError => e
        warnings << {"code" => "stage_unavailable", "workspace" => name, "message" => e.message.lines.first.to_s.strip}
        nil
      end

      def inferred_stage(name, member, plan, panes, warnings)
        return nil if plan.nil?
        daemon = member["daemon"] || {}
        readings = SpineFacts::Readings.new(plan: plan, git: nil, pull_request: nil, panes: panes, daemon_reason: (daemon["up"] == false) ? "no_daemon" : nil,
          asks: member["questions"], review_ahead: nil, review: false)
        result = @spine_facts.facts_from(name, readings)
        docs = @spine_inferred.infer(workspace: name, checkout: member["path"], result: result)
        doc = docs.find { |each| each["path"] == SpineEvaluator.current(docs) }
        doc && {"path" => doc["path"], "title" => doc["title"], "status" => doc["status"], "owner" => doc["owner"], "source" => "inferred"}
      end

      def step_of(run, plan)
        if run
          current = run["current"]
          return {"source" => "workflow", "run" => run["id"], "workflow" => run["workflow"], "step" => current["step"], "attempt" => current["attempt"],
                  "state" => current["state"], "reason" => current["reason"], "flags" => current["flags"]}
        end
        task = plan && plan != :missing && current_task(plan)
        return nil unless task
        {"source" => "plan", "task" => {"id" => task.id, "title" => task.title, "state" => task.state, "owner" => task.owner}}
      end

      def current_task(plan)
        plan.tasks.find { |task| task.state == "in_progress" } || plan.tasks.find { |task| task.state == "todo" }
      end

      # The run's pane, else the stage's owner, else the plan's owner, else the main agent pane.
      def pane_for(run, stage, plan, panes)
        return nil unless panes
        candidates = [run && run["pane"], stage && stage["owner"], plan_owner(plan)].compact
        found = candidates.filter_map { |id| panes.find { |pane| pane["pane_id"] == id } }.first
        found || main_pane(panes)
      end

      def plan_owner(plan)
        return nil if plan.nil? || plan == :missing
        current_task(plan)&.owner || plan.owner_pane
      end

      def main_pane(panes)
        panes.reject { |pane| %w[shell unknown].include?(pane["kind"]) }.min_by { |pane| pane["index"].to_i }
      end

      def turn_of(pane)
        return nil unless pane
        {"pane" => pane["pane_id"], "kind" => pane["kind"], "state" => pane["state"], "state_since" => pane["state_since"],
         "waiting_message" => pane["waiting_message"], "context_pct" => pane["context_pct"],
         "subagents" => Array(pane["agents"]).select { |agent| agent["state"] == "running" }.map { |agent| agent["name"] }}
      end

      # The tool call needs the daemon's own pane row; the snapshot document leaves it out.
      def tool_of(name, pane, member, warnings)
        return nil unless pane
        raw = @snapshot_client.fetch(name, timeout: DAEMON_TIMEOUT)
        row = Array(raw["panes"]).find { |each| each["pane_id"] == pane["pane_id"] }
        return nil unless row
        {"current" => row["current_tool"], "since" => row["current_tool_since"], "last_event_at" => row["last_event_at"]}
      rescue Workspace::Error, SystemCallError
        nil
      end

      def warn_no_daemon(name, member, run, warnings)
        return unless run && member["daemon"] && member["daemon"]["up"] == false && member["running"] != false
        return if run["state"] == "waiting"
        warnings << {"code" => "no_daemon", "workspace" => name, "message" => "'#{name}' has no agent daemon answering, so run #{run["id"]} will not move and its turn is unknown."}
      end

      # --- state and what comes next ---------------------------------------

      def state_of(member, run, plan_state, pane, turn)
        reason = run&.dig("current", "reason")
        flags = run&.dig("current", "flags") || []
        spine = member["spine"]
        return "done" if done?(spine, plan_state, run)
        return "waiting" if (reason && WAITING_REASONS.include?(reason["code"])) || plan_state == "waiting" || (turn && turn["state"] == "waiting")
        return "waiting_lock" if reason && reason["code"] == "waiting_lock"
        return "working" if (turn && turn["state"] == "working") || plan_state == "working"
        return "stuck" if flags.intersect?(%w[idle timed_out]) || (reason && reason["code"] == "pane_gone") || plan_state == "stalled" || run_without_daemon?(member, run)
        return "stopped" if member["running"] == false
        return "idle" if structure?(spine, plan_state, run)
        "none"
      end

      def done?(spine, plan_state, run)
        if spine && spine["exists"] && spine["stages"].to_i.positive?
          counts = spine["counts"] || {}
          return true if counts["completed"].to_i + counts["skipped"].to_i == spine["stages"]
        end
        plan_state == "done" && run.nil?
      end

      def run_without_daemon?(member, run)
        run && %w[running checking].include?(run.dig("current", "state")) && member["daemon"] && member["daemon"]["up"] == false && member["running"] != false
      end

      def structure?(spine, plan_state, run)
        !run.nil? || (spine && spine["exists"]) || !(plan_state.nil? || plan_state == "empty")
      end

      # @return [Array(String, Hash|nil)] `waiting_on` and `next`
      def expect(state, name, member, run, pane, plan)
        reason = run&.dig("current", "reason")
        case state
        when "done", "none" then ["nothing", nil]
        when "waiting" then waiting_next(name, member, run, reason, pane)
        when "waiting_lock"
          ["lock", {"event" => "lock_released", "resource" => reason.dig("details", "resource"), "holder" => reason.dig("details", "holder"),
                    "action" => Array(reason["actions"]).first}]
        when "working" then ["agent", {"event" => "turn_ended", "action" => nil}]
        when "stuck"
          action = run ? action("workflow resume", run["id"]) : action("launch", name)
          ["person", {"event" => run ? "workflow_resumed" : "agent_restarted", "action" => action}]
        when "stopped" then ["person", {"event" => "launched", "action" => action("launch", name)}]
        else ["person", {"event" => (run || plan.nil? || plan == :missing) ? "stage_started" : "task_started", "action" => nil}]
        end
      end

      def waiting_next(name, member, run, reason, pane)
        if reason && WAITING_REASONS.include?(reason["code"])
          event = {"waiting_you" => ((reason.dig("details", "kind") == "gate") ? "gate_approved" : "answered"),
                   "failed_check" => "check_passed", "turn_ended_incomplete" => "turn_ended"}.fetch(reason["code"])
          return ["person", {"event" => event, "action" => Array(reason["actions"]).first}]
        end
        ask = Array(member["questions"]).first
        if ask
          return ["person", {"event" => "ask_answered", "action" => action("ask answer", ask["id"].to_s, "--name", name, needs: [{"name" => "answer", "flag" => nil}])}]
        end
        focus = pane ? action("focus", name, "--pane", pane["pane_id"].to_s) : nil
        ["person", {"event" => "prompt_answered", "action" => focus}]
      end

      def action(name, *args, needs: [])
        {"action" => name, "args" => args, "needs" => needs}
      end

      # --- text output ------------------------------------------------------

      def print_show(out)
        goal = out["goal"]
        @output.puts "#{goal["workspace"]}  (#{goal["project"]})  #{goal["title"]}"
        @output.puts "State:  #{state_line(goal)}"
        @output.puts "Stage:  #{stage_line(goal["stage"])}"
        @output.puts "Step:   #{step_line(goal["step"])}"
        @output.puts "Runs:   #{goal["runs"].map { |run| "#{run["id"]} (#{run["workflow"]} #{run["step"]}, #{run["state"]})" }.join(", ")}" if goal["runs"].size > 1
        @output.puts "Turn:   #{turn_line(goal["turn"])}"
        @output.puts "Tool:   #{tool_line(goal["tool"])}"
        @output.puts "Next:   #{next_line(goal["next"])}" if goal["next"]
        out["warnings"].each { |warning| @output.puts "Warning: #{warning["message"]}" }
      end

      def print_list(out)
        @output.puts "No goals." if out["goals"].empty?
        out["goals"].each do |goal|
          @output.puts [goal["workspace"], goal["state"], goal.dig("stage", "title") || "-", step_label(goal["step"]), goal.dig("turn", "state") || "-"].join("  ")
        end
        out["warnings"].each { |warning| @output.puts "Warning: #{warning["message"]}" }
      end

      def state_line(goal)
        (goal["waiting_on"] && goal["waiting_on"] != "nothing") ? "#{goal["state"]} (on #{goal["waiting_on"]})" : goal["state"]
      end

      def stage_line(stage)
        stage ? "#{stage["title"]} (#{stage["source"]}, #{stage["status"]})" : "none"
      end

      def step_label(step)
        return "-" unless step
        (step["source"] == "workflow") ? "#{step["workflow"]}/#{step["step"]}" : "task #{step.dig("task", "id") || "?"}"
      end

      def step_line(step)
        return "none" unless step
        return "plan task #{step.dig("task", "id") || "?"} #{step.dig("task", "title")} (#{step.dig("task", "state")})" if step["source"] == "plan"
        reason = step["reason"] ? ", #{step["reason"]["code"]}" : ""
        "run #{step["run"]} #{step["workflow"]}/#{step["step"]} attempt #{step["attempt"]} (#{step["state"]}#{reason})"
      end

      def turn_line(turn)
        return "unknown (no agent daemon answered)" unless turn
        "#{turn["pane"]} #{turn["kind"]} #{turn["state"]}#{" since #{turn["state_since"]}" if turn["state_since"]}"
      end

      def tool_line(tool)
        return "unknown" unless tool
        tool["current"] ? "#{tool["current"]} since #{tool["since"]}" : "none running"
      end

      def next_line(next_step)
        action = next_step["action"]
        text = next_step["event"]
        text += "  ->  workspace #{[action["action"], *action["args"]].join(" ")}" if action
        text
      end
    end
  end
end
