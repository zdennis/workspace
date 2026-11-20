require "spec_helper"

RSpec.describe Workspace::WorkflowGraph do
  let(:catalog) { Workspace::WorkflowCatalog.new(config: Workspace::Config.new) }
  # rpiv-auto-approve and explore-parallel have a fan_out group, which the graph refuses until it draws one.
  let(:presets) { %w[rpiv rpiv-auto-approve-v2 pr-feedback investigate explore bugfix] }

  def graph_of(id)
    described_class.build(catalog.find(id).to_h).to_h
  end

  def edges_of(graph, kind)
    graph["edges"].select { |edge| edge["kind"] == kind }
  end

  def step(id, **rest)
    {"id" => id}.merge(rest.transform_keys(&:to_s))
  end

  def edge_pairs(graph)
    graph["edges"].map { |edge| [edge["from"], edge["to"], edge["kind"]] }
  end

  it "gives nodes, edges and legend in that order" do
    expect(graph_of("rpiv").keys).to eq(%w[nodes edges legend])
  end

  describe "rpiv" do
    let(:graph) { graph_of("rpiv") }

    it "lists the terminals, the steps and the gate in order" do
      expect(graph["nodes"].map { |node| node["id"] }).to eq(%w[.start research plan plan.gate implement verify .end])
      expect(graph["nodes"].map { |node| node["kind"] }).to eq(%w[start step step gate step step end])
    end

    it "walks the forward path with next edges" do
      expect(edges_of(graph, "next").map { |edge| edge.values_at("from", "to") }).to eq(
        [[".start", "research"], %w[research plan], %w[plan plan.gate], %w[plan.gate implement], %w[implement verify], ["verify", ".end"]]
      )
    end

    it "has the verify fail edge and the gate reject edge" do
      expect(edges_of(graph, "fail")).to eq([{"from" => "verify", "to" => "implement", "kind" => "fail", "label" => "max 3"}])
      expect(edges_of(graph, "reject").map { |edge| edge.values_at("from", "to") }).to eq([%w[plan.gate plan]])
    end

    it "annotates a step only with what it sets" do
      verify = graph["nodes"].find { |node| node["id"] == "verify" }
      expect(verify["annotations"]).to include("uses" => ["test-db"], "produces" => ["verify.md"])
      expect(verify["annotations"]).not_to have_key("origin")
    end

    it "tags a step with its origin, but not one the definition wrote itself" do
      tagged = described_class.build(catalog.find("rpiv").to_h, origins: {"plan" => "rpiv", "verify" => "own"}).to_h
      expect(tagged["nodes"].find { |node| node["id"] == "plan" }["annotations"]["origin"]).to eq("rpiv")
      expect(tagged["nodes"].find { |node| node["id"] == "verify" }["annotations"]).not_to have_key("origin")
    end

    it "puts the run limits in the legend" do
      expect(graph["legend"]).to eq("max_attempts" => 14)
    end
  end

  describe "rpiv-auto-approve-v2" do
    let(:graph) { graph_of("rpiv-auto-approve-v2") }

    it "has a review node with its settings and a review_rejected edge" do
      review = graph["nodes"].find { |node| node["id"] == "plan.review" }
      expect(review["kind"]).to eq("review")
      expect(review["annotations"]).to eq("from" => %w[supportive skeptical implementer], "need" => 2, "must" => ["skeptical"], "max_rounds" => 6)
      expect(edges_of(graph, "review_rejected")).to eq([{"from" => "plan.review", "to" => "plan", "kind" => "review_rejected", "label" => "max_rounds 6"}])
      expect(edge_pairs(graph)).to include(["plan", "plan.review", "next"], ["plan.review", "implement", "next"])
    end

    it "puts budget, timeout and max_attempts in the legend" do
      expect(graph["legend"].keys).to include("max_attempts", "timeout", "budget")
    end
  end

  it "labels a fail edge with its except list" do
    on_fail = {"goto" => "plan", "max" => 9, "except" => %w[stale_plan_revision guard check_error]}
    graph = described_class.build({"steps" => [step("plan"), step("plan_review", on_fail: on_fail)]}).to_h
    edge = edges_of(graph, "fail").find { |found| found["from"] == "plan_review" }
    expect(edge["label"]).to eq("max 9, except stale_plan_revision, guard, check_error")
  end

  it "labels a fail edge with its backoff" do
    graph = described_class.build({"steps" => [step("a", on_fail: {"goto" => "a", "max" => 2, "backoff" => 30})]}).to_h
    expect(edges_of(graph, "fail").first["label"]).to eq("max 2, backoff 30s")
  end

  it "prints a whole-number float backoff, as a stored run keeps it, without a decimal" do
    graph = described_class.build({"steps" => [step("a", on_fail: {"goto" => "a", "max" => 2, "backoff" => 120.0})]}).to_h
    expect(edges_of(graph, "fail").first["label"]).to eq("max 2, backoff 120s")
  end

  it "leaves the review_rejected label empty when a stored review has no max_rounds" do
    graph = described_class.build({"steps" => [step("a", review: {"from" => ["x"], "need" => 1})]}).to_h
    expect(edges_of(graph, "review_rejected").first["label"]).to be_nil
  end

  it "leaves out the default fresh context and keeps any other" do
    graph = described_class.build({"steps" => [step("a", context: "fresh"), step("b", context: "continue")]}).to_h
    annotations = graph["nodes"].to_h { |node| [node["id"], node["annotations"]] }
    expect(annotations["a"]).not_to have_key("context")
    expect(annotations["b"]["context"]).to eq("continue")
  end

  it "points every edge at a declared node, with unique node ids, in every shipped preset" do
    presets.each do |id|
      graph = graph_of(id)
      ids = graph["nodes"].map { |node| node["id"] }
      expect(ids.uniq).to eq(ids), id
      graph["edges"].each do |edge|
        expect(ids).to include(edge["from"], edge["to"]), id
      end
    end
  end

  it "keeps steps named start and end apart from the terminals" do
    graph = described_class.build({"steps" => [step("start"), step("end")]}).to_h

    expect(graph["nodes"].map { |node| node["id"] }).to eq([".start", "start", "end", ".end"])
    expect(edge_pairs(graph)).to eq([[".start", "start", "next"], %w[start end next], ["end", ".end", "next"]])
  end

  it "runs a step through its review and gate and fails from the step itself" do
    graph = described_class.build({"steps" => [
      step("a", gate: "approve", review: {"from" => ["x"], "need" => 1, "must" => [], "max_rounds" => 4}, on_fail: {"goto" => "a", "max" => 2}),
      step("b")
    ]}).to_h

    expect(edges_of(graph, "next").map { |edge| edge.values_at("from", "to") }).to eq(
      [[".start", "a"], %w[a a.review], %w[a.review a.gate], %w[a.gate b], ["b", ".end"]]
    )
    expect(edges_of(graph, "fail").map { |edge| edge.values_at("from", "to") }).to eq([%w[a a]])
  end

  it "is a straight line without gates, reviews or on_fail" do
    graph = described_class.build({"steps" => [step("a"), step("b"), step("c")]}).to_h

    expect(graph["edges"].map { |edge| edge["kind"] }.uniq).to eq(["next"])
    expect(graph["nodes"].map { |node| node["kind"] }).to eq(%w[start step step step end])
    expect(graph["legend"]).to eq({})
  end

  it "leaves out a fail edge whose goto is not a step id" do
    graph = described_class.build({"steps" => [step("a", "on_fail" => {"goto" => "gone", "max" => 2}), step("b", "on_fail" => {"goto" => ".end", "max" => 1})]}).to_h

    expect(edges_of(graph, "fail")).to eq([])
    ids = graph["nodes"].map { |node| node["id"] }
    expect(graph["edges"].flat_map { |edge| edge.values_at("from", "to") } - ids).to eq([])
  end

  it "is frozen all the way down" do
    built = described_class.build(catalog.find("rpiv-auto-approve-v2").to_h)

    expect(built).to be_frozen
    expect(built.to_h).to be_frozen
    expect(built.to_h["nodes"].first).to be_frozen
    expect(built.to_h["edges"].first).to be_frozen
    expect(built.to_h["legend"]).to be_frozen
  end

  it "refuses a definition with a fan_out group, which it would draw as steps in a row" do
    definition = {"id" => "demo", "steps" => [step("plan"), step("lint", group: "checks"), step("test", group: "checks"), step("report")]}

    expect { described_class.build(definition) }.to raise_error(Workspace::Error) { |error|
      expect(error.code).to eq("invalid_workflow")
      expect(error.message).to include("can't be graphed", "fan_out group checks (lint, test)", "side by side")
      expect(error.details["groups"]).to eq("checks" => %w[lint test])
    }
  end

  it "draws a definition whose group tags are empty or not text as it always did" do
    definition = {"steps" => [step("a", group: ""), step("b", group: nil)]}
    expect(described_class.build(definition).to_h["nodes"].map { |node| node["id"] }).to eq(%w[.start a b .end])
  end
end
