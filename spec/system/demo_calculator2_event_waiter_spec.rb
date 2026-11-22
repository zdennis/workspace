require "spec_helper"
require "tmpdir"

load File.join(PROJECT_ROOT, "script", "demo-calculator2")

# The waiter over a fake `workspace` follower: a real child process, so this is a system spec.
RSpec.describe DemoCalculator2::EventWaiter do
  let(:tmp) { Dir.mktmpdir }
  let(:argv_log) { File.join(tmp, "argv") }
  let(:slept) { [] }
  let(:children) { [] }
  let(:spawn) do
    lambda do |argv|
      stdout, thread = described_class.popen([File.join(tmp, "workspace"), *argv.drop(1)])
      children << thread
      [stdout, thread]
    end
  end
  let(:waiter) { described_class.new(workspaces: %w[lane-a lane-b], spawn: spawn, sleeper: ->(seconds) { slept << seconds }) }

  after do
    waiter.close
    FileUtils.rm_rf(tmp)
  end

  def fake_workspace(body)
    path = File.join(tmp, "workspace")
    File.write(path, "#!/bin/sh\necho \"$@\" > #{argv_log}\n#{body}\n")
    File.chmod(0o755, path)
  end

  def lines(*events) = events.map { |event| "echo '#{event}'" }.join("\n")

  let(:noise) do
    lines('{"type":"follow_started","cursor":"c"}', '{"type":"work_queue_item_started","workspace":"other"}')
  end

  it "returns on a lane A line, not on the lines before it" do
    fake_workspace("#{noise}\nsleep 1\n#{lines('{"type":"work_queue_item_finished","workspace":"lane-a"}')}\nexec sleep 30")
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    waiter.call(20)
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
    expect(elapsed).to be_between(0.9, 10)
    expect(slept).to be_empty
    expect(File.read(argv_log).strip).to eq("events --follow --json --types work_queue_item_started,work_queue_item_finished")
  end

  it "wakes on a lane B line" do
    fake_workspace("#{noise}\n#{lines('{"type":"work_queue_item_started","workspace":"lane-b"}')}\nexec sleep 30")
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    waiter.call(20)
    expect(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).to be < 10
    expect(slept).to be_empty
  end

  it "returns at the timeout when nothing matches" do
    fake_workspace("#{noise}\nexec sleep 30")
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    waiter.call(1)
    expect(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).to be_between(0.9, 5)
  end

  it "falls back to sleeping when the follower exits" do
    fake_workspace("exit 0")
    waiter.call(5)
    waiter.call(5)
    expect(slept).to eq([3, 3])
  end

  it "kills and reaps the child on close" do
    fake_workspace("exec sleep 30")
    waiter.call(0.2)
    pid = children.first.pid
    waiter.close
    expect(children.first).not_to be_alive
    expect { Process.kill(0, pid) }.to raise_error(Errno::ESRCH)
    expect { Process.wait(pid) }.to raise_error(Errno::ECHILD)
  end
end
