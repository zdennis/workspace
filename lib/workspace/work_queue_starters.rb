module Workspace
  # The starters {WorkQueueAdvance} calls for the `workflow` and `go` kinds of queue item.
  class WorkQueueStarters
    # @param workflow [Workspace::Commands::Workflow] runs a workflow in a checkout
    # @param workflow_start [Workspace::Commands::WorkflowStart] starts a run from a ref and checks the agent
    # @param go [Workspace::Commands::Go] picks a workflow for a ref or text and starts it
    # @param workflow_project [Workspace::WorkflowProject] names the project whose definitions are read
    # @param catalog [Workspace::WorkflowCatalog] says whether a definition declares `task`
    def initialize(workflow:, workflow_start:, go:, workflow_project:, catalog:)
      @workflow = workflow
      @workflow_start = workflow_start
      @go = go
      @workflow_project = workflow_project
      @catalog = catalog
    end

    # @return [Hash{String=>#call}] kind to starter; each takes `(item, workspace:, checkout:, note:)` and returns a run id
    def to_h
      {"workflow" => method(:workflow), "go" => method(:go)}
    end

    # Starts a `workflow` item. The spec holds `workflow`, and optionally `ref`, `prompt` and `inputs`.
    #
    # @param item [Hash] the queue item
    # @param workspace [String]
    # @param checkout [Workspace::Commands::WorkflowStart::Here]
    # @param note [String] the run's note
    # @return [String] the run id
    # @raise [Workspace::Error] whatever the start refuses with
    def workflow(item, workspace:, checkout:, note:)
      spec = item["spec"]
      inputs = spec["inputs"] || {}
      id = spec["workflow"]
      if spec["ref"]
        row = @workflow_start.call(id: id, ref: spec["ref"], prompt: spec["prompt"], inputs: inputs, note: note, headless: item["headless"] || false, here: checkout, root: checkout.path)
      else
        project = @workflow_project.for_directory(checkout.path)&.project
        @workflow_start.check_agent!(workspace, project: @workflow_start.locate_project(checkout.path)[:project_workspace])
        row = @workflow.run(id: id, workspace: workspace, worktree: checkout.path, inputs: seeded(inputs, spec["prompt"], id, project), note: note, project: project, fill_from_branch: true)
      end
      row.dig("run", "id")
    end

    # Starts a `go` item. The spec holds `argument` and optionally `text`, `workflow` and `inputs`.
    #
    # @param item [Hash] the queue item
    # @param workspace [String]
    # @param checkout [Workspace::Commands::WorkflowStart::Here]
    # @param note [String] the run's note
    # @return [String] the run id
    # @raise [Workspace::Error] code `run_going` when `go` took the task route, so nothing was started
    def go(item, workspace:, checkout:, note:)
      spec = item["spec"]
      row = @go.call(argument: spec["argument"], text: spec["text"] || false, workflow: spec["workflow"], inputs: spec["inputs"] || {}, headless: item["headless"] || false, checkout: checkout, note: note)
      if row.dig("decision", "route") == "task"
        raise Workspace::Error.new("go added a task to the running plan in #{workspace} instead of starting a run, because a run is going.", code: "run_going", details: {"workspace" => workspace})
      end
      row.dig("run", "id")
    end

    private

    def seeded(inputs, prompt, id, project)
      return inputs if prompt.nil? || inputs.key?("task")
      return inputs unless @catalog.find(id, project: project).to_h["inputs"].key?("task")

      inputs.merge("task" => prompt)
    end
  end
end
