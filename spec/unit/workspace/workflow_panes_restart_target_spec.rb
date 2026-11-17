require "spec_helper"

RSpec.describe Workspace::WorkflowPanes, "#restart_target" do
  let(:config) { instance_double(Workspace::Config, agent_running?: true) }
  let(:bindings) { instance_double(Workspace::PaneBindings, binding_for: nil, pane_for: "%5", stale?: false) }
  let(:tmux) { instance_double(Workspace::Tmux, session_name_for_pane: "app", pane_slot: "app:0.1", server_pid_for_pane: "1") }
  let(:snapshot_client) { instance_double(Workspace::AgentSnapshotClient) }
  let(:ensured) { [] }
  let(:agent_ensurer) do
    lambda do |name:|
      ensured << name
      Workspace::Commands::EnsureAgent::Result.new(:running)
    end
  end
  let(:now) { Time.utc(2026, 10, 4, 12, 0, 30) }
  let(:rows) { [] }
  subject(:panes) do
    described_class.new(config: config, bindings: bindings, tmux: tmux, locator: nil, binder: nil,
      snapshot_client: snapshot_client, agent_ensurer: agent_ensurer, clock: -> { now })
  end

  let(:idle) { {"kind" => "claude", "state" => "idle"} }
  let(:working) { {"kind" => "claude", "state" => "working"} }

  def row(pane, base) = base.merge("pane_id" => pane)

  def target(**options) = panes.restart_target("app", "wr_1", bound: "%5", **options)

  def error_of
    target_error = nil
    begin
      yield
    rescue Workspace::Error => e
      target_error = e
    end
    target_error
  end

  before do
    allow(snapshot_client).to receive(:fetch) { {"panes" => rows} }
    allow(bindings).to receive(:binding_for).with("%5").and_return({"kind" => "run", "id" => "wr_1", "role" => "author"})
  end

  describe "the bound pane's fact" do
    it "is idle when its turn is over" do
      rows << row("%5", idle)
      expect(target).to eq("pane" => "%5", "bound" => "idle")
    end

    it "is idle when the turn ended long enough ago to count as done" do
      rows << row("%5", "kind" => "claude", "state" => "done", "state_since" => (now - 60).iso8601)
      expect(target["bound"]).to eq("idle")
    end

    it "is busy otherwise, and the bound pane is still the target" do
      rows << row("%5", working)
      expect(target).to eq("pane" => "%5", "bound" => "busy")
    end

    it "is failed when the turn failed" do
      rows << row("%5", "kind" => "claude", "state" => "idle", "turn_failed" => true)
      expect(target).to eq("pane" => "%5", "bound" => "failed")
    end

    it "is shell when the row is a shell, even one whose turn failed" do
      rows << row("%5", "kind" => "shell", "turn_failed" => true)
      rows << row("%6", idle)
      expect(target).to eq("pane" => "%6", "bound" => "shell")
    end

    it "is gone when the snapshot does not list the pane" do
      rows << row("%6", idle)
      expect(target).to eq("pane" => "%6", "bound" => "gone")
    end

    it "is gone when the binding is dead" do
      allow(bindings).to receive(:stale?).and_return(true)
      allow(bindings).to receive(:binding_for).with("%5").and_return({"kind" => "run", "id" => "wr_1"})
      rows << row("%5", idle)
      rows << row("%6", working)
      expect(target).to eq("pane" => "%5", "bound" => "gone")
    end

    it "is gone when the run has no bound pane" do
      rows << row("%6", idle)
      expect(panes.restart_target("app", "wr_1", bound: nil)).to eq("pane" => "%6", "bound" => "gone")
    end
  end

  describe "the target" do
    it "is the named pane when its turn is over, whatever the bound pane is" do
      rows << row("%5", working)
      rows << row("%7", idle)
      expect(target(named: "%7")).to eq("pane" => "%7", "bound" => "busy")
    end

    it "is the named pane when its turn failed" do
      rows << row("%7", "kind" => "claude", "turn_failed" => true, "state" => "idle")
      expect(target(named: "%7")["pane"]).to eq("%7")
    end

    it "refuses a named pane that runs no agent, with no_agent_pane" do
      rows << row("%7", "kind" => "shell")
      error = error_of { target(named: "%7") }
      expect(error.code).to eq("no_agent_pane")
      expect(error.message).to include("Nothing was changed")
    end

    it "refuses a named pane that is not in the snapshot" do
      expect(error_of { target(named: "%7") }.code).to eq("no_agent_pane")
    end

    it "refuses a named pane in the middle of a turn, with pane_busy and the reason" do
      rows << row("%7", working)
      error = error_of { target(named: "%7") }
      expect(error.code).to eq("pane_busy")
      expect(error.details).to include("reason" => "working")
      expect(error.message).to include("Nothing was changed")
    end

    it "is busy for a done row still inside the grace period" do
      rows << row("%5", "kind" => "claude", "state" => "done", "state_since" => (now - 3).iso8601)
      expect(target["bound"]).to eq("busy")
    end

    it "prefers an idle bound pane to a free idle pane" do
      rows << row("%5", idle)
      rows << row("%6", idle)
      expect(target["pane"]).to eq("%5")
    end

    it "never picks a pane bound to a review or a play" do
      rows << row("%5", "kind" => "shell")
      rows << row("%6", idle)
      rows << row("%7", idle)
      rows << row("%8", idle)
      allow(bindings).to receive(:binding_for).with("%6").and_return({"kind" => "review", "id" => "pr1", "session" => "app"})
      allow(bindings).to receive(:binding_for).with("%7").and_return({"kind" => "play", "id" => "p", "session" => "app"})
      expect(target["pane"]).to eq("%8")
    end

    it "picks the claude pane, not an idle codex pane" do
      rows << row("%5", "kind" => "shell")
      rows << row("%6", "kind" => "codex", "state" => "idle")
      rows << row("%7", idle)
      expect(target["pane"]).to eq("%7")
    end

    it "does not pick an unbound pane whose turn failed" do
      rows << row("%5", "kind" => "shell")
      rows << row("%6", "kind" => "claude", "state" => "idle", "turn_failed" => true)
      expect(error_of { target }.code).to eq("no_agent_pane")
    end

    it "refuses a named codex pane with no_agent_pane" do
      rows << row("%7", "kind" => "codex", "state" => "idle")
      expect(error_of { target(named: "%7") }.code).to eq("no_agent_pane")
    end

    it "refuses the caller's own pane when named" do
      rows << row("%7", idle)
      error = error_of { target(named: "%7", caller: "%7") }
      expect(error.code).to eq("pane_busy")
      expect(error.message).to include("Nothing was changed")
    end

    it "refuses a named pane bound to another run, as a reviewer, as a review pane, or to something else" do
      rows << row("%7", idle)
      rows << row("%8", idle.merge("review" => "wr_2:plan:1"))
      [{"kind" => "run", "id" => "wr_2", "role" => "author", "session" => "app"},
        {"kind" => "run", "id" => "wr_1", "role" => "reviewer", "session" => "app"},
        {"kind" => "play", "id" => "p", "session" => "app"}].each do |entry|
        allow(bindings).to receive(:binding_for).with("%7").and_return(entry)
        error = error_of { target(named: "%7") }
        expect(error.code).to eq("pane_busy")
        expect(error.message).to include("Nothing was changed")
      end
      expect(error_of { target(named: "%8") }.code).to eq("pane_busy")
    end

    it "takes a named pane whose binding is stale" do
      rows << row("%7", idle)
      stale = {"kind" => "run", "id" => "wr_2", "session" => "old"}
      allow(bindings).to receive(:binding_for).with("%7").and_return(stale)
      allow(bindings).to receive(:stale?).with(stale, any_args).and_return(true)
      expect(target(named: "%7")["pane"]).to eq("%7")
    end

    it "is the one free idle Claude Code pane when the bound pane is shell or gone" do
      rows << row("%5", "kind" => "shell")
      rows << row("%6", idle)
      expect(target["pane"]).to eq("%6")
    end

    it "never picks an unbound busy pane, such as an orchestrator's" do
      rows << row("%5", "kind" => "shell")
      rows << row("%6", working)
      rows << row("%7", idle)
      expect(target["pane"]).to eq("%7")
    end

    it "never picks a pane bound to another run" do
      rows << row("%5", "kind" => "shell")
      rows << row("%6", idle)
      rows << row("%7", idle)
      allow(bindings).to receive(:binding_for).with("%6").and_return({"kind" => "run", "id" => "wr_2", "role" => "author"})
      expect(target["pane"]).to eq("%7")
    end

    it "never picks a review pane" do
      rows << row("%5", "kind" => "shell")
      rows << row("%6", idle.merge("review" => "wr_2:plan:1"))
      rows << row("%7", idle)
      expect(target["pane"]).to eq("%7")
    end

    it "never picks the caller's pane" do
      rows << row("%5", "kind" => "shell")
      rows << row("%6", idle)
      rows << row("%7", idle)
      expect(target(caller: "%6")["pane"]).to eq("%7")
    end

    it "raises no_agent_pane with the way out when none qualifies" do
      rows << row("%5", "kind" => "shell")
      rows << row("%6", idle)
      error = error_of { target(caller: "%6") }
      expect(error.code).to eq("no_agent_pane")
      expect(error.message).to include("Start Claude Code in a pane of app, or name one with --pane")
      expect(error.message).to include("Nothing was changed")
    end

    it "raises pane_ambiguous listing the panes when several qualify" do
      rows << row("%5", "kind" => "shell")
      rows << row("%6", idle)
      rows << row("%7", idle)
      error = error_of { target }
      expect(error.code).to eq("pane_ambiguous")
      expect(error.details).to include("panes" => %w[%6 %7], "run_id" => "wr_1")
      expect(error.message).to include("--pane")
      expect(error.message).to include("Nothing was changed")
    end
  end

  it "fetches the snapshot exactly once per call" do
    rows << row("%5", "kind" => "shell")
    rows << row("%6", idle)
    target
    expect(snapshot_client).to have_received(:fetch).once
    expect(ensured).to eq(["app"])
  end

  it "raises no_daemon when the daemon does not answer" do
    allow(snapshot_client).to receive(:fetch).and_raise(Workspace::AgentSnapshotClient::Unavailable.new("No agent daemon for 'app'.", reason: :no_daemon))
    expect(error_of { target }.code).to eq("no_daemon")
  end
end
