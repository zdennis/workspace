require "spec_helper"
require "tmpdir"
require "stringio"

RSpec.describe Workspace::Commands::GoTask do
  around do |example|
    Dir.mktmpdir("go-task") do |dir|
      @dir = File.realpath(dir)
      example.run
    end
  end

  let(:output) { StringIO.new }
  let(:notes) { instance_double(Workspace::Commands::Notes) }
  let(:event_log) { instance_double(Workspace::EventLog, record: nil) }
  let(:access) { Workspace::PlanAccess.new(notes: notes, tmux: tmux, event_log: event_log) }
  let(:plan_task) { Workspace::Commands::PlanTask.new(access: access, output: output) }
  let(:tmux) { instance_spy(Workspace::Tmux) }
  let(:engine) { instance_double(Workspace::WorkflowEngine) }
  let(:checkout) { Workspace::Commands::WorkflowStart::Here.new(workspace: "app.worktree-x", path: "/src/app/.worktrees/x", caller_pane: nil) }
  let(:definition) { Workspace::WorkflowDefinition.parse(File.read(File.join(__dir__, "../../../lib/workflows/#{workflow}.yml")), id: workflow, source: "preset", path: "/defs/#{workflow}.yml").to_h }
  let(:workflow) { "rpiv" }
  let(:step) { "plan" }
  let(:run) { {"id" => "wr_1", "workflow" => workflow, "current" => step, "state" => "running", "worktree" => checkout.path, "definition" => definition} }
  let(:plan_text) { "---\nstatus: #{status}\n---\n## Tasks\n- [x] T7 Seven\n- [x] T8 Eight\n## Task details\n" }
  let(:status) { "active" }
  let(:flags) { {workflow: nil, inputs: {}} }

  subject(:task) { described_class.new(engine: engine, plan_task: plan_task, access: access, output: output) }

  before { allow(notes).to receive(:info) { |name:, create: false| {"workspace" => name, "dir" => @dir} } }

  def plan_path = File.join(@dir, "IMPLEMENTATION_PLAN.md")

  def refusal(**args)
    task.add(run, "also this", checkout, flags: flags, dry_run: false, **args)
    nil
  rescue Workspace::Error, Workspace::UsageError => e
    e
  end

  describe "#run_for" do
    it "asks the engine for the run on the checkout's path" do
      allow(engine).to receive(:run_on_checkout).with(checkout.path).and_return(run)

      expect(task.run_for(checkout)).to eq(run)
    end
  end

  describe "#add" do
    before { File.write(plan_path, plan_text) }

    it "adds the next task even when every task is checked and the status is active, and answers a task row" do
      row = task.add(run, "also this", checkout, flags: flags, dry_run: false)

      expect(File.read(plan_path)).to include("- [ ] T9 also this")
      expect(row).to include("outcome" => "added", "task" => "T9", "workspace" => "app.worktree-x", "run_id" => "wr_1", "warnings" => [])
      expect(row["decision"]).to include("workflow" => "rpiv", "source" => "run", "kind" => "prompt", "route" => "task")
      expect(output.string).to include("go: task for run wr_1 (rpiv at step plan), added to this workspace's plan.")
      expect(output.string).to include("The agent takes it when it next reads the plan.")
      expect(tmux).not_to have_received(:deliver)
      expect(tmux).not_to have_received(:send_keys)
    end

    it "adds to a run on implement" do
      run["current"] = "implement"

      expect(task.add(run, "also this", checkout, flags: flags, dry_run: false)["task"]).to eq("T9")
      lines = File.readlines(plan_path)
      expect(lines.index { |l| l.include?("- [ ] T9") }).to eq(lines.index { |l| l.include?("T8 Eight") } + 1)
    end

    context "with a paused plan" do
      let(:status) { "paused" }

      it "takes the task and warns, in the row and on the output" do
        row = task.add(run, "also this", checkout, flags: flags, dry_run: false)

        expect(File.read(plan_path)).to include("- [ ] T9 also this")
        expect(row["warnings"]).to eq([described_class::PAUSED_WARNING])
        expect(output.string).to include("Warning: #{described_class::PAUSED_WARNING}")
      end

      it "warns and writes nothing under dry_run" do
        row = task.add(run, "also this", checkout, flags: flags, dry_run: true)

        expect(row["outcome"]).to eq("dry_run")
        expect(row["warnings"]).to eq([described_class::PAUSED_WARNING])
        expect(File.read(plan_path)).to eq(plan_text)
      end
    end

    it "writes nothing under dry_run, says would add and answers dry_run" do
      row = task.add(run, "also this", checkout, flags: flags, dry_run: true)

      expect(row["outcome"]).to eq("dry_run")
      expect(File.read(plan_path)).to eq(plan_text)
      expect(output.string).to include("would add to this workspace's plan")
      expect(output.string).not_to include("takes it")
    end

    it "refuses --workflow, --input and --base before touching the plan" do
      error = refusal(flags: {workflow: "rpiv", inputs: {"a" => "b"}, base: "main"})

      expect(error).to be_a(Workspace::UsageError)
      expect(error.message).to include("--workflow, --input, --base")
      expect(File.read(plan_path)).to eq(plan_text)
    end

    it "refuses a dry run as the real call does" do
      run["current"] = "verify"

      expect { task.add(run, "also this", checkout, flags: flags, dry_run: true) }.to raise_error(Workspace::Error) { |e| expect(e.code).to eq("checkout_has_run") }
      expect(File.read(plan_path)).to eq(plan_text)
    end

    it "refuses an rpiv run on verify with checkout_has_run and the run's details" do
      run["current"] = "verify"
      error = refusal

      expect(error.code).to eq("checkout_has_run")
      expect(error.details).to include("run_id" => "wr_1", "step" => "verify", "worktree" => checkout.path)
      expect(error.message).to include("Leave off --here")
      expect(File.read(plan_path)).to eq(plan_text)
    end

    context "with the investigate preset" do
      let(:workflow) { "investigate" }
      let(:step) { "reproduce" }

      it "refuses checkout_has_run" do
        expect(refusal.code).to eq("checkout_has_run")
        expect(File.read(plan_path)).to eq(plan_text)
      end
    end

    context "with a plan marked done" do
      let(:status) { "done" }

      it "refuses plan_done naming the run, leaving the file alone" do
        error = refusal

        expect(error.code).to eq("plan_done")
        expect(error.details).to include("run_id" => "wr_1", "step" => "plan")
        expect(File.read(plan_path)).to eq(plan_text)
      end
    end

    ["x" * 501, "two\nlines", "before -- after"].each do |text|
      it "passes invalid_task through for #{text[0, 15].inspect}" do
        error = nil
        begin
          task.add(run, text, checkout, flags: flags, dry_run: false)
        rescue Workspace::Error => e
          error = e
        end

        expect(error.code).to eq("invalid_task")
        expect(File.read(plan_path)).to eq(plan_text)
      end
    end
  end

  context "with no plan file" do
    it "refuses no_plan naming the run and step, and never makes the file" do
      error = refusal

      expect(error.code).to eq("no_plan")
      expect(error.details).to include("run_id" => "wr_1", "step" => "plan")
      expect(error.message).to include("plan step has not written it")
      expect(File.exist?(plan_path)).to be(false)
    end
  end
end
