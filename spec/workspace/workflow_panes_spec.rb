require "spec_helper"
require "tmpdir"
require "stringio"

RSpec.describe Workspace::WorkflowPanes do
  around do |example|
    Dir.mktmpdir("wf-panes") do |dir|
      @dir = dir
      example.run
    end
  end

  let(:config) { instance_double(Workspace::Config, agent_socket_path: "/run/app.sock", agent_running?: true) }
  let(:bindings) { Workspace::PaneBindings.new(path: File.join(@dir, "bindings.json")) }
  let(:tmux) { instance_double(Workspace::Tmux) }
  let(:locator) { instance_double(Workspace::PaneLocator) }
  let(:binder) { Workspace::Commands::Binding.new(bindings: bindings, locator: locator, tmux: tmux, output: StringIO.new) }
  let(:snapshot_client) { instance_double(Workspace::AgentSnapshotClient) }
  let(:ensured) { [] }
  let(:ensure_result) { Workspace::Commands::EnsureAgent::Result.new(:running) }
  let(:agent_ensurer) do
    lambda do |name:|
      ensured << name
      ensure_result
    end
  end
  let(:replies) { [] }
  let(:sockets) { [] }
  let(:connector) do
    lambda do |path|
      raise Errno::ENOENT if replies.empty?
      FakeDaemonSocket.new(replies.shift).tap { |socket| sockets << [path, socket] }
    end
  end
  subject(:panes) do
    described_class.new(config: config, bindings: bindings, tmux: tmux, locator: locator, binder: binder,
      snapshot_client: snapshot_client, agent_ensurer: agent_ensurer, connector: connector, clock: -> { Time.utc(2026, 10, 4, 12, 0, 30) })
  end

  before do
    allow(locator).to receive(:locate).with("app", "%5").and_return(id: "%5", session: "app", window: 0, index: 1)
    allow(tmux).to receive(:session_name_for_pane).with("%5").and_return("app")
    allow(tmux).to receive(:pane_slot).with("%5").and_return("app:0.1")
  end

  def bind(**overrides)
    panes.bind(workspace: "app", pane: "%5", run_id: "wr_1", step: "plan", attempt: 2,
      instructions: "/src/app/.workflow/wr_1/steps/plan.2.prompt.md", artifacts: "/src/app/.workflow/wr_1", **overrides)
  end

  describe "#default_pane" do
    it "is the workspace's first Claude Code pane, as its daemon sees it, starting the daemon if needed" do
      allow(snapshot_client).to receive(:fetch).with("app").and_return("panes" => [
        {"pane_id" => "%4", "kind" => "shell"}, {"pane_id" => "%5", "kind" => "claude"}, {"pane_id" => "%7", "kind" => "claude"}
      ])

      expect(panes.default_pane("app")).to eq("%5")
      expect(ensured).to eq(["app"])
    end

    it "raises no_agent_pane when no pane runs Claude Code" do
      allow(snapshot_client).to receive(:fetch).and_return("panes" => [{"pane_id" => "%4", "kind" => "shell"}])

      expect { panes.default_pane("app") }.to raise_error(Workspace::Error, /No pane of 'app' is running Claude Code/) { |error|
        expect(error.code).to eq("no_agent_pane")
      }
    end

    it "raises no_daemon when the daemon can't be started, or doesn't answer" do
      allow(snapshot_client).to receive(:fetch).and_raise(Workspace::AgentSnapshotClient::Unavailable.new("No agent daemon for 'app'.", reason: :no_daemon))
      expect { panes.default_pane("app") }.to raise_error(Workspace::Error) { |error| expect(error.code).to eq("no_daemon") }

      ensure_result.status = :failed
      ensure_result.detail = "it did not answer within 5s"
      expect { panes.default_pane("app") }.to raise_error(Workspace::Error, /Could not start the agent daemon for 'app': it did not answer within 5s/) { |error|
        expect(error.code).to eq("no_daemon")
      }
    end

    it "starts nothing for a dry run: nil when no daemon is running" do
      allow(config).to receive(:agent_running?).with("app").and_return(false)

      expect(panes.default_pane("app", start_daemon: false)).to be_nil
      expect(ensured).to eq([])
    end
  end

  describe "#locate" do
    it "resolves a pane the caller named to its id, within the workspace's own session" do
      allow(locator).to receive(:locate).with("app", "0.1").and_return(id: "%5", session: "app")

      expect(panes.locate("app", "0.1")).to eq("%5")
    end
  end

  describe "binding" do
    it "binds the pane to the run's step, where the SessionStart hook and `binding show` find it" do
      entry = bind

      expect(entry).to include("kind" => "run", "id" => "wr_1", "step" => "plan", "attempt" => 2, "workspace" => "app",
        "session" => "app", "pane_slot" => "app:0.1", "pane_id" => "%5",
        "instructions" => "/src/app/.workflow/wr_1/steps/plan.2.prompt.md", "artifacts" => "/src/app/.workflow/wr_1")
      expect(bindings.binding_for("%5")).to eq(entry)
      expect(panes.run_on("%5")).to eq("wr_1")
      expect(panes.pane_of("wr_1")).to eq("%5")
      expect(panes.alive?("wr_1")).to be true
    end

    it "leaves out a path too long for a binding field, and still binds" do
      entry = bind(instructions: "/#{"deep/" * 50}plan.2.prompt.md")

      expect(entry).not_to have_key("instructions")
      expect(entry).to include("id" => "wr_1", "artifacts" => "/src/app/.workflow/wr_1")
    end

    it "does not count a binding made for another pane: one whose slot or session changed" do
      bind
      allow(tmux).to receive(:pane_slot).with("%5").and_return("app:0.2")

      expect(panes.run_on("%5")).to be_nil
      expect(panes.alive?("wr_1")).to be false
    end

    it "does not count a pane that is gone, or one bound to something other than a run" do
      bind
      allow(tmux).to receive(:session_name_for_pane).with("%5").and_return(nil)
      allow(tmux).to receive(:pane_slot).with("%5").and_return(nil)
      expect(panes.alive?("wr_1")).to be false

      bindings.bind("%5", "kind" => "play", "id" => "playbook", "session" => "app")
      allow(tmux).to receive(:session_name_for_pane).with("%5").and_return("app")
      expect(panes.run_on("%5")).to be_nil
      expect(panes.run_on("%9")).to be_nil
      expect(panes.alive?("wr_9")).to be false
    end

    it "follows a binding `restore` moved to the pane's new id" do
      bind
      bindings.move([{from: "%5", to: "%12", session: "app", from_slot: "app:0.1", to_slot: "app:0.1"}])

      expect(panes.pane_of("wr_1")).to eq("%12")
    end

    it "unbinds the run's pane, and does nothing for a run with none" do
      bind

      panes.unbind("wr_1")
      panes.unbind("wr_1")

      expect(bindings.binding_for("%5")).to be_nil
    end

    it "unbinds a run whose binding waits under its slot for `restore`, so no pane is bound to it later" do
      bind
      allow(tmux).to receive(:pane_slot).with("%6").and_return("app:0.2")
      bindings.bind("%6", "kind" => "play", "id" => "p", "session" => "app", "pane_slot" => "app:0.2")
      bindings.move([{from: "%6", to: "%5", session: "app", from_slot: "app:0.2", to_slot: "app:0.2"}])
      expect(JSON.parse(File.read(File.join(@dir, "bindings.json"))).keys).to include("slot:app:0.1")

      panes.unbind("wr_1")

      expect(JSON.parse(File.read(File.join(@dir, "bindings.json"))).keys).to eq(["%5"])
    end
  end

  describe "#idle?" do
    before { allow(config).to receive(:agent_running?).with("app").and_return(true) }

    it "is true only when the daemon says the pane's agent is idle" do
      allow(snapshot_client).to receive(:fetch).with("app", timeout: 1.0).and_return("panes" => [
        {"pane_id" => "%5", "kind" => "claude", "state" => "idle"}, {"pane_id" => "%6", "kind" => "claude", "state" => "working"},
        {"pane_id" => "%7", "kind" => "claude", "state" => "waiting"}
      ])

      expect(%w[%5 %6 %7 %8].map { |pane| panes.idle?("app", pane) }).to eq([true, false, false, false])
    end

    it "counts a pane whose turn ended (done) once it has been quiet for ten seconds, by when the daemon's own advance has the run" do
      # Measured from the turn's end, not from how long the screen has been quiet.
      shown = {"pane_id" => "%5", "kind" => "claude", "state" => "done", "state_since" => "2026-10-04T12:00:21Z", "idle_seconds" => 600}
      allow(snapshot_client).to receive(:fetch).with("app", timeout: 1.0).and_return("panes" => [shown])
      expect(panes.idle?("app", "%5")).to be false

      shown["state_since"] = "2026-10-04T12:00:20Z"
      expect(panes.idle?("app", "%5")).to be true
    end

    it "does not count a pane that is working or waiting, however long ago that began, nor a done pane with no time" do
      allow(snapshot_client).to receive(:fetch).with("app", timeout: 1.0).and_return("panes" => [
        {"pane_id" => "%5", "state" => "working", "state_since" => "2026-10-04T11:00:00Z", "idle_seconds" => 600},
        {"pane_id" => "%6", "state" => "waiting", "state_since" => "2026-10-04T11:00:00Z", "idle_seconds" => 600},
        {"pane_id" => "%7", "state" => "done", "state_since" => nil, "idle_seconds" => 600},
        {"pane_id" => "%8", "state" => "done", "state_since" => "yesterday", "idle_seconds" => 600}
      ])

      expect(%w[%5 %6 %7 %8].map { |pane| panes.idle?("app", pane) }).to eq([false, false, false, false])
    end

    it "is false when the daemon is not running or does not answer, and starts none" do
      allow(snapshot_client).to receive(:fetch).and_raise(Workspace::AgentSnapshotClient::Unavailable.new("no answer", reason: :timeout))
      expect(panes.idle?("app", "%5")).to be false

      allow(config).to receive(:agent_running?).with("app").and_return(false)
      allow(snapshot_client).to receive(:fetch).and_return("panes" => [{"pane_id" => "%5", "state" => "idle"}])
      expect(panes.idle?("app", "%5")).to be false
      # Only the first call, made while the daemon was running, asked it.
      expect(snapshot_client).to have_received(:fetch).once
      expect(panes.daemon_running?("app")).to be false
      expect(ensured).to eq([])
    end
  end

  describe "#kick" do
    let(:shown) { {"pane_id" => "%5", "kind" => "claude", "state" => "done"} }

    before { allow(snapshot_client).to receive(:fetch).with("app", timeout: 1.0) { {"panes" => [shown]} } }

    it "does not type a continuing step's line into a pane whose agent is in the middle of a turn, or at a prompt" do
      allow(tmux).to receive(:deliver)

      %w[working waiting].each do |state|
        shown["state"] = state
        expect(panes.kick(workspace: "app", pane: "%5", text: "x", fresh: false))
          .to eq(ok: false, code: "pane_busy", message: "the agent in pane %5 is in the middle of a turn; resume the run when it is done")
      end
      expect(tmux).not_to have_received(:deliver)
    end

    it "types it when the agent is idle or done, when the daemon does not know the pane, and when the daemon does not answer" do
      allow(tmux).to receive(:deliver).and_return(Workspace::Tmux::Delivery.new(status: :submitted, message: "ok"))

      %w[idle done].each do |state|
        shown["state"] = state
        expect(panes.kick(workspace: "app", pane: "%5", text: "x", fresh: false)).to eq(ok: true)
      end
      shown["pane_id"] = "%9"
      expect(panes.kick(workspace: "app", pane: "%5", text: "x", fresh: false)).to eq(ok: true)
      allow(snapshot_client).to receive(:fetch).and_raise(Workspace::AgentSnapshotClient::Unavailable.new("no answer", reason: :timeout))
      expect(panes.kick(workspace: "app", pane: "%5", text: "x", fresh: false)).to eq(ok: true)
    end
    it "types the line into the pane for a step that continues the conversation" do
      allow(tmux).to receive(:deliver).with("app", "%5", "Read plan.md and follow it.")
        .and_return(Workspace::Tmux::Delivery.new(status: :submitted, message: "ok"))

      expect(panes.kick(workspace: "app", pane: "%5", text: "Read plan.md and follow it.", fresh: false)).to eq(ok: true)
      expect(sockets).to eq([])
    end

    it "starts the daemon for a step that continues the conversation too, and types nothing when it can't be started" do
      allow(tmux).to receive(:deliver).and_return(Workspace::Tmux::Delivery.new(status: :submitted, message: "ok"))

      panes.kick(workspace: "app", pane: "%5", text: "x", fresh: false)
      expect(ensured).to eq(["app"])

      ensure_result.status = :failed
      expect(panes.kick(workspace: "app", pane: "%5", text: "x", fresh: false)).to include(ok: false, code: "no_daemon")
      expect(tmux).to have_received(:deliver).once
    end

    it "counts text that may have reached the pane as delivered, since typing it again would send it twice" do
      allow(tmux).to receive(:deliver).and_return(Workspace::Tmux::Delivery.new(status: :unsubmitted, message: "Enter left the screen unchanged"))

      expect(panes.kick(workspace: "app", pane: "%5", text: "x", fresh: false)).to eq(ok: true)
    end

    it "reports text that never reached the pane, and a pane that is gone" do
      allow(tmux).to receive(:deliver).and_return(Workspace::Tmux::Delivery.new(status: :failed, message: "tmux could not paste into %5"))
      expect(panes.kick(workspace: "app", pane: "%5", text: "x", fresh: false))
        .to eq(ok: false, code: "not_delivered", message: "tmux could not paste into %5")

      allow(tmux).to receive(:session_name_for_pane).with("%5").and_return(nil)
      expect(panes.kick(workspace: "app", pane: "%5", text: "x", fresh: false))
        .to eq(ok: false, code: "pane_gone", message: "pane %5 of 'app' is gone")
    end

    it "has the daemon clear the conversation and type the line for a fresh step, and waits for the outcome" do
      replies << JSON.generate("ok" => true, "status" => "restarted", "pane_id" => "%5") + "\n"

      expect(panes.kick(workspace: "app", pane: "%5", text: "Read plan.md and follow it.", fresh: true)).to eq(ok: true)
      expect(ensured).to eq(["app"])
      expect(sockets.map(&:first)).to eq(["/run/app.sock"])
      expect(sockets.first.last.sent).to eq([{"type" => "restart_agent", "workspace" => "app", "pane" => "%5",
                                              "prompt" => "Read plan.md and follow it.", "force" => false, "wait" => true}])
    end

    it "passes on the daemon's refusal, with its code and how to fix it" do
      replies << JSON.generate("ok" => false, "error" => "context_unknown", "message" => "can't read context usage for pane 0.1", "fix" => "Run workspace doctor.") + "\n"

      expect(panes.kick(workspace: "app", pane: "%5", text: "x", fresh: true))
        .to eq(ok: false, code: "context_unknown", message: "can't read context usage for pane 0.1 Run workspace doctor.")
    end

    it "reports a daemon that can't be started, doesn't answer, hangs up, or replies with something unreadable" do
      expect(panes.kick(workspace: "app", pane: "%5", text: "x", fresh: true)).to include(ok: false, code: "no_daemon")

      replies << nil
      expect(panes.kick(workspace: "app", pane: "%5", text: "x", fresh: true)).to include(ok: false, code: "connection_failed")

      replies << "not json\n"
      expect(panes.kick(workspace: "app", pane: "%5", text: "x", fresh: true)).to include(ok: false, code: "unreadable_reply")

      # A daemon that takes the request and never answers: the wait ends, with the run's lock still held by the caller.
      replies << :silent
      expect(panes.kick(workspace: "app", pane: "%5", text: "x", fresh: true))
        .to eq(ok: false, code: "connection_failed", message: "The agent daemon for 'app' did not answer within 150s.")

      ensure_result.status = :failed
      expect(panes.kick(workspace: "app", pane: "%5", text: "x", fresh: true)).to include(ok: false, code: "no_daemon")
    end
  end
end
