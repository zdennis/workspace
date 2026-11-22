require "spec_helper"
require "workspace/gateway_window_closer"

class GwcFakeIterm
  attr_reader :map_calls, :window_calls
  attr_accessor :timed_out, :fail_with, :maps, :screens

  def initialize(maps: [{}], windows: [[]])
    @maps = maps
    @screens = windows
    @map_calls = 0
    @window_calls = 0
  end

  def session_map
    raise fail_with if fail_with
    @map_calls += 1
    @maps[[@map_calls - 1, @maps.size - 1].min]
  end

  def single_session_windows
    @window_calls += 1
    @screens[[@window_calls - 1, @screens.size - 1].min]
  end

  def last_call_timed_out? = !!timed_out

  def applescript_timeout = 5.0
end

class GwcFakeWindows
  attr_reader :closed
  attr_writer :result

  def initialize(result: true)
    @closed = []
    @result = result
  end

  def close_window(id)
    @closed << id
    @result
  end
end

class GwcFakeTmux
  def reattach_or_start(session, _start) = "tmux -CC attach -t \\=#{session}: || x"

  def command_for(project) = "tmuxinator start #{project} --attach"
end

class GwcFakeTty
  def initialize(commands = ["-zsh"]) = @commands = commands

  def commands(_tty) = @commands
end

RSpec.describe Workspace::GatewayWindowCloser do
  let(:now) { [0.0] }
  let(:sleeps) { [] }
  let(:sleeper) {
    ->(s) {
      sleeps << s
      now[0] += s
    }
  }
  let(:clock) { -> { now[0] } }
  let(:windows) { GwcFakeWindows.new(result: window_result) }
  let(:window_result) { true }
  let(:iterm) { GwcFakeIterm.new(maps: maps, windows: screens) }
  let(:maps) { [{}] }
  let(:screens) { [[]] }
  let(:tty) { GwcFakeTty.new }
  let(:out) { StringIO.new }
  let(:snapshot) { {"a" => {"unique_id" => "UA"}, "b" => {"unique_id" => "UB"}} }
  let(:names) { {"a" => "a", "b" => "b"} }

  def closer
    described_class.new(iterm: iterm, window_manager: windows, tmux: GwcFakeTmux.new, tty_processes: tty,
      sleeper: sleeper, clock: clock)
  end

  def run(targets, snap: snapshot)
    closer.close(targets: targets, state_snapshot: snap, session_names: names, output: out)
  end

  def gateway(project, wid: 9, uid: "G1")
    prompt = "me@host ~ %"
    contents = [
      "#{prompt} tmux -CC attach -t \\=#{project}: || tmux has-session -t \\=#{project}: || x",
      "** tmux mode started **",
      "",
      "Command Menu",
      "----------------------------",
      "esc    Detach cleanly.",
      "  X    Force-quit tmux mode.",
      "  L    Toggle logging.",
      "  C    Run tmux command.",
      "",
      "Detached",
      "",
      "#{prompt} "
    ].join("\n") + "\n"
    {window_id: wid, unique_id: uid, tty: "/dev/ttys001", contents: contents}
  end

  it "closes nothing and asks iTerm nothing for no targets" do
    expect(run({})).to eq([])
    expect(iterm.map_calls + iterm.window_calls).to eq(0)
  end

  it "closes a window whose uid is already present, without sleeping" do
    iterm.maps = [{"UA" => "3"}]
    expect(run({"a" => "UA"})).to eq([])
    expect(windows.closed).to eq([3])
    expect(sleeps).to be_empty
    expect(out.string).to include("Closing launcher window 3")
  end

  it "waits for a uid that appears on the second poll" do
    iterm.maps = [{}, {"UA" => "3"}]
    run({"a" => "UA"})
    expect(windows.closed).to eq([3])
    expect(sleeps).to eq([0.25])
  end

  it "closes a window once when targets share it" do
    iterm.maps = [{"UA" => "3", "UB" => "3"}]
    run({"a" => "UA", "b" => "UB"})
    expect(windows.closed).to eq([3])
  end

  it "leaves a window shared with a non-target's tracked uid" do
    iterm.maps = [{"UA" => "3", "UB" => "3"}]
    run({"a" => "UA"})
    expect(windows.closed).to be_empty
  end

  it "leaves a window that also holds a session nothing tracks" do
    iterm.maps = [{"UA" => "3", "UX" => "3"}]
    expect(run({"a" => "UA"})).to eq([])
    expect(windows.closed).to be_empty
  end

  it "falls back to a matching detached window when the uid never appears" do
    iterm.screens = [[gateway("a")]]
    expect(run({"a" => "UA"})).to eq([])
    expect(windows.closed).to eq([9])
    expect(out.string).to include("Closing gateway window 9")
    expect(sleeps.sum).to be >= 2.0
  end

  it "falls back for a nil uid and finds a window that shows up later" do
    iterm.screens = [[], [gateway("a")]]
    run({"a" => nil})
    expect(windows.closed).to eq([9])
    expect(iterm.map_calls).to eq(0)
  end

  it "closes nothing when only another workspace's detached window exists" do
    iterm.screens = [[gateway("b")]]
    expect(run({"a" => nil})).to eq([])
    expect(windows.closed).to be_empty
  end

  it "closes none and warns when two windows match" do
    iterm.screens = [[gateway("a", wid: 8, uid: "G1"), gateway("a", wid: 9, uid: "G2")]]
    expect(run({"a" => nil})).to eq(["More than one detached gateway window matched a; none was closed."])
    expect(windows.closed).to be_empty
  end

  it "skips a fallback window whose uid belongs to a non-target" do
    iterm.screens = [[gateway("a", uid: "UB")]]
    run({"a" => nil})
    expect(windows.closed).to be_empty
  end

  it "does not close when tty processes cannot be read" do
    iterm.screens = [[gateway("a")]]
    allow(tty).to receive(:commands).and_return(nil)
    run({"a" => nil})
    expect(windows.closed).to be_empty
  end

  it "does not close when no tty reader is given" do
    iterm.screens = [[gateway("a")]]
    c = described_class.new(iterm: iterm, window_manager: windows, tmux: GwcFakeTmux.new, tty_processes: nil,
      sleeper: sleeper, clock: clock)
    c.close(targets: {"a" => nil}, state_snapshot: snapshot, session_names: names, output: out)
    expect(windows.closed).to be_empty
  end

  it "warns when iTerm does not close the window" do
    iterm.maps = [{"UA" => "3"}]
    windows.result = false
    expect(run({"a" => "UA"})).to eq(["iTerm did not close the window 3 for a; it was left open."])
  end

  it "warns once per target and stops when iTerm times out" do
    iterm.timed_out = true
    expect(run({"a" => "UA", "b" => "UB"})).to eq([
      "iTerm did not answer in 5s; the window for a was left open.",
      "iTerm did not answer in 5s; the window for b was left open."
    ])
    expect(iterm.map_calls).to eq(1)
    expect(windows.closed).to be_empty
  end

  it "closes one target by uid and another with no uid by screen, with no warnings" do
    iterm.maps = [{"UA" => "3"}]
    iterm.screens = [[gateway("b", wid: 9)]]
    expect(run({"a" => "UA", "b" => nil})).to eq([])
    expect(windows.closed).to contain_exactly(3, 9)
    expect(out.string).to include("Closing launcher window 3", "Closing gateway window 9")
  end

  it "does not close again, by screen, a window the uid pass already closed" do
    iterm.maps = [{"UA" => "3"}]
    iterm.screens = [[gateway("b", wid: 3, uid: "UA")]]
    expect(run({"a" => "UA", "b" => nil})).to eq([])
    expect(windows.closed).to eq([3])
  end

  it "warns and closes nothing when iTerm times out listing windows for the fallback" do
    iterm.timed_out = true
    iterm.screens = [[gateway("a")]]
    expect(run({"a" => nil})).to eq(["iTerm did not answer in 5s; the window for a was left open."])
    expect(iterm.window_calls).to eq(1)
    expect(windows.closed).to be_empty
  end

  it "turns a collaborator error into a warning" do
    iterm.fail_with = RuntimeError.new("boom")
    warnings = run({"a" => "UA"})
    expect(warnings.first).to include("Could not close the launcher window for a: boom")
  end

  it "turns an error in the fallback into a warning" do
    allow(iterm).to receive(:single_session_windows).and_raise(RuntimeError, "boom")
    expect(run({"a" => nil}).first).to include("Could not close the gateway window for a: boom")
  end

  it "turns an error while closing into a warning" do
    iterm.maps = [{"UA" => "3"}]
    allow(windows).to receive(:close_window).and_raise(RuntimeError, "gone")
    expect(run({"a" => "UA"})).to eq(["Could not close the launcher window for a: gone; it was left open."])
  end

  it "types launch commands a real Tmux would build" do
    config = double(config_path_for: "/x/foo.yml")
    tmux = Workspace::Tmux.new(config: config)
    expect(tmux.reattach_or_start("foo", "").split(" || ").first).to eq("tmux -CC attach -t \\=foo:")
    expect(tmux.command_for("foo")).to eq("tmuxinator start foo --attach")
  end
end
