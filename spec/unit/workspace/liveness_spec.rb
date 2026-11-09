require "spec_helper"

RSpec.describe Workspace::Liveness do
  let(:tmux) { FakeTmux.new(sessions: ["ws-alpha"], session_names: {"alpha" => "ws-alpha", "beta" => "ws-beta"}) }

  it "reports true for a project whose tmux session exists and false for one whose session is gone" do
    expect(described_class.new(tmux: tmux).call(%w[alpha beta])).to eq("alpha" => true, "beta" => false)
  end

  it "matches on the tmux session name from the project's config, not the project name" do
    expect(described_class.new(tmux: tmux).call(%w[alpha])).to eq("alpha" => true)
  end

  it "lists tmux sessions once for any number of projects" do
    described_class.new(tmux: tmux).call(%w[alpha beta gamma])
    expect(tmux.sessions_calls).to eq(1)
  end

  it "asks tmux strictly, so a tmux error is not mistaken for no sessions" do
    described_class.new(tmux: tmux).call(%w[alpha])
    expect(tmux.sessions_strict_args).to eq([true])
  end

  it "does not ask tmux when there are no projects" do
    expect(described_class.new(tmux: tmux).call([])).to eq({})
    expect(tmux.sessions_calls).to eq(0)
  end

  it "reports nil for every project when tmux does not answer" do
    tmux = FakeTmux.new(sessions: [], sessions_error: Workspace::Error.new("tmux did not answer"))
    expect(described_class.new(tmux: tmux).call(%w[alpha beta])).to eq("alpha" => nil, "beta" => nil)
  end

  it "reports nil for every project when tmux cannot be run" do
    tmux = FakeTmux.new(sessions: [], sessions_error: Errno::ENOENT.new("tmux"))
    expect(described_class.new(tmux: tmux).call(%w[alpha beta])).to eq("alpha" => nil, "beta" => nil)
  end

  it "reports nil for a project on a custom tmux socket, which the default socket cannot see" do
    tmux = FakeTmux.new(sessions: ["alpha"], sockets: {"alpha" => "-L other"})
    expect(described_class.new(tmux: tmux).call(%w[alpha beta])).to eq("alpha" => nil, "beta" => false)
  end
end
