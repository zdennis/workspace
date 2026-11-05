require "spec_helper"
require "tmpdir"

# The mapping cases are ported from workspace-ui's src/core/spine/facts.test.ts.
RSpec.describe Workspace::SpineFacts do
  let(:tmpdir) { Dir.mktmpdir }
  after { FileUtils.remove_entry(tmpdir) }

  let(:git_answers) { {branch: "fix", upstream: "origin/fix", config: ["origin", "refs/heads/fix"], ahead: 4} }
  let(:git_calls) { [] }
  let(:git) do
    answers = git_answers
    calls = git_calls
    Class.new do
      define_method(:worktree_branch) { |_path| calls << :branch && answers[:branch] }
      define_method(:upstream_branch) { |_path| calls << :upstream && answers[:upstream] }
      define_method(:upstream_config) { |_path, _branch| calls << :config && answers[:config] }
      define_method(:commits_ahead_of_upstream) do |_path|
        sleep answers[:git_delay] if answers[:git_delay]
        calls << :ahead && answers[:ahead]
      end
    end.new
  end

  let(:pr_answer) { {"available" => true, "found" => false} }
  let(:pr_calls) { [] }
  let(:pr_delay) { nil }
  let(:pull_request_status) do
    answer = -> { pr_answer }
    calls = pr_calls
    delay = pr_delay
    Class.new do
      define_method(:call) do |path|
        calls << path
        sleep delay if delay
        answer.call
      end
    end.new
  end

  let(:snapshot) { {"panes" => [{"pane_id" => "%1", "kind" => "claude", "state" => "done", "state_since" => "t0"}]} }
  let(:daemon_calls) { [] }
  let(:snapshot_client) do
    reply = -> { snapshot }
    calls = daemon_calls
    Class.new do
      define_method(:fetch) do |name, timeout:|
        calls << [name, timeout]
        value = reply.call
        raise value if value.is_a?(Exception)
        sleep value[:sleep] if value.is_a?(Hash) && value[:sleep]
        value
      end
    end.new
  end

  let(:base_ahead) { 2 }
  let(:review) do
    ahead = -> { base_ahead }
    Class.new do
      define_method(:agent_facts_from) do |_workspace, panes:, unavailable: nil|
        next {"available" => false, "reason" => unavailable} unless panes
        done = panes.any? { |p| p["state"] == "done" }
        {"available" => true, "state" => done ? "done" : "working"}
      end
      define_method(:commits_ahead_of_base) { |_path| ahead.call }
    end.new
  end

  let(:asks) { [] }
  let(:ask_store_for) do
    records = -> { asks }
    ->(_workspace) { Class.new { define_method(:list) { |open_only:| records.call } }.new }
  end

  let(:gh_on_path) { true }
  let(:which) { ->(exe) { exe == "gh" && gh_on_path } }

  subject(:spine_facts) do
    described_class.new(git: git, pull_request_status: pull_request_status, snapshot_client: snapshot_client, review: review,
      ask_store_for: ask_store_for, which: which, daemon_timeout: 0.2, git_timeout: 0.3, gh_timeout: 0.3)
  end

  def readings(**over) = described_class::Readings.new(**over)

  def map(**over) = spine_facts.facts_from("app", readings(**over))

  def git_reading(**over) = {"branch" => "fix", "upstream" => "origin/fix", "upstream_configured" => true, "ahead" => 4}.merge(over)

  def gone = git_reading("upstream" => nil, "ahead" => nil)

  def never_pushed = git_reading("upstream" => nil, "upstream_configured" => false, "ahead" => nil)

  def pr(state, checks = {}, **extra)
    {"available" => true, "found" => true, "state" => state,
     "checks" => {"total" => 0, "passing" => 0, "failing" => 0, "pending" => 0}.merge(checks)}.merge(extra)
  end

  def read(gates: [])
    spine_facts.read(workspace: "app", checkout: "/src/app", notes_dir: tmpdir, gates: gates)
  end

  it "is all nil with nothing read" do
    facts = map.facts
    expect(facts.to_h).to eq(plan: nil, git: nil, pr: nil, review: nil, panes: nil)
  end

  describe "plan" do
    def plan(text) = Workspace::PlanFile.parse(text)

    it "counts tasks neither done nor skipped as open" do
      text = "## Tasks\n\n- [x] T1 a\n- [x] T2 b\n- [~] T3 c\n- [-] T4 d\n- [ ] T5 e\n"
      expect(map(plan: plan(text)).facts.plan).to eq(Workspace::SpineEvaluator::PlanFact.new(exists: true, total: 5, open: 2))
    end

    it "says when there is no plan file" do
      result = map(plan: :missing)
      expect(result.facts.plan).to eq(Workspace::SpineEvaluator::PlanFact.new(exists: false, total: 0, open: 0))
      expect(result.sources["plan"]).to eq("ok")
    end

    it "an empty plan has no tasks" do
      expect(map(plan: plan("")).facts.plan).to eq(Workspace::SpineEvaluator::PlanFact.new(exists: true, total: 0, open: 0))
    end

    it "an unreadable plan file is not read" do
      File.write(File.join(tmpdir, "IMPLEMENTATION_PLAN.md"), "x")
      File.chmod(0o000, File.join(tmpdir, "IMPLEMENTATION_PLAN.md"))
      result = read
      expect(result.facts.plan).to be_nil
      expect(result.sources["plan"]).to eq("unavailable")
    ensure
      File.chmod(0o644, File.join(tmpdir, "IMPLEMENTATION_PLAN.md"))
    end
  end

  describe "git" do
    {
      "ahead of its upstream" => [{}, Workspace::SpineEvaluator::GitFact.new(upstream: true, ahead: 4)],
      "pushed" => [{"ahead" => 0}, Workspace::SpineEvaluator::GitFact.new(upstream: true, ahead: 0)],
      "no upstream" => [{"upstream" => nil, "upstream_configured" => false, "ahead" => nil}, Workspace::SpineEvaluator::GitFact.new(upstream: false, ahead: 0)],
      "upstream gone" => [{"upstream" => nil, "ahead" => nil}, nil],
      "the count failed" => [{"ahead" => nil}, nil],
      "detached" => [{"branch" => nil}, nil]
    }.each do |name, (over, expected)|
      it name do
        expect(map(git: git_reading(**over)).facts.git).to eq(expected)
      end
    end

    it "names why the fact is nil" do
      expect(map(git: gone).reasons["git"]).to eq("upstream_gone")
      expect(map(git: git_reading("ahead" => nil)).reasons["git"]).to eq("ahead_unknown")
      expect(map(git: git_reading("branch" => nil)).sources["git"]).to eq("unavailable")
    end

    it "is nil outside a checkout" do
      expect(map(git: nil).facts.git).to be_nil
    end

    it "an upstream gone after a merge leaves pushed unchecked" do
      result = map(git: gone)
      gate = Workspace::SpineEvaluator.gate_result("pushed", {"done" => 0, "total" => 0}, result.facts)
      expect(gate["result"]).to eq("unchecked")
    end

    it "an ahead count git couldn't give leaves pushed unchecked" do
      result = map(git: git_reading("ahead" => nil), pull_request: pr("OPEN"))
      expect(Workspace::SpineEvaluator.gate_result("pushed", {"done" => 0, "total" => 0}, result.facts)["result"]).to eq("unchecked")
    end
  end

  describe "pr" do
    {
      "never pushed" => [nil, Workspace::SpineEvaluator::PrFact.new(state: "none", checks: "none")],
      "a failed query" => [{"available" => false, "reason" => "error"}, nil],
      "gh missing" => [{"available" => false, "reason" => "gh_missing"}, nil],
      "no pull request" => [{"available" => true, "found" => false}, Workspace::SpineEvaluator::PrFact.new(state: "none", checks: "none")],
      "a state GitHub didn't name" => [{"available" => true, "found" => true, "state" => nil}, nil]
    }.each do |name, (answer, expected)|
      it name do
        git = (name == "never pushed") ? never_pushed : git_reading
        expect(map(git: git, pull_request: answer).facts.pr).to eq(expected)
      end
    end

    {
      "open with checks passing" => [["OPEN", {"total" => 2, "passing" => 2}], "open", "pass"],
      "open with checks failing" => [["OPEN", {"total" => 3, "passing" => 1, "failing" => 1, "pending" => 1}], "open", "fail"],
      "open with checks running" => [["OPEN", {"total" => 2, "passing" => 1, "pending" => 1}], "open", "pending"],
      "open with no checks" => [["OPEN", {}], "open", "none"],
      "merged" => [["MERGED", {"total" => 1, "passing" => 1}], "merged", "pass"],
      "closed" => [["CLOSED", {}], "closed", "none"]
    }.each do |name, ((gh_state, counts), state, checks)|
      it name do
        answer = pr(gh_state, counts)
        fact = map(git: git_reading, pull_request: answer).facts.pr
        expect([fact.state, fact.checks]).to eq([state, checks])
        expect([fact.failing, fact.total]).to eq(answer["checks"].values_at("failing", "total"))
      end
    end

    it "is nil detached or outside a checkout" do
      expect(map(git: git_reading("branch" => nil), pull_request: pr("OPEN")).facts.pr).to be_nil
      expect(map(git: nil, pull_request: pr("OPEN")).facts.pr).to be_nil
    end

    it "can't tell when the remote branch was deleted and no pull request is found, as after a merge" do
      result = map(git: gone, pull_request: {"available" => true, "found" => false})
      expect(result.facts.pr).to be_nil
      expect(result.facts.git).to be_nil
      expect(result.reasons["pr"]).to eq("not_found")
    end

    it "can't tell from an unmerged pull request once the remote branch is gone" do
      expect(map(git: gone, pull_request: pr("CLOSED")).facts.pr).to be_nil
    end

    it "a merged pull request on record still counts after the remote branch is deleted" do
      result = map(git: gone, pull_request: pr("MERGED"))
      expect(result.facts.pr.state).to eq("merged")
      expect(Workspace::SpineEvaluator.gate_result("pushed", {"done" => 0, "total" => 0}, result.facts)["result"]).to eq("pass")
    end

    it "says the pull request wasn't read when no gate needed it" do
      result = map(git: git_reading)
      expect(result.sources["gh"]).to eq("not_needed")
      expect(result.facts.pr).to be_nil
    end
  end

  describe "#commits_ahead_of_base" do
    it "asks the review reader" do
      expect(spine_facts.commits_ahead_of_base("/src/app")).to eq(2)
    end
  end

  describe "review" do
    let(:panes) { [{"pane_id" => "%1", "kind" => "claude", "state" => "done"}] }

    it "is not wanted without a review gate" do
      result = map(panes: panes, review_ahead: 2)
      expect(result.facts.review).to be_nil
      expect(result.sources["review"]).to eq("not_needed")
    end

    it "the agent done with no changes asked" do
      expect(map(review: true, panes: panes, review_ahead: 2).facts.review).to eq(Workspace::SpineEvaluator::ReviewFact.new(agent_done: true, changes_requested: false))
    end

    it "the agent still working" do
      fact = map(review: true, panes: [{"pane_id" => "%1", "kind" => "claude", "state" => "working"}], review_ahead: 2).facts.review
      expect(fact.agent_done).to be(false)
    end

    it "changes requested on the pull request" do
      fact = map(review: true, panes: panes, review_ahead: 2, pull_request: pr("OPEN", {}, "review_decision" => "CHANGES_REQUESTED")).facts.review
      expect(fact.changes_requested).to be(true)
    end

    it "no pull request found asks for no changes" do
      fact = map(review: true, panes: panes, review_ahead: 2, pull_request: {"available" => true, "found" => false}).facts.review
      expect(fact.changes_requested).to be(false)
    end

    it "is not checked when the agent can't be read" do
      result = map(review: true, panes: nil, daemon_reason: "timeout", review_ahead: 2)
      expect(result.facts.review).to be_nil
      expect(result.reasons["review"]).to eq("timeout")
    end

    it "is not checked when nothing is on the branch, as after a merge" do
      result = map(review: true, panes: panes, review_ahead: 0)
      expect(result.facts.review).to be_nil
      expect(result.reasons["review"]).to eq("nothing_ahead")
      expect(Workspace::SpineEvaluator.gate_result("review", {"done" => 0, "total" => 0}, result.facts)["result"]).to eq("unchecked")
    end

    it "still reads the agent when git can't be read" do
      expect(map(review: true, panes: panes, review_ahead: nil).facts.review).to eq(Workspace::SpineEvaluator::ReviewFact.new(agent_done: true, changes_requested: false))
    end
  end

  describe "panes" do
    it "lists agents with waiting and working, and shells as present" do
      panes = [
        {"pane_id" => "%1", "kind" => "claude", "state" => "working", "state_since" => 900},
        {"pane_id" => "%2", "kind" => "codex", "state" => "waiting", "state_since" => 800},
        {"pane_id" => "%3", "kind" => "claude", "state" => "idle"},
        {"pane_id" => "%4", "kind" => "claude", "state" => "idle", "state_since" => 700},
        {"pane_id" => "%9", "kind" => "shell", "state" => "working"}
      ]
      result = map(panes: panes, asks: [{"id" => "q1", "pane" => "%3"}, {"id" => "q2", "pane" => nil}])
      expect(result.facts.panes).to eq([
        Workspace::SpineEvaluator::Pane.new(pane: "%1", waiting: false, working: true, since: 900),
        Workspace::SpineEvaluator::Pane.new(pane: "%2", waiting: true, working: false, since: nil),
        Workspace::SpineEvaluator::Pane.new(pane: "%3", waiting: true, working: false, since: nil),
        Workspace::SpineEvaluator::Pane.new(pane: "%4", waiting: false, working: false, since: nil),
        Workspace::SpineEvaluator::Pane.new(pane: "%9", waiting: false, working: false, since: nil)
      ])
      expect(result.sources["panes"]).to eq("ok")
    end

    it "counts no questions when the ask store couldn't be read" do
      expect(map(panes: [{"pane_id" => "%1", "kind" => "claude", "state" => "idle"}], asks: nil).facts.panes.first.waiting).to be(false)
    end

    it "is nil when the panes can't be read" do
      result = map(panes: nil, daemon_reason: "no_daemon")
      expect(result.facts.panes).to be_nil
      expect(result.sources["panes"]).to eq("unavailable")
      expect(result.reasons["panes"]).to eq("no_daemon")
    end
  end

  describe ".gates_in" do
    it "collects the gates of every stage and sub-stage once" do
      stage = ->(gates, children = []) { Struct.new(:gates, :children).new(gates, children) }
      stages = [stage.call(["pr"], [stage.call(["ci", "pr"])]), stage.call(["review"])]
      expect(described_class.gates_in(stages)).to eq(%w[pr ci review])
    end
  end

  describe "#read" do
    it "reads git, the plan and the daemon, and runs no gh when no gate needs it" do
      result = read(gates: ["checklist"])
      expect(pr_calls).to be_empty
      expect(result.facts.git).to eq(Workspace::SpineEvaluator::GitFact.new(upstream: true, ahead: 4))
      expect(result.facts.plan).to eq(Workspace::SpineEvaluator::PlanFact.new(exists: false, total: 0, open: 0))
      expect(result.facts.panes.map(&:pane)).to eq(["%1"])
      expect(daemon_calls).to eq([["app", 0.2]])
      expect(result.sources).to include("plan" => "ok", "git" => "ok", "gh" => "not_needed", "review" => "not_needed", "panes" => "ok")
    end

    it "runs one gh for every gate that needs it" do
      read(gates: %w[pr ci merged review pushed])
      expect(pr_calls).to eq(["/src/app"])
    end

    it "asks gh for pushed only when git can't pass it" do
      git_answers[:ahead] = 0
      read(gates: ["pushed"])
      expect(pr_calls).to be_empty
      git_answers[:ahead] = 1
      read(gates: ["pushed"])
      expect(pr_calls).to eq(["/src/app"])
    end

    it "asks no gh for a branch never pushed: it has no pull request" do
      git_answers.merge!(upstream: nil, config: nil)
      result = read(gates: ["pr"])
      expect(pr_calls).to be_empty
      expect(result.facts.pr).to eq(Workspace::SpineEvaluator::PrFact.new(state: "none", checks: "none"))
      expect(result.facts.git).to eq(Workspace::SpineEvaluator::GitFact.new(upstream: false, ahead: 0))
      expect(git_calls).not_to include(:ahead)
    end

    it "tells a deleted remote branch from one never pushed through the upstream config" do
      git_answers[:upstream] = nil
      result = read(gates: ["pr", "pushed"])
      expect(git_calls).to include(:config)
      expect(result.facts.git).to be_nil
      expect(result.reasons["git"]).to eq("upstream_gone")
      expect(result.facts.pr).to be_nil
    end

    it "reads no upstream config when @{u} resolves" do
      read
      expect(git_calls).not_to include(:config)
    end

    it "says gh is missing without running it" do
      result = spine_facts_without_gh.read(workspace: "app", checkout: "/src/app", notes_dir: tmpdir, gates: ["ci"])
      expect(result.sources["gh"]).to eq("unavailable")
      expect(result.reasons["gh"]).to eq("gh_missing")
      expect(pr_calls).to be_empty
    end

    def spine_facts_without_gh
      described_class.new(git: git, pull_request_status: pull_request_status, snapshot_client: snapshot_client, review: review,
        ask_store_for: ask_store_for, which: ->(_exe) { false })
    end

    it "reads the review agent from the same daemon snapshot and the ahead count from review" do
      result = read(gates: ["review"])
      expect(daemon_calls.size).to eq(1)
      expect(result.facts.review).to eq(Workspace::SpineEvaluator::ReviewFact.new(agent_done: true, changes_requested: false))
    end

    it "counts open questions against their panes" do
      asks << {"id" => "q1", "pane" => "%1"}
      expect(read.facts.panes.first.waiting).to be(true)
    end

    context "when gh takes too long" do
      let(:pr_delay) { 2 }

      it "leaves the pull request unread and says it timed out" do
        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        result = read(gates: ["pr"])
        expect(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).to be < 1.8
        expect(result.facts.pr).to be_nil
        expect(result.sources["gh"]).to eq("unavailable")
        expect(result.reasons["gh"]).to eq("timeout")
      end
    end

    context "when the daemon is down" do
      let(:snapshot) { Workspace::AgentSnapshotClient::Unavailable.new("none", reason: :no_daemon) }

      it "leaves the panes and the review unread" do
        result = read(gates: ["review"])
        expect(result.facts.panes).to be_nil
        expect(result.facts.review).to be_nil
        expect(result.reasons).to include("panes" => "no_daemon", "review" => "no_daemon")
      end
    end

    context "when the daemon sends a bad reply" do
      let(:snapshot) { Workspace::Error.new("Malformed reply") }

      it "reads as an error" do
        expect(read.reasons["panes"]).to eq("error")
      end
    end

    it "reads a gh or daemon read that raised as an error, not a timeout" do
      allow(pull_request_status).to receive(:call).and_raise(ArgumentError)
      allow(snapshot_client).to receive(:fetch).and_raise(ArgumentError)
      result = read(gates: ["pr"])
      expect(result.reasons).to include("gh" => "error", "panes" => "error")
    end

    context "when the daemon answers after the limit" do
      let(:snapshot) { {sleep: 2} }

      it "stops waiting and says it timed out" do
        result = read
        expect(result.facts.panes).to be_nil
        expect(result.reasons["panes"]).to eq("timeout")
      end
    end

    it "reads gh and the daemon in parallel" do
      slow = described_class.new(git: git, pull_request_status: pull_request_status, snapshot_client: snapshot_client, review: review,
        ask_store_for: ask_store_for, which: which, daemon_timeout: 1, gh_timeout: 1)
      allow(pull_request_status).to receive(:call) do
        sleep 0.4
        pr_answer
      end
      allow(snapshot_client).to receive(:fetch) do
        sleep 0.4
        snapshot
      end
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      result = slow.read(workspace: "app", checkout: "/src/app", notes_dir: tmpdir, gates: ["pr"])
      expect(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).to be < 0.75
      expect(result.sources).to include("gh" => "ok", "panes" => "ok")
    end

    context "when git takes too long" do
      before { git_answers[:git_delay] = 1 }

      it "leaves git unread" do
        result = read(gates: ["pushed"])
        expect(result.facts.git).to be_nil
        expect(result.reasons["git"]).to eq("not_read")
      end
    end

    it "reads the plan file in the notes directory" do
      File.write(File.join(tmpdir, "IMPLEMENTATION_PLAN.md"), "## Tasks\n\n- [x] T1 a\n- [ ] T2 b\n")
      expect(read.facts.plan).to eq(Workspace::SpineEvaluator::PlanFact.new(exists: true, total: 2, open: 1))
    end
  end
end
