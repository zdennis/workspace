require "spec_helper"
require "tmpdir"

RSpec.describe Workspace::AgentStatusDesk do
  let(:prompt_screen) { "────────────────────\n❯ \n" }

  let(:tmux) do
    Class.new do
      attr_accessor :details, :statuses
      attr_reader :delivered

      def initialize(screen)
        @details = [{id: "%5", window: 0, index: 1, pid: 100}, {id: "%6", window: 0, index: 2, pid: 200}]
        @screen = screen
        @screens = [screen]
        @statuses = []
        @delivered = []
      end

      def pane_details(_session, window: "0")
        raise ArgumentError, "expected every window" unless window.nil?
        @details
      end

      # Scripted screens are shown as given; otherwise a paste shows in the
      # input line and Enter empties it again.
      def screens=(list)
        @scripted = true
        @screens = list
      end

      def capture_screen(_pane_id) = (@screens.size > 1) ? @screens.shift : @screens.first

      def capture_screen_styled(pane_id) = capture_screen(pane_id)

      def deliver(session, target, text, enter: true)
        @delivered << [session, target, text, enter]
        @screens = [enter ? @screen : "────────────────────\n❯ #{text}\n"] unless @scripted
        status = @statuses.shift || (enter ? :submitted : :pasted)
        Workspace::Tmux::Delivery.new(status: status, message: "fake #{status}")
      end
    end.new(prompt_screen)
  end

  let(:facts) { {"%5" => {kind: "claude", state: "idle", open_tools: []}, "%6" => {kind: "claude", state: "idle", open_tools: []}} }
  let(:monitor) { double("monitor").tap { |m| allow(m).to receive(:typing_facts) { |id| facts[id] } } }
  let(:events_dir) { Dir.mktmpdir }
  let(:hook_log) { Workspace::HookEventLog.new(dir: events_dir, workspace: "api", boot_id: "BOOT") }
  let(:now) { [Time.utc(2026, 10, 17, 22, 0, 0)] }
  let(:requests) { Workspace::AgentStatusRequests.new(clock: -> { now[0] }, id_generator: -> { "sr-abc" }) }

  subject(:desk) do
    described_class.new(tmux: tmux, session_name: "api", workspace: "api", session_monitor: monitor,
      hook_event_log: hook_log, delivery_lock: Mutex.new, requests: requests)
  end

  after { FileUtils.remove_entry(events_dir) }

  def lines = File.readlines(File.join(events_dir, "api.jsonl")).map { |l| JSON.parse(l) }

  describe "#request" do
    it "types the fixed line carrying the request id and returns the id" do
      reply = desk.request("pane_id" => "%5")

      expect(reply).to eq("ok" => true, "request_id" => "sr-abc", "expires_at" => "2026-10-17T22:10:00Z",
        "delivery" => "submitted", "pane" => "0.1", "pane_id" => "%5")
      expect(tmux.delivered).to eq([["api", "0.1", described_class.prompt_for("sr-abc"), false], ["api", "0.1", "", true]])
      expect(described_class.prompt_for("sr-abc")).to include("workspace agent status post --reply-to sr-abc --summary")
    end

    context "while a restart or a --clear-first prompt holds the pane" do
      let(:held) { ["%5"] }

      subject(:desk) do
        described_class.new(tmux: tmux, session_name: "api", workspace: "api", session_monitor: monitor,
          hook_event_log: hook_log, delivery_lock: Mutex.new, requests: requests, restarting: ->(id) { held.include?(id) })
      end

      it "refuses restart_in_progress, typing and opening nothing" do
        reply = desk.request("pane_id" => "%5")

        expect(reply).to include("ok" => false, "error" => "restart_in_progress", "pane_id" => "%5")
        expect(tmux.delivered).to be_empty
        expect(requests.claim("sr-abc", pane_id: "%5", pane_pid: 100).first).to eq("status_request_unknown")
      end

      it "refuses when the hold starts after the first check, under the delivery lock" do
        held.clear
        allow(monitor).to receive(:typing_facts) do |id|
          held << id
          facts[id]
        end

        expect(desk.request("pane_id" => "%5")).to include("error" => "restart_in_progress")
        expect(tmux.delivered).to be_empty
      end
    end

    it "refuses a pane that isn't in the session" do
      expect(desk.request("pane_id" => "%9")).to include("ok" => false, "error" => "no_such_pane")
      expect(tmux.delivered).to be_empty
    end

    it "types nothing and opens nothing when the pane can't take text" do
      facts["%5"] = {kind: "claude", state: "waiting", open_tools: []}

      reply = desk.request("pane_id" => "%5")

      expect(reply).to include("ok" => false, "error" => "pane_not_ready", "reason" => "waiting", "pane_id" => "%5")
      expect(tmux.delivered).to be_empty
      facts["%5"] = {kind: "claude", state: "idle", open_tools: []}
      expect(desk.request("pane_id" => "%5")).to include("ok" => true)
    end

    it "checks again just before typing, with a fresh screen" do
      tmux.screens = [prompt_screen, "│ ❯ 1. Yes\n"]

      reply = desk.request("pane_id" => "%5")

      expect(reply).to include("ok" => false, "error" => "pane_not_ready", "reason" => "no_input_prompt")
      expect(tmux.delivered).to be_empty
      expect(requests.claim("sr-abc", pane_id: "%5", pane_pid: 100).first).to eq("status_request_unknown")
    end

    it "refuses a second request to a pane with one open, naming it, and types once" do
      desk.request("pane_id" => "%5")

      reply = desk.request("pane_id" => "%5")

      expect(reply).to include("ok" => false, "error" => "status_request_open", "request_id" => "sr-abc",
        "expires_at" => "2026-10-17T22:10:00Z")
      expect(tmux.delivered.map { |d| d[2] }).to eq([described_class.prompt_for("sr-abc"), ""])
    end

    it "drops the request when the line never reached the pane" do
      tmux.statuses = [:failed]

      expect(desk.request("pane_id" => "%5")).to include("ok" => false, "error" => "not_delivered")
      expect(requests.claim("sr-abc", pane_id: "%5", pane_pid: 100).first).to eq("status_request_unknown")
    end

    it "keeps the request open when the line landed but wasn't confirmed submitted" do
      tmux.statuses = [:pasted, :unsubmitted]

      reply = desk.request("pane_id" => "%5")

      expect(reply).to include("ok" => false, "error" => "not_submitted", "request_id" => "sr-abc", "delivery" => "unsubmitted")
      expect(requests.claim("sr-abc", pane_id: "%5", pane_pid: 100).first).to be_nil
    end

    it "doesn't press Enter when the paste may not have arrived, and keeps the request open" do
      tmux.statuses = [:unverified]

      expect(desk.request("pane_id" => "%5")).to include("ok" => false, "error" => "not_submitted", "delivery" => "unverified")
      expect(tmux.delivered.size).to eq(1)
      expect(requests.claim("sr-abc", pane_id: "%5", pane_pid: 100).first).to be_nil
    end

    it "doesn't press Enter when a dialog opened while the line was pasted" do
      tmux.screens = [prompt_screen, prompt_screen, "│ ❯ 1. Yes\n"]

      reply = desk.request("pane_id" => "%5")

      expect(reply).to include("ok" => false, "error" => "not_submitted", "reason" => "no_input_prompt", "request_id" => "sr-abc")
      expect(tmux.delivered.map(&:last)).to eq([false])
    end

    it "refuses a pane whose input line holds a draft" do
      tmux.screens = ["────────────────────\n❯ half a thought\n"]

      expect(desk.request("pane_id" => "%5")).to include("ok" => false, "error" => "pane_not_ready", "reason" => "input_not_empty")
      expect(tmux.delivered).to be_empty
    end

    it "drops the request when typing raises, so the pane isn't refused for the request's lifetime" do
      allow(tmux).to receive(:deliver).and_raise(IOError, "tmux went away")

      expect { desk.request("pane_id" => "%5") }.to raise_error(IOError)
      expect(requests.claim("sr-abc", pane_id: "%5", pane_pid: 100).first).to eq("status_request_unknown")
    end

    it "types nothing when the pane was replaced while the request opened" do
      allow(requests).to receive(:open).and_wrap_original do |original, **args|
        result = original.call(**args)
        tmux.details = [{id: "%5", window: 0, index: 1, pid: 999}]
        result
      end

      expect(desk.request("pane_id" => "%5")).to include("ok" => false, "error" => "no_such_pane")
      expect(tmux.delivered).to be_empty
    end
  end

  describe "#post" do
    it "writes an agent_status line and returns it" do
      reply = desk.post("pane_id" => "%5", "summary" => "Writing\nspecs\e[31m", "task" => "T3", "progress" => {"done" => 3, "total" => 7})

      expect(reply).to include("ok" => true, "truncated" => false, "pane_id" => "%5", "workspace" => "api",
        "boot_id" => "BOOT", "seq" => 1, "summary" => "Writing specs [31m", "task" => "T3",
        "progress" => {"done" => 3, "total" => 7}, "reply_to" => nil)
      expect(lines.map { |l| l.values_at("type", "pane_id", "summary") }).to eq([["agent_status", "%5", "Writing specs [31m"]])
    end

    it "turns bidi overrides, zero-width and line separators into spaces, in the summary and the task" do
      reply = desk.post("pane_id" => "%5", "summary" => "a‮b​c d", "task" => "⁦T3\tx⁩")

      expect(reply.values_at("summary", "task")).to eq(["a b c d", "T3 x"])
    end

    it "cuts a long summary and says so" do
      reply = desk.post("pane_id" => "%5", "summary" => "x" * 600)

      expect(reply).to include("ok" => true, "truncated" => true)
      expect(lines.first["summary"].length).to eq(500)
    end

    it "refuses an empty summary or bad progress" do
      expect(desk.post("pane_id" => "%5", "summary" => " \n ")).to include("error" => "usage")
      expect(desk.post("pane_id" => "%5", "summary" => "ok", "progress" => {"done" => 4, "total" => 3})).to include("error" => "usage")
      expect(File.exist?(File.join(events_dir, "api.jsonl"))).to be false
    end

    it "closes the request it answers, from the pane that was asked" do
      desk.request("pane_id" => "%5")

      expect(desk.post("pane_id" => "%5", "summary" => "ok", "reply_to" => "sr-abc")).to include("ok" => true, "reply_to" => "sr-abc")
      expect(desk.post("pane_id" => "%5", "summary" => "again", "reply_to" => "sr-abc")).to include("error" => "status_request_unknown")
      expect(lines.size).to eq(1)
    end

    it "refuses a reply from another pane, logs nothing, and leaves the request open" do
      desk.request("pane_id" => "%5")

      expect(desk.post("pane_id" => "%6", "summary" => "ok", "reply_to" => "sr-abc"))
        .to include("ok" => false, "error" => "status_reply_wrong_pane", "request_id" => "sr-abc")
      expect(File.exist?(File.join(events_dir, "api.jsonl"))).to be false
      expect(desk.post("pane_id" => "%5", "summary" => "ok", "reply_to" => "sr-abc")).to include("ok" => true)
    end

    it "refuses a reply from a reused pane id" do
      desk.request("pane_id" => "%5")
      tmux.details = [{id: "%5", window: 0, index: 1, pid: 4242}]

      expect(desk.post("pane_id" => "%5", "summary" => "ok", "reply_to" => "sr-abc")).to include("error" => "status_request_stale")
    end

    it "refuses an expired request" do
      desk.request("pane_id" => "%5")
      now[0] += Workspace::AgentStatusRequests::DEFAULT_TTL

      expect(desk.post("pane_id" => "%5", "summary" => "ok", "reply_to" => "sr-abc")).to include("error" => "status_request_expired")
    end

    it "says the line wasn't logged when the daemon has no hook event log, and keeps the request open" do
      desk.request("pane_id" => "%5")
      unlogged = described_class.new(tmux: tmux, session_name: "api", workspace: "api", session_monitor: monitor,
        hook_event_log: nil, delivery_lock: Mutex.new, requests: requests)

      expect(unlogged.post("pane_id" => "%5", "summary" => "ok", "reply_to" => "sr-abc")).to include("error" => "status_not_logged")
      expect(requests.claim("sr-abc", pane_id: "%5", pane_pid: 100).first).to be_nil
    end
  end
end
