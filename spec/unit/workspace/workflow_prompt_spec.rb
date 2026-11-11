require "spec_helper"
require "tmpdir"

RSpec.describe Workspace::WorkflowPrompt do
  around do |example|
    Dir.mktmpdir("wf-prompt") do |dir|
      @dir = dir
      example.run
    end
  end

  let(:composer) { RecordingComposer.new(text: "the instructions", packs: ["play/binding"]) }
  let(:git) { FakeGit.new(worktree_branch: "topic") }
  let(:excludes) { RecordingGitExclude.new }
  let(:written) { [] }
  let(:writer) { ->(path, text, encoding:) { written << [path, text, encoding] } }
  subject(:prompt) { described_class.new(composer: composer, git: git, excludes: excludes, prompt_writer: writer) }

  let(:step) { {"id" => "plan", "prompt" => "Plan {{inputs.task}} on {{branch}} in {{run}}.", "produces" => ["plan.md"], "include" => ["review"]} }
  let(:run) do
    Workspace::WorkflowRun.from_h(
      "id" => "wr_1", "workspace" => "app", "worktree" => @dir, "artifacts_dir" => File.join(@dir, ".workflow", "wr_1"),
      "inputs" => {"task" => "the fix"}, "note" => nil,
      "definition" => {"id" => "flow", "include" => ["commits"], "instructions" => "Run {{run}}.", "steps" => [step]}
    )
  end

  def composed_with
    composer.calls.last.last
  end

  describe "#artifacts_dir" do
    it "is the run's directory under the checkout's .workflow" do
      expect(prompt.artifacts_dir("/src/app", "wr_7")).to eq("/src/app/.workflow/wr_7")
    end
  end

  describe "#compose" do
    it "hands the composer the workflow's and the step's text, filled from the run, and the attempt's context" do
      answer = prompt.compose(run, step, ["Fix it."], binding: {"kind" => "run"})

      expect(answer).to eq("text" => "the instructions", "packs" => [{"ref" => "play/binding"}])
      expect(composed_with).to include(packs: nil, cwd: @dir, binding: {"kind" => "run"}, skip: [], attempt: ["Fix it."])
      expect(composed_with[:workflow]).to eq("name" => "flow", "include" => ["commits"], "text" => "Run wr_1.")
      expect(composed_with[:step]["text"]).to eq("Plan the fix on topic in wr_1.\n\nThis step is finished when your turn ends and these files " \
        "exist, written during this attempt: #{File.join(@dir, ".workflow", "wr_1", "plan.md")}.")
    end

    it "puts the run's note first, skips the dev pack for a devenv step and words a strict run's produces line" do
      strict = Workspace::WorkflowRun.from_h(run.to_h.merge("note" => "Be brief.",
        "definition" => run.definition.merge(Workspace::WorkflowProduced::MARKER_KEY => Workspace::WorkflowProduced::STRICT)))
      context = ["Fix it."]

      prompt.compose(strict, step.merge("uses" => ["devenv"], "status" => {"command" => "test"}), context)

      expect(composed_with[:attempt]).to eq(["Note for this run: Be brief.", "Fix it."])
      expect(context).to eq(["Fix it."])
      expect(composed_with[:skip]).to eq(["dev"])
      expect(composed_with[:step]["text"]).to include("exist as non-empty regular files (not links)")
      expect(composed_with[:step]["text"]).to end_with("the runner checks the step with the project's own command; work until it would pass.")
    end

    it "takes the stored Hash as well as a WorkflowRun" do
      prompt.compose(run.to_h, step, [])

      expect(composed_with[:workflow]["text"]).to eq("Run wr_1.")
    end

    it "fills an empty branch when git can't name it" do
      failing = FakeGit.new
      allow(failing).to receive(:worktree_branch).and_raise(Workspace::Error, "no branch")

      described_class.new(composer: composer, git: failing, excludes: excludes, prompt_writer: writer).compose(run, step, [])

      expect(composed_with[:step]["text"]).to start_with("Plan the fix on  in wr_1.")
    end

    it "turns an encoding clash into a Workspace::Error" do
      allow(composer).to receive(:compose).and_raise(Encoding::CompatibilityError, "incompatible")

      expect { prompt.compose(run, step, []) }.to raise_error(Workspace::Error, /not UTF-8 text \(Encoding::CompatibilityError\)/)
    end
  end

  describe "#prompt_path and #step_binding" do
    it "name the attempt's file under the run's steps directory and the binding its pane gets" do
      path = prompt.prompt_path(run, step, 2)

      expect(path).to eq(File.join(@dir, ".workflow", "wr_1", "steps", "plan.2.prompt.md"))
      expect(prompt.step_binding(run, step, 2, path)).to eq(
        "kind" => "run", "id" => "wr_1", "workspace" => "app", "step" => "plan", "attempt" => 2,
        "instructions" => path, "artifacts" => File.join(@dir, ".workflow", "wr_1")
      )
    end
  end

  describe "#write" do
    it "writes the composed text as UTF-8 with .workflow/ excluded, composing with the attempt's binding" do
      path, composed = prompt.write(run, step, 1, ["Fix it."])

      expect(path).to eq(File.join(@dir, ".workflow", "wr_1", "steps", "plan.1.prompt.md"))
      expect(composed["text"]).to eq("the instructions")
      expect(Dir.exist?(File.dirname(path))).to be true
      expect(excludes.calls).to eq([[:add, @dir, "/.workflow/"]])
      expect(written).to eq([[path, "the instructions", Encoding::UTF_8]])
      expect(composed_with[:binding]).to eq(prompt.step_binding(run, step, 1, path))
      expect(composed_with[:attempt]).to eq(["Fix it."])
    end
  end
end
