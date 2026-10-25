require "json"

module Workspace
  module Commands
    # `goal show [REF]` and `goal list`: where a goal is at each level (the goal,
    # its journey stage, its workflow step, the agent's turn, the tool call), what
    # it waits for and on whom. A goal is a workspace; a run id, task id, ticket
    # key, URL or branch resolves to the workspace that holds it.
    #
    # It only combines reads that exist: {Workspace::Commands::Snapshot#document}'s member
    # row (plan, spine or its inferred stage, panes, task, git, questions),
    # {Workspace::WorkflowStatus#runs}, and the daemon's panes for the tool call;
    # {Workspace::GoalState} holds the state rules. It writes nothing and makes no `gh`
    # call. A level with nothing to show is null; a source that can't answer is null
    # and a warning, never an error.
    class Goal
      # Bumped whenever the `--json` payload's shape changes in a backward-incompatible way.
      JSON_SCHEMA_VERSION = 1

      # What `unknown_goal` lists as tried, in order.
      TRIED = %w[workspace run task ref branch].freeze

      # Seconds the daemon may take to give the tool call.
      DAEMON_TIMEOUT = 1.0

      # @param snapshot [Workspace::Commands::Snapshot] gives the document of every member's row
      # @param catalog [Workspace::ProjectCatalog] knows every workspace's name
      # @param task_store [Workspace::TaskStore] resolves a task id, ref or branch
      # @param workflow_status [Workspace::WorkflowStatus] the workspace's runs
      # @param start_ref [Workspace::StartRef] reads a ticket key, URL or branch
      # @param plan [Workspace::Commands::Plan] says where a workspace's plan file is
      # @param snapshot_client [Workspace::AgentSnapshotClient] reads the daemon's panes for the tool call
      # @param output [IO]
      def initialize(snapshot:, catalog:, task_store:, workflow_status:, start_ref:, plan:, snapshot_client:, output: $stdout)
        @snapshot = snapshot
        @catalog = catalog
        @task_store = task_store
        @workflow_status = workflow_status
        @start_ref = start_ref
        @plan = plan
        @snapshot_client = snapshot_client
        @output = output
      end

      # @param ref [String] workspace name, run id, task id, ticket key or URL, or branch
      # @param json [Boolean] print the document documented in docs/README.goal.md
      # @return [void]
      # @raise [Workspace::Error] `unknown_goal` or `ambiguous_goal`
      def show(ref, json: false)
        warnings = []
        project, member = locate(ref, warnings)
        goal = build(project, member, runs_for(member["workspace"], warnings), warnings, detail: true)
        out = {"schema_version" => JSON_SCHEMA_VERSION, "ok" => true, "goal" => goal, "warnings" => warnings}
        json ? @output.puts(JSON.generate(out)) : print_show(out)
      end

      # @param all [Boolean] include workspaces whose goal `state` is `none`
      # @param json [Boolean]
      # @return [void]
      def list(all: false, json: false)
        warnings = []
        document = read([], warnings)
        by_workspace = runs_by_workspace(warnings)
        goals = members(document).map { |project, member| build(project, member, by_workspace.fetch(member["workspace"], []), warnings, detail: false) }
        goals = goals.reject { |goal| goal["state"] == "none" } unless all
        out = {"schema_version" => JSON_SCHEMA_VERSION, "ok" => true, "goals" => goals, "warnings" => warnings}
        json ? @output.puts(JSON.generate(out)) : print_list(out)
      end

      private

      # --- resolution -------------------------------------------------------

      # One snapshot read, whose warnings join the command's.
      def read(names, warnings)
        document = @snapshot.document(names: names, inferred: true)
        warnings.concat(Array(document["warnings"]))
        document
      end

      # @return [Array(Hash, Hash)] the snapshot's project row and the member row of the goal `ref` names
      def locate(ref, warnings)
        name = workspace_named(ref, warnings)
        return entry(read([name], warnings), name) if name
        document = read([], warnings)
        parsed = parse_ref(ref)
        matches = members(document).select { |_, member| parsed && member.dig("git", "branch") == parsed[:branch] }
        name = single(ref, matches.map { |_, member| member["workspace"] }.uniq, matches)
        matches.find { |_, member| member["workspace"] == name }
      end

      def entry(document, name)
        members(document).find { |_, member| member["workspace"] == name } || unknown(name)
      end

      # @return [String, nil] the workspace a name, run id, task id or task ref names; nil when none does
      def workspace_named(ref, warnings)
        names = @catalog.all.flat_map { |project| project.members.map(&:workspace) }
        return ref if names.include?(ref)
        run_workspace = workspace_of_run(ref, warnings)
        return run_workspace if run_workspace
        tasks = @task_store.latest_by_workspace.values.reject { |record| record["outcome"] }
        by_id = tasks.select { |record| record["id"] == ref }.map { |record| record["workspace"] }.uniq
        return single(ref, by_id) if by_id.any?
        parsed = parse_ref(ref)
        by_ref = tasks.select { |record| task_matches?(record, ref, parsed) }.map { |record| record["workspace"] }.uniq
        by_ref.any? ? single(ref, by_ref) : nil
      end

      def unknown(ref)
        raise Workspace::Error.new("No goal matches '#{ref}'. Tried: #{TRIED.join(", ")}.", code: "unknown_goal", details: {"ref" => ref, "tried" => TRIED})
      end

      def single(ref, workspaces, matches = nil)
        return workspaces.first if workspaces.size == 1
        unknown(ref) if workspaces.empty?
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

      # Composes the levels; the state rules are {Workspace::GoalState}'s.
      def build(project, member, runs, warnings, detail:)
        name = member["workspace"]
        plan = read_plan(name, warnings)
        run = runs.first
        stage = stage_of(member)
        pane = pane_for(run, stage, plan, member["panes"])
        turn = turn_of(pane)
        warn_turn_gone(name, member, run, turn, warnings)
        status = GoalState.new(name: name, member: member, run: run, turn: turn, pane: pane, plan_present: !(plan.nil? || plan == :missing))
        warn_stage_disagrees(name, status, stage, warnings)
        task = member["task"] || {}
        goal = {
          "workspace" => name, "project" => project["name"], "title" => task["title"] || name, "ref" => task["ref"],
          "branch" => task["branch"] || member.dig("git", "branch"), "task_id" => task["id"],
          "state" => status.state, "waiting_on" => status.waiting_on, "next" => status.next_step, "stage" => stage, "step" => step_of(run, plan),
          "runs" => runs.map { |each| {"id" => each["id"], "workflow" => each["workflow"], "step" => each.dig("current", "step"), "state" => each["state"]} },
          "turn" => turn
        }
        goal["tool"] = tool_of(name, pane) if detail
        goal
      end

      def read_plan(name, warnings)
        PlanFile.read(@plan.path_for(name)) || :missing
      rescue Workspace::Error, SystemCallError => e
        warnings << {"code" => "plan_unavailable", "workspace" => name, "message" => e.message.lines.first.to_s.strip}
        nil
      end

      # The spine's current stage, else the one the snapshot inferred from the plan, runs and panes.
      def stage_of(member)
        spine = member["spine"]
        return nil unless spine
        return spine["inferred"] unless spine["exists"]
        return nil unless spine["current"]
        {"path" => spine["current"], "title" => spine["title"], "status" => spine["status"], "owner" => spine["owner"], "source" => "spine"}
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
      def tool_of(name, pane)
        return nil unless pane
        row = Array(@snapshot_client.fetch(name, timeout: DAEMON_TIMEOUT)["panes"]).find { |each| each["pane_id"] == pane["pane_id"] }
        row && {"current" => row["current_tool"], "since" => row["current_tool_since"], "last_event_at" => row["last_event_at"]}
      rescue Workspace::Error, SystemCallError
        nil
      end

      # A running workspace whose daemon gave no panes has no turn; say why. A stopped workspace has none by design.
      def warn_turn_gone(name, member, run, turn, warnings)
        return if turn || member["running"] == false || member["panes"]
        warnings << {"code" => "turn_unavailable", "workspace" => name, "message" => "'#{name}' has no agent daemon answering, so its turn and tool call are unknown."}
        return unless run && run["state"] != "waiting"
        warnings << {"code" => "no_daemon", "workspace" => name, "message" => "'#{name}' has no agent daemon answering, so run #{run["id"]} will not move and its turn is unknown."}
      end

      # The goal is done by its own rules while the current stage says otherwise; both are reported as they are.
      def warn_stage_disagrees(name, status, stage, warnings)
        return unless status.state == "done" && stage && !%w[completed skipped].include?(stage["status"])
        warnings << {"code" => "stage_disagrees", "workspace" => name,
                     "message" => "'#{name}' is done by its plan or spine counts, but its current stage '#{stage["path"]}' is #{stage["status"]}.",
                     "details" => {"stage" => stage["path"], "status" => stage["status"]}}
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
