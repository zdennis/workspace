require "spec_helper"
require "tmpdir"
require "fileutils"
require "yaml"

# demo/calculator2/workflows/deliver-goal.yml played through the real engine by `workflow simulate`, with the
# scripts under demo/calculator2/simulate/.
RSpec.describe "the deliver-goal workflow in the simulator" do
  let(:base) { File.realpath(Dir.mktmpdir("wf-deliver")) }
  let(:tmpdir) { ->(prefix, &block) { block.call(Dir.mktmpdir(prefix, base)) } }
  let(:path) { File.join(PROJECT_ROOT, "demo", "calculator2", "workflows", "deliver-goal.yml") }
  let(:lookup) do
    lambda do |id, below: nil|
      file = File.join(PROJECT_ROOT, "lib", "workflows", "#{id}.yml")
      {"text" => File.read(file), "path" => file, "source" => "builtin"} if File.file?(file) && below.nil?
    end
  end
  let(:definition) { Workspace::WorkflowDefinition.parse(File.read(path), id: "deliver-goal", source: "global", path: path, parent_lookup: lookup) }
  let(:simulator) do
    factory = ->(**parts) { Workspace.build_workflow_engine(**parts) }
    Workspace::WorkflowSimulator.new(engine_factory: factory, tmpdir: tmpdir)
  end

  after { FileUtils.rm_rf(base) }

  def play(name)
    file = File.join(PROJECT_ROOT, "demo", "calculator2", "simulate", "#{name}.yml")
    script = Workspace::WorkflowSimScript.parse(File.read(file), definition: definition.to_h, source: "#{name}.yml")
    simulator.call(definition: definition, script: script, inputs: script.inputs)
  end

  def outcomes(result, id) = result["steps"].find { |each| each["id"] == id }["attempts"].map { |each| each["outcome"] }

  it "parses with no problems and puts acceptance last, with its exec proof" do
    expect(definition.to_h["steps"].map { |each| each["id"] }).to eq(%w[research plan implement verify acceptance])
    expect(definition.to_h["steps"].find { |each| each["id"] == "acceptance" }["require"].first).to include("exec" => ["/usr/bin/env", "git", "diff", "--quiet", "HEAD"])
    expect(definition.to_h["steps"].find { |each| each["id"] == "acceptance" }["require"].last).to include("exec" => ["/usr/bin/env", "{{inputs.acceptance}}", "{{inputs.goal}}"], "timeout" => 900)
    expect(definition.to_h["deny"]).to include("*calculator2/acceptance/*", "*calculator2/acceptance", "*refs/demo-calc2*")
    expect(definition.to_h["max_attempts"]).to eq(25)
  end

  it "uses no project words outside the deny globs" do
    expect(File.read(path).gsub(%r{"\*(calculator2/acceptance/?\*?|refs/demo-calc2\*)"}, "")).not_to match(/calc|arithmetic/i)
  end

  it "tells the implement step to keep hidden or denied paths out of shell command lines" do
    composer = RecordingComposer.new
    prompt = Workspace::WorkflowPrompt.new(composer: composer, git: FakeGit.new(worktree_branch: "topic"), excludes: RecordingGitExclude.new, prompt_writer: ->(*) {})
    run = {"id" => "wr_1", "workspace" => "app", "worktree" => base, "artifacts_dir" => File.join(base, ".workflow", "wr_1"),
           "inputs" => {"task" => "t", "goal" => "g.md", "acceptance" => "a"}, "definition" => definition.to_h}
    step = definition.to_h["steps"].find { |each| each["id"] == "implement" }

    prompt.compose(run, step, [])

    text = composer.calls.last.last[:workflow]["text"].gsub(/\s+/, " ")
    expect(text).to include("Shell commands that mention a hidden or denied path, even one you only saw in a log or error, inside quotes or an inline script, are blocked and reported; keep such paths out of shell command lines.")
  end

  it "completes when acceptance passes first time" do
    result = play("happy")
    expect(result["outcome"]).to eq("completed")
    expect(outcomes(result, "acceptance")).to eq(%w[passed])
  end

  it "goes back to implement once when acceptance fails, then completes" do
    result = play("acceptance-fails-once")
    expect(result["outcome"]).to eq("completed")
    expect(outcomes(result, "acceptance")).to eq(%w[failed passed])
    expect(outcomes(result, "implement")).to eq(%w[passed passed])
  end

  it "stops for a person when acceptance fails after the one loop" do
    result = play("acceptance-fails-twice")
    expect(result["outcome"]).to eq("stopped")
    expect(result["stopped"]).to include("step" => "acceptance")
  end
end
