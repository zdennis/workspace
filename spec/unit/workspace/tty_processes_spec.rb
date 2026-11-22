require "spec_helper"

RSpec.describe Workspace::TtyProcesses do
  let(:calls) { [] }
  let(:result) { ["-zsh\n  \nvim\n", "", true] }
  let(:runner) do
    lambda do |argv, **opts|
      calls << [argv, opts]
      result.is_a?(Proc) ? result.call : result
    end
  end

  subject(:processes) { described_class.new(runner: runner) }

  it "returns stripped command names, dropping blank lines" do
    expect(processes.commands("/dev/ttys003")).to eq(["-zsh", "vim"])
    expect(calls.first[0]).to eq(["ps", "-o", "comm=", "-t", "ttys003"])
    expect(calls.first[1][:timeout]).to eq(2)
  end

  context "when ps fails" do
    let(:result) { ["", "err", false] }

    it("returns nil") { expect(processes.commands("/dev/ttys003")).to be_nil }
  end

  context "when ps times out" do
    let(:result) { -> { raise Timeout::Error } }

    it("returns nil") { expect(processes.commands("/dev/ttys003")).to be_nil }
  end

  ["/dev/tty", "ttys003", "/dev/ttys", "/dev/ttys3; ls", nil].each do |bad|
    it "returns nil without running ps for #{bad.inspect}" do
      expect(processes.commands(bad)).to be_nil
      expect(calls).to be_empty
    end
  end
end
