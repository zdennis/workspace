require "spec_helper"

RSpec.describe Workspace::Pane do
  let(:rows) { [{id: "%5", window: 0, index: 1, pid: 77, command: "claude", cwd: "/src", title: "t"}, {id: "%6", window: 0, index: 2}] }
  let(:calls) { [] }
  let(:tmux) do
    FakeTmux.new(details: rows, screens: ["plain"], styled_screens: ["styled"], server_pid: "900",
      start_commands: [{window: 0, index: 1, id: "%5", start_command: "claude --x"}, {window: 0, index: 2, id: "%6", start_command: nil}])
  end
  let(:pane) { described_class.new(tmux: tmux, session_name: "app", id: "%5") }

  before { tmux.on_details = -> { calls << :details } }

  it "refuses an id that is not a tmux pane id" do
    ["five", "5", "%", "%5x", "0.1", nil, 5].each do |id|
      expect { described_class.new(tmux: tmux, session_name: "app", id: id) }.to raise_error(ArgumentError, /not a tmux pane id/)
    end
  end

  it "captures its own screen plain and styled" do
    expect(pane.capture).to eq("plain")
    expect(pane.capture_styled).to eq("styled")
  end

  it "delivers to its own session and pane, with Enter by default" do
    tmux.delivery_status = :pasted
    delivery = pane.deliver("hi")
    pane.deliver("", enter: false)
    expect(delivery.status).to eq(:pasted)
    expect(tmux.sent_keys).to eq([{session: "app", pane: "%5", text: "hi", enter: true}, {session: "app", pane: "%5", text: "", enter: false}])
  end

  it "presses a key in its own pane" do
    expect(pane.send_key("C-u")).to be(true)
    expect(tmux.sent_key_names).to eq([{session: "app", pane: "%5", key: "C-u"}])
  end

  it "finds its own row among the session's panes with one list call" do
    expect(pane.details).to eq(rows.first)
    expect(calls.size).to eq(1)
  end

  it "answers nil when the session no longer lists it" do
    gone = described_class.new(tmux: tmux, session_name: "app", id: "%9")
    expect(gone.details).to be_nil
  end

  it "answers its first details call from the row it was built with and lists afterwards" do
    seeded = described_class.new(tmux: tmux, session_name: "app", id: "%5", row: {id: "%5", pid: 1})
    expect(seeded.details).to eq({id: "%5", pid: 1})
    expect(calls).to be_empty
    expect(seeded.details).to eq(rows.first)
    expect(calls.size).to eq(1)
  end

  it "reads the server pid, start command and whether the session is gone" do
    expect(pane.server_pid).to eq("900")
    expect(pane.start_command).to eq("claude --x")
    expect(described_class.new(tmux: tmux, session_name: "app", id: "%6").start_command).to be_nil
    expect(described_class.new(tmux: tmux, session_name: "app", id: "%7").start_command).to eq(:gone)
    expect(pane.session_gone?).to be(false)
    tmux.session_gone = true
    expect(pane.session_gone?).to be(true)
  end

  describe "over the real Tmux with its process call stubbed" do
    let(:ok) { instance_double(Process::Status, success?: true) }
    let(:failed) { instance_double(Process::Status, success?: false) }
    let(:dir) { Dir.mktmpdir }
    let(:real) { Workspace::Tmux.new(config: Workspace::Config.new(workspace_dir: dir)) }
    let(:pane) { described_class.new(tmux: real, session_name: "app", id: "%5") }

    after { FileUtils.remove_entry(dir) }

    it "captures with the pane id as the target" do
      allow(Open3).to receive(:capture3).and_return(["screen", "", ok])
      expect(pane.capture).to eq("screen")
      expect(pane.capture_styled).to eq("screen")
      expect(Open3).to have_received(:capture3).with("tmux", "capture-pane", "-p", "-t", "%5")
      expect(Open3).to have_received(:capture3).with("tmux", "capture-pane", "-e", "-p", "-t", "%5")
    end

    it "answers nil for a screen tmux could not read" do
      allow(Open3).to receive(:capture3).and_return(["", "no pane", failed])
      expect(pane.capture).to be_nil
    end

    it "reads the server pid of the pane" do
      allow(Open3).to receive(:capture3).and_return(["900\n", "", ok])
      expect(pane.server_pid).to eq("900")
      expect(Open3).to have_received(:capture3).with("tmux", "display-message", "-p", "-t", "%5", "\#{pid}")
    end

    it "lists the whole session once for details and finds its row" do
      allow(Open3).to receive(:capture3).and_return(["%4\t0\t0\t1\ta\t/a\tA\n%5\t0\t1\t77\tclaude\t/src\tT\n", "", ok])
      expect(pane.details).to include(id: "%5", index: 1, pid: 77)
      expect(Open3).to have_received(:capture3).once.with("tmux", "list-panes", "-s", "-t", "=app:", "-F", anything)
    end

    it "finds its start command" do
      allow(Open3).to receive(:capture3).and_return(["0\t1\t%5\tclaude --x\n", "", ok])
      expect(pane.start_command).to eq("claude --x")
    end
  end
end

RSpec.describe Workspace::PaneFactory do
  let(:rows) { [{id: "%5", window: 0, index: 1}] }
  let(:calls) { [] }
  let(:tmux) { FakeTmux.new(details: rows, strict_windows: true) }
  before { tmux.on_details = -> { calls << :details } }
  let(:factory) { described_class.new(tmux: tmux, session_name: "app") }

  it "answers :gone for an id that is not a String without listing" do
    [nil, 5, :"%5"].each { |id| expect(factory.call(id)).to eq(:gone) }
    expect(calls).to be_empty
  end

  it "answers :gone for a String the session does not list, \"five\" included" do
    expect(factory.call("five")).to eq(:gone)
    expect(factory.call("%9")).to eq(:gone)
  end

  it "answers :unlisted when tmux lists no pane at all, whatever the id" do
    empty = described_class.new(tmux: FakeTmux.new(details: []), session_name: "app")
    expect(empty.call("%5")).to eq(:unlisted)
    expect(empty.call("five")).to eq(:unlisted)
  end

  it "answers a Pane that keeps the row found, so its first details call lists nothing again" do
    pane = factory.call("%5")
    expect(pane).to be_a(Workspace::Pane)
    expect(pane.id).to eq("%5")
    expect(calls.size).to eq(1)
    expect(pane.details).to eq(rows.first)
    expect(calls.size).to eq(1)
  end
end
