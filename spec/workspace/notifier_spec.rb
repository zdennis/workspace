require "spec_helper"
require "tmpdir"

RSpec.describe Workspace::Notifier do
  let(:dir) { Dir.mktmpdir("ws-notifier") }
  let(:error_output) { StringIO.new }
  let(:env) { {"WORKSPACE_ALERT" => "waiting", "WORKSPACE_ALERT_TEXT" => "app pane 0.1 is waiting"} }

  after { FileUtils.remove_entry(dir) }

  def child_alive?(pid)
    Process.kill(0, pid)
    true
  rescue Errno::ESRCH
    false
  end

  def notifier(command, **options)
    described_class.new(command: command, error_output: error_output, **options)
  end

  it "runs the command with the alert details in its environment" do
    out = File.join(dir, "out")
    n = notifier(%(printf '%s|%s' "$WORKSPACE_ALERT" "$WORKSPACE_ALERT_TEXT" > "#{out}"))

    n.notify(env).join(5)

    expect(File.read(out)).to eq("waiting|app pane 0.1 is waiting")
    expect(error_output.string).to be_empty
  end

  it "passes shell syntax in a message through as plain text" do
    out = File.join(dir, "out")
    marker = File.join(dir, "injected")
    n = notifier(%(printf '%s' "$WORKSPACE_ALERT_MESSAGE" > "#{out}"))

    n.notify(env.merge("WORKSPACE_ALERT_MESSAGE" => "$(touch #{marker}); `touch #{marker}`")).join(5)

    expect(File.read(out)).to eq("$(touch #{marker}); `touch #{marker}`")
    expect(File.exist?(marker)).to be false
  end

  it "returns before the command finishes" do
    n = notifier("sleep 1", timeout: 5)

    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    thread = n.notify(env)
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

    expect(elapsed).to be < 0.5
    thread.join(5)
  end

  it "stops and reaps a command that runs past its timeout, along with its children" do
    pid_file = File.join(dir, "child")
    n = notifier(%(sleep 30 & echo $! > "#{pid_file}"; wait), timeout: 0.3, kill_grace: 1)

    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    n.notify(env).join(5)

    expect(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).to be < 3
    expect(error_output.string).to include("still running after 0.3s")
    child = File.read(pid_file).to_i
    # The orphaned child is reaped by init, not by us, so allow it a moment.
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 2
    sleep 0.05 while child_alive?(child) && Process.clock_gettime(Process::CLOCK_MONOTONIC) < deadline
    expect(child_alive?(child)).to be false
  end

  it "reports a command that exits non-zero" do
    notifier("exit 3").notify(env).join(5)

    expect(error_output.string).to include("notify command failed", "exit 3")
  end

  it "reports a command that can't start instead of raising" do
    notifier("/nonexistent/notify-command").notify(env).join(5)

    expect(error_output.string).to include("notify command failed to start")
  end

  it "skips an alert while too many earlier runs are still going" do
    n = notifier("sleep 0.5", max_in_flight: 1)

    first = n.notify(env)
    second = n.notify(env)

    expect(second).to be_nil
    expect(error_output.string).to include("skipped notify command for app pane 0.1 is waiting")
    first.join(5)
    expect(n.notify(env)).to be_a(Thread)
    n.wait
  end

  it "runs the command in its own process group" do
    calls = []
    spawner = ->(*args, **options) {
      calls << [args, options]
      Process.spawn("true", **options)
    }

    notifier("say hi", spawner: spawner).notify(env).join(5)

    expect(calls.first[0]).to eq([env, "say hi"])
    expect(calls.first[1]).to include(pgroup: true, in: File::NULL, out: File::NULL)
  end
end
