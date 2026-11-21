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

  it "keeps v1's paths as the default config" do
    expect(DemoCalculator::Config.v1).to have_attributes(demo_dir: "demo/calculator", workflows_suffix: "/demo/calculator/workflows",
      runs_dir: "tmp/demo-calculator/runs", acceptance_ref: nil, lint_command: nil)
  end
end
