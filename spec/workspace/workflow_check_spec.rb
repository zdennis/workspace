require "spec_helper"
require "tmpdir"

RSpec.describe Workspace::WorkflowCheck do
  around do |example|
    Dir.mktmpdir("wf-check") do |dir|
      @dir = File.realpath(dir)
      example.run
    end
  end

  let(:log) { File.join(@dir, "steps", "verify.1.check.log") }
  subject(:check) { described_class.new }

  describe ".env_for" do
    around do |example|
      saved = ENV["GIT_DIR"]
      ENV["GIT_DIR"] = "/elsewhere"
      example.run
    ensure
      ENV["GIT_DIR"] = saved
    end

    it "removes an inherited GIT_ variable" do
      env = described_class.env_for({"id" => "wr_1", "artifacts_dir" => "/a", "base_sha" => "abc"})
      expect(env).to include("GIT_DIR" => nil, "WORKSPACE_RUN_ID" => "wr_1", "WORKSPACE_RUN_ARTIFACTS" => "/a", "WORKSPACE_RUN_BASE_SHA" => "abc")
    end

    it "gives an empty base for a run with no recorded commit" do
      expect(described_class.env_for({"id" => "wr_1", "base_sha" => nil})).to include("WORKSPACE_RUN_BASE_SHA" => "", "WORKSPACE_RUN_ARTIFACTS" => "")
    end
  end

  it "runs the command through the shell in the checkout and reports a pass" do
    result = check.call(command: "pwd && echo to-stderr >&2", cwd: @dir, timeout: 30, log: log)

    expect(result).to eq(exit_code: 0, timed_out: false)
    expect(File.read(log)).to eq("#{@dir}\nto-stderr\n")
  end

  it "reports the exit status of a command that fails" do
    expect(check.call(command: "echo broken; exit 3", cwd: @dir, timeout: 30, log: log)).to eq(exit_code: 3, timed_out: false)
    expect(File.read(log)).to eq("broken\n")
  end

  it "replaces the log of an earlier run of the same check" do
    FileUtils.mkdir_p(File.dirname(log))
    File.write(log, "old\n")

    check.call(command: "echo new", cwd: @dir, timeout: 30, log: log)

    expect(File.read(log)).to eq("new\n")
  end

  it "gives the command the environment it is passed, and keeps the rest" do
    result = check.call(command: 'test "$WORKSPACE_RUN_ID" = wr_1 && test -n "$PATH"', cwd: @dir, timeout: 30, log: log,
      env: {"WORKSPACE_RUN_ID" => "wr_1"})

    expect(result).to eq(exit_code: 0, timed_out: false)
  end
  it "removes a variable given as nil, so an inherited GIT_DIR never reaches the command" do
    saved = ENV["GIT_DIR"]
    ENV["GIT_DIR"] = "/elsewhere"
    begin
      kept = check.call(command: 'test "$GIT_DIR" = /elsewhere', cwd: @dir, timeout: 30, log: log)
      cleared = check.call(command: 'test -z "${GIT_DIR+set}"', cwd: @dir, timeout: 30, log: log, env: {"GIT_DIR" => nil})
    ensure
      ENV["GIT_DIR"] = saved
    end

    expect(kept).to eq(exit_code: 0, timed_out: false)
    expect(cleared).to eq(exit_code: 0, timed_out: false)
  end

  it "gives the command no stdin to wait on" do
    expect(check.call(command: "cat", cwd: @dir, timeout: 30, log: log)).to eq(exit_code: 0, timed_out: false)
  end

  let(:marker) { File.join(@dir, "child.pid") }

  # Whatever a spec's command started is gone when the spec ends, pass or fail.
  after do
    next unless File.size?(marker)
    begin
      Process.kill("KILL", Integer(File.read(marker)))
    rescue Errno::ESRCH, ArgumentError
      nil
    end
  end

  # A killed child stays a zombie until it is reaped, so `ps` is asked for its state.
  def state_of_child
    child = Integer(File.read(marker))
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 10
    loop do
      state = `ps -o stat= -p #{child}`.strip
      return state if state.empty? || state.start_with?("Z") || Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
      sleep 0.05
    end
  end

  it "stops a command that runs past its time limit, with everything it started" do
    # The time limit passes the moment the command has started its child. The first look at the
    # clock (which sets the deadline) always reads 0, so a child that is quick to start its own
    # child cannot move the deadline out of reach.
    looked = false
    clock = lambda do
      first = !looked
      looked = true
      (!first && File.size?(marker)) ? 100 : 0
    end
    timed = described_class.new(clock: clock, sleeper: ->(_) { Thread.pass }, kill_grace: 1_000)

    result = timed.call(command: "sleep 30 & echo $! > #{marker}; wait", cwd: @dir, timeout: 25, log: log)

    expect(result).to eq(exit_code: nil, timed_out: true)
    expect(state_of_child).to satisfy("be gone or a zombie") { |value| value.empty? || value.start_with?("Z") }
  end

  it "stops the command's group when the caller is interrupted while it waits" do
    pidfile = File.join(@dir, "pid")
    caller_thread = Thread.new do
      check.call(command: "echo $$ > #{pidfile}; exec sleep 30", cwd: @dir, timeout: 60, log: log)
    rescue Interrupt
      :interrupted
    end
    sleep 0.05 until File.size?(pidfile)
    pid = Integer(File.read(pidfile))

    caller_thread.raise(Interrupt)

    expect(caller_thread.value).to eq(:interrupted)
    expect { Process.kill(0, pid) }.to raise_error(Errno::ESRCH)
  end

  it "kills a command that traps TERM when the stop itself is interrupted" do
    pidfile = File.join(@dir, "pid")
    patient = described_class.new(kill_grace: 30)
    caller_thread = Thread.new do
      patient.call(command: "trap '' TERM; echo $$ > #{pidfile}; while :; do sleep 1; done", cwd: @dir, timeout: 60, log: log)
    rescue Interrupt
      :interrupted
    end
    sleep 0.05 until File.size?(pidfile)
    pid = Integer(File.read(pidfile))

    caller_thread.raise(Interrupt)
    sleep 0.5
    expect { Process.kill(0, pid) }.not_to raise_error
    caller_thread.raise(Interrupt)
    caller_thread.join(10)

    expect { Process.kill(0, pid) }.to raise_error(Errno::ESRCH)
  end

  it "stops a command whose run moved on, with everything it started, asking only every stop_poll seconds" do
    ticks = 0
    asked = []
    # A tenth of a second passes per look at the clock; the run moves on once the child is started.
    polled = described_class.new(clock: -> { (ticks += 1) / 10.0 }, sleeper: ->(_) { Thread.pass }, kill_grace: 1_000, stop_poll: 2)
    stop_when = lambda do
      asked << ticks
      !File.size?(marker).nil?
    end

    result = polled.call(command: "sleep 30 & echo $! > #{marker}; wait", cwd: @dir, timeout: 100_000, log: log, stop_when: stop_when)

    expect(result).to eq(exit_code: nil, timed_out: false, error: "stopped: the run moved on")
    expect(asked.each_cons(2).map { |a, b| b - a }).to all(be >= 20)
    expect(state_of_child).to satisfy("be gone or a zombie") { |value| value.empty? || value.start_with?("Z") }
  end

  it "runs to the end while the run still wants the check" do
    quick = described_class.new(stop_poll: 0)

    expect(quick.call(command: "sleep 0.3; exit 4", cwd: @dir, timeout: 30, log: log, stop_when: -> { false })).to eq(exit_code: 4, timed_out: false)
  end

  it "says the check could not be run when the checkout is gone" do
    result = check.call(command: "true", cwd: File.join(@dir, "gone"), timeout: 30, log: log)

    expect(result).to eq(exit_code: nil, timed_out: false, error: "could not run the check (Errno::ENOENT)")
  end

  describe "with argv:" do
    it "runs the program without a shell and reports a pass" do
      result = check.call(argv: ["pwd"], cwd: @dir, timeout: 30, log: log)

      expect(result).to eq(exit_code: 0, timed_out: false)
      expect(File.read(log)).to eq("#{@dir}\n")
    end

    it "reports the exit status of a program that fails" do
      expect(check.call(argv: ["sh", "-c", "exit 3"], cwd: @dir, timeout: 30, log: log)).to eq(exit_code: 3, timed_out: false)
    end

    it "hands an argument with shell characters over as one argument and creates no file" do
      hostile = "x;touch pwned|sh"
      result = check.call(argv: ["printf", "[%s]", hostile], cwd: @dir, timeout: 30, log: log)

      expect(result).to eq(exit_code: 0, timed_out: false)
      expect(File.read(log)).to eq("[#{hostile}]")
      expect(File.exist?(File.join(@dir, "pwned"))).to be(false)
    end

    it "runs a one-word program with no arguments without a shell" do
      expect(check.call(argv: ["true"], cwd: @dir, timeout: 30, log: log)).to eq(exit_code: 0, timed_out: false)
    end

    it "says the check could not be run when the program is missing" do
      result = check.call(argv: ["no-such-program-xyz"], cwd: @dir, timeout: 30, log: log)

      expect(result).to eq(exit_code: nil, timed_out: false, error: "could not run the check (Errno::ENOENT)")
    end

    it "stops the program's group when it runs past the time limit" do
      timed = described_class.new(kill_grace: 1)

      result = timed.call(argv: ["sh", "-c", "sleep 30 & echo $! > #{marker}; wait"], cwd: @dir, timeout: 1, log: log)

      expect(result).to eq(exit_code: nil, timed_out: true)
      expect(state_of_child).to satisfy("be gone or a zombie") { |value| value.empty? || value.start_with?("Z") }
    end

    it "refuses both command: and argv:, and neither" do
      expect { check.call(command: "true", argv: ["true"], cwd: @dir, timeout: 30, log: log) }.to raise_error(ArgumentError)
      expect { check.call(cwd: @dir, timeout: 30, log: log) }.to raise_error(ArgumentError)
    end
  end
end
