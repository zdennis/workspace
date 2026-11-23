require "spec_helper"
require "tmpdir"

RSpec.describe Workspace::WorkflowSweep, "unreadable_run alerts" do
  let(:dir) { Dir.mktmpdir }
  let(:last_path) { File.join(dir, ".workflows", "sweep-last.json") }
  let(:bad) { "/state/.workflows/wr_bad.json" }
  let(:unreadable) { [bad] }
  let(:store) { instance_double(Workspace::WorkflowRunStore, going: []) }
  let(:reviews) { instance_double(Workspace::WorkflowReviewSweep, orphan_rows: []) }
  let(:told) { [] }
  let(:alerts) { instance_double(Workspace::WorkflowAlerts) }
  let(:sweep) { described_class.new(store: store, engine: nil, panes: nil, interrupter: ->(*) {}, reviews: reviews, last_path: last_path, alerts: alerts) }

  before do
    allow(store).to receive(:unreadable) { unreadable }
    allow(store).to receive(:run).and_return(instance_double(Workspace::WorkflowRun, workspace: "app", id: "r"))
    allow(sweep).to receive(:sweep_run).and_return(nil)
    allow(alerts).to receive(:unreadable) { |path| (told << path) && true }
  end

  after { FileUtils.remove_entry(dir) }

  it "alerts once per file across two full passes" do
    2.times { sweep.call }

    expect(told).to eq([bad])
  end

  it "alerts once for a file that was already broken when the event is turned on later" do
    allow(alerts).to receive(:unreadable).and_return(false)
    sweep.call
    allow(alerts).to receive(:unreadable) { |path| (told << path) && true }
    2.times { sweep.call }

    expect(told).to eq([bad])
  end

  it "does not alert again from a fresh sweep that reads the set a previous one wrote" do
    sweep.call
    fresh = described_class.new(store: store, engine: nil, panes: nil, interrupter: ->(*) {}, reviews: reviews, last_path: last_path, alerts: alerts)
    allow(fresh).to receive(:sweep_run).and_return(nil)
    fresh.call

    expect(told).to eq([bad])
  end

  it "alerts once and does not raise when sweep-last.json is corrupt" do
    FileUtils.mkdir_p(File.dirname(last_path))
    File.write(last_path, "{not json")

    expect { 2.times { sweep.call } }.not_to raise_error
    expect(told).to eq([bad])
  end

  it "alerts for nothing on a dry run" do
    sweep.call(dry_run: true)

    expect(told).to be_empty
  end

  it "alerts for nothing on a run or workspace pass, and a filtered pass leaves the set alone" do
    sweep.call(workspace: "app")
    sweep.call(run: "r")
    expect(told).to be_empty

    sweep.call
    sweep.call(workspace: "app")
    sweep.call

    expect(told).to eq([bad])
  end

  it "alerts again once the file was fixed and is broken again" do
    sweep.call
    allow(store).to receive(:unreadable).and_return([])
    sweep.call
    allow(store).to receive(:unreadable).and_return([bad])
    sweep.call

    expect(told).to eq([bad, bad])
  end

  it "sends nothing without alerts: wired" do
    plain = described_class.new(store: store, engine: nil, panes: nil, interrupter: ->(*) {}, reviews: reviews, last_path: last_path)
    allow(plain).to receive(:sweep_run).and_return(nil)

    expect { plain.call }.not_to raise_error
    expect(told).to be_empty
  end
end
