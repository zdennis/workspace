require "spec_helper"

class FakeLivenessTmux
  attr_reader :list_calls, :strict_args

  def initialize(sessions:, names: {}, sockets: {}, error: nil)
    @sessions = sessions
    @names = names
    @sockets = sockets
    @error = error
    @list_calls = 0
  end

  def sessions(strict: false)
    (@strict_args ||= []) << strict
    @list_calls += 1
    raise @error if @error
    @sessions
  end

  def session_name_for(project) = @names.fetch(project, project)

  def custom_socket_option(project) = @sockets[project]
end

RSpec.describe Workspace::Liveness do
  let(:tmux) { FakeLivenessTmux.new(sessions: ["ws-alpha"], names: {"alpha" => "ws-alpha", "beta" => "ws-beta"}) }

  it "reports true for a project whose tmux session exists and false for one whose session is gone" do
    expect(described_class.new(tmux: tmux).call(%w[alpha beta])).to eq("alpha" => true, "beta" => false)
  end

  it "matches on the tmux session name from the project's config, not the project name" do
    expect(described_class.new(tmux: tmux).call(%w[alpha])).to eq("alpha" => true)
  end

  it "lists tmux sessions once for any number of projects" do
    described_class.new(tmux: tmux).call(%w[alpha beta gamma])
    expect(tmux.list_calls).to eq(1)
  end

  it "asks tmux strictly, so a tmux error is not mistaken for no sessions" do
    described_class.new(tmux: tmux).call(%w[alpha])
    expect(tmux.strict_args).to eq([true])
  end

  it "does not ask tmux when there are no projects" do
    expect(described_class.new(tmux: tmux).call([])).to eq({})
    expect(tmux.list_calls).to eq(0)
  end

  it "reports nil for every project when tmux does not answer" do
    tmux = FakeLivenessTmux.new(sessions: [], error: Workspace::Error.new("tmux did not answer"))
    expect(described_class.new(tmux: tmux).call(%w[alpha beta])).to eq("alpha" => nil, "beta" => nil)
  end

  it "reports nil for every project when tmux cannot be run" do
    tmux = FakeLivenessTmux.new(sessions: [], error: Errno::ENOENT.new("tmux"))
    expect(described_class.new(tmux: tmux).call(%w[alpha beta])).to eq("alpha" => nil, "beta" => nil)
  end

  it "reports nil for a project on a custom tmux socket, which the default socket cannot see" do
    tmux = FakeLivenessTmux.new(sessions: ["alpha"], sockets: {"alpha" => "-L other"})
    expect(described_class.new(tmux: tmux).call(%w[alpha beta])).to eq("alpha" => nil, "beta" => false)
  end
end
