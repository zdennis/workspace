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

  def reading(pct, at: nil, session: nil)
    ->(wall_now) { {pct: pct, error: nil, updated_at: (at || wall_now).utc.iso8601, session_id: session} }
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
    expect(result["message"]).to include("no status-line reading from a new conversation", "within 3s",
      "before: 42%", "the prompt was not sent")
    expect(tmux.delivered.map { |d| d[:text] }).to eq(["/clear"])
  end

  it "does not count a low reading recorded before the /clear" do
    stale = Time.utc(2026, 9, 27, 11, 0, 0)
    readings.push(reading(42), ->(_) { {pct: 1, error: nil, updated_at: stale.iso8601} })

    result = call(confirm_timeout: 2)

    expect(result["error"]).to eq("clear_not_confirmed")
    expect(result["message"]).to include("last reading: 1% at #{stale.iso8601}")
  end

  context "when the readings carry a session id" do
    it "confirms from a new session's reading with no usage yet, as Claude renders right after /clear" do
      readings.push(reading(42, session: "old"), reading(nil, session: "new"))

      result = call

      expect(result).to include("ok" => true, "context_before" => 42, "context_after" => nil)
      expect(tmux.delivered.map { |d| d[:text] }).to eq(["/clear", "Read HANDOFF.md"])
    end

    it "confirms from a new session even at the same usage" do
      readings.push(reading(0, session: "old"), reading(0, session: "new"))

      expect(call).to include("ok" => true, "context_after" => 0)
    end

    it "does not count a lower reading from the same session" do
      readings.push(reading(42, session: "old"), reading(3, session: "old"))

      result = call(confirm_timeout: 2)

      expect(result["error"]).to eq("clear_not_confirmed")
      expect(result["message"]).to include("session old")
      expect(tmux.delivered.map { |d| d[:text] }).to eq(["/clear"])
    end

    it "does not count a new session's reading from the same second as the /clear" do
      readings.push(reading(42, session: "old"),
        ->(wall_now) { {pct: nil, error: nil, updated_at: Time.at(wall_now.to_i).utc.iso8601, session_id: "new"} })
      frozen = wall[0]

      result = described_class.new(
        tmux: tmux, context_reader: context_reader, session_name: "workspace-wt-app",
        delivery_lock: Mutex.new, pipeline_ref: ->(_) {}, pane_state: ->(_) {},
        clock: -> { now[0] }, wall_clock: -> { frozen },
        sleeper: ->(seconds) { now[0] += seconds },
        quiet_timeout: 10, quiet_for: 1, poll_interval: 0.5
      ).call(pane_id: "%18", prompt: "Read HANDOFF.md", confirm_timeout: 2)

      expect(result["error"]).to eq("clear_not_confirmed")
    end
  end

  it "without a session id, confirms from a fresh reading with no usage" do
    readings.push(reading(0), reading(nil))

    expect(call).to include("ok" => true, "context_after" => nil)
  end

  it "without a session id, does not count an unchanged 0%" do
    readings.push(reading(0))

    expect(call(confirm_timeout: 2)).to include("error" => "clear_not_confirmed")
  end

  it "refuses without typing anything when no reading could ever confirm the /clear" do
    readings.push({pct: nil, error: Workspace::ContextReasons::NO_PATTERN, updated_at: nil})

    result = call

    expect(result).to include("ok" => false, "error" => "context_unknown")
    expect(result["message"]).to include(Workspace::ContextReasons::NO_PATTERN, "nothing was typed")
    expect(tmux.delivered).to be_empty
  end

  context "when the pane's usage isn't known before the /clear" do
    it "restarts a freshly cleared pane once a different session reports" do
      readings.push(->(w) { {pct: nil, error: Workspace::ContextReasons::NO_READING_YET, updated_at: w.utc.iso8601, session_id: "s-1"} },
        reading(nil, session: "s-1"), reading(nil, session: "s-2"))

      expect(call).to include("ok" => true, "context_before" => nil, "context_after" => nil)
      expect(tmux.delivered.map { |d| d[:text] }).to eq(["/clear", "Read HANDOFF.md"])
    end

    it "does not confirm from the same session's later render" do
      readings.push(->(w) { {pct: nil, error: Workspace::ContextReasons::NO_READING_YET, updated_at: w.utc.iso8601, session_id: "s-1"} },
        reading(nil, session: "s-1"))

      expect(call(confirm_timeout: 2)).to include("error" => "clear_not_confirmed")
      expect(tmux.delivered.map { |d| d[:text] }).to eq(["/clear"])
    end

    it "with no reading at all, confirms from the first reading with no usage recorded after the /clear" do
      readings.push({pct: nil, error: Workspace::ContextReasons::NO_READING, updated_at: nil},
        {pct: nil, error: Workspace::ContextReasons::NO_READING, updated_at: nil}, reading(nil, session: "s-2"))

      expect(call).to include("ok" => true, "context_before" => nil, "context_after" => nil)
    end

    it "with no reading at all, does not confirm from a reading that shows usage" do
      readings.push({pct: nil, error: Workspace::ContextReasons::NO_READING, updated_at: nil}, reading(40, session: "s-2"))

      expect(call(confirm_timeout: 2)).to include("error" => "clear_not_confirmed")
      expect(tmux.delivered.map { |d| d[:text] }).to eq(["/clear"])
    end
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

  context "when a pipeline stage starts on the pane before /clear is typed" do
    before do
      readings.push(reading(42), reading(1))
      pipeline_refs[1] = "WC-7"
    end

    it "types nothing" do
      result = call

      expect(result).to include("ok" => false, "error" => "pane_in_pipeline")
      expect(result["message"]).to include("WC-7", "/clear was not typed")
      expect(tmux.delivered).to be_empty
    end

    it "types both anyway with force" do
      expect(call(force: true)).to include("ok" => true)
      expect(tmux.delivered.map { |d| d[:text] }).to eq(["/clear", "Read HANDOFF.md"])
    end
  end

  it "does not type the prompt when a pipeline stage starts after /clear" do
    readings.push(reading(42), ->(wall_now) {
      pipeline_refs[1] = "WC-7"
      {pct: 1, error: nil, updated_at: wall_now.utc.iso8601}
    })

    result = call

    expect(result).to include("ok" => false, "error" => "pane_in_pipeline")
    expect(result["message"]).to include("WC-7", "the prompt was not typed")
    expect(tmux.delivered.map { |d| d[:text] }).to eq(["/clear"])
  end

  it "does not type /clear while the session monitor says the agent is working" do
    pane_states["%18"] = "working"
    readings.push(reading(42))

    result = call

    expect(result).to include("ok" => false, "error" => "pane_busy")
    expect(result["message"]).to include("was still working")
    expect(tmux.delivered).to be_empty
  end

  it "reports whether /clear was typed" do
    readings.push(reading(42), reading(1))

    expect { call }.to change(restart, :cleared?).from(false).to(true)
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
