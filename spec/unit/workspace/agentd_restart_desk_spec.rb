require "spec_helper"

RSpec.describe Workspace::AgentdRestartDesk do
  let(:details) do
    [{id: "%18", window: 0, index: 1}, {id: "%19", window: 0, index: 2}, {id: "%30", window: 1, index: 0}]
  end
  let(:monitor) { RecordingRestartMonitor.new(kinds: {"%18" => "claude", "%19" => "codex", "%30" => "claude"}) }
  let(:context_reader) { RecordingContextReader.new }
  let(:registry) { RecordingRestartRegistry.new }
  let(:runner) { RecordingRestartRunner.new }
  let(:pipeline_refs) { {} }
  let(:client) { StringIO.new }

  subject(:desk) do
    described_class.new(workspace: "myapp", session_name: "workspace-myapp", pane_details: -> { details },
      monitor: monitor, context_reader: context_reader, registry: registry, runner: runner,
      pipeline_ref: ->(index) { pipeline_refs[index] })
  end

  def restart(**fields)
    {"type" => "restart_agent", "workspace" => "myapp", "pane" => "%18", "prompt" => "carry on"}.merge(fields.transform_keys(&:to_s))
  end

  def replied = JSON.parse(client.string.lines.last)

  def run_worker(pane_id = "%18") = registry.workers.fetch(pane_id).call

  describe "#handle" do
    it "replies started, then starts a worker that runs the restart with the default confirm timeout" do
      expect(desk.handle(restart, client)).to be_nil

      expect(client.string).to eq(%({"ok":true,"status":"started","pane":"0.1","pane_id":"%18","context_pct":40}\n))
      expect(registry.calls).to eq([[:claim_pending, "%18"], [:start_worker, "%18"]])
      expect(runner.calls).to be_empty

      run_worker
      started = {"ok" => true, "status" => "started", "pane" => "0.1", "pane_id" => "%18", "context_pct" => 40}
      expect(runner.calls).to eq([[:run, started, "carry on", false, Workspace::AgentRestart::CONFIRM_TIMEOUT, nil, {run_id: nil}]])
    end

    it "hands the connection to the worker when the caller waits, replying nothing itself" do
      expect(desk.handle(restart(wait: true, timeout: 30, force: true, run_id: "wr_1"), client)).to eq(:handed_off)

      expect(client.string).to be_empty
      run_worker
      expect(runner.calls.first.drop(2)).to eq(["carry on", true, 30, client, {run_id: "wr_1"}])
    end

    it "gives the claim up when the worker could not be started" do
      failing = RecordingRestartRegistry.new(fail_start: ThreadError.new("can't create Thread"))
      desk = described_class.new(workspace: "myapp", session_name: "workspace-myapp", pane_details: -> { details },
        monitor: monitor, context_reader: context_reader, registry: failing, runner: runner, pipeline_ref: ->(_index) {})

      expect { desk.handle(restart, client) }.to raise_error(ThreadError)
      expect(failing.calls).to eq([[:claim_pending, "%18"], [:start_worker, "%18"], [:abandon_pending, "%18"]])
    end

    it "keeps going when the caller has already hung up" do
      gone = StringIO.new.tap(&:close_write)

      expect(desk.handle(restart, gone)).to be_nil
      expect(registry.workers.keys).to eq(["%18"])
    end

    it "refuses a message with no prompt before anything else" do
      desk.handle(restart(prompt: "  ", pane: ""), client)

      expect(client.string).to eq(%({"ok":false,"error":"missing_prompt","message":"restart_agent needs a non-empty \\"prompt\\""}\n))
      expect(registry.calls).to be_empty
    end

    it "refuses every restart when it has no context reader" do
      desk = described_class.new(workspace: "myapp", session_name: "workspace-myapp", pane_details: -> { details },
        monitor: monitor, context_reader: nil, registry: registry, runner: runner, pipeline_ref: ->(_index) {})

      desk.handle(restart, client)

      expect(replied).to include("ok" => false, "error" => "context_unavailable")
    end

    it "refuses a confirm timeout outside 1 to 600 seconds" do
      [0, 601, "30"].each do |timeout|
        fresh = StringIO.new
        desk.handle(restart(timeout: timeout), fresh)
        expect(JSON.parse(fresh.string)).to eq("ok" => false, "error" => "bad_timeout",
          "message" => "\"timeout\" must be a number of seconds from 1 to 600")
      end
      expect(registry.calls).to be_empty
    end

    describe "naming the pane" do
      it "finds a pane by id, window.pane, session:window.pane or a bare index in window 0" do
        {"%30" => "1.0", "1.0" => "1.0", "myapp:0.2" => "0.2", "workspace-myapp:0.1" => "0.1", "MyApp:0.1" => "0.1", "2" => "0.2"}.each do |spec, target|
          fresh = StringIO.new
          desk.handle(restart(pane: spec), fresh)
          expect(JSON.parse(fresh.string)).to include("pane" => target)
        end
        claimed = registry.calls.filter_map { |name, id| id if name == :claim_pending }
        expect(claimed).to eq(%w[%30 %30 %19 %18 %18 %19])
      end

      it "refuses a missing, malformed, foreign or unknown pane" do
        expect_refusal = lambda do |spec, error, message|
          fresh = StringIO.new
          desk.handle(restart(pane: spec), fresh)
          expect(JSON.parse(fresh.string)).to eq("ok" => false, "error" => error, "message" => message)
        end

        expect_refusal.call(nil, "missing_pane", "restart_agent needs a \"pane\": a pane id (%12), window.pane (0.1), or a pane index")
        expect_refusal.call("left", "bad_pane", "\"left\" is not a pane id (%12), window.pane (0.1), session:window.pane, or a pane index")
        expect_refusal.call("other:0.1", "wrong_session", "pane other:0.1 is not in this workspace's tmux session (workspace-myapp)")
        expect_refusal.call("%99", "no_such_pane", "no pane %99 in tmux session workspace-myapp")
        expect(registry.calls).to be_empty
      end
    end

    describe "what the pane runs" do
      it "refuses a shell after looking once more" do
        monitor = RecordingRestartMonitor.new(kinds: {"%18" => "shell"})
        desk = described_class.new(workspace: "myapp", session_name: "workspace-myapp", pane_details: -> { details },
          monitor: monitor, context_reader: context_reader, registry: registry, runner: runner, pipeline_ref: ->(_index) {})

        desk.handle(restart, client)

        expect(replied).to eq("ok" => false, "error" => "not_an_agent", "pane" => "0.1",
          "message" => "pane 0.1 (%18) is running a shell, not a coding agent")
        expect(monitor.calls.first(3)).to eq([[:pane_kind, "%18"], [:rescan_pane, "%18"], [:pane_kind, "%18"]])
      end

      it "goes on when the second look finds an agent started since the last scan" do
        monitor = RecordingRestartMonitor.new(kinds: {"%18" => "shell"}, rescanned: {"%18" => "claude"})
        desk = described_class.new(workspace: "myapp", session_name: "workspace-myapp", pane_details: -> { details },
          monitor: monitor, context_reader: context_reader, registry: registry, runner: runner, pipeline_ref: ->(_index) {})

        desk.handle(restart, client)

        expect(replied).to include("ok" => true, "status" => "started")
      end

      it "refuses an agent whose clear command is not /clear" do
        monitor = RecordingRestartMonitor.new(kinds: {"%18" => "opencode"})
        desk = described_class.new(workspace: "myapp", session_name: "workspace-myapp", pane_details: -> { details },
          monitor: monitor, context_reader: context_reader, registry: registry, runner: runner, pipeline_ref: ->(_index) {})

        desk.handle(restart, client)

        expect(replied).to include("ok" => false, "error" => "unsupported_agent", "pane" => "0.1")
        expect(replied["message"]).to eq("pane 0.1 (%18) is running OpenCode; restart_agent only restarts Claude Code and Codex, whose /clear it types")
      end

      it "reads the context of the pane's agent by its kind and pid" do
        monitor = RecordingRestartMonitor.new(kinds: {"%19" => "codex"}, agent_pids: {"%19" => 4242})
        desk = described_class.new(workspace: "myapp", session_name: "workspace-myapp", pane_details: -> { details },
          monitor: monitor, context_reader: context_reader, registry: registry, runner: runner, pipeline_ref: ->(_index) {})

        desk.handle(restart(pane: "%19"), client)

        expect(context_reader.calls).to eq([[:read, {pane_id: "%19", agent_pid: 4242, current_session_id: nil, kind: "codex"}]])
      end
    end

    describe "a pipeline stage on the pane" do
      let(:pipeline_refs) { {1 => "WC-7"} }

      it "refuses without force, naming the work item" do
        desk.handle(restart, client)

        expect(replied).to include("ok" => false, "error" => "pane_in_pipeline", "pane" => "0.1", "work_item_ref" => "WC-7")
        expect(registry.calls).to be_empty
      end

      it "starts with force, warning that the stage may not finish" do
        desk.handle(restart(force: true), client)

        expect(replied).to include("ok" => true, "status" => "started",
          "warning" => "WC-7 has a pipeline stage running on this pane; it will only finish if the new conversation prints its sentinel")
      end

      it "asks about window 0 only" do
        pipeline_refs[0] = "WC-8"

        desk.handle(restart(pane: "1.0"), client)

        expect(replied).to include("ok" => true, "status" => "started")
        expect(replied).not_to have_key("warning")
      end
    end

    describe "whether a /clear could be confirmed" do
      def desk_reading(reading, kinds: {"%18" => "claude"}, facts: {})
        described_class.new(workspace: "myapp", session_name: "workspace-myapp", pane_details: -> { details },
          monitor: RecordingRestartMonitor.new(kinds: kinds, delivery_facts: facts),
          context_reader: RecordingContextReader.new(reading: reading), registry: registry, runner: runner,
          pipeline_ref: ->(_index) {})
      end

      it "refuses a pane with no confirmable reading, with the reason and a fix" do
        desk_reading({pct: nil, error: Workspace::ContextReasons::NO_PATTERN, updated_at: nil}).handle(restart, client)

        expect(replied).to include("ok" => false, "error" => "context_unknown", "pane" => "0.1",
          "reason" => Workspace::ContextReasons::NO_PATTERN, "fix" => Workspace::ContextReasons.fix_hint("claude"))
        expect(replied["message"]).to end_with("so a /clear couldn't be confirmed; nothing was typed")
      end

      it "lets a Claude pane with no reading yet through, but not a pane of unknown kind" do
        no_reading = {pct: nil, error: Workspace::ContextReasons::NO_READING, updated_at: nil}

        desk_reading(no_reading).handle(restart, client)
        expect(replied).to include("ok" => true, "context_pct" => nil)

        fresh = StringIO.new
        desk_reading(no_reading, kinds: {}).handle(restart(pane: "%19"), fresh)
        expect(JSON.parse(fresh.string)).to include("ok" => false, "error" => "context_unknown",
          "fix" => Workspace::ContextReasons.fix_hint(nil))
      end

      it "lets a pane whose hooks reach the daemon through whatever the reading says" do
        unreadable = {pct: nil, error: Workspace::ContextReasons::NO_PATTERN, updated_at: nil}

        desk_reading(unreadable, facts: {"%18" => {hooks: true}}).handle(restart, client)

        expect(replied).to include("ok" => true, "status" => "started")
      end
    end

    it "refuses a pane another restart already holds" do
      held = RecordingRestartRegistry.new(held: ["%18"])
      desk = described_class.new(workspace: "myapp", session_name: "workspace-myapp", pane_details: -> { details },
        monitor: monitor, context_reader: context_reader, registry: held, runner: runner, pipeline_ref: ->(_index) {})

      desk.handle(restart, client)

      expect(replied).to eq("ok" => false, "error" => "restart_in_progress", "pane" => "0.1",
        "message" => "a restart is already running on pane 0.1")
      expect(held.calls).to eq([[:claim_pending, "%18"]])
    end
  end

  describe ".refusal_before_start" do
    it "refuses a message with no prompt as missing_prompt, and any other as context_unavailable" do
      expect(described_class.refusal_before_start(restart(prompt: nil))).to include("error" => "missing_prompt")
      expect(described_class.refusal_before_start(restart)).to eq("ok" => false, "error" => "context_unavailable",
        "message" => "this agent can't read context usage, so a /clear couldn't be confirmed")
    end
  end
end
