require "stringio"

RSpec.describe Workspace::Commands::WaitUntilContent do
  subject(:command) do
    described_class.new(tmux: tmux, output: output, error_output: error_output,
      sleeper: sleeper, exec_handler: exec_handler, clock: clock,
      spinner_enabled: false)
  end

  let(:tmux) { double("tmux") }
  let(:output) { StringIO.new }
  let(:error_output) { StringIO.new }
  let(:sleep_calls) { [] }
  let(:sleeper) { ->(seconds) { sleep_calls << seconds } }
  let(:exec_calls) { [] }
  let(:exec_handler) { ->(cmd, out, err) { exec_calls << [cmd, out, err] } }
  # Advances 1s per call so max_wait_time tests terminate deterministically.
  let(:clock) do
    counter = 0
    -> { counter += 1 }
  end
  let(:pane_details) do
    [
      {id: "%10", window: 0, index: 0},
      {id: "%11", window: 0, index: 1},
      {id: "%12", window: 0, index: 2}
    ]
  end

  before do
    allow(tmux).to receive(:session_name_for).with("myproject").and_return("myproject")
    allow(tmux).to receive(:sessions).and_return(["myproject"])
    allow(tmux).to receive(:panes).with("myproject", window: "0").and_return([0, 1, 2])
    allow(tmux).to receive(:pane_details).and_return(pane_details)
    allow(tmux).to receive(:capture_pane_by_id).and_return("some output\n")
  end

  describe "preflight" do
    it "raises when no tmux session exists for the project" do
      allow(tmux).to receive(:sessions).and_return([])
      expect { command.call("myproject", "READY") }
        .to raise_error(Workspace::Error, /No active tmux session for 'myproject'/)
    end

    it "raises a TmuxPane error when the pane cannot be found" do
      expect { command.call("myproject", "READY", pane: 9) }
        .to raise_error(Workspace::Error, /Pane 9 does not exist/)
    end
  end

  describe "matching" do
    it "matches immediately and returns 0" do
      allow(tmux).to receive(:capture_pane_by_id).and_return("booting...\nREADY\n")
      status = command.call("myproject", "READY", exec_command: ["irb"])
      expect(status).to eq(0)
      expect(output.string).to include("✓ Matched")
      expect(output.string).to include("▶ Executing irb")
      expect(exec_calls.length).to eq(1)
      expect(exec_calls.first[0]).to eq(["irb"])
      expect(exec_calls.first[1]).to eq(output)
      expect(exec_calls.first[2]).to eq(error_output)
    end

    it "anchors to the pane id resolved at start and re-resolves by that id every poll" do
      allow(tmux).to receive(:capture_pane_by_id).and_return("a", "b", "READY")
      command.call("myproject", "READY", pane: 1)
      # One preflight resolve_id lookup (pane %11) plus one pane-details
      # re-resolve per poll: 3 polls here, each keyed on the pane id.
      expect(tmux).to have_received(:pane_details).exactly(4).times
      expect(tmux).to have_received(:capture_pane_by_id)
        .with("%11", lines: 100).exactly(3).times
    end

    it "polls at the given interval until the content appears" do
      allow(tmux).to receive(:capture_pane_by_id).and_return("a", "b", "READY")
      command.call("myproject", "READY", interval: 0.25, exec_command: ["irb"])
      expect(sleep_calls).to eq([0.25, 0.25])
    end

    it "matches multi-line content against the whole captured blob" do
      allow(tmux).to receive(:capture_pane_by_id).and_return("one\ntwo\nthree\n")
      status = command.call("myproject", "two\nthree")
      expect(status).to eq(0)
    end

    it "passes --lines through to capture so tmux bounds the window" do
      allow(tmux).to receive(:capture_pane_by_id).and_return("READY\n")
      command.call("myproject", "READY", lines: 5)
      expect(tmux).to have_received(:capture_pane_by_id)
        .with("%12", lines: 5)
    end

    it "keeps polling when a capture returns nil mid-poll for a pane that still resolves" do
      allow(tmux).to receive(:capture_pane_by_id).and_return(nil, nil, "READY\n")
      status = command.call("myproject", "READY")
      expect(status).to eq(0)
    end

    it "errors rather than following a renumbered pane when the anchored pane closes" do
      allow(tmux).to receive(:capture_pane_by_id).and_return("a")
      # Pane %12 (pane 2) closes and a new pane %99 takes its index; the wait
      # is anchored to %12, which no longer resolves, so it errors out
      # instead of silently watching %99.
      renumbered = pane_details.reject { |d| d[:id] == "%12" } + [{id: "%99", window: 0, index: 2}]
      allow(tmux).to receive(:pane_details).and_return(pane_details, pane_details, renumbered)
      expect { command.call("myproject", "READY") }
        .to raise_error(Workspace::Error, /No pane with id %12 in session 'myproject'/)
    end

    it "raises when the session has no panes left mid-poll" do
      allow(tmux).to receive(:capture_pane_by_id).and_return("a")
      allow(tmux).to receive(:pane_details).and_return(pane_details, pane_details, [])
      expect { command.call("myproject", "READY") }
        .to raise_error(Workspace::Error, /No pane with id %12 in session 'myproject'/)
    end
  end

  describe "timeout" do
    it "returns 1 and reports the timeout when max_wait_time elapses" do
      status = command.call("myproject", "NEVER", max_wait_time: 1)
      expect(status).to eq(1)
      expect(error_output.string).to include("✗ Timed out")
      expect(error_output.string).to include("pane 2 of 'myproject'")
    end

    it "honors the deadline when interval exceeds max_wait_time" do
      allow(tmux).to receive(:capture_pane_by_id).and_return("nope")
      status = command.call("myproject", "NEVER", interval: 30, max_wait_time: 10)
      expect(status).to eq(1)
      expect(error_output.string).to include("✗ Timed out after 10.0 waiting for content")
      expect(sleep_calls).to all(be <= 10)
    end

    it "waits forever when max_wait_time is nil" do
      allow(tmux).to receive(:capture_pane_by_id).and_return("nope")
      sleeper = ->(_) { throw :stop_after_three_polls }
      command = described_class.new(tmux: tmux, output: output, error_output: error_output,
        sleeper: sleeper, exec_handler: exec_handler, clock: clock, spinner_enabled: false)
      expect { command.call("myproject", "NEVER") }
        .to throw_symbol(:stop_after_three_polls)
    end
  end

  describe "--since-start" do
    it "takes a baseline of the full scrollback and ignores pre-existing content" do
      # Baseline holds READY; the later capture keeps it at the top, so the
      # surviving baseline anchors there and the pre-existing match must be
      # ignored and the wait time out.
      allow(tmux).to receive(:capture_pane_by_id)
        .and_return("READY\n", "READY\nstill booting\n")
      status = command.call("myproject", "READY", since_start: true, max_wait_time: 10)
      expect(status).to eq(1)
      expect(tmux).to have_received(:capture_pane_by_id)
        .with("%12", all: true).at_least(:twice)
    end

    it "matches content written after start" do
      allow(tmux).to receive(:capture_pane_by_id)
        .and_return("old output\n", "old output\nREADY\n")
      status = command.call("myproject", "READY", since_start: true)
      expect(status).to eq(0)
    end

    it "bounds the match window to the last --lines lines of post-start output" do
      # The baseline line was evicted, so everything in the later capture is
      # post-start output: 3 lines, of which with lines: 2 only the last two
      # are considered, so a match on the first post-start line is out of
      # window.
      allow(tmux).to receive(:capture_pane_by_id)
        .and_return("baseline\n", "READY\npost1\npost2\n")
      status = command.call("myproject", "READY", since_start: true,
        lines: 2, max_wait_time: 10)
      expect(status).to eq(1)
    end

    it "raises at start when the baseline capture fails instead of silently baselining at zero" do
      # A nil baseline capture baselined at 0 via to_s, letting pre-existing
      # content match; it must error out before polling starts.
      allow(tmux).to receive(:capture_pane_by_id).and_return(nil)
      expect { command.call("myproject", "READY", since_start: true) }
        .to raise_error(Workspace::Error, /Could not capture the pane to take a --since-start baseline/)
    end

    it "allows a zero-line baseline for a pane with no history yet" do
      # A zero-line, non-nil capture is a legitimate empty history: the
      # baseline is 0 and post-start content matches.
      allow(tmux).to receive(:capture_pane_by_id).and_return("", "READY\n")
      status = command.call("myproject", "READY", since_start: true)
      expect(status).to eq(0)
    end

    it "keeps polling when a capture returns nil mid-poll instead of matching nothing" do
      # A nil mid-poll capture must read as no-match and continue polling,
      # like the bounded path.
      allow(tmux).to receive(:capture_pane_by_id)
        .and_return("old\n", nil, "old\nREADY\n")
      status = command.call("myproject", "READY", since_start: true)
      expect(status).to eq(0)
    end

    it "matches post-start content when the scrollback is already at the history limit" do
      # The baseline sits at tmux's history limit: the later capture evicts
      # the top two baseline lines to make room for new ones, so the line
      # count never grows. The surviving baseline suffix (l3, l4, l5) anchors
      # the window and the new line still matches.
      allow(tmux).to receive(:capture_pane_by_id)
        .and_return("l1\nl2\nl3\nl4\nl5\n", "l3\nl4\nl5\nNEW-TARGET\n")
      status = command.call("myproject", "NEW-TARGET", since_start: true)
      expect(status).to eq(0)
    end

    it "does not match pre-start content evicted from a scrollback at the history limit" do
      # Same churned capture as above: only NEW-TARGET is post-start, so a
      # target on an evicted pre-start line must not match.
      allow(tmux).to receive(:capture_pane_by_id)
        .and_return("l1\nl2\nl3\nl4\nl5\n", "l3\nl4\nl5\nNEW-TARGET\n")
      status = command.call("myproject", "l1", since_start: true, max_wait_time: 10)
      expect(status).to eq(1)
    end

    it "anchors on the longest surviving baseline suffix, not the first" do
      # With duplicated lines the shortest suffix aligns too: taking the
      # first match instead of the longest would leave a pre-start line in
      # the window ("A\nA") and falsely match baseline content. The longest
      # suffix (both baseline lines) leaves only the last line post-start,
      # so the multi-line target times out.
      allow(tmux).to receive(:capture_pane_by_id)
        .and_return("A\nA\n", "A\nA\nA\n")
      status = command.call("myproject", "A\nA", since_start: true, max_wait_time: 10)
      expect(status).to eq(1)
    end

    it "does not match a target spanning the anchor boundary" do
      # "old\nnew" is half pre-start ("old", a surviving baseline line)
      # and half post-start ("new"): the window is only the post-start
      # line, so a multi-line target cannot match across the boundary.
      allow(tmux).to receive(:capture_pane_by_id)
        .and_return("x\nold\n", "x\nold\nnew\n")
      status = command.call("myproject", "old\nnew", since_start: true, max_wait_time: 10)
      expect(status).to eq(1)
    end

    it "matches content when the baseline is fully evicted at the history limit" do
      # The whole baseline churned out of the history: nothing in the capture
      # predates the wait, so everything is post-start content and matches.
      allow(tmux).to receive(:capture_pane_by_id)
        .and_return("old1\nold2\n", "brand new\nNEW-TARGET\n")
      status = command.call("myproject", "NEW-TARGET", since_start: true)
      expect(status).to eq(0)
    end

    it "matches post-start content on a pane shorter than the screen" do
      # tmux pads the visible screen with blank lines below the cursor, and
      # new lines are written into that region, so the capture stays the same
      # size while content grows. The baseline anchors on its content lines
      # (padding is stripped), so the new line matches.
      allow(tmux).to receive(:capture_pane_by_id)
        .and_return("booting\n#{"\n" * 9}", "booting\nNEW-TARGET\n#{"\n" * 8}")
      status = command.call("myproject", "NEW-TARGET", since_start: true)
      expect(status).to eq(0)
    end

    it "matches content written after a mid-wait clear-history keeps the visible screen" do
      # clear-history drops the scrollback but keeps the visible screen, so
      # pre-start content survives at the top of the capture while new lines
      # land below it: the surviving baseline anchors the window and only the
      # new line matches.
      allow(tmux).to receive(:capture_pane_by_id)
        .and_return("pre1\npre2\n#{"\n" * 8}", "pre1\npre2\nNEW-TARGET\n#{"\n" * 7}")
      status = command.call("myproject", "NEW-TARGET", since_start: true)
      expect(status).to eq(0)
    end

    it "does not match pre-start content that survives a mid-wait clear-history" do
      # Same clear-history capture: the pre-start lines are still on the
      # visible screen, but they are the surviving baseline, not post-start
      # content, so they must not match despite since_start.
      allow(tmux).to receive(:capture_pane_by_id)
        .and_return("pre1\npre2\n#{"\n" * 8}", "pre1\npre2\nNEW-TARGET\n#{"\n" * 7}")
      status = command.call("myproject", "pre1", since_start: true, max_wait_time: 10)
      expect(status).to eq(1)
    end
  end

  describe "exec" do
    it "returns 0 without exec'ing when no command is given" do
      allow(tmux).to receive(:capture_pane_by_id).and_return("READY\n")
      status = command.call("myproject", "READY", exec_command: nil)
      expect(status).to eq(0)
      expect(exec_calls).to be_empty
      expect(output.string).to include("command on match")
    end

    it "returns 1 and reports the failure when exec raises SystemCallError" do
      allow(tmux).to receive(:capture_pane_by_id).and_return("READY\n")
      exec_handler = ->(_cmd, _out, _err) { raise SystemCallError.new("no such file") }
      command = described_class.new(tmux: tmux, output: output, error_output: error_output,
        sleeper: sleeper, exec_handler: exec_handler, clock: clock, spinner_enabled: false)
      status = command.call("myproject", "READY", exec_command: ["nope"])
      expect(status).to eq(1)
      expect(error_output.string).to include("✗ Failed to execute")
    end
  end

  describe "banner" do
    it "shows workspace, pane, window, content, and command" do
      allow(tmux).to receive(:capture_pane_by_id).and_return("READY\nsecond line\n")
      command.call("myproject", "READY\nsecond line", exec_command: ["echo", "done"])
      expect(output.string).to include("wait-until-content")
      expect(output.string).to include("workspace   myproject")
      expect(output.string).to include("pane        2")
      expect(output.string).to include("window      last 100 lines")
      expect(output.string).to include("READY")
      expect(output.string).to include("second line")
      expect(output.string).to include("echo done")
    end

    it "describes the since-start window and max wait" do
      allow(tmux).to receive(:capture_pane_by_id).and_return("READY\n")
      command.call("myproject", "READY", since_start: true, max_wait_time: 30)
      expect(output.string).to include("window      since start (last 100 lines)")
      expect(output.string).to include("wait for    up to 30s")
    end
  end

  describe "DEFAULT_EXEC_HANDLER" do
    it "flushes output and error_output before exec'ing" do
      order = []
      output = double("output", flush: order << :output_flush)
      error_output = double("error", flush: order << :error_flush)
      allow(Kernel).to receive(:exec).with("irb") { order << :exec }
      described_class::DEFAULT_EXEC_HANDLER.call("irb", output, error_output)
      expect(order).to eq([:output_flush, :error_flush, :exec])
    end

    it "execs an Array as argv without a shell" do
      allow(Kernel).to receive(:exec).with("irb", "--noreadline")
      described_class::DEFAULT_EXEC_HANDLER.call(["irb", "--noreadline"],
        StringIO.new, StringIO.new)
      expect(Kernel).to have_received(:exec).with("irb", "--noreadline")
    end
  end

  describe "spinner" do
    it "runs when output is a tty and spinner_enabled" do
      tty_output = StringIO.new
      allow(tty_output).to receive(:tty?).and_return(true)
      allow(tmux).to receive(:capture_pane_by_id).and_return("nope")
      ticks = 0
      clock = -> do
        ticks += 1
        ticks * 0.4
      end
      command = described_class.new(tmux: tmux, output: tty_output,
        error_output: error_output,
        sleeper: ->(_) { sleep 0.2 }, exec_handler: exec_handler,
        clock: clock, spinner_enabled: true)
      command.call("myproject", "NEVER", max_wait_time: 1)
      expect(tty_output.string).to match(/waiting\.\.\./)
    end

    it "does not run when output is not a tty" do
      allow(tmux).to receive(:capture_pane_by_id).and_return("READY\n")
      command = described_class.new(tmux: tmux, output: output,
        error_output: error_output, sleeper: sleeper,
        exec_handler: exec_handler, clock: clock, spinner_enabled: true)
      command.call("myproject", "READY")
      expect(output.string).not_to match(/\r/)
    end
  end
end
