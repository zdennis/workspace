require "spec_helper"
require "open3"

RSpec.describe Workspace::TtyProcesses do
  it "lists commands on the current process's terminal" do
    out, _, ok = Open3.capture3("ps", "-o", "tty=", "-p", Process.pid.to_s)
    tty = out.strip
    skip "no controlling tty" unless ok && tty.match?(/\Attys\d+\z/)

    commands = described_class.new.commands("/dev/#{tty}")
    expect(commands).to be_an(Array)
    expect(commands).not_to be_empty
  end
end
