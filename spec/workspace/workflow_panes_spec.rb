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
      snapshot_client: snapshot_client, agent_ensurer: agent_ensurer, connector: connector, clock: -> { now[0] },
      sleeper: lambda { |seconds|
        sleeps << seconds
        now[0] += seconds
        on_sleep.call
      })
  end
  let(:now) { [Time.utc(2026, 10, 4, 12, 0, 30)] }
  let(:sleeps) { [] }
  let(:on_sleep) { -> {} }

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

    it "does not count a pane showing a failed turn, whether idle or done for long" do
      allow(snapshot_client).to receive(:fetch).with("app", timeout: 1.0).and_return("panes" => [
        {"pane_id" => "%5", "state" => "idle", "turn_failed" => true},
        {"pane_id" => "%6", "state" => "done", "turn_failed" => true, "state_since" => "2026-10-04T11:00:00Z"}
      ])

      expect(%w[%5 %6].map { |pane| panes.idle?("app", pane) }).to eq([false, false])
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

    it "answers pane_busy for a shell pane showing a failed turn, and types for an agent pane showing one" do
      allow(tmux).to receive(:deliver).and_return(Workspace::Tmux::Delivery.new(status: :submitted, message: "ok"))
      shown.merge!("kind" => "shell", "state" => "idle", "turn_failed" => true)
      expect(panes.kick(workspace: "app", pane: "%5", text: "x", fresh: false)).to include(ok: false, code: "pane_busy")
      expect(tmux).not_to have_received(:deliver)

      shown["kind"] = "claude"
      expect(panes.kick(workspace: "app", pane: "%5", text: "x", fresh: false)).to eq(ok: true)
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

    it "keeps the reason the daemon gives for a busy pane" do
      replies << JSON.generate("ok" => false, "error" => "pane_busy", "message" => "pane %5 kept changing", "reason" => "background_activity") + "\n"

      expect(panes.kick(workspace: "app", pane: "%5", text: "x", fresh: true))
        .to eq(ok: false, code: "pane_busy", message: "pane %5 kept changing", reason: "background_activity")
    end

    it "sends the run id, so the daemon stops typing once the run is gone" do
      replies << JSON.generate("ok" => true) + "\n"

      panes.kick(workspace: "app", pane: "%5", text: "x", fresh: true, run_id: "wr_1")

      expect(sockets.first.last.sent.first).to include("run_id" => "wr_1")
    end

    it "keeps what the daemon says kept a moving screen from being accepted" do
      replies << JSON.generate("ok" => false, "error" => "pane_busy", "message" => "kept changing", "reason" => "background_activity",
        "details" => {"proof_missing" => "transcript_activity:cost-v2"}) + "\n"

      expect(panes.kick(workspace: "app", pane: "%5", text: "x", fresh: true)).to eq(ok: false, code: "pane_busy", message: "kept changing",
        reason: "background_activity", proof_missing: "transcript_activity:cost-v2")
    end

    it "keeps the daemon's warning, on a success and on a failure" do
      replies << JSON.generate("ok" => true, "warning" => "may be lost") + "\n"
      expect(panes.kick(workspace: "app", pane: "%5", text: "x", fresh: true)).to eq(ok: true, warning: "may be lost")

      replies.clear
      replies << JSON.generate("ok" => false, "error" => "not_delivered", "message" => "m", "reason" => "prompt_unconfirmed", "warning" => "may be lost") + "\n"
      expect(panes.kick(workspace: "app", pane: "%5", text: "x", fresh: true))
        .to eq(ok: false, code: "not_delivered", message: "m", reason: "prompt_unconfirmed", warning: "may be lost")
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

  def box(*above, input: "")
    rule = "─" * 40
    [*above, rule, "❯ #{input}", rule, "  [Model] status", ""].join("\n")
  end

  describe "#main_turn_over?" do
    let(:stopped_at) { "2026-10-04T12:00:10.000Z" }
    let(:transcript) { File.join(@dir, "t.jsonl") }
    let(:row) do
      {"pane_id" => "%5", "kind" => "claude", "state" => "done", "activity_state" => "working", "open_tools" => [], "turn_failed" => false,
       "main_turn_over_since" => stopped_at, "transcript_path" => transcript, "last_event_at" => "2026-10-04T12:00:10Z"}
    end
    let(:no_stop) { {"state" => "idle", "activity_state" => "idle", "main_turn_over_since" => nil, "transcript_path" => nil, "last_event_at" => nil} }
    let(:screen) { [box] }

    def record(type, at, **extra) = {"type" => type, "timestamp" => at, **extra}

    def write_transcript(*records)
      File.write(transcript, records.map { |entry| JSON.generate(entry) + "\n" }.join)
    end

    def over? = panes.main_turn_over?("app", "%5")

    before do
      write_transcript(record("assistant", "2026-10-04T12:00:09.000Z"), record("system", "2026-10-04T12:00:11.000Z"))
      allow(snapshot_client).to receive(:fetch).with("app", timeout: 1.0) { {"panes" => [row]} }
      allow(tmux).to receive(:capture_screen_styled).with("%5") { screen.first }
    end

    it "is false when tmux can't be run" do
      allow(tmux).to receive(:capture_screen_styled).and_raise(Errno::ENOENT)
      expect(over?).to be(false)
    end

    context "after a Stop" do
      it "is true with housekeeping alone after the Stop and a quiet box" do
        expect(over?).to be(true)
      end

      it "goes by the screen and the hooks, not by a done mark" do
        row["state"] = "working"
        expect(over?).to be(true)
      end

      it "is false for a woken turn with no hook yet: queue-operation in the transcript, a clear screen" do
        write_transcript(record("queue-operation", "2026-10-04T12:00:12.000Z"))
        expect(over?).to be(false)
      end

      it "does not fall back to the rule for no Stop when the transcript shows activity" do
        write_transcript(record("queue-operation", "2026-10-04T12:00:12.000Z"))
        row.merge!("state" => "idle", "activity_state" => "idle", "last_event_at" => "2026-10-04T11:59:00Z")
        expect(over?).to be(false)
      end

      it "is false for a woken turn with no hook yet: a spinner row, a clean transcript" do
        screen[0] = box("✽ Frosting… (3s · ↓ 12 tokens)", "")
        expect(over?).to be(false)
      end

      it "is false with a draft, and true with a suggestion" do
        screen[0] = box(input: "half a thought")
        expect(over?).to be(false)

        screen[0] = box(input: "\e[2msend the reply\e[0m")
        expect(over?).to be(true)
      end

      it "is false with a nil transcript path, and an unreadable transcript" do
        row["transcript_path"] = nil
        expect(over?).to be(false)

        row["transcript_path"] = File.join(@dir, "gone.jsonl")
        expect(over?).to be(false)
      end

      it "is false for a stored time that can't be read" do
        row["main_turn_over_since"] = "yesterday"
        expect(over?).to be(false)
      end

      it "ignores a sub-agent's records after the Stop" do
        write_transcript(record("assistant", "2026-10-04T12:00:12.000Z", isSidechain: true))
        expect(over?).to be(true)
      end
    end

    context "with no Stop to go by" do
      before { row.merge!(no_stop) }

      it "is true with no hook event at all: a pane with no hooks, a daemon restarted since the Stop" do
        expect(over?).to be(true)
      end

      it "goes by the age of the last hook event, since activity_state can be a scan stale" do
        row["last_event_at"] = "2026-10-04T12:00:25Z"
        expect(over?).to be(false)

        row["last_event_at"] = "2026-10-04T11:59:59Z"
        expect(over?).to be(true)
      end

      it "is held by a background sub-agent's hook events only while they arrive" do
        row["last_event_at"] = "2026-10-04T12:00:29Z"
        expect(over?).to be(false)

        now[0] += 31
        expect(over?).to be(true)
      end

      it "is false while the screen reads working" do
        row["activity_state"] = "working"
        expect(over?).to be(false)
      end

      it "is false with a draft" do
        screen[0] = box(input: "half a thought")
        expect(over?).to be(false)
      end

      it "with a tool left open by Esc, goes by the screen" do
        row["open_tools"] = ["Bash"]
        expect(over?).to be(true)

        screen[0] = box("  ⎿  Running… (54s · timeout 5m)", "")
        expect(over?).to be(false)
      end

      it "is false with a question tool's menu open" do
        row["open_tools"] = ["AskUserQuestion"]
        expect(over?).to be(false)
      end
    end

    %w[after_stop no_stop].each do |name|
      context "in the #{name} case" do
        before { row.merge!(no_stop) if name == "no_stop" }

        it "is false for a failed turn, a permission prompt and another kind" do
          row["turn_failed"] = true
          expect(over?).to be(false)
          row["turn_failed"] = false

          row["state"] = "waiting"
          expect(over?).to be(false)
          row["state"] = "idle"

          row["activity_state"] = "waiting"
          expect(over?).to be(false)
          row["activity_state"] = "idle"

          row["kind"] = "codex"
          expect(over?).to be(false)
        end

        it "is false for a failed capture" do
          screen[0] = nil
          expect(over?).to be(false)
        end
      end
    end

    it "is false with no row, no daemon and a daemon that doesn't answer" do
      allow(snapshot_client).to receive(:fetch).and_return("panes" => [])
      expect(over?).to be(false)

      allow(snapshot_client).to receive(:fetch).and_raise(Workspace::AgentSnapshotClient::Unavailable.new("no", reason: :timeout))
      expect(over?).to be(false)

      allow(config).to receive(:agent_running?).and_return(false)
      expect(over?).to be(false)
    end

    it "is false for a row from a daemon before this code" do
      row.reject! { |key, _| %w[activity_state open_tools main_turn_over_since transcript_path].include?(key) }
      expect(over?).to be(false)
    end
  end

  describe "the screen check before a continuing step's line" do
    let(:shown) { {"pane_id" => "%5", "kind" => "claude", "state" => "done", "activity_state" => "working", "open_tools" => []} }
    let(:snapshot) { {"features" => ["parked_resume"], "panes" => [shown]} }
    let(:screen) { [box] }
    let(:typed) { Workspace::Tmux::Delivery.new(status: :submitted, message: "ok") }

    def kick = panes.kick(workspace: "app", pane: "%5", text: "x", fresh: false)

    before do
      allow(snapshot_client).to receive(:fetch).with("app", timeout: 1.0) { snapshot }
      allow(tmux).to receive(:capture_screen_styled).with("%5") { screen.first }
      allow(tmux).to receive(:deliver).and_return(typed)
    end

    it "types into an empty box and into a suggestion, with no wait" do
      expect(kick).to eq(ok: true)

      screen[0] = box(input: "\e[2msend the reply\e[0m")
      expect(kick).to eq(ok: true)
      expect(tmux).to have_received(:deliver).twice
      expect(sleeps).to eq([])
    end

    it "refuses a spinner row with its reason, after waiting SCREEN_SETTLE, typing nothing" do
      screen[0] = box("✽ Frosting… (3s)", "")

      expect(kick).to include(ok: false, code: "pane_busy", reason: "turn_started", message: a_string_including("pane %5"))
      expect(sleeps).to eq([0.5] * 10)
      expect(tmux).not_to have_received(:deliver)
    end

    it "refuses a draft with its reason, typing nothing" do
      screen[0] = box(input: "half a thought")

      expect(kick).to include(ok: false, code: "pane_busy", reason: "input_not_empty")
      expect(tmux).not_to have_received(:deliver)
    end

    context "when the refusal clears within SCREEN_SETTLE" do
      let(:on_sleep) { -> { screen[0] = box if sleeps.size == 3 } }

      it "types" do
        screen[0] = box("✽ Frosting… (3s)", "")

        expect(kick).to eq(ok: true)
        expect(sleeps).to eq([0.5] * 3)
        expect(tmux).to have_received(:deliver).once
      end
    end

    context "when the daemon's row changes between looks" do
      let(:on_sleep) { -> { shown["open_tools"] = [] if sleeps.size == 2 } }

      it "fetches the snapshot again on each retry" do
        shown["open_tools"] = ["AskUserQuestion"]

        expect(kick).to eq(ok: true)
        expect(snapshot_client).to have_received(:fetch).exactly(4).times
      end
    end

    context "when the daemon stops answering after a refusal" do
      let(:on_sleep) { -> { allow(snapshot_client).to receive(:fetch).and_raise(Workspace::AgentSnapshotClient::Unavailable.new("no", reason: :timeout)) } }

      it "keeps the refusal" do
        screen[0] = box("✽ Frosting… (3s)", "")

        expect(kick).to include(ok: false, code: "pane_busy", reason: "turn_started")
        expect(tmux).not_to have_received(:deliver)
      end
    end

    it "types as today for another kind and for no row, without reading the screen" do
      shown["kind"] = "codex"
      expect(kick).to eq(ok: true)

      snapshot["panes"] = []
      expect(kick).to eq(ok: true)
      expect(tmux).not_to have_received(:capture_screen_styled)
    end

    it "types as today against a daemon from before this code" do
      snapshot.delete("features")
      shown.delete("activity_state")
      shown.delete("open_tools")

      expect(kick).to eq(ok: true)
      expect(tmux).not_to have_received(:capture_screen_styled)
    end
  end

  describe "#parkable?" do
    let(:snapshot) { {"features" => ["parked_resume"], "panes" => [{"pane_id" => "%5", "kind" => "claude"}]} }

    before do
      allow(snapshot_client).to receive(:fetch).with("app") { snapshot }
      allow(tmux).to receive(:session_name_for).with("app").and_return("app-session")
      allow(tmux).to receive(:pane_details).with("app-session").and_return([{id: "%5"}, {id: "%6"}])
    end

    it "is true for a Claude Code row, having started the daemon" do
      expect(panes.parkable?("app", "%5")).to be(true)
      expect(ensured).to eq(["app"])
    end

    it "is false for a shell or Codex row" do
      %w[shell codex].each do |kind|
        snapshot["panes"].first["kind"] = kind
        expect(panes.parkable?("app", "%5")).to be(false)
      end
    end

    it "is true for a missing row in window 0, false for a pane in another window" do
      snapshot["panes"] = []

      expect(panes.parkable?("app", "%6")).to be(true)
      expect(panes.parkable?("app", "%9")).to be(false)
    end

    it "is false for a snapshot with no features" do
      snapshot.delete("features")
      expect(panes.parkable?("app", "%5")).to be(false)
    end

    it "is false when the daemon can't start or doesn't answer" do
      allow(snapshot_client).to receive(:fetch).and_raise(Workspace::AgentSnapshotClient::Unavailable.new("no", reason: :no_daemon))
      expect(panes.parkable?("app", "%5")).to be(false)

      ensure_result.status = :failed
      expect(panes.parkable?("app", "%5")).to be(false)
    end
  end

  describe "#agent_gone?" do
    let(:row) { {"pane_id" => "%5", "kind" => "shell", "idle_seconds" => 30} }

    before { allow(snapshot_client).to receive(:fetch).with("app", timeout: 1.0) { {"panes" => [row]} } }

    it "is true for a shell row idle 30 seconds, false before that" do
      expect(panes.agent_gone?("app", "%5")).to be(true)

      row["idle_seconds"] = 29
      expect(panes.agent_gone?("app", "%5")).to be(false)
    end

    it "is false for an agent row and for no row" do
      row["kind"] = "claude"
      expect(panes.agent_gone?("app", "%5")).to be(false)
      expect(panes.agent_gone?("app", "%9")).to be(false)
    end

    it "is false for a daemon that doesn't answer" do
      allow(snapshot_client).to receive(:fetch).and_raise(Workspace::AgentSnapshotClient::Unavailable.new("no", reason: :no_daemon))
      expect(panes.agent_gone?("app", "%5")).to be(false)
    end
  end

  describe "#pane_gone?" do
    it "says whether tmux still knows the pane" do
      expect(panes.pane_gone?("%5")).to be(false)

      allow(tmux).to receive(:session_name_for_pane).with("%5").and_return(nil)
      expect(panes.pane_gone?("%5")).to be(true)
    end

    it "is false when tmux can't be run" do
      allow(tmux).to receive(:session_name_for_pane).and_raise(Errno::ENOENT)
      expect(panes.pane_gone?("%5")).to be(false)
    end
  end
end
