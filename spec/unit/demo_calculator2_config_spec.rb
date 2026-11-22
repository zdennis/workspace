require "spec_helper"

load File.join(PROJECT_ROOT, "script", "demo-calculator2")

RSpec.describe DemoCalculator2 do
  let(:config) { described_class.config }

  it "queues one deliver-goal item per goal, with the goal and the acceptance program as inputs" do
    items = config.queue_items.call(["--name", "ws"])
    expect(items.map(&:first).uniq).to eq(["deliver-goal"])
    expect(items.size).to eq(7)
    expect(items.last.last).to eq(["work-queue", "add", "workflow", "deliver-goal", "--prompt", "Deliver the goal in demo/calculator2/goals/07-repl.md",
      "--input", "goal=demo/calculator2/goals/07-repl.md", "--input", "acceptance=script/demo_calculator2/acceptance_runner",
      "--dedupe-key", "calculator2-demo:07-repl", "--json", "--name", "ws"])
  end

  it "names a goal file that exists for every goal" do
    expect(described_class::GOALS.map { |goal| File.exist?(File.join(PROJECT_ROOT, "demo/calculator2/goals/#{goal}.md")) }).to all(be(true))
  end

  it "points at the calculator2 paths and the test and lint commands" do
    expect(config).to have_attributes(workflows_suffix: "/demo/calculator2/workflows", test_command: "ruby demo/calculator2/test/calc_test.rb",
      lint_command: "bundle exec standardrb demo/calculator2", acceptance_ref: "refs/demo-calc2/acceptance-base", stub_ref: "main")
  end

  it "takes a stub ref and a goal list, and records both for run.json" do
    picked = described_class.config(stub_ref: "wip", goals: %w[02-mul-div 05-mod-pow])
    expect(picked.queue_items.call([]).size).to eq(2)
    expect(picked).to have_attributes(stub_ref: "wip", record_extras: {"stub_ref" => "wip", "goals" => %w[02-mul-div 05-mod-pow]})
  end

  it "picks goals by number or name, in goal order, and refuses an unknown one" do
    expect(described_class.pick_goals("03, 01-add-sub")).to eq(%w[01-add-sub 03-div-zero])
    expect { described_class.pick_goals("09") }.to raise_error(DemoCalculator::Refused, /no goal 09/)
    expect { described_class.pick_goals(",") }.to raise_error(DemoCalculator::Refused, /names no goal/)
    expect { described_class.pick_goals("") }.to raise_error(DemoCalculator::Refused, /names no goal/)
    expect { described_class.pick_goals("01,01-add-sub") }.to raise_error(DemoCalculator::Refused, /01-add-sub more than once/)
  end

  it "keeps v1's paths as the default config" do
    expect(DemoCalculator::Config.v1).to have_attributes(demo_dir: "demo/calculator", workflows_suffix: "/demo/calculator/workflows",
      runs_dir: "tmp/demo-calculator/runs", acceptance_ref: nil, lint_command: nil)
  end
  describe "the workflow id" do
    it "defaults to deliver-goal and takes another for every item" do
      fast = described_class.config(workflow_id: "deliver-goal-fast", goals: %w[01-add-sub])
      expect(fast.queue_items.call([]).first.first).to eq("deliver-goal-fast")
      expect(fast.queue_items.call([]).first.last).to start_with("work-queue", "add", "workflow", "deliver-goal-fast")
    end

    it "lists the three definitions the run record hashes" do
      expect(config.definition_ids).to eq(%w[deliver-goal deliver-goal-fast integrate-branch])
      expect(described_class::GOAL_WORKFLOW_IDS).to eq(%w[deliver-goal deliver-goal-fast])
    end

    it "names a definition file that exists for each id" do
      expect(config.definition_ids.map { |id| File.exist?(File.join(PROJECT_ROOT, "demo/calculator2/workflows/#{id}.yml")) }).to all(be(true))
    end
  end

  describe "the lanes" do
    it "puts 01-05 in lane A and 06 and 07 in lane B, forking after 03" do
      expect(described_class::LANES).to eq(a: %w[01-add-sub 02-mul-div 03-div-zero 04-precedence 05-mod-pow], b: %w[06-json 07-repl], fork_after: "03-div-zero")
      expect(described_class::LANES[:a] + described_class::LANES[:b]).to eq(described_class::GOALS)
    end

    it "queues each lane's goals under the lanes' acceptance runner, and gives only lane B the prompt that names the earlier goals" do
      a = described_class.lane_config(:a, workflow_id: "deliver-goal-fast").queue_items.call(["--name", "a"])
      b = described_class.lane_config(:b, workflow_id: "deliver-goal-fast").queue_items.call(["--name", "b"])
      expect(a.size).to eq(5)
      expect(b.map { |_, argv| argv[argv.index("--dedupe-key") + 1] }).to eq(%w[calculator2-demo:06-json calculator2-demo:07-repl])
      (a + b).each { |_, argv| expect(argv).to include("acceptance=script/demo_calculator2/acceptance_runner_lanes") }
      expect(a.map { |_, argv| argv[argv.index("--prompt") + 1] }).to all(satisfy { |text| text.start_with?("Deliver the goal in demo/calculator2/goals/0") && !text.include?("Earlier goals") })
      expect(b.map { |_, argv| argv[argv.index("--prompt") + 1] }).to all(end_with("Earlier goals here means 01, 02 and 03. This branch holds only their work; do not read or build goals 04 or 05."))
    end

    it "takes each lane's goals from the goals of the run" do
      expect(described_class.lane_goals(:a, %w[01-add-sub 06-json])).to eq(%w[01-add-sub])
      expect(described_class.lane_goals(:b, %w[01-add-sub 06-json])).to eq(%w[06-json])
    end

    it "forks after the last lane A goal at or before 03 in the run" do
      expect(described_class.fork_goal).to eq("03-div-zero")
      expect(described_class.fork_goal(%w[01-add-sub 06-json])).to eq("01-add-sub")
      expect(described_class.fork_goal(%w[01-add-sub 03-div-zero 05-mod-pow 06-json])).to eq("03-div-zero")
      expect(described_class.fork_goal(%w[05-mod-pow 06-json])).to be_nil
    end

    it "keeps the integration run on the 07 goal name with the plain acceptance runner" do
      argv = described_class.integrate_argv("calc-demo/x-b", ["--name", "a"])
      expect(argv).to include("integrate-branch", "branch=calc-demo/x-b", "goal=demo/calculator2/goals/07-repl.md", "acceptance=script/demo_calculator2/acceptance_runner")
    end

    it "tells which groups no item's own check runs, so the plain 07 run after the merge is the only one to cover them" do
      expect(described_class.group_coverage(%w[06-json 07-repl])).to eq("06-json" => [1, 2, 3, 6], "07-repl" => [1, 2, 3, 6, 7])
      expect(described_class.coverage_check(described_class::GOALS)).to eq(covered: [1, 2, 3, 4, 5, 6, 7], integration_only: [])
      expect(described_class.coverage_check(%w[01-add-sub 06-json])).to eq(covered: [1, 2, 3, 6], integration_only: [4, 5, 7])
    end
  end
end
