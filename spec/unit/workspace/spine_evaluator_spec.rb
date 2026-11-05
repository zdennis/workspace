require "spec_helper"
require "tmpdir"

# Ported from workspace-ui's src/core/spine/model.test.ts, case for case, in the reply's shape:
# `gate_results` with reason codes, snake_case dispute kinds, `owner_state` in place of overlays.
RSpec.describe Workspace::SpineEvaluator do
  def stage(path, status: "not_started", gates: [], depends_on: [], owner: nil, done_when: nil, children: [], number: 10, check: nil, checked_by: nil)
    id = path.split("/").last
    text = +"---\n"
    text << "status: #{status}\n" unless status == "unknown"
    text << "owner: \"#{owner}\"\n" if owner
    text << "check: #{check}\n" if check
    text << "checked_by: #{checked_by}\n" if checked_by
    text << "---\n"
    if done_when
      done, total = done_when
      text << "\n## Done when\n\n"
      total.times { |i| text << "- [#{(i < done) ? "x" : " "}] item #{i}\n" }
    end
    Workspace::SpineTree::Stage.new(
      path: path, id: id, number: number, level: path.count("/") + 1,
      file: Workspace::SpineFile.parse(text, relative: "#{number}-#{id}.md"), relative: "#{number}-#{id}.md",
      children: children, warnings: [], kind: "custom", depends_on: depends_on, gates: gates
    )
  end

  def child(id, status, number = 10) = stage("parent/#{id}", status: status, number: number)

  def evaluate(stages, facts = Workspace::SpineEvaluator::Facts.new) = described_class.evaluate_stages(stages, facts)

  def one(stage, facts = Workspace::SpineEvaluator::Facts.new) = evaluate([stage], facts).first

  def facts(**over) = Workspace::SpineEvaluator::Facts.new(**over)

  def pr(state, checks, **counts) = Workspace::SpineEvaluator::PrFact.new(state: state, checks: checks, **counts)

  def result(gate, facts, done_when: nil)
    one(stage("v", gates: [gate], done_when: done_when), facts)["gate_results"].first
  end

  describe "roll-up" do
    [
      ["all completed", %w[completed completed], "completed"],
      ["completed and skipped", %w[completed skipped], "completed"],
      ["any blocked wins", %w[completed blocked in_progress], "blocked"],
      ["any in progress", %w[not_started in_progress], "in_progress"],
      ["completed and not started", %w[completed not_started], "in_progress"],
      ["none started", %w[not_started not_started], "not_started"],
      ["unknown counts as not started", %w[unknown not_started], "not_started"],
      ["unknown beside completed", %w[unknown completed], "in_progress"],
      ["all skipped", %w[skipped skipped], "skipped"],
      ["no children", [], nil]
    ].each do |name, statuses, expected|
      it name do
        parent = one(stage("parent", status: "unknown", children: statuses.each_with_index.map { |s, i| child("c#{i}", s, i) }))
        expect(parent.dig("rollup", "status")).to eq(expected)
      end
    end

    it "counts completed of the children that aren't skipped" do
      parent = one(stage("parent", status: "in_progress", children: [child("a", "completed"), child("b", "skipped"), child("c", "in_progress"), child("d", "not_started")]))
      expect(parent["rollup"].slice("status", "done", "total")).to eq("status" => "in_progress", "done" => 1, "total" => 3)
    end

    it "counts a disputed child as open and in progress" do
      parent = one(stage("parent", status: "completed", children: [
        stage("parent/a", status: "completed", gates: ["checklist"], done_when: [1, 2]),
        child("b", "completed")
      ]))
      expect(parent["children"][0]["state"]).to eq("disputed")
      expect(parent["rollup"].slice("status", "done", "total")).to eq("status" => "in_progress", "done" => 1, "total" => 2)
      expect(parent["rollup"]["counts"]).to include("disputed" => 1, "completed" => 1)
      expect(parent["state"]).to eq("disputed")
      expect(parent["disputes"]).to eq([{"kind" => "sub_stages", "open" => 1, "total" => 2, "message" => "Marked completed, but 1 of 2 sub-stages are open"}])
    end

    it "rolls up a list of evaluated children through SpineRollup" do
      kids = evaluate([child("a", "blocked"), child("b", "completed")])
      expect(Workspace::SpineRollup.call(kids.map { |k| k["state"] }).slice("status", "done", "total"))
        .to eq("status" => "blocked", "done" => 1, "total" => 2)
    end

    it "has no rollup key without children" do
      expect(one(stage("verify"))).not_to have_key("rollup")
    end
  end

  describe ".gate_result" do
    [
      ["plan unread", Workspace::SpineEvaluator::Facts.new, "unchecked", "not_read"],
      ["plan done", {plan: Workspace::SpineEvaluator::PlanFact.new(exists: true, total: 3, open: 0)}, "pass", "plan_done"],
      ["plan open tasks", {plan: Workspace::SpineEvaluator::PlanFact.new(exists: true, total: 3, open: 1)}, "fail", "tasks_open"],
      ["plan without tasks", {plan: Workspace::SpineEvaluator::PlanFact.new(exists: true, total: 0, open: 0)}, "fail", "no_tasks"],
      ["no plan file", {plan: Workspace::SpineEvaluator::PlanFact.new(exists: false, total: 0, open: 0)}, "fail", "no_plan"]
    ].each do |name, over, expected, reason|
      it "plan: #{name}" do
        f = over.is_a?(Hash) ? facts(**over) : over
        expect(result("plan", f).values_at("result", "reason")).to eq([expected, reason])
      end
    end

    [
      ["all ticked", [2, 2], "pass", "all_ticked", "2 of 2 ticked"],
      ["one unticked", [1, 2], "fail", "unticked", "1 of 2 ticked"],
      ["empty list fails under the gate", [0, 0], "fail", "no_criteria", "No Done when items"],
      ["no Done when heading fails under the gate", nil, "fail", "no_criteria", "No Done when items"]
    ].each do |name, done_when, expected, reason, message|
      it "checklist: #{name}" do
        expect(result("checklist", Workspace::SpineEvaluator::Facts.new, done_when: done_when).values_at("result", "reason", "message")).to eq([expected, reason, message])
      end
    end

    [
      ["unread", nil, "unchecked", "not_read"],
      ["pushed", Workspace::SpineEvaluator::GitFact.new(upstream: true, ahead: 0), "pass", "pushed"],
      ["ahead", Workspace::SpineEvaluator::GitFact.new(upstream: true, ahead: 2), "fail", "ahead"],
      ["no upstream", Workspace::SpineEvaluator::GitFact.new(upstream: false, ahead: 0), "fail", "no_upstream"]
    ].each do |name, git, expected, reason|
      it "pushed: #{name}" do
        expect(result("pushed", facts(git: git)).values_at("result", "reason")).to eq([expected, reason])
      end
    end

    it "pushed passes once the PR is merged, even with the remote branch gone" do
      expect(result("pushed", facts(git: Workspace::SpineEvaluator::GitFact.new(upstream: false, ahead: 0), pr: pr("merged", "pass")))["result"]).to eq("pass")
      expect(result("pushed", facts(pr: pr("merged", "none"))).values_at("result", "reason")).to eq(%w[pass merged])
    end

    it "pushed counts one commit in the singular" do
      expect(result("pushed", facts(git: Workspace::SpineEvaluator::GitFact.new(upstream: true, ahead: 1)))["message"]).to eq("1 commit not pushed")
    end

    [
      # name, pr, pr gate, ci gate, merged gate
      ["no gh", nil, %w[unchecked not_read], %w[unchecked not_read], %w[unchecked not_read]],
      ["no PR yet", %w[none none], %w[fail no_pr], %w[unchecked no_pr], %w[fail no_pr]],
      ["open, passing", %w[open pass], %w[pass pr_open], %w[pass checks_passing], %w[fail pr_open]],
      ["open, failing", %w[open fail], %w[pass pr_open], %w[fail checks_failing], %w[fail pr_open]],
      ["open, running", %w[open pending], %w[pass pr_open], %w[pending checks_pending], %w[fail pr_open]],
      ["open, no checks", %w[open none], %w[pass pr_open], %w[unchecked no_checks], %w[fail pr_open]],
      ["merged", %w[merged pass], %w[pass pr_merged], %w[pass checks_passing], %w[pass pr_merged]],
      ["closed", %w[closed pass], %w[fail pr_closed], %w[pass checks_passing], %w[fail pr_closed]]
    ].each do |name, state_checks, pr_gate, ci_gate, merged_gate|
      it "pr, ci, merged: #{name}" do
        f = facts(pr: state_checks && pr(*state_checks))
        expect(result("pr", f).values_at("result", "reason")).to eq(pr_gate)
        expect(result("ci", f).values_at("result", "reason")).to eq(ci_gate)
        expect(result("merged", f).values_at("result", "reason")).to eq(merged_gate)
      end
    end

    it "ci words a failure with the check counts when known" do
      expect(result("ci", facts(pr: pr("open", "fail", failing: 1, total: 6)))["message"]).to eq("1 of 6 checks failing")
      expect(result("ci", facts(pr: pr("open", "fail")))["message"]).to eq("Checks failing")
    end

    [
      ["unread", nil, %w[unchecked not_read]],
      ["agent done, no changes asked", [true, false], %w[pass review_done]],
      ["agent still running", [false, false], %w[fail review_running]],
      ["changes requested", [true, true], %w[fail changes_requested]]
    ].each do |name, review, expected|
      it "review: #{name}" do
        f = facts(review: review && Workspace::SpineEvaluator::ReviewFact.new(agent_done: review[0], changes_requested: review[1]))
        expect(result("review", f).values_at("result", "reason")).to eq(expected)
      end
    end

    it "is the reply's shape" do
      expect(described_class.gate_result("checklist", {"done" => 3, "total" => 3}, Workspace::SpineEvaluator::Facts.new))
        .to eq("gate" => "checklist", "result" => "pass", "reason" => "all_ticked", "message" => "3 of 3 ticked")
    end

    it "words an unchecked gate by its name" do
      expect(result("ci", Workspace::SpineEvaluator::Facts.new)["message"]).to eq("CI wasn't checked")
    end
  end

  describe "the done rule" do
    let(:ci_failing) { facts(pr: pr("open", "fail", failing: 1, total: 6)) }
    let(:ci_passing) { facts(pr: pr("open", "pass")) }

    it "skipped is skipped whatever the evidence" do
      s = one(stage("verify", status: "skipped", gates: ["ci"], done_when: [0, 3]), ci_failing)
      expect(s["state"]).to eq("skipped")
      expect(s["disputes"]).to eq([])
    end

    it "completed with passing gates, ticked list, no open sub-stages is completed" do
      s = one(stage("verify", status: "completed", gates: %w[checklist ci], done_when: [3, 3]), ci_passing)
      expect(s["state"]).to eq("completed")
      expect(s["gate_results"].map { |g| g.values_at("gate", "result") }).to eq([%w[checklist pass], %w[ci pass]])
    end

    it "completed with no Done when list and no gates is completed" do
      expect(one(stage("plan", status: "completed"))["state"]).to eq("completed")
    end

    it "a failing gate disputes a completed claim, naming the gate" do
      s = one(stage("verify", status: "completed", gates: ["ci"]), ci_failing)
      expect(s["state"]).to eq("disputed")
      expect(s["status"]).to eq("completed")
      expect(s["disputes"]).to eq([{"kind" => "gate", "gate" => "ci", "message" => "Marked completed, but CI is failing"}])
    end

    it "unticked criteria dispute a completed claim without a checklist gate" do
      s = one(stage("verify", status: "completed", done_when: [1, 3]))
      expect(s["state"]).to eq("disputed")
      expect(s["disputes"]).to eq([{"kind" => "done_when", "done" => 1, "total" => 3, "message" => "Marked completed, but 1 of 3 Done when items are ticked"}])
    end

    it "an unticked checklist gate disputes once, as done_when" do
      s = one(stage("verify", status: "completed", gates: ["checklist"], done_when: [1, 3]))
      expect(s["disputes"].map { |d| d["kind"] }).to eq(["done_when"])
      expect(s["gate_results"].first["result"]).to eq("fail")
    end

    it "an empty list under a checklist gate disputes as the gate" do
      s = one(stage("verify", status: "completed", gates: ["checklist"]))
      expect(s["disputes"]).to eq([{"kind" => "gate", "gate" => "checklist", "message" => "Marked completed, but there are no Done when items"}])
    end

    it "gives every reason, gates first" do
      s = one(stage("parent", status: "completed", gates: ["ci"], done_when: [0, 1], children: [child("a", "in_progress")]), ci_failing)
      expect(s["disputes"].map { |d| d.except("message") }).to eq([
        {"kind" => "gate", "gate" => "ci"},
        {"kind" => "done_when", "done" => 0, "total" => 1},
        {"kind" => "sub_stages", "open" => 1, "total" => 1}
      ])
    end

    [
      ["not checked", Workspace::SpineEvaluator::Facts.new],
      ["pending", Workspace::SpineEvaluator::Facts.new(pr: Workspace::SpineEvaluator::PrFact.new(state: "open", checks: "pending"))]
    ].each do |name, f|
      it "a gate that is #{name} never disputes" do
        s = one(stage("verify", status: "completed", gates: ["ci"]), f)
        expect(s["state"]).to eq("completed")
        expect(s["disputes"]).to eq([])
      end
    end

    it "words each failing gate's dispute" do
      f = facts(plan: Workspace::SpineEvaluator::PlanFact.new(exists: false, total: 0, open: 0), git: Workspace::SpineEvaluator::GitFact.new(upstream: true, ahead: 2),
        pr: pr("closed", "fail"), review: Workspace::SpineEvaluator::ReviewFact.new(agent_done: false, changes_requested: false))
      s = one(stage("ship", status: "completed", gates: %w[plan pushed pr ci merged review]), f)
      expect(s["disputes"].map { |d| d["message"] }).to eq([
        "Marked completed, but there is no plan file",
        "Marked completed, but the branch has unpushed commits",
        "Marked completed, but the pull request was closed",
        "Marked completed, but CI is failing",
        "Marked completed, but the pull request was closed",
        "Marked completed, but the review agent hasn't finished"
      ])
    end

    [
      ["plan", {plan: [true, 0, 0]}, "no_tasks", "the plan has no tasks"],
      ["plan", {plan: [true, 3, 1]}, "tasks_open", "the plan has open tasks"],
      ["pushed", {git: [false, 0]}, "no_upstream", "the branch was never pushed"],
      ["pr", {pr: %w[none none]}, "no_pr", "there is no pull request"],
      ["merged", {pr: %w[open pass]}, "pr_open", "the pull request is not merged"],
      ["review", {review: [true, true]}, "changes_requested", "changes were requested on the pull request"]
    ].each do |gate, over, reason, words|
      it "words a #{reason} dispute" do
        f = facts(
          plan: over[:plan] && Workspace::SpineEvaluator::PlanFact.new(exists: over[:plan][0], total: over[:plan][1], open: over[:plan][2]),
          git: over[:git] && Workspace::SpineEvaluator::GitFact.new(upstream: over[:git][0], ahead: over[:git][1]),
          pr: over[:pr] && pr(*over[:pr]),
          review: over[:review] && Workspace::SpineEvaluator::ReviewFact.new(agent_done: over[:review][0], changes_requested: over[:review][1])
        )
        s = one(stage("ship", status: "completed", gates: [gate]), f)
        expect(s["gate_results"].first.values_at("result", "reason")).to eq(["fail", reason])
        expect(s["disputes"].map { |d| d["message"] }).to eq(["Marked completed, but #{words}"])
      end
    end

    %w[not_started in_progress].each do |status|
      it "#{status} with all evidence met looks completed and does not advance" do
        s = one(stage("verify", status: status, gates: ["ci"], done_when: [2, 2]), ci_passing)
        expect(s["state"]).to eq(status)
        expect(s["looks_completed"]).to be(true)
      end
    end

    it "does not look completed with no evidence at all" do
      expect(one(stage("verify", status: "in_progress"))["looks_completed"]).to be(false)
      expect(one(stage("verify", status: "in_progress", done_when: [0, 0]))["looks_completed"]).to be(false)
    end

    it "does not look completed while a gate is not checked or pending" do
      pending_ci = facts(pr: pr("open", "pending"))
      expect(one(stage("verify", status: "in_progress", gates: ["ci"], done_when: [2, 2]), pending_ci)["looks_completed"]).to be(false)
      expect(one(stage("verify", status: "in_progress", gates: ["ci"], done_when: [2, 2]))["looks_completed"]).to be(false)
    end

    it "blocked and unknown never look completed" do
      %w[blocked unknown].each do |status|
        s = one(stage("v", status: status, done_when: [1, 1]))
        expect(s["looks_completed"]).to be(false)
        expect(s["state"]).to eq(status)
      end
    end
  end

  describe "parents" do
    def parent(status, kids) = one(stage("parent", status: status, children: kids.each_with_index.map { |s, i| child("c#{i}", s, i) }))

    it "without a status shows the roll-up, labelled from sub-stages" do
      s = parent("unknown", %w[completed in_progress])
      expect(s.values_at("state", "from_sub_stages", "status")).to eq(["in_progress", true, "unknown"])
    end

    it "without a status and every child done reads completed from sub-stages" do
      s = parent("unknown", %w[completed skipped])
      expect(s.values_at("state", "from_sub_stages")).to eq(["completed", true])
    end

    it "agreeing with its children is shown plainly" do
      s = parent("in_progress", %w[completed in_progress])
      expect(s.values_at("state", "from_sub_stages", "disputes")).to eq(["in_progress", false, []])
    end

    it "completed with open children is disputed with the count" do
      s = parent("completed", %w[completed completed completed in_progress not_started])
      expect(s["state"]).to eq("disputed")
      expect(s["disputes"].map { |d| d.except("message") }).to eq([{"kind" => "sub_stages", "open" => 2, "total" => 5}])
    end

    it "not started with every child done looks completed" do
      s = parent("not_started", %w[completed skipped])
      expect(s["state"]).to eq("not_started")
      expect(s["looks_completed"]).to be(true)
    end

    it "blocked stays blocked whatever the children say" do
      s = parent("blocked", %w[completed completed])
      expect(s["state"]).to eq("blocked")
      expect(s["looks_completed"]).to be(false)
    end

    it "skipped dims its children and still reports their roll-up" do
      s = parent("skipped", %w[in_progress blocked])
      expect(s["state"]).to eq("skipped")
      expect(s["rollup"]["status"]).to eq("blocked")
      expect(s["dimmed"]).to be(false)
      expect(s["children"].map { |c| c["dimmed"] }).to eq([true, true])
    end

    it "dims grandchildren under a skipped parent" do
      s = one(stage("a", status: "skipped", children: [stage("a/b", status: "unknown", children: [stage("a/b/c")])]))
      expect(s["children"][0]["children"][0]["dimmed"]).to be(true)
    end

    it "names its own current child, or nil" do
      s = parent("in_progress", %w[completed skipped not_started in_progress])
      expect(s["current"]).to eq("parent/c2")
      expect(parent("completed", %w[completed skipped])["current"]).to be_nil
      expect(one(stage("leaf"))["current"]).to be_nil
    end
  end

  describe "waits_on" do
    it "waits on siblings that are not completed or skipped" do
      stages = evaluate([
        stage("research", status: "completed", number: 10),
        stage("plan", status: "skipped", number: 20),
        stage("implement", status: "in_progress", number: 30),
        stage("verify", number: 40, depends_on: %w[research plan implement])
      ])
      expect(stages[3]["waits_on"]).to eq(["implement"])
      expect(stages[0]["waits_on"]).to eq([])
    end

    it "a disputed sibling is not met" do
      stages = evaluate([stage("verify", status: "completed", done_when: [0, 1]), stage("review", depends_on: ["verify"])])
      expect(stages[1]["waits_on"]).to eq(["verify"])
    end

    it "resolves a duplicate id to the first stage with it" do
      stages = evaluate([
        stage("implement", status: "completed", number: 30),
        stage("implement", status: "not_started", number: 31),
        stage("verify", number: 40, depends_on: ["implement"])
      ])
      expect(stages[2]["waits_on"]).to eq([])
    end

    it "a sibling without a status is met when its sub-stages are all done" do
      stages = evaluate([stage("implement", status: "unknown", children: [child("a", "completed")]), stage("verify", depends_on: ["implement"])])
      expect(stages[1]["waits_on"]).to eq([])
    end

    it "ignores an id that isn't a sibling" do
      expect(evaluate([stage("verify", depends_on: ["qa"])])[0]["waits_on"]).to eq([])
    end

    it "looks only among siblings in a sub-stage folder" do
      s = one(stage("implement", status: "in_progress", children: [
        stage("implement/api", status: "in_progress", number: 10),
        stage("implement/docs", number: 20, depends_on: ["api"])
      ]))
      expect(s["children"][1]["waits_on"]).to eq(["api"])
    end
  end

  describe ".current" do
    it "is the first by order not completed or skipped" do
      stages = evaluate([stage("research", status: "completed"), stage("plan", status: "skipped"), stage("implement"), stage("verify", status: "in_progress")])
      expect(described_class.current(stages)).to eq("implement")
    end

    [
      ["disputed", {status: "completed", done_when: [0, 1]}],
      ["unknown", {status: "unknown"}]
    ].each do |name, opts|
      it "counts a #{name} stage as not done" do
        expect(described_class.current(evaluate([stage("research", status: "completed"), stage("verify", **opts)]))).to eq("verify")
      end
    end

    it "is nil when every stage is done, or there are none" do
      expect(described_class.current(evaluate([stage("a", status: "completed"), stage("b", status: "skipped")]))).to be_nil
      expect(described_class.current([])).to be_nil
    end

    it "an unknown parent whose children are all done is not current" do
      stages = evaluate([stage("implement", status: "unknown", children: [child("a", "completed")]), stage("verify")])
      expect(described_class.current(stages)).to eq("verify")
    end
  end

  describe "owner_state" do
    def panes(*list) = facts(panes: list.map { |p| Workspace::SpineEvaluator::Pane.new(waiting: false, working: false, since: nil, **p) })

    [
      ["a pane with a question or waiting prompt is waiting", {pane: "%6", waiting: true, working: true}, "waiting", nil],
      ["a working pane gives since when", {pane: "%6", working: true, since: "2026-10-18T10:00:00Z"}, "working", "2026-10-18T10:00:00Z"],
      ["a pane at rest is idle", {pane: "%6"}, "idle", nil],
      ["a pane not among the panes is gone", {pane: "%7"}, "gone", nil]
    ].each do |name, pane, state, since|
      it name do
        s = one(stage("implement", status: "in_progress", owner: "%6"), panes(pane))
        expect(s.values_at("owner_state", "owner_since")).to eq([state, since])
      end
    end

    it "is unknown while the panes are not read" do
      expect(one(stage("implement", status: "in_progress", owner: "%6"))["owner_state"]).to eq("unknown")
    end

    it "is null for an owner that isn't a pane id" do
      ["you", "claude", "%", "%6x", ""].each do |owner|
        expect(one(stage("s", status: "in_progress", owner: owner), panes)["owner_state"]).to be_nil
      end
      expect(one(stage("s", status: "in_progress"), panes)["owner_state"]).to be_nil
    end

    # model.ts draws no overlay on these; the reply makes owner_state a fact on every stage and leaves
    # the overlay choice to the app.
    it "is reported on done, not started, blocked, disputed and dimmed stages alike" do
      f = panes({pane: "%6", working: true})
      expect(one(stage("r", status: "completed", owner: "%6"), f)["owner_state"]).to eq("working")
      expect(one(stage("r", status: "completed", owner: "%6", done_when: [0, 1]), f)["owner_state"]).to eq("working")
      expect(one(stage("p", status: "not_started", owner: "%7"), f)["owner_state"]).to eq("gone")
      expect(one(stage("p", status: "blocked", owner: "%7"), f)["owner_state"]).to eq("gone")
      expect(one(stage("p", status: "skipped", owner: "%6"), f)["owner_state"]).to eq("working")
      dimmed = one(stage("a", status: "skipped", children: [stage("a/b", status: "in_progress", owner: "%6")]), f)
      expect(dimmed["children"][0]["owner_state"]).to eq("working")
    end
  end

  describe ".evaluate_stages" do
    it "keeps file order and the stage's own keys" do
      stages = evaluate([stage("b", number: 20), stage("a", number: 10)])
      expect(stages.map { |s| s["path"] }).to eq(%w[b a])
      expect(stages[0]).to include("file" => "20-b.md", "status" => "not_started", "gates" => [], "depends_on" => [])
    end

    it "gate results follow the file's gate order" do
      expect(one(stage("ship", gates: %w[merged pushed]))["gate_results"].map { |g| g["gate"] }).to eq(%w[merged pushed])
    end

    it "adds every evaluation key" do
      expect(one(stage("verify")).keys).to include("state", "from_sub_stages", "looks_completed", "gate_results",
        "disputes", "waits_on", "owner_state", "owner_since", "dimmed", "current", "children")
    end
  end

  describe ".call" do
    around do |example|
      Dir.mktmpdir("spine-eval") do |dir|
        @notes = dir
        example.run
      end
    end

    def write(relative, text)
      path = File.join(@notes, "spine", relative)
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, text)
    end

    it "evaluates a tree read from disk, with the top-level current" do
      write("goal.md", "---\ntitle: Ship it\n---\n")
      write("10-research.md", "---\nstatus: completed\n---\n")
      write("20-implement/10-api.md", "---\nstatus: completed\n---\n")
      write("30-verify.md", "---\nstatus: completed\ngates: [ci]\ndepends_on: [implement]\n---\n")
      write("40-ship.md", "---\nstatus: not_started\ndepends_on: [verify]\n---\n")
      doc = described_class.call(Workspace::SpineTree.read(@notes), facts(pr: pr("open", "fail")))

      expect(doc).to include("exists" => true, "evaluated" => true, "current" => "verify")
      expect(doc["goal"]["title"]).to eq("Ship it")
      implement, verify, ship = doc["stages"].drop(1)
      expect(implement.values_at("state", "from_sub_stages")).to eq(["completed", true])
      expect(verify.values_at("state", "waits_on")).to eq(["disputed", []])
      expect(ship["waits_on"]).to eq(["verify"])
    end

    it "is current nil for a missing spine" do
      expect(described_class.call(Workspace::SpineTree.read(@notes))).to include("exists" => false, "stages" => [], "current" => nil)
    end
  end

  describe "checks" do
    def pane(id, working: false, waiting: false) = Workspace::SpineEvaluator::Pane.new(pane: id, waiting: waiting, working: working, since: nil)

    it "reads a completed claim awaiting its check as checking, and a failed one as check_failed" do
      states = %w[required pending passed failed].map { |check| one(stage("a", status: "completed", check: check))["state"] }
      expect(states).to eq(%w[checking checking completed check_failed])
    end

    it "leaves a stage that is not completed, and a stage without a check, as it was" do
      expect(one(stage("a", status: "in_progress", check: "required"))["state"]).to eq("in_progress")
      expect(one(stage("a", status: "completed"))["state"]).to eq("completed")
    end

    it "lets a dispute outrank the check state" do
      doc = one(stage("a", status: "completed", check: "pending", done_when: [1, 2]))
      expect(doc["state"]).to eq("disputed")
      expect(doc["check"]).to eq("pending")
    end

    it "holds a checking stage as the current one and its dependents waiting" do
      docs = evaluate([stage("a", status: "completed", check: "pending"), stage("b", depends_on: ["a"], number: 20)])
      expect(docs[1]["waits_on"]).to eq(["a"])
      expect(described_class.current(docs)).to eq("a")

      passed = evaluate([stage("a", status: "completed", check: "passed"), stage("b", depends_on: ["a"], number: 20)])
      expect(passed[1]["waits_on"]).to eq([])
      expect(described_class.current(passed)).to eq("b")
    end

    it "counts checking and check_failed children in the roll-up, never as done" do
      parent = one(stage("parent", status: "unknown", children: [child("a", "completed"), stage("parent/b", status: "completed", check: "pending", number: 20), stage("parent/c", status: "completed", check: "failed", number: 30)]))
      expect(parent["rollup"]).to include("status" => "in_progress", "done" => 1, "total" => 3)
      expect(parent["rollup"]["counts"]).to include("completed" => 1, "checking" => 1, "check_failed" => 1)
      expect(parent["state"]).to eq("in_progress")
    end

    it "does not roll a parent up to completed while its only open child is checking" do
      parent = one(stage("parent", status: "unknown", children: [stage("parent/a", status: "completed", check: "pending")]))
      expect(parent["rollup"]["status"]).to eq("in_progress")
    end

    it "holds a completed parent back with a sub_stages dispute while a child is checking" do
      parent = one(stage("parent", status: "completed", children: [stage("parent/a", status: "completed", check: "pending")]))
      expect(parent["disputes"].map { |d| d["kind"] }).to eq(["sub_stages"])
    end

    it "reports the checker from checked_by: a pane id found in the label, else the label, with its pane state" do
      panes = [pane("%27", working: true), pane("%28")]
      doc = one(stage("a", status: "completed", check: "failed", checked_by: "claude %27"), facts(panes: panes))
      expect(doc.values_at("checker", "checker_state")).to eq(["%27", "working"])

      expect(one(stage("a", status: "completed", check: "failed", checked_by: "claude %29"), facts(panes: panes)).values_at("checker", "checker_state")).to eq(["%29", "gone"])
      expect(one(stage("a", status: "completed", check: "failed", checked_by: "claude %27"), facts(panes: nil))["checker_state"]).to eq("unknown")
      expect(one(stage("a", status: "completed", check: "passed", checked_by: "person"), facts(panes: panes)).values_at("checker", "checker_state")).to eq(["person", nil])
      expect(one(stage("a", status: "completed", check: "pending"), facts(panes: panes)).values_at("checker", "checker_state")).to eq([nil, nil])
    end
  end
end
