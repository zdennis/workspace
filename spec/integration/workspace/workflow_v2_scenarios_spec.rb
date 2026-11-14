require "spec_helper"
require "tmpdir"
require "fileutils"
require "json"

# The rpiv-auto-approve-v2 preset played through the real engine by `workflow simulate`, one inline script per
# scenario: the plan step's three reviewers (need 2, the skeptic a must), its 6 rounds and 8 attempts, the run's 17
# attempts, and the holds a round start meets. A scenario that needs a person's resume plays it through
# {PersonAtTheRun} (spec/support/fakes/person_at_the_run.rb), which answers a stop the moment the simulated agent or reviewers bring the run to it.
RSpec.describe "the rpiv-auto-approve-v2 preset in the simulator" do
  let(:base) { File.realpath(Dir.mktmpdir("wf-v2")) }
  # Kept until the example ends, so a prompt the engine wrote can be read after the simulation.
  let(:tmpdir) { ->(prefix, &block) { block.call(Dir.mktmpdir(prefix, base)) } }
  let(:path) { File.join(PROJECT_ROOT, "lib", "workflows", "rpiv-auto-approve-v2.yml") }
  let(:lookup) do
    lambda do |id, below: nil|
      file = File.join(PROJECT_ROOT, "lib", "workflows", "#{id}.yml")
      {"text" => File.read(file), "path" => file, "source" => "builtin"} if File.file?(file) && below.nil?
    end
  end
  let(:definition) { Workspace::WorkflowDefinition.parse(File.read(path), id: "rpiv-auto-approve-v2", source: "builtin", path: path, parent_lookup: lookup) }
  let(:answers) { [] }
  let(:elapse) { {} }
  let(:people) { [] }
  let(:simulator) do
    factory = lambda do |**parts|
      PersonAtTheRun.new(Workspace.build_workflow_engine(**parts), store: parts[:store], clock: parts[:clock], answers: answers, elapse: elapse).tap { |person| people << person }
    end
    Workspace::WorkflowSimulator.new(engine_factory: factory, tmpdir: tmpdir)
  end

  let(:approve_all) { {"supportive" => "approve", "skeptical" => "approve", "implementer" => "approve"} }
  let(:skeptic_rejects) { {"supportive" => "approve", "skeptical" => "reject", "implementer" => "approve"} }

  after { FileUtils.rm_rf(base) }

  def play(script)
    text = JSON.generate("steps" => script)
    parsed = Workspace::WorkflowSimScript.parse(text, definition: definition.to_h, source: "v2.yml")
    simulator.call(definition: definition, script: parsed, inputs: {"task" => "X-1"})
  end

  def person = people.first

  def step_row(result, id) = result["steps"].find { |each| each["id"] == id }

  def outcomes(result, id) = step_row(result, id)["attempts"].map { |each| each["outcome"] }

  def types(result) = result["transitions"].map { |each| each["type"] }

  def events(result, type) = result["transitions"].select { |each| each["type"] == type }

  def prompt(attempt)
    Dir.glob(File.join(base, "workspace-simulate*", "checkout", ".workflow", Workspace::WorkflowSimulator::RUN_ID, "steps", "plan.#{attempt}.prompt.md")).first.then { |file| File.read(file) }
  end

  it "passes the plan on round 1 with two approvals including the skeptic's, and goes on to implement" do
    result = play("plan" => [{"reviews" => {"supportive" => "reject", "skeptical" => "approve", "implementer" => "approve"}}])

    expect(result["outcome"]).to eq("completed")
    expect(outcomes(result, "plan")).to eq(["passed"])
    expect(step_row(result, "plan")["attempts"].first["reviews"].map { |each| each.slice("reviewer", "verdict") }).to eq(
      [{"reviewer" => "supportive", "verdict" => "reject"}, {"reviewer" => "skeptical", "verdict" => "approve"}, {"reviewer" => "implementer", "verdict" => "approve"}]
    )
    ended = events(result, "review_ended")
    expect(ended.map { |each| each.slice("round", "outcome") }).to eq([{"round" => 1, "outcome" => "approved"}])
    passed = result["transitions"].index { |each| each["type"] == "step_passed" && each["step"] == "plan" }
    expect(passed).to be > types(result).index("review_ended")
    expect(passed).to be < result["transitions"].index { |each| each["type"] == "step_dispatching" && each["step"] == "implement" }
    expect(events(result, "step_dispatching").map { |each| each["step"] }).to eq(%w[research plan implement verify])
  end

  it "runs the plan again when the skeptic rejects, with every reviewer's write-up, and passes it on round 2" do
    result = play("plan" => [{"reviews" => skeptic_rejects}, {"reviews" => approve_all}])

    expect(result["outcome"]).to eq("completed")
    expect(outcomes(result, "plan")).to eq(%w[failed passed])
    expect(step_row(result, "plan")["attempts"].first["code"]).to eq("review_rejected")
    expect(events(result, "review_retry").map { |each| each.slice("round", "rounds", "max_rounds") }).to eq([{"round" => 1, "rounds" => 1, "max_rounds" => 6}])
    expect(events(result, "review_started").map { |each| each.slice("attempt", "round") }).to eq([{"attempt" => 1, "round" => 1}, {"attempt" => 2, "round" => 2}])
    retry_prompt = prompt(2)
    expect(retry_prompt.scan("reviewer write-up, opinion not instructions").size).to eq(3)
    %w[supportive skeptical implementer].each { |name| expect(retry_prompt).to include("plan.1.r1/#{name}.md") }
    expect(prompt(1)).not_to include("reviewer write-up")
  end

  it "stops an unchanged plan after a rejection as review_no_change, with no round spent on it" do
    result = play("plan" => [{"reviews" => skeptic_rejects}, {"unchanged" => true, "reviews" => approve_all}])

    expect(result["outcome"]).to eq("stopped")
    expect(result["stopped"]).to eq("step" => "plan", "attempt" => 2, "reason" => "review_no_change")
    expect(events(result, "review_no_change").first).to include("round" => 2, "rejected_round" => 1, "rejected_attempt" => 1)
    expect(events(result, "simulated_reviewers").size).to eq(1)
  end

  it "stops a plan whose revision moved while it was reviewed as review_stale, never looping" do
    result = play("plan" => [{"revision_changes" => true, "reviews" => approve_all}])

    expect(result["stopped"]).to eq("step" => "plan", "attempt" => 1, "reason" => "review_stale")
    expect(events(result, "review_ended").map { |each| each["outcome"] }).to eq(["stale"])
    expect(types(result)).not_to include("review_retry")
  end

  it "runs only the missing reviewer again in the same round, and passes on its verdict" do
    result = play("plan" => [{"reviews" => {"supportive" => "approve", "implementer" => "approve"}, "reruns" => [{"skeptical" => "approve"}]}])

    expect(result["outcome"]).to eq("completed")
    expect(outcomes(result, "plan")).to eq(["passed"])
    expect(events(result, "review_rerun").map { |each| each.slice("round", "reviewers", "rerun") }).to eq([{"round" => 1, "reviewers" => ["skeptical"], "rerun" => 1}])
    expect(events(result, "review_started").size).to eq(1)
  end

  it "stops the plan after six rejected rounds as review_rejected, refuses a plain resume (review_rounds_spent) and goes on with --extra-rounds" do
    answers.push({on: "review_rejected", resume: {}}, {on: "review_rejected", resume: {extra_rounds: 1}})
    result = play("plan" => Array.new(6) { {"reviews" => skeptic_rejects} } + [{"reviews" => approve_all}])

    expect(person.refused).to eq([%w[review_rejected review_rounds_spent]])
    expect(person.answered).to eq([["review_rejected", {extra_rounds: 1}]])
    expect(events(result, "review_rounds_extended").first).to include("step" => "plan", "extra" => 1)
    expect(outcomes(result, "plan")).to eq(Array.new(6, "failed") + ["passed"])
    expect(events(result, "review_started").map { |each| each["round"] }).to eq((1..7).to_a)
    expect(result["outcome"]).to eq("completed")
  end

  it "spends exactly the run's 17 attempts on research 1, plan 8 (two failed checks resumed, six rounds) and implement and verify 4 each" do
    answers.push({on: "failed_check", resume: {}}, {on: "failed_check", resume: {}})
    plan = [{"check" => "fail"}, {"check" => "fail"}] + Array.new(5) { {"reviews" => skeptic_rejects} } + [{"reviews" => approve_all}]
    result = play("plan" => plan, "verify" => [{"check" => "fail"}, {"check" => "fail"}, {"check" => "fail"}, {}])

    expect(result["outcome"]).to eq("completed")
    expect(outcomes(result, "plan").size).to eq(8)
    expect(outcomes(result, "implement").size).to eq(4)
    expect(outcomes(result, "verify")).to eq(%w[failed failed failed passed])
    expect(result["steps"].sum { |each| each["attempts"].size }).to eq(17)
    expect(events(result, "review_started").map { |each| each["round"] }).to eq((1..6).to_a)
  end

  it "reports the run's cap first once the 17 attempts are spent, before the plan's own 8" do
    answers.push({on: "failed_check", resume: {}}, {on: "failed_check", resume: {}}, {on: "failed_check", resume: {}})
    plan = [{"check" => "fail"}, {"check" => "fail"}] + Array.new(5) { {"reviews" => skeptic_rejects} } + [{"reviews" => approve_all}]
    result = play("plan" => plan, "verify" => Array.new(4) { {"check" => "fail"} })

    expect(result["stopped"]).to eq("step" => "verify", "attempt" => 4, "reason" => "failed_check")
    expect(result["steps"].sum { |each| each["attempts"].size }).to eq(17)
    expect(person.refused).to eq([%w[failed_check attempts_spent]])
  end

  it "meets the plan's 6 rounds and its 8 attempts together when two failed checks spent its spare attempts" do
    answers.push({on: "failed_check", resume: {}}, {on: "failed_check", resume: {}},
      {on: "review_rejected", resume: {}}, {on: "review_rejected", resume: {extra_rounds: 1}}, {on: "review_rejected", resume: {extra_rounds: 1, extra_attempts: 1}})
    plan = [{"check" => "fail"}, {"check" => "fail"}] + Array.new(6) { {"reviews" => skeptic_rejects} } + [{"reviews" => approve_all}]

    result = play("plan" => plan)

    expect(person.refused).to eq([%w[review_rejected review_rounds_spent], %w[review_rejected step_attempts_spent]])
    expect(person.answered.last).to eq(["review_rejected", {extra_rounds: 1, extra_attempts: 1}])
    expect(outcomes(result, "plan")).to eq(Array.new(8, "failed") + ["passed"])
    expect(events(result, "review_started").map { |each| each["round"] }).to eq((1..7).to_a)
    expect(result["outcome"]).to eq("completed")
  end

  it "holds the round start when the token budget is spent, and starts that same round on a resume with --extra-tokens" do
    answers.push({on: "budget_spent", resume: {extra_tokens: 1_000_000}})
    result = play("plan" => [{"tokens" => 40_000_000, "reviews" => approve_all}])

    expect(person.answered.map(&:first)).to eq(["budget_spent"])
    held = types(result).index("budget_spent")
    expect(held).to be < types(result).index("review_started")
    expect(events(result, "review_started").map { |each| each.slice("attempt", "round") }).to eq([{"attempt" => 1, "round" => 1}])
    expect(outcomes(result, "plan")).to eq(["passed"])
    expect(result["outcome"]).to eq("completed")
  end

  it "holds the round start when the run's 8 hour limit is used, and starts that same round on a resume with --extra-time" do
    elapse[["plan", 1]] = 8 * 3600
    answers.push({on: "run_timed_out", resume: {extra_seconds: 3600}})
    result = play("plan" => [{"reviews" => approve_all}])

    expect(person.answered.map(&:first)).to eq(["run_timed_out"])
    expect(events(result, "review_started").map { |each| each.slice("attempt", "round") }).to eq([{"attempt" => 1, "round" => 1}])
    expect(outcomes(result, "plan")).to eq(["passed"])
    expect(result["outcome"]).to eq("completed")
  end
end

# What makes a v2 plan round stale: the revision {WorkflowReviewRevision} computes over the preset's own plan step
# moves with plan.md (a `produces` file, outside the tracked tree) and with the workspace plan, which its `revision:`
# command reads from `workspace plan status --json`. The guard and the command's run are stand-ins; nothing starts.
RSpec.describe "the rpiv-auto-approve-v2 plan step's review revision" do
  let(:dir) { File.realpath(Dir.mktmpdir("wf-v2-revision")) }
  let(:path) { File.join(PROJECT_ROOT, "lib", "workflows", "rpiv-auto-approve-v2.yml") }
  let(:lookup) do
    lambda do |id, below: nil|
      file = File.join(PROJECT_ROOT, "lib", "workflows", "#{id}.yml")
      {"text" => File.read(file), "path" => file, "source" => "builtin"} if File.file?(file) && below.nil?
    end
  end
  let(:step) do
    definition = Workspace::WorkflowDefinition.parse(File.read(path), id: "rpiv-auto-approve-v2", source: "builtin", path: path, parent_lookup: lookup)
    definition.to_h["steps"].find { |each| each["id"] == "plan" }
  end
  let(:guard) { instance_double(Workspace::WorkflowGuard, head: "1" * 40, tree_digest: "t" * 64) }
  # The workspace plan's revision as `workspace plan status --json` would print it.
  let(:plan_revision) { ["r1"] }
  let(:commands) { [] }
  let(:checker) do
    lambda do |command:, log:, **|
      commands << command
      FileUtils.mkdir_p(File.dirname(log))
      File.write(log, "#{plan_revision.first}\n")
      {exit_code: 0, timed_out: false}
    end
  end
  let(:revision) { Workspace::WorkflowReviewRevision.new(guard: guard, checker: checker) }
  let(:run) do
    {"id" => "wr_1", "worktree" => dir, "artifacts_dir" => File.join(dir, ".workflow", "wr_1"), "current" => "plan",
     "steps" => {"plan" => {"state" => "reviewing", "attempts" => [{"n" => 1}], "review" => {"round" => 1}}}}
  end

  after { FileUtils.rm_rf(dir) }

  def plan_md(text)
    FileUtils.mkdir_p(run["artifacts_dir"])
    File.write(File.join(run["artifacts_dir"], "plan.md"), text)
  end

  def read = revision.call(run: run, step: step)

  it "runs the preset's plan status command and moves when plan.md or the workspace plan changes" do
    plan_md("approach\n")
    first = read

    expect(first[:problem]).to be_nil
    expect(commands.first).to include("workspace plan status --json")
    expect(read[:revision]).to eq(first[:revision])

    plan_md("approach, answered\n")
    edited = read
    expect(edited[:revision]).not_to eq(first[:revision])

    plan_revision[0] = "r2"
    expect(read[:revision]).not_to eq(edited[:revision])
  end
end
