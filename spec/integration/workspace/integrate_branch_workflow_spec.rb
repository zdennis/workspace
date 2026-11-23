require "spec_helper"
require "tmpdir"
require "fileutils"

# demo/calculator2/workflows/integrate-branch.yml and deliver-goal-fast.yml restate steps of deliver-goal.yml (their
# comments say to keep them in sync), so these examples hold the restated keys to deliver-goal's, never the prompts.
RSpec.describe "the integrate-branch and deliver-goal-fast workflows" do
  let(:base) { File.realpath(Dir.mktmpdir("wf-integrate")) }
  let(:tmpdir) { ->(prefix, &block) { block.call(Dir.mktmpdir(prefix, base)) } }
  let(:demo) { File.join(PROJECT_ROOT, "demo", "calculator2") }
  let(:lookup) do
    lambda do |id, below: nil|
      next nil unless below.nil?
      demo_file = File.join(demo, "workflows", "#{id}.yml")
      next {"text" => File.read(demo_file), "path" => demo_file, "source" => "global"} if File.file?(demo_file)
      file = File.join(PROJECT_ROOT, "lib", "workflows", "#{id}.yml")
      {"text" => File.read(file), "path" => file, "source" => "builtin"} if File.file?(file)
    end
  end
  let(:simulator) do
    factory = ->(**parts) { Workspace.build_workflow_engine(**parts) }
    Workspace::WorkflowSimulator.new(engine_factory: factory, tmpdir: tmpdir)
  end

  after { FileUtils.rm_rf(base) }

  def parse(id)
    path = File.join(demo, "workflows", "#{id}.yml")
    Workspace::WorkflowDefinition.parse(File.read(path), id: id, source: "global", path: path, parent_lookup: lookup)
  end

  let(:deliver_goal) { parse("deliver-goal").to_h }
  let(:integrate) { parse("integrate-branch").to_h }
  let(:fast) { parse("deliver-goal-fast").to_h }

  def step(definition, id) = definition["steps"].find { |each| each["id"] == id }

  def play(name, id)
    definition = parse(id)
    file = File.join(demo, "simulate", "#{name}.yml")
    script = Workspace::WorkflowSimScript.parse(File.read(file), definition: definition.to_h, source: "#{name}.yml")
    simulator.call(definition: definition, script: script, inputs: script.inputs)
  end

  it "keeps integrate-branch's verify equal to deliver-goal's apart from the prompt and the loop back to merge" do
    expect(step(integrate, "verify").except("prompt", "on_fail")).to eq(step(deliver_goal, "verify").except("prompt", "on_fail"))
    expect(step(integrate, "verify")["on_fail"].except("goto", "max")).to eq(step(deliver_goal, "verify")["on_fail"].except("goto", "max"))
    expect(step(integrate, "verify")["on_fail"]).to include("goto" => "merge")
  end

  it "keeps integrate-branch's acceptance equal to deliver-goal's apart from its place and the loop back to merge" do
    expect(step(integrate, "acceptance").except("after", "on_fail")).to eq(step(deliver_goal, "acceptance").except("after", "on_fail"))
    expect(step(integrate, "acceptance")["on_fail"].except("goto")).to eq(step(deliver_goal, "acceptance")["on_fail"].except("goto"))
    expect(step(integrate, "acceptance")["on_fail"]).to include("goto" => "merge")
  end

  it "denies integrate-branch the same paths as deliver-goal" do
    expect(integrate["deny"]).to eq(deliver_goal["deny"])
  end

  it "proves the merge by asking git whether the branch is an ancestor of HEAD" do
    expect(step(integrate, "merge")["require"].map { |each| each["exec"] })
      .to eq([["/usr/bin/env", "git", "merge-base", "--is-ancestor", "{{inputs.branch}}", "HEAD"]])
  end

  it "keeps deliver-goal-fast's verify equal to deliver-goal's apart from the test-db lock" do
    expect(step(fast, "verify").except("uses")).to eq(step(deliver_goal, "verify").except("uses"))
    expect(step(fast, "verify")["uses"]).to be_nil.or be_empty
    expect(step(deliver_goal, "verify")["uses"]).to eq(["test-db"])
  end

  it "has deliver-goal's plan step write plan.md" do
    expect(step(deliver_goal, "plan")["produces"]).to include("plan.md")
  end

  it "completes deliver-goal-fast when every step passes once" do
    expect(play("fast-happy", "deliver-goal-fast")["outcome"]).to eq("completed")
  end

  it "stops deliver-goal-fast at verify after its three loops back to implement are spent" do
    result = play("fast-verify-fails-four", "deliver-goal-fast")
    expect(result["outcome"]).to eq("stopped")
    expect(result["stopped"]).to include("step" => "verify")
    expect(step(result, "verify")["attempts"].map { |each| each["outcome"] }).to eq(%w[failed failed failed failed])
  end

  it "completes integrate-branch when the merge, verify and acceptance pass once" do
    result = play("integrate-happy", "integrate-branch")
    expect(result["outcome"]).to eq("completed")
    expect(result["steps"].map { |each| each["id"] }).to eq(%w[merge verify acceptance])
  end
end
