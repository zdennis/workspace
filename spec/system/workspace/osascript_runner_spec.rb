require "tmpdir"

RSpec.describe Workspace::OsascriptRunner do
  it "answers what the program printed" do
    runner = described_class.new(command: ["sh", "-c", "echo answer", "sh"])

    result = runner.call("ignored")

    expect(result.stdout).to eq("answer\n")
    expect(result).to be_success
    expect(result).not_to be_timed_out
  end

  it "reports a failed run without raising" do
    result = described_class.new(command: ["sh", "-c", "exit 3", "sh"]).call("ignored")

    expect(result).not_to be_success
    expect(result).not_to be_timed_out
  end

  it "reads a missing program as an empty answer" do
    result = described_class.new(command: ["/nonexistent/osascript"]).call("ignored")

    expect(result.stdout).to eq("")
    expect(result).not_to be_success
    expect(result).not_to be_timed_out
  end

  it "stops a program that never answers and gives an empty, timed-out result" do
    Dir.mktmpdir do |dir|
      pid_file = File.join(dir, "pid")
      runner = described_class.new(timeout: 0.3, command: ["sh", "-c", "echo $$ > #{pid_file}; sleep 30", "sh"])

      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      result = runner.call("ignored")
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

      expect(result.stdout).to eq("")
      expect(result).to be_timed_out
      expect(elapsed).to be < 5
      pid = File.read(pid_file).to_i
      gone = 20.times.any? do
        Process.kill(0, pid)
        sleep 0.1
        false
      rescue Errno::ESRCH
        true
      end
      expect(gone).to be true
    end
  end
end
