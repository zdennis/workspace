module WorkflowGraphGolden
  FIXTURES = File.join(PROJECT_ROOT, "spec", "fixtures", "workflow_graph_golden")

  def self.model(id)
    catalog = Workspace::WorkflowCatalog.new(config: Workspace::Config.new)
    Workspace::WorkflowGraph.build(catalog.find(id).to_h).to_h
  end

  def self.run(name)
    Workspace::WorkflowRun.from_h(JSON.parse(File.read(File.join(PROJECT_ROOT, "spec", "fixtures", "workflow_runs", "#{name}.json"))))
  end

  def self.looped_model
    run = run("looped_twice")
    Workspace::WorkflowGraphStates.mark(Workspace::WorkflowGraph.build(run.definition).to_h, run)
  end

  def self.pin(actual, file)
    path = File.join(FIXTURES, file)
    File.write(path, actual) if ENV["UPDATE_GOLDEN"]
    File.read(path)
  end

  TRICKY = {
    "steps" => [
      {"id" => "start", "title" => "Say \"hi\"\nthen <b>go</b>\e[31m"},
      {"id" => "ci-run", "gate" => "approve", "on_fail" => {"goto" => "start", "max" => 2}},
      {"id" => "end", "review" => {"from" => %w[a b], "need" => 1, "max_rounds" => 3}}
    ],
    "max_attempts" => 4
  }.freeze
end
