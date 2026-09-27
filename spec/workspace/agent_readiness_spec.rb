RSpec.describe Workspace::AgentReadiness do
  let(:now) { [0.0] }
  let(:sleeps) { [] }
  let(:panes) { [{id: "%1", window: 0, index: 0, pid: 100, command: "zsh"}, {id: "%2", window: 0, index: 1, pid: 200, command: "claude"}] }
  let(:screens) { ["Welcome to Claude Code\n" + ("─" * 20) + "\n❯ Try \"write a test\"\n" + ("─" * 20)] }
  let(:processes) { [] }
  let(:tmux) { instance_double(Workspace::Tmux) }
  let(:process_tree) { instance_double(Workspace::ProcessTree) }

  subject(:readiness) do
    described_class.new(tmux: tmux, process_tree: process_tree,
      clock: -> { now[0] },
      sleeper: ->(seconds) {
        sleeps << seconds
        now[0] += seconds
      },
      poll_interval: 0.5, quiet_for: 2.0)
  end

  before do
    allow(tmux).to receive(:pane_details) { panes }
    allow(tmux).to receive(:capture_screen) { (screens.size > 1) ? screens.shift : screens.first }
    allow(process_tree).to receive(:snapshot) { Workspace::ProcessTree::Snapshot.new(processes) }
  end

  it "is ready once the agent's screen has stayed the same for quiet_for seconds" do
    result = readiness.wait("proj", deadline: readiness.deadline_in(60))

    expect(result).to be_ready
    expect(result.pane).to eq("0.1")
    expect(result.label).to eq("Claude Code")
    expect(now[0]).to eq(2.0)
    expect(tmux).to have_received(:capture_screen).with("%2").at_least(:once)
  end

  it "finds an agent running in a window other than the first" do
    panes.replace([{id: "%1", window: 0, index: 0, pid: 100, command: "zsh"}, {id: "%7", window: 2, index: 1, pid: 700, command: "claude"}])

    result = readiness.wait("proj", deadline: readiness.deadline_in(60))

    expect(tmux).to have_received(:pane_details).with("proj", window: nil).at_least(:once)
    expect(result).to be_ready
    expect(result.pane).to eq("2.1")
  end

  it "waits while the screen is still changing" do
    ready = ("─" * 20) + "\n❯ "
    screens.replace(["", "Loading", "Loading.", "Loading..", ready, ready])

    result = readiness.wait("proj", deadline: readiness.deadline_in(60))

    expect(result).to be_ready
    # Blank at 0, changing until "> " first shows at 2.0, quiet from then on.
    expect(now[0]).to eq(4.0)
  end

  it "finds an agent started under a shell wrapper" do
    panes.replace([{id: "%5", window: 0, index: 2, pid: 300, command: "zsh"}])
    processes.replace([{pid: 301, ppid: 300, command: "claude", args: "claude"}])

    result = readiness.wait("proj", deadline: readiness.deadline_in(60))

    expect(result).to be_ready
    expect(result.pane).to eq("0.2")
  end

  it "prefers the first provider, then the lowest pane, when several agents run" do
    panes.replace([{id: "%1", window: 0, index: 0, pid: 100, command: "codex"}, {id: "%3", window: 0, index: 2, pid: 300, command: "claude"},
      {id: "%2", window: 0, index: 1, pid: 200, command: "claude"}])

    expect(readiness.wait("proj", deadline: readiness.deadline_in(60)).pane).to eq("0.1")
  end

  it "gives up at the deadline when no agent ever starts, saying why" do
    panes.replace([{id: "%1", window: 0, index: 0, pid: 100, command: "zsh"}])

    result = readiness.wait("proj", deadline: readiness.deadline_in(5))

    expect(result).not_to be_ready
    expect(result.reason).to eq("no coding agent is running in tmux session 'proj' yet")
    expect(now[0]).to eq(5.0)
    expect(sleeps).to all(be <= 0.5)
  end

  it "gives up at the deadline when the agent never settles" do
    counter = [0]
    allow(tmux).to receive(:capture_screen) { "frame #{counter[0] += 1}" }

    result = readiness.wait("proj", deadline: readiness.deadline_in(5))

    expect(result).not_to be_ready
    expect(result.pane).to eq("0.1")
    expect(result.reason).to eq("Claude Code (pane 0.1) is still starting up")
  end

  it "reports a session with no panes" do
    panes.clear

    result = readiness.wait("gone", deadline: readiness.deadline_in(1))

    expect(result.reason).to include("tmux session 'gone' has no panes")
  end

  it "reports a blank screen as not drawn yet" do
    screens.replace([""])

    result = readiness.wait("proj", deadline: readiness.deadline_in(1))

    expect(result.reason).to eq("Claude Code (pane 0.1) has not drawn its screen yet")
  end

  it "does not count a static trust dialog as ready, even once the screen is quiet" do
    allow(tmux).to receive(:capture_screen) { "Do you trust the files in this folder?\n╭──────────╮\n│ ❯ 1. Yes │\n│   2. No  │\n╰──────────╯" }

    result = readiness.wait("proj", deadline: readiness.deadline_in(5))

    expect(result).not_to be_ready
    expect(result.reason).to eq("Claude Code (pane 0.1) agent prompt never appeared")
  end

  it "becomes ready once a dialog is dismissed and the real prompt settles" do
    screens.replace(["Do you trust the files in this folder?", "Do you trust the files in this folder?", "Welcome to Claude Code\n" + ("─" * 20) + "\n❯ "])

    result = readiness.wait("proj", deadline: readiness.deadline_in(60))

    expect(result).to be_ready
  end

  it "reports a process table that can't be read" do
    panes.replace([{id: "%1", window: 0, index: 0, pid: 100, command: "zsh"}])
    allow(process_tree).to receive(:snapshot).and_raise(Workspace::Error, "could not read the process table")

    expect(readiness.wait("proj", deadline: readiness.deadline_in(1)).reason).to eq("could not read the process table")
  end

  it "restarts the quiet period when the agent moves to another pane" do
    first = [{id: "%2", window: 0, index: 1, pid: 200, command: "claude"}]
    second = [{id: "%3", window: 0, index: 2, pid: 300, command: "claude"}]
    calls = [0]
    allow(tmux).to receive(:pane_details) { ((calls[0] += 1) <= 3) ? first : second }

    result = readiness.wait("proj", deadline: readiness.deadline_in(60))

    expect(result.pane).to eq("0.2")
    expect(now[0]).to eq(3.5)
  end

  it "checks once and answers when the deadline has already passed" do
    result = readiness.wait("proj", deadline: now[0] - 1)

    expect(result).not_to be_ready
    expect(sleeps).to be_empty
  end
end
