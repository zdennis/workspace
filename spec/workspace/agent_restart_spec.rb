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

  attr_reader :kinds

  def read(pane_id:, agent_pid: nil, current_session_id: nil, kind: nil)
    (@kinds ||= []) << kind
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
  let(:delivery_facts) { ->(id) { @facts_fn&.call(id) } }

  subject(:restart) do
    described_class.new(
      tmux: tmux, context_reader: context_reader, session_name: "workspace-wt-app",
      delivery_lock: Mutex.new,
      pipeline_ref: ->(index) { pipeline_refs[index] },
      pane_state: ->(id) { pane_states[id] },
      delivery_facts: ->(id) { delivery_facts.call(id) },
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

  it "reads by the pane's agent pid too, so readings recorded without $TMUX_PANE confirm the /clear" do
    scripted = [reading(14, session: "old"), reading(nil, session: "new")]
    clock_now = wall
    pid_reader = Object.new
    pid_reader.define_singleton_method(:read) do |pane_id:, agent_pid: nil, current_session_id: nil, kind: nil|
      next {pct: nil, error: Workspace::ContextReasons::NO_READING, updated_at: nil} unless agent_pid == 4242
      ((scripted.size > 1) ? scripted.shift : scripted.first).call(clock_now[0])
    end
    restart = described_class.new(tmux: tmux, context_reader: pid_reader, session_name: "workspace-wt-app",
      delivery_lock: Mutex.new, pipeline_ref: ->(_) {}, agent_pid: ->(id) { (id == "%18") ? 4242 : nil },
      clock: -> { now[0] }, wall_clock: -> { wall[0] },
      sleeper: ->(seconds) {
        now[0] += seconds
        wall[0] += seconds
      },
      quiet_timeout: 10, quiet_for: 1, poll_interval: 0.5)

    result = restart.call(pane_id: "%18", prompt: "Read HANDOFF.md")

    expect(result).to include("ok" => true, "status" => "restarted", "context_before" => 14, "context_after" => nil)
    expect(tmux.delivered.map { |d| d[:text] }).to eq(["/clear", "Read HANDOFF.md"])
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

  context "when the pane's hooks report SessionStart events" do
    let(:stale_reading) { reading(nil, at: Time.utc(2026, 9, 27, 11, 0, 0)) }

    def start_event(source, offset: 0, prompt_offset: nil, hooks: true)
      lambda do |_id|
        next {hooks: hooks} unless tmux.delivered.any?
        {hooks: hooks, last_session_start: {source: source, at: wall[0] + offset},
         last_user_prompt_at: prompt_offset && wall[0] + prompt_offset}
      end
    end

    it "confirms a fresh session whose reading never changes" do
      readings.push(stale_reading)
      @facts_fn = start_event("clear")

      result = call(confirm_timeout: 3)

      expect(result).to include("ok" => true, "status" => "restarted", "context_after" => nil)
      expect(tmux.delivered.map { |d| d[:text] }).to eq(["/clear", "Read HANDOFF.md"])
    end

    it "does not count a SessionStart when a prompt was submitted after the /clear and before it" do
      readings.push(stale_reading)
      @facts_fn = start_event("clear", offset: 1, prompt_offset: 0.5)

      result = call(confirm_timeout: 2)

      expect(result["error"]).to eq("clear_not_confirmed")
      expect(result["message"]).to include("no SessionStart with source clear")
    end

    it "types /clear on a pane whose reading could not confirm it, because its hooks reach the daemon" do
      readings.push({pct: nil, error: Workspace::ContextReasons::NO_PATTERN, updated_at: nil})
      @facts_fn = start_event("clear")

      expect(call(confirm_timeout: 2)).to include("ok" => true, "status" => "restarted")
      expect(tmux.delivered.first[:text]).to eq("/clear")
    end

    it "refuses that pane with no hooks, typing nothing" do
      readings.push({pct: nil, error: Workspace::ContextReasons::NO_PATTERN, updated_at: nil})
      @facts_fn = ->(_id) { {hooks: false} }

      expect(call(confirm_timeout: 2)["error"]).to eq("context_unknown")
      expect(tmux.delivered).to be_empty
    end

    it "does not count a SessionStart from before the /clear" do
      readings.push(stale_reading)
      @facts_fn = start_event("clear", offset: -60)

      result = call(confirm_timeout: 2)

      expect(result["error"]).to eq("clear_not_confirmed")
      expect(tmux.delivered.map { |d| d[:text] }).to eq(["/clear"])
    end

    it "does not count a SessionStart with another source" do
      readings.push(stale_reading)
      @facts_fn = start_event("startup")

      expect(call(confirm_timeout: 2)["error"]).to eq("clear_not_confirmed")
    end
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

  describe "the proof on a moving screen and the last check" do
    let(:kinds) { {"%18" => "claude"} }
    let(:missing) { [nil] }
    let(:screen_refusals) { [nil] }
    let(:bound) { [true] }
    let(:prompt_hook) { [true] }
    let(:moving) { [true] }
    let(:hook_facts) do
      ->(_id) { {hooks: true, last_user_prompt_at: (prompt_hook[0] && tmux.delivered.size >= 2) ? wall[0] : nil} }
    end

    def proven(**overrides)
      described_class.new(tmux: tmux, context_reader: context_reader, session_name: "workspace-wt-app",
        delivery_lock: Mutex.new, pipeline_ref: ->(_) {},
        pane_state: ->(id) { pane_states[id] }, pane_kind: ->(id) { kinds[id] }, delivery_facts: hook_facts,
        turn_over: ->(_id) { missing[0] }, screen_ready: ->(_id) { screen_refusals[0] },
        run_bound: ->(_id, _run) { bound[0] },
        clock: -> { now[0] }, wall_clock: -> { wall[0] },
        sleeper: ->(seconds) {
          now[0] += seconds
          wall[0] += seconds
          @on_tick&.call
        },
        quiet_timeout: 30, quiet_for: 1, poll_interval: 0.5, turn_over_for: 5, prompt_confirm_timeout: 15, **overrides)
    end

    def go(**opts)
      proven.call(pane_id: "%18", prompt: "Read HANDOFF.md", **opts)
    end

    before do
      pane_states["%18"] = "idle"
      frame = 0
      flag = moving
      tmux.define_singleton_method(:capture_screen) { |_| flag[0] ? "frame #{frame += 1}" : "still" }
      readings.push(reading(42, at: wall[0] - 60), reading(3, at: wall[0] + 3600))
    end

    it "accepts a moving screen once the proof has held for TURN_OVER_FOR" do
      result = go

      expect(result).to include("ok" => true, "status" => "restarted")
      expect(tmux.delivered.map { |d| d[:text] }).to eq(["/clear", "Read HANDOFF.md"])
      expect(now[0]).to be_between(5, 8)
    end

    it "starts the hold again when the proof lapses" do
      missing[0] = nil
      @on_tick = -> { missing[0] = now[0].between?(2.9, 3.1) ? "main_tool_after_stop" : nil }

      go

      expect(now[0]).to be >= 8
    end

    {"late main tool" => "main_tool_after_stop", "transcript record" => "transcript_activity:queue-operation", "no hooks" => "no_hooks"}.each do |name, code|
      it "keeps the wait on a #{name} and names it" do
        missing[0] = code

        result = go

        expect(result).to include("ok" => false, "error" => "pane_busy", "reason" => "background_activity")
        expect(result.dig("details", "proof_missing")).to eq(code)
        expect(result["message"]).to include(code)
        expect(tmux.delivered).to be_empty
      end
    end

    it "names a refused screen in proof_missing" do
      screen_refusals[0] = {reason: "input_not_empty", message: "a draft"}

      result = go

      expect(result.dig("details", "proof_missing")).to eq("input_not_empty")
      expect(tmux.delivered).to be_empty
    end

    it "says the proof came too late when the deadline falls inside the hold" do
      missing[0] = "no_stop_seen"
      @on_tick = -> { missing[0] = (now[0] >= 28) ? nil : "no_stop_seen" }

      expect(go.dig("details", "proof_missing")).to eq("proof_too_recent")
    end

    it "keeps a Codex pane on the screen rule" do
      kinds["%18"] = "codex"

      result = go

      expect(result.dig("details", "proof_missing")).to eq("not_claude")
      expect(tmux.delivered).to be_empty
    end

    it "never accepts a pane the monitor reads as working" do
      pane_states["%18"] = "working"

      expect(go).to include("reason" => "working", "details" => {"proof_missing" => "working"})
    end

    it "waits out a spinner at the last check on the bypass path" do
      calls = 0
      restart = proven(screen_ready: lambda { |_id|
        calls += 1
        (calls > 11 && now[0] < 9) ? {reason: "turn_started", message: "a spinner"} : nil
      })

      result = restart.call(pane_id: "%18", prompt: "Read HANDOFF.md")

      expect(result).to include("ok" => true)
      expect(now[0]).to be >= 9
    end

    it "refuses when the spinner outlasts the deadline, and takes the lock only for each check" do
      lock = Mutex.new
      held_during_sleep = false
      calls = 0
      restart = proven(delivery_lock: lock, screen_ready: lambda { |_id|
        calls += 1
        (calls > 11) ? {reason: "turn_started", message: "a spinner"} : nil
      })
      @on_tick = -> { held_during_sleep ||= lock.locked? }

      result = restart.call(pane_id: "%18", prompt: "Read HANDOFF.md")

      expect(result).to include("ok" => false, "error" => "pane_busy", "reason" => "turn_started",
        "details" => {"proof_missing" => "turn_started"})
      expect(tmux.delivered).to be_empty
      expect(now[0]).to be_within(1).of(30)
      expect(held_during_sleep).to be(false)
    end

    it "refuses turn_started when the turn proof lapses at the last check" do
      @on_tick = -> { missing[0] = "main_tool_after_stop" if now[0] >= 5.5 }
      restart = proven(turn_over_for: 5.5)

      expect(restart.call(pane_id: "%18", prompt: "x")).to include("error" => "pane_busy")
      expect(tmux.delivered).to be_empty
    end

    describe "after the last check refuses" do
      let(:draft) { {reason: "input_not_empty", message: "the input holds a draft"} }
      let(:clear_times) { [] }

      before do
        times = clear_times
        clock = now
        original = tmux.method(:deliver)
        tmux.define_singleton_method(:deliver) do |session, target, text|
          times << clock[0] if text == "/clear"
          original.call(session, target, text)
        end
      end

      # A last check that refuses once the wait has passed, until t=9.
      def refusing_last_check
        calls = 0
        ->(refused) { ((calls += 1) > 11 && now[0] < 9) ? refused : nil }
      end

      it "holds QUIET_FOR again after a draft is deleted" do
        moving[0] = false
        screen = ["❯ half a thought"]
        tmux.define_singleton_method(:capture_screen) { |_| screen[0] }
        screen_refusals[0] = draft
        @on_tick = lambda do
          next unless now[0] >= 3
          screen[0] = "❯ "
          screen_refusals[0] = nil
        end

        expect(go).to include("ok" => true)
        expect(clear_times.first).to be >= 4
      end

      it "holds QUIET_FOR again after a submitted draft's turn stops" do
        moving[0] = false
        screen = ["❯ half a thought"]
        tmux.define_singleton_method(:capture_screen) { |_| screen[0] }
        screen_refusals[0] = draft
        @on_tick = lambda do
          next unless now[0] >= 2
          screen_refusals[0] = nil
          pane_states["%18"] = (now[0] < 6) ? "working" : "idle"
          screen[0] = (now[0] < 6) ? "✽ Frosting… (#{now[0]}s)" : "❯ "
        end

        expect(go).to include("ok" => true)
        expect(clear_times.first).to be >= 7
      end

      it "holds TURN_OVER_FOR again after a spinner at the last check" do
        refuse = refusing_last_check
        restart = proven(screen_ready: ->(_id) { refuse.call({reason: "turn_started", message: "a spinner"}) })

        expect(restart.call(pane_id: "%18", prompt: "Read HANDOFF.md")).to include("ok" => true)
        expect(clear_times.first).to be >= 14
      end

      it "holds TURN_OVER_FOR again after the proof lapses at the last check" do
        refuse = refusing_last_check
        restart = proven(turn_over: ->(_id) { refuse.call("main_tool_after_stop") })

        expect(restart.call(pane_id: "%18", prompt: "Read HANDOFF.md")).to include("ok" => true)
        expect(clear_times.first).to be >= 14
      end

      it "warns and needs the prompt hook when the retry was accepted on a moving screen" do
        moving[0] = false
        prompt_hook[0] = false
        screen_refusals[0] = draft
        @on_tick = lambda do
          next unless now[0] >= 2
          moving[0] = true
          screen_refusals[0] = nil
        end

        result = go

        expect(result).to include("ok" => false, "error" => "not_delivered", "reason" => "prompt_unconfirmed")
        expect(result["warning"]).to include("background work")
      end

      it "neither warns nor needs the prompt hook when the retry went in on a still screen" do
        prompt_hook[0] = false
        refuse = refusing_last_check
        @on_tick = -> { moving[0] = false if now[0] >= 6 }
        restart = proven(screen_ready: ->(_id) { refuse.call({reason: "turn_started", message: "a spinner"}) })

        result = restart.call(pane_id: "%18", prompt: "Read HANDOFF.md")

        expect(result).to include("ok" => true)
        expect(result).not_to have_key("warning")
      end

      it "answers pane_gone when the pane closes during the retry's wait" do
        moving[0] = false
        gone = [false]
        tmux.define_singleton_method(:capture_screen) { |_| gone[0] ? nil : "still" }
        screen_refusals[0] = draft
        @on_tick = -> { gone[0] = true if now[0] >= 2 }

        expect(go).to include("ok" => false, "error" => "pane_gone")
        expect(tmux.delivered).to be_empty
      end
    end

    context "on a still screen" do
      before { moving[0] = false }

      it "types as before with an empty box, and warns of nothing" do
        result = go

        expect(result).to include("ok" => true)
        expect(result).not_to have_key("warning")
      end

      it "needs no proof and no prompt hook" do
        missing[0] = "no_stop_seen"
        prompt_hook[0] = false

        expect(go).to include("ok" => true)
      end

      it "refuses a draft with TypingSafety's reason and types nothing" do
        screen_refusals[0] = {reason: "input_not_empty", message: "the input holds a draft"}

        result = go

        expect(result).to include("ok" => false, "error" => "pane_busy", "reason" => "input_not_empty")
        expect(result).not_to have_key("details")
        expect(tmux.delivered).to be_empty
      end

      it "refuses a turn that started during the last check" do
        screen_refusals[0] = {reason: "turn_started", message: "a spinner"}

        expect(go).to include("reason" => "turn_started")
        expect(tmux.delivered).to be_empty
      end

      it "refuses when the monitor turns to working during the last check" do
        tmux.define_singleton_method(:capture_screen) { |_| "still" }
        states = pane_states
        original = tmux.method(:pane_details)
        tmux.define_singleton_method(:pane_details) do |session, window: "0"|
          states["%18"] = "working"
          original.call(session, window: window)
        end

        expect(go).to include("ok" => false, "reason" => "turn_started")
        expect(tmux.delivered).to be_empty
      end

      it "types over a draft on Codex, as it always has" do
        kinds["%18"] = "codex"
        screen_refusals[0] = {reason: "input_not_empty", message: "a draft"}

        expect(go).to include("ok" => true)
      end

      it "types on a pane the monitor has not identified, as it always has" do
        kinds.clear
        screen_refusals[0] = {reason: "unknown", message: "not seen"}

        expect(go).to include("ok" => true)
      end
    end

    it "gives run_unbound with nothing typed when the run is gone before /clear" do
      bound[0] = false

      expect(go(run_id: "wr_1")).to include("ok" => false, "error" => "run_unbound")
      expect(tmux.delivered).to be_empty
    end

    it "gives run_unbound before the prompt when the run goes after /clear" do
      original = tmux.method(:deliver)
      flag = bound
      tmux.define_singleton_method(:deliver) do |*args|
        flag[0] = false
        original.call(*args)
      end

      expect(go(run_id: "wr_1")).to include("ok" => false, "error" => "run_unbound")
      expect(tmux.delivered.map { |d| d[:text] }).to eq(["/clear"])
    end

    it "does not ask about a binding with no run id" do
      bound[0] = false

      expect(go).to include("ok" => true)
    end

    it "reports prompt_unconfirmed when no user_prompt hook comes" do
      prompt_hook[0] = false

      result = go

      expect(result).to include("ok" => false, "error" => "not_delivered", "reason" => "prompt_unconfirmed")
      expect(result["message"]).to include("may still be in the input box")
      expect(result["warning"]).to include("background work")
    end

    it "bounds the prompt wait by the time left to reply to a waiting caller" do
      prompt_hook[0] = false
      restart = proven(reply_timeout: 12)

      restart.call(pane_id: "%18", prompt: "Read HANDOFF.md", waiting: true)

      expect(now[0]).to be <= 11
    end

    it "gives the prompt hook its whole wait when no caller is waiting" do
      prompt_hook[0] = false
      @on_tick = -> { prompt_hook[0] = now[0] >= 18 }
      restart = proven(reply_timeout: 12)

      expect(restart.call(pane_id: "%18", prompt: "Read HANDOFF.md")).to include("ok" => true)
    end

    context "when the reply is already due as the prompt is typed" do
      let(:typed_at) { [] }

      before do
        prompt_hook[0] = false
        @on_tick = -> { typed_at << now[0] if tmux.delivered.size >= 2 && typed_at.empty? }
      end

      it "still waits MIN_PROMPT_CONFIRM for the prompt hook" do
        tick = @on_tick
        @on_tick = lambda do
          tick.call
          prompt_hook[0] = typed_at.any? && now[0] >= typed_at.first + 2.5
        end

        result = proven(reply_timeout: 7).call(pane_id: "%18", prompt: "Read HANDOFF.md", waiting: true)

        expect(result).to include("ok" => true)
      end

      it "gives up on the prompt hook just after MIN_PROMPT_CONFIRM" do
        result = proven(reply_timeout: 7).call(pane_id: "%18", prompt: "Read HANDOFF.md", waiting: true)

        expect(result).to include("reason" => "prompt_unconfirmed")
        expect(now[0] - typed_at.first).to be <= described_class::MIN_PROMPT_CONFIRM
      end
    end

    it "does not count a prompt hook from before the typing" do
      earlier = wall[0]
      prompt_hook[0] = false
      restart = proven(delivery_facts: ->(_id) { {hooks: true, last_user_prompt_at: earlier} })

      expect(restart.call(pane_id: "%18", prompt: "x")).to include("reason" => "prompt_unconfirmed")
    end

    it "joins the background warning and the prompt delivery's own warning" do
      tmux.statuses.push(:submitted, :unverified)

      result = go

      expect(result["warning"]).to start_with("background work in pane %18")
      expect(result["warning"]).to end_with("; fake unverified")
    end
  end

  describe "when the pane never goes quiet" do
    before do
      frame = 0
      tmux.define_singleton_method(:capture_screen) { |_| "⠋ working #{frame += 1}" }
      readings.push(reading(42))
    end

    it "names a possible background job when the agent reads as idle" do
      pane_states["%18"] = "idle"

      result = call

      expect(result).to include("ok" => false, "error" => "pane_busy", "reason" => "background_activity")
      expect(result["message"]).to include("pane %18 reads as idle", "kept changing for 10s", "background sub-agent or shell", "/clear was not typed")
      expect(tmux.delivered).to be_empty
    end

    it "says the state isn't known when the monitor has none" do
      result = call

      expect(result).to include("ok" => false, "error" => "pane_busy", "reason" => "unknown_state")
      expect(result["message"]).to include("kept changing for 10s", "state isn't known")
      expect(tmux.delivered).to be_empty
    end

    it "keeps the working message and gives reason working" do
      pane_states["%18"] = "working"

      result = call

      expect(result).to include("error" => "pane_busy", "reason" => "working")
      expect(result["message"]).to include("was still working within 10s")
    end
  end

  it "does not type /clear into a pane waiting on a person" do
    pane_states["%18"] = "waiting"
    readings.push(reading(42))

    result = call

    expect(result).to include("error" => "pane_busy")
    expect(result).to include("reason" => "waiting")
    expect(result["message"]).to include("is waiting on a person")
    expect(tmux.delivered).to be_empty
  end

  context "when the agent restarts itself (Stop event, screen quiet, idle_after not yet elapsed)" do
    let(:wall_clock_source) { Struct.new(:wall) { def now = wall[0] }.new(wall) }
    let(:session_tmux) { instance_double(Workspace::Tmux, pane_details: [{id: "%18", index: 1, pid: 1, command: "node", cwd: "/p", title: "Claude"}], capture_pane: "output") }
    let(:process_tree) do
      tree = instance_double(Workspace::ProcessTree)
      snap = instance_double(Workspace::ProcessTree::Snapshot)
      allow(tree).to receive(:snapshot).and_return(snap)
      allow(snap).to receive(:find_descendant).and_return({pid: 2, command: "claude", args: "claude"})
      tree
    end
    let(:monitor) do
      Workspace::SessionMonitor.new(tmux: session_tmux, process_tree: process_tree, session_name: "proj",
        idle_after: 600, clock: wall_clock_source)
    end

    subject(:restart) do
      described_class.new(
        tmux: tmux, context_reader: context_reader, session_name: "workspace-wt-app",
        delivery_lock: Mutex.new, pipeline_ref: ->(_) {},
        pane_state: ->(id) { monitor.restart_state(id) },
        clock: -> { now[0] }, wall_clock: -> { wall[0] },
        sleeper: ->(seconds) {
          now[0] += seconds
          wall[0] += seconds
        },
        quiet_timeout: 120, quiet_for: 2, poll_interval: 0.5
      )
    end

    it "types /clear once the screen has been quiet, long before the timeout" do
      monitor.scan
      monitor.record("pane_id" => "%18", "event" => "user_prompt")
      monitor.record("pane_id" => "%18", "event" => "stop")
      expect(monitor.pane_state("%18")).to eq("working")
      readings.push(reading(42), reading(42), reading(42), reading(3))

      result = call

      expect(result).to include("ok" => true, "status" => "restarted")
      expect(now[0]).to be < 10
      expect(tmux.delivered.map { |d| d[:text] }).to eq(["/clear", "Read HANDOFF.md"])
    end

    it "still refuses while the turn is running and the pane is within idle_after" do
      monitor.scan
      monitor.record("pane_id" => "%18", "event" => "user_prompt")
      readings.push(reading(42))

      result = call

      expect(result).to include("ok" => false, "error" => "pane_busy")
      expect(tmux.delivered).to be_empty
    end
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

  context "when the pane runs Codex" do
    let(:kinds_by_pane) { {"%18" => "codex"} }
    subject(:restart) do
      described_class.new(
        tmux: tmux, context_reader: context_reader, session_name: "workspace-wt-app",
        delivery_lock: Mutex.new, pipeline_ref: ->(_) {}, pane_kind: ->(id) { kinds_by_pane[id] },
        clock: -> { now[0] }, wall_clock: -> { wall[0] },
        sleeper: ->(seconds) {
          now[0] += seconds
          wall[0] += seconds
        },
        quiet_timeout: 10, quiet_for: 1, poll_interval: 0.5
      )
    end

    it "reads the pane by its kind, types /clear, and confirms from usage that dropped" do
      readings.push(reading(60), reading(60), reading(60), reading(2))

      result = call

      expect(result).to include("ok" => true, "status" => "restarted", "context_before" => 60, "context_after" => 2)
      expect(context_reader.kinds.uniq).to eq(["codex"])
      expect(tmux.delivered.map { |d| d[:text] }).to eq(["/clear", "Read HANDOFF.md"])
    end

    it "does not type the prompt while usage stays where it was" do
      readings.push(reading(60))

      expect(call(confirm_timeout: 2)).to include("ok" => false, "error" => "clear_not_confirmed")
      expect(tmux.delivered.map { |d| d[:text] }).to eq(["/clear"])
    end
  end

  it "reads with no kind when the pane has none, and still types /clear" do
    readings.push(reading(42), reading(42), reading(42), reading(3))

    call

    expect(context_reader.kinds.uniq).to eq([nil])
    expect(tmux.delivered.first[:text]).to eq("/clear")
  end
end
