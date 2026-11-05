require "spec_helper"
require "tmpdir"

class StatuslineRestartTmux
  attr_reader :delivered

  def initialize(on_clear)
    @on_clear = on_clear
    @delivered = []
  end

  def capture_screen(_target) = "❯ "

  def pane_details(_session, window: "0") = [{id: "%18", window: 0, index: 1}]

  def deliver(_session, _target, text)
    @delivered << text
    @on_clear.call(text) if text == Workspace::AgentRestart::CLEAR_COMMAND
    Workspace::Tmux::Delivery.new(status: :submitted, message: "fake")
  end
end

# A restart against the real store and reader, with the status line's
# writes scripted to land when /clear is typed. Claude re-renders within a
# second of /clear, so the new conversation's first reading is often
# stamped in the same whole second as the /clear itself.
RSpec.describe Workspace::AgentRestart, "with the status-line store" do
  let(:dir) { Dir.mktmpdir("ws-restart-store", "/tmp") }
  let(:store) { Workspace::ContextStore.new(path: File.join(dir, "context.json")) }
  let(:reader) do
    Workspace::ContextReader.new(context_store: store,
      project_settings: instance_double(Workspace::ProjectSettings, load_global: {}))
  end
  let(:cleared_at) { Time.utc(2026, 9, 27, 12, 0, 0.2r) }
  let(:wall) { [cleared_at] }
  let(:now) { [0.0] }
  let(:on_clear) { ->(_tmux) {} }
  let(:tmux) do
    StatuslineRestartTmux.new(on_clear)
  end

  after { FileUtils.remove_entry(dir) }

  subject(:result) do
    described_class.new(
      tmux: tmux, context_reader: reader, session_name: "workspace-wt-app",
      delivery_lock: Mutex.new, pipeline_ref: ->(_) {}, pane_state: ->(_) {},
      clock: -> { now[0] }, wall_clock: -> { wall[0] },
      sleeper: ->(seconds) { now[0] += seconds },
      quiet_timeout: 10, quiet_for: 1, poll_interval: 0.5
    ).call(pane_id: "%18", prompt: "Read HANDOFF.md", confirm_timeout: 2)
  end

  def record(pct, session, at)
    store.record(pct: pct, pane_id: "%18", session_id: session, recorded_at: at)
  end

  before do
    record(42, "old", Time.utc(2026, 9, 27, 11, 59, 50))
  end

  context "when the new conversation's first render lands later in the /clear's second" do
    let(:on_clear) { ->(_) { record(nil, "new", cleared_at + 0.5) } }

    it "confirms the clear and types the prompt" do
      expect(result).to include("ok" => true, "status" => "restarted", "context_before" => 42, "context_after" => nil)
      expect(tmux.delivered).to eq(["/clear", "Read HANDOFF.md"])
    end
  end

  context "when a reading was stamped before the /clear, even in the same second" do
    let(:on_clear) { ->(_) { record(nil, "new", cleared_at - 0.1) } }

    it "does not confirm, and the prompt is not typed" do
      expect(result).to include("ok" => false, "error" => "clear_not_confirmed")
      expect(tmux.delivered).to eq(["/clear"])
    end
  end

  context "when the pane was itself just cleared, with no usage reported yet" do
    before { record(nil, "old", Time.utc(2026, 9, 27, 11, 59, 55)) }

    let(:on_clear) { ->(_) { record(nil, "new", cleared_at + 0.3) } }

    it "restarts it, confirming from the next session's reading" do
      expect(result).to include("ok" => true, "context_before" => nil, "context_after" => nil)
      expect(tmux.delivered).to eq(["/clear", "Read HANDOFF.md"])
    end
  end
end
