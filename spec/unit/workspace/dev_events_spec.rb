require "spec_helper"
require "tmpdir"

RSpec.describe Workspace::DevEvents do
  let(:recorded) { [] }
  let(:event_log) do
    events = recorded
    Object.new.tap { |log| log.define_singleton_method(:record) { |type:, project:, data: {}| events << [type, project, data] } }
  end
  let(:lineage) { instance_double(Workspace::WorkspaceLineage) }
  let(:tmpdir) { Dir.mktmpdir("ws-dev-events") }
  let(:events) { described_class.new(event_log: event_log, lineage: lineage) }

  after { FileUtils.remove_entry(tmpdir) }

  def resolves(name:, worktree: nil)
    allow(lineage).to receive(:resolve).with(cwd: tmpdir)
      .and_return(Workspace::WorkspaceLineage::Lineage.new(name: name, worktree: worktree))
  end

  it "writes dev_started under the project with the workspace and lock" do
    events.started(project: "app", workspace: "app.worktree-login")

    expect(recorded).to eq([["dev_started", "app", {"workspace" => "app.worktree-login", "lock" => "devenv"}]])
  end

  it "writes dev_stopped with its reason" do
    events.stopped(project: "app", workspace: "app", reason: "down")

    expect(recorded).to eq([["dev_stopped", "app", {"workspace" => "app", "lock" => "devenv", "reason" => "down"}]])
  end

  describe "#holder_stopped" do
    it "names the project and the worktree's own workspace from the holder's worktree" do
      resolves(name: "app", worktree: "app.worktree-login")

      events.holder_stopped({"worktree" => tmpdir}, reason: "forced")

      expect(recorded).to eq([["dev_stopped", "app", {"workspace" => "app.worktree-login", "lock" => "devenv", "reason" => "forced"}]])
    end

    it "uses the project's name as the workspace for a main checkout" do
      resolves(name: "app")

      events.holder_stopped({"worktree" => tmpdir}, reason: "down")

      expect(recorded.first[2]).to include("workspace" => "app")
    end

    it "writes nothing for no holder, no worktree, or a worktree that is gone" do
      events.holder_stopped(nil, reason: "down")
      events.holder_stopped({}, reason: "down")
      events.holder_stopped({"worktree" => File.join(tmpdir, "gone")}, reason: "down")

      expect(recorded).to be_empty
    end

    it "writes nothing when the lineage cannot be read" do
      allow(lineage).to receive(:resolve).and_raise(Workspace::Error, "no git")

      events.holder_stopped({"worktree" => tmpdir}, reason: "down")

      expect(recorded).to be_empty
    end
  end

  describe "#reaped" do
    before { resolves(name: "app") }

    it "writes reason reaped for a dead dev wrapper" do
      events.reaped("devenv", {"kind" => "process", "worktree" => tmpdir})

      expect(recorded.map { |type, _, data| [type, data["reason"]] }).to eq([["dev_stopped", "reaped"]])
    end

    it "ignores other locks and holders that are not a wrapper" do
      events.reaped("edit", {"kind" => "process", "worktree" => tmpdir})
      events.reaped("devenv", {"kind" => "run", "worktree" => tmpdir})
      events.reaped("devenv", {"kind" => "agent", "worktree" => tmpdir})

      expect(recorded).to be_empty
    end
  end
end
