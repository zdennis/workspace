require "spec_helper"

# A pane whose screen stays put unless a spec scripts it, and whose
# deliveries are recorded. Time moves only when the restart sleeps.
class RestartFakeTmux
  attr_accessor :screens, :details, :statuses
  attr_reader :delivered

  def initialize
    @screens = ["❯ "]
    @details = [{id: "%18", window: 0, index: 1}]
    @statuses = []
    @delivered = []
  end

  def capture_screen(_target)
    (@screens.size > 1) ? @screens.shift : @screens.first
  end

  def pane_details(_session, window: "0")
    raise ArgumentError, "expected every window" unless window.nil?
    @details
  end

  def deliver(session, target, text)
    @delivered << {session: session, target: target, text: text}
    status = @statuses.shift || :submitted
    Workspace::Tmux::Delivery.new(status: status, message: "fake #{status}")
  end
end

# Readings come from a script; the last one repeats. Each carries the
# time it was recorded, relative to the wall clock.
class RestartFakeContextReader
  def initialize(wall, readings)
    @wall = wall
    @readings = readings
  end

  def read(pane_id:, agent_pid: nil, current_session_id: nil)
    reading = (@readings.size > 1) ? @readings.shift : @readings.first
    reading.is_a?(Proc) ? reading.call(@wall[0]) : reading
  end
end

RSpec.describe Workspace::AgentRestart do
  let(:now) { [0.0] }
  let(:wall) { [Time.utc(2026, 9, 27, 12, 0, 0)] }
  let(:tmux) { RestartFakeTmux.new }
  let(:pipeline_refs) { {} }
  let(:pane_states) { {} }
  let(:readings) { [] }
  let(:context_reader) { RestartFakeContextReader.new(wall, readings) }

  subject(:restart) do
    described_class.new(
      tmux: tmux, context_reader: context_reader, session_name: "workspace-wt-app",
      delivery_lock: Mutex.new,
      pipeline_ref: ->(index) { pipeline_refs[index] },
      pane_state: ->(id) { pane_states[id] },
      clock: -> { now[0] },
      wall_clock: -> { wall[0] },
      sleeper: ->(seconds) {
        now[0] += seconds
        wall[0] += seconds
      },
      quiet_timeout: 10, quiet_for: 1, poll_interval: 0.5
    )
  end

  def reading(pct, at: nil)
    ->(wall_now) { {pct: pct, error: nil, updated_at: (at || wall_now).utc.iso8601} }
  end

  def call(**opts)
    restart.call(pane_id: "%18", prompt: "Read HANDOFF.md", **opts)
  end

  it "types /clear, waits for usage to drop, then types the prompt" do
    readings.push(reading(42), reading(42), reading(42), reading(3))

    result = call

    expect(result).to include("ok" => true, "status" => "restarted", "pane_id" => "%18",
      "context_before" => 42, "context_after" => 3, "delivery" => "submitted")
    expect(tmux.delivered).to eq([
      {session: "workspace-wt-app", target: "0.1", text: "/clear"},
      {session: "workspace-wt-app", target: "0.1", text: "Read HANDOFF.md"}
    ])
  end

  it "does not type the prompt when usage never drops, and says so" do
    readings.push(reading(42))

    result = call(confirm_timeout: 3)

    expect(result).to include("ok" => false, "error" => "clear_not_confirmed")
    expect(result["message"]).to include("did not drop below 42%", "within 3s", "the prompt was not sent")
    expect(tmux.delivered.map { |d| d[:text] }).to eq(["/clear"])
  end

  it "does not count a low reading recorded before the /clear" do
    stale = Time.utc(2026, 9, 27, 11, 0, 0)
    readings.push(reading(42), ->(_) { {pct: 1, error: nil, updated_at: stale.iso8601} })

    result = call(confirm_timeout: 2)

    expect(result["error"]).to eq("clear_not_confirmed")
    expect(result["message"]).to include("last reading: 1% at #{stale.iso8601}")
  end

  it "counts a fresh reading of 0% as dropped even from a 0% baseline" do
    readings.push(reading(0), reading(0))

    expect(call).to include("ok" => true, "context_after" => 0)
  end

  it "refuses without typing anything when usage can't be read" do
    readings.push({pct: nil, error: Workspace::ContextReasons::NO_READING, updated_at: nil})

    result = call

    expect(result).to include("ok" => false, "error" => "context_unknown")
    expect(result["message"]).to include(Workspace::ContextReasons::NO_READING, "nothing was typed")
    expect(tmux.delivered).to be_empty
  end

  it "waits for the screen to stop changing before typing /clear" do
    tmux.screens = ["⠋ working", "⠙ working", "⠹ working", "❯ "]
    readings.push(reading(42), reading(42), reading(5))

    call

    # Three changing reads, then QUIET_FOR (1s) of the same screen.
    expect(now[0]).to be >= 2.5
    expect(tmux.delivered.first[:text]).to eq("/clear")
  end

  it "gives up without typing when the pane never goes quiet" do
    frame = 0
    tmux.define_singleton_method(:capture_screen) { |_| "⠋ working #{frame += 1}" }
    readings.push(reading(42))

    result = call

    expect(result).to include("ok" => false, "error" => "pane_busy")
    expect(result["message"]).to include("never stopped changing within 10s")
    expect(tmux.delivered).to be_empty
  end

  it "does not type /clear into a pane waiting on a person" do
    pane_states["%18"] = "waiting"
    readings.push(reading(42))

    result = call

    expect(result).to include("error" => "pane_busy")
    expect(result["message"]).to include("is waiting on a person")
    expect(tmux.delivered).to be_empty
  end

  it "reports a pane that is gone before anything is typed" do
    tmux.define_singleton_method(:capture_screen) { |_| nil }

    expect(call).to include("ok" => false, "error" => "pane_gone")
  end

  it "types into the pane's current window.index when the index moved" do
    readings.push(reading(42), reading(2))
    tmux.details = [{id: "%9", window: 0, index: 0}, {id: "%18", window: 0, index: 3}]

    call

    expect(tmux.delivered.map { |d| d[:target] }.uniq).to eq(["0.3"])
  end

  it "reports /clear that never reached the pane" do
    readings.push(reading(42))
    tmux.statuses = [:failed]

    result = call

    expect(result).to include("ok" => false, "error" => "not_delivered")
    expect(result["message"]).to include("/clear was not typed")
    expect(tmux.delivered.size).to eq(1)
  end

  it "warns when the prompt may not have been submitted" do
    readings.push(reading(42), reading(1))
    tmux.statuses = [:submitted, :unsubmitted]

    result = call

    expect(result).to include("ok" => true, "delivery" => "unsubmitted", "warning" => "fake unsubmitted")
  end

  context "when a pipeline stage starts on the pane during the restart" do
    before do
      readings.push(reading(42), reading(1))
      pipeline_refs[1] = "WC-7"
    end

    it "does not type the prompt" do
      result = call

      expect(result).to include("ok" => false, "error" => "pane_in_pipeline")
      expect(result["message"]).to include("WC-7")
      expect(tmux.delivered.map { |d| d[:text] }).to eq(["/clear"])
    end

    it "types it anyway with force" do
      expect(call(force: true)).to include("ok" => true)
      expect(tmux.delivered.map { |d| d[:text] }).to eq(["/clear", "Read HANDOFF.md"])
    end
  end

  it "reports a pane that closed between /clear and the prompt" do
    readings.push(reading(42), ->(wall_now) {
      tmux.details = []
      {pct: 1, error: nil, updated_at: wall_now.utc.iso8601}
    })

    result = call

    expect(result).to include("ok" => false, "error" => "pane_gone")
    expect(result["message"]).to include("the prompt was not typed")
  end
end
