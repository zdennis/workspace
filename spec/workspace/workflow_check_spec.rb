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
    # The time limit passes the moment the command has started its child.
    timed = described_class.new(clock: -> { File.size?(marker) ? 100 : 0 }, sleeper: ->(_) { Thread.pass }, kill_grace: 1_000)

    result = timed.call(command: "sleep 30 & echo $! > #{marker}; wait", cwd: @dir, timeout: 25, log: log)

    expect(result).to eq(exit_code: nil, timed_out: true)
    expect(state_of_child).to satisfy("be gone or a zombie") { |value| value.empty? || value.start_with?("Z") }
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
end
