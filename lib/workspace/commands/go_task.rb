module Workspace
  module Commands
    # The task path of `go --here "TEXT"`: when a workflow run is already going on the checkout,
    # the text becomes a new task in the workspace's plan instead of a second run. {Go} keeps to
    # routing; this object finds the run, checks that the plan will still be read, and adds the
    # task through {PlanTask#add}. Every refusal happens before anything is written, and nothing
    # is typed into any pane: the run's agent takes the task the next time it reads the plan.
    class GoTask
      PAUSED_WARNING = "The plan is paused, so the agent will not take the task until someone resumes it with `workspace plan start`."

      # @param engine [Workspace::WorkflowEngine] answers which run holds a checkout
      # @param plan_task [Workspace::Commands::PlanTask] adds the task
      # @param access [Workspace::PlanAccess] finds the plan
      # @param output [IO]
      def initialize(engine:, plan_task:, access:, output: $stdout)
        @engine = engine
        @plan_task = plan_task
        @access = access
        @output = output
      end

      # @param checkout [Workspace::Commands::WorkflowStart::Here]
      # @return [Hash{String=>Object}, nil] the stored run going on the checkout, or nil
      def run_for(checkout)
        @engine.run_on_checkout(checkout.path)
      end

      # @param run [Hash] the run from {#run_for}
      # @param text [String] the task's title
      # @param checkout [Workspace::Commands::WorkflowStart::Here]
      # @param flags [Hash{Symbol=>Object}] +workflow+, +inputs+ and +base+ as `go` was given them
      # @param dry_run [Boolean] check everything and write nothing
      # @return [Hash{String=>Object}] the {PlanTask#add} row, plus +workspace+, +run_id+, +decision+ (route `task`) and +warnings+
      # @raise [Workspace::UsageError] a flag that would be ignored
      # @raise [Workspace::Error] `checkout_has_run` (the run won't read the plan), `no_plan`, `plan_done`, or any of {PlanTask#add}
      def add(run, text, checkout, flags:, dry_run:)
        refuse_flags!(flags)
        refuse_unread!(run)
        plan = plan_of(run, checkout)
        raise plan_done(run, checkout) if plan.status == "done"

        paused = plan.status == "paused"
        row = @plan_task.add(name: checkout.workspace, title: text, dry_run: dry_run)
        @output.puts "go: task for run #{run["id"]} (#{run["workflow"]} at step #{run["current"]}), #{dry_run ? "would add to" : "added to"} this workspace's plan."
        @output.puts "The agent takes it when it next reads the plan." unless dry_run
        @output.puts "Warning: #{PAUSED_WARNING}" if paused
        reason = "run #{run["id"]} is going on this checkout, so the text is a task in its plan"
        decision = {"workflow" => run["workflow"], "source" => "run", "kind" => "prompt", "route" => "task", "reason" => reason, "extracted" => nil}
        row.merge("workspace" => checkout.workspace, "run_id" => run["id"], "decision" => decision, "warnings" => paused ? [PAUSED_WARNING] : [])
      end

      private

      def refuse_flags!(flags)
        given = []
        given << "--workflow" if flags[:workflow]
        given << "--input" if flags[:inputs] && !flags[:inputs].empty?
        given << "--base" if flags[:base]
        return if given.empty?

        raise Workspace::UsageError, "#{given.join(", ")} would be ignored: a run is already going here, so --here adds the text to its plan. Drop #{(given.size == 1) ? "it" : "them"}."
      end

      def refuse_unread!(run)
        return if WorkflowDefinition.reads_plan?(run["definition"], from: run["current"])

        raise Workspace::Error.new("Run #{run["id"]} (#{run["workflow"]}) is at step #{run["current"]} and won't read the plan again, so a task added now would not be picked up. " \
          "Leave off --here to make a new workspace for the text.",
          code: "checkout_has_run", details: {"worktree" => run["worktree"], "run_id" => run["id"], "step" => run["current"],
                                              "state" => run["state"], "next" => ["workspace workflow cancel #{run["id"]}"]})
      end

      def plan_of(run, checkout)
        _file, plan = @access.require_plan(checkout.workspace)
        plan
      rescue Workspace::Error => e
        raise unless e.code == "no_plan"

        raise Workspace::Error.new("Run #{run["id"]} (#{run["workflow"]}) is at step #{run["current"]} and the workspace has no plan yet: the plan step has not written it. " \
          "Run again after it does, or leave off --here to make a new workspace for the text.",
          code: "no_plan", details: e.details.merge("run_id" => run["id"], "step" => run["current"]))
      end

      def plan_done(run, checkout)
        file = @access.path_for(checkout.workspace)
        Workspace::Error.new("The plan for '#{checkout.workspace}' is marked done, though run #{run["id"]} is still going (step #{run["current"]}). " \
          "Edit #{file} to reopen it, or leave off --here to make a new workspace for the text.",
          code: "plan_done", details: {"name" => checkout.workspace, "path" => file, "run_id" => run["id"], "step" => run["current"]})
      end
    end
  end
end
