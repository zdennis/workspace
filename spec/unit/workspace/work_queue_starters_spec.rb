RSpec.describe Workspace::WorkQueueStarters do
  let(:workflow) { double("workflow", run: {"run" => {"id" => "run-1"}}) }
  let(:workflow_start) { double("workflow_start", call: {"run" => {"id" => "run-2"}}, check_agent!: nil, locate_project: {project_workspace: "api"}) }
  let(:go) { double("go", call: {"run" => {"id" => "run-3"}, "decision" => {"route" => "run"}}) }
  let(:workflow_project) { double("workflow_project", for_directory: double(project: "api")) }
  let(:definition) { double("definition", to_h: {"inputs" => {"task" => {}}}) }
  let(:catalog) { double("catalog", find: definition) }
  let(:checkout) { Workspace::Commands::WorkflowStart::Here.new(workspace: "api-w", path: "/repo/api-w", caller_pane: nil) }
  let(:starters) { described_class.new(workflow: workflow, workflow_start: workflow_start, go: go, workflow_project: workflow_project, catalog: catalog).to_h }

  def start(kind, spec, headless: false)
    starters.fetch(kind).call({"spec" => spec, "headless" => headless}, workspace: "api-w", checkout: checkout, note: "the note")
  end

  it "registers the workflow and go kinds" do
    expect(starters.keys).to eq(%w[workflow go])
  end

  it "runs a prompt-only item with task filled, without WorkflowStart#call" do
    expect(workflow).to receive(:run).with(id: "rpiv", workspace: "api-w", worktree: "/repo/api-w", inputs: {"task" => "fix it"}, note: "the note", project: "api", fill_from_branch: true)
    expect(workflow_start).not_to receive(:call)
    expect(start("workflow", {"workflow" => "rpiv", "prompt" => "fix it"})).to eq("run-1")
    expect(workflow_start).to have_received(:check_agent!).with("api-w", project: "api")
  end

  it "passes an item with neither ref nor prompt its inputs" do
    expect(workflow).to receive(:run).with(hash_including(inputs: {"a" => "b"}))
    start("workflow", {"workflow" => "rpiv", "inputs" => {"a" => "b"}})
  end

  it "keeps a given task input" do
    expect(workflow).to receive(:run).with(hash_including(inputs: {"task" => "mine"}))
    start("workflow", {"workflow" => "rpiv", "prompt" => "other", "inputs" => {"task" => "mine"}})
  end

  it "leaves task out when the definition does not declare it" do
    allow(definition).to receive(:to_h).and_return({"inputs" => {}})
    expect(workflow).to receive(:run).with(hash_including(inputs: {}))
    start("workflow", {"workflow" => "rpiv", "prompt" => "x"})
  end

  it "starts a ref item with here and root set to the checkout" do
    expect(workflow_start).to receive(:call).with(id: "rpiv", ref: "PROJ-1", prompt: nil, inputs: {}, note: "the note", headless: true, here: checkout, root: "/repo/api-w")
    expect(workflow).not_to receive(:run)
    expect(start("workflow", {"workflow" => "rpiv", "ref" => "PROJ-1"}, headless: true)).to eq("run-2")
  end

  it "passes a go item the checkout and note" do
    expect(go).to receive(:call).with(argument: "PROJ-1", text: false, workflow: nil, inputs: {}, headless: false, checkout: checkout, note: "the note").and_return({"run" => {"id" => "run-3"}, "decision" => {"route" => "run"}})
    expect(start("go", {"argument" => "PROJ-1"})).to eq("run-3")
  end

  it "raises run_going when go took the task route" do
    allow(go).to receive(:call).and_return({"decision" => {"route" => "task"}})
    expect { start("go", {"argument" => "do a thing", "text" => true}) }.to raise_error(Workspace::Error) { |e| expect(e.code).to eq("run_going") }
  end

  it "reads the project from the checkout's path, never the cwd" do
    start("workflow", {"workflow" => "rpiv"})
    expect(workflow_project).to have_received(:for_directory).with("/repo/api-w")
    expect(workflow_start).to have_received(:locate_project).with("/repo/api-w")
  end
end
