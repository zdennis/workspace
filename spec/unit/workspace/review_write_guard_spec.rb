require "tmpdir"

RSpec.describe Workspace::ReviewWriteGuard do
  let(:tmpdir) { Dir.mktmpdir }
  let(:checkout) { File.join(tmpdir, "repo") }
  let(:round_dir) { File.join(checkout, ".workflow", "wr_1", "reviews", "review.1.r2") }
  let(:verdict) { File.join(round_dir, "skeptic.md") }
  let(:entry) do
    {"kind" => "run", "id" => "wr_1", "role" => "reviewer", "step" => "review", "attempt" => 1, "round" => 2, "workspace" => "proj", "session" => "proj", "server_pid" => 7}
  end
  let(:bindings) { instance_double(Workspace::PaneBindings, binding_for: entry, stale?: false) }
  let(:event_log) { instance_double(Workspace::EventLog, record: nil) }
  let(:tmux) { instance_double(Workspace::Tmux, session_name_for_pane: "proj", pane_slot: "proj:0.1", server_pid_for_pane: 7) }
  let(:guard) { described_class.new(pane_bindings: bindings, tmux: tmux, env: {"TMUX_PANE" => "%2"}, event_log: event_log) }

  before do
    FileUtils.mkdir_p(round_dir)
    FileUtils.mkdir_p(File.join(checkout, ".git"))
  end

  after { FileUtils.remove_entry(tmpdir) }

  def check(tool: "Write", path: verdict, agent_id: "sub1", input: nil)
    guard.check(tool_name: tool, tool_input: input || {"file_path" => path}, cwd: checkout, agent_id: agent_id)
  end

  it "allows a sub-agent to write a verdict file, existing or not" do
    expect(check).to be_nil
    File.write(verdict, "x")
    expect(check(tool: "Edit")).to be_nil
  end

  it "refuses the main thread, even in the round directory" do
    message = check(agent_id: nil)

    expect(message).to include("review pane for run wr_1", "main thread (no sub-agent id)")
    expect(event_log).to have_received(:record).with(hash_including(type: "review_write_denied", project: "proj",
      data: hash_including("run_id" => "wr_1", "reason" => "main_thread", "tool" => "Write")))
  end

  context "in a pane bound to a direct round (direct: true)" do
    let(:entry) { super().merge("direct" => true) }

    it "allows the main thread to write the verdict file" do
      expect(check(agent_id: nil)).to be_nil
      File.write(verdict, "x")
      expect(check(tool: "Edit", agent_id: nil)).to be_nil
    end

    it "refuses a main-thread write outside the round's directory, below it, through a link, to summary.md and by apply_patch" do
      elsewhere = File.join(tmpdir, "elsewhere")
      FileUtils.mkdir_p(elsewhere)
      File.symlink(elsewhere, File.join(round_dir, "link"))
      [File.join(checkout, "lib", "a.rb"), File.join(round_dir, "..", "other.1.r1", "x.md"), File.join(round_dir, "sub", "x.md"),
        File.join(round_dir, "link", "x.md"), File.join(round_dir, "summary.md")].each do |path|
        expect(check(path: path, agent_id: nil)).to include("only its round's verdict files")
      end
      expect(check(tool: "apply_patch", input: {"command" => "x"}, agent_id: nil)).to include("verdict files")
      expect(event_log).to have_received(:record).with(hash_including(data: hash_including("reason" => "outside_round"))).at_least(:once)
    end

    it "keeps refusing the main thread when direct is anything but true" do
      allow(bindings).to receive(:binding_for).and_return(entry.merge("direct" => "true"))

      expect(check(agent_id: nil)).to include("main thread (no sub-agent id)")
    end
  end

  it "refuses a sub-agent's write outside the round's directory" do
    [File.join(checkout, "lib", "a.rb"), File.join(round_dir, "..", "other.1.r1", "x.md"), File.join(checkout, ".workflow", "wr_2", "reviews", "review.1.r2", "x.md")].each do |path|
      expect(check(path: path)).to include("only its round's verdict files")
    end
  end

  it "refuses a write with no path, an apply_patch, and a path through a link" do
    expect(check(input: {})).to include("verdict files")
    expect(check(tool: "apply_patch", input: {"command" => "x"})).to include("verdict files")
    elsewhere = File.join(tmpdir, "elsewhere")
    FileUtils.mkdir_p(elsewhere)
    File.symlink(elsewhere, File.join(round_dir, "link"))
    expect(check(path: File.join(round_dir, "link", "x.md"))).to include("verdict files")
  end

  it "reads NotebookEdit's notebook_path" do
    expect(check(tool: "NotebookEdit", input: {"notebook_path" => File.join(checkout, "a.ipynb")})).to include("verdict files")
  end

  it "ignores other tools, unbound panes, author panes and a pane with no TMUX_PANE" do
    expect(check(tool: "Read", path: "/etc/passwd")).to be_nil
    allow(bindings).to receive(:binding_for).and_return(nil)
    expect(check(path: "/etc/passwd", agent_id: nil)).to be_nil
    allow(bindings).to receive(:binding_for).and_return(entry.merge("role" => nil))
    expect(check(path: "/etc/passwd", agent_id: nil)).to be_nil
    bare = described_class.new(pane_bindings: bindings, tmux: tmux, env: {})
    expect(bare.check(tool_name: "Write", tool_input: {}, cwd: checkout, agent_id: nil)).to be_nil
  end

  it "allows the call when the bindings can't be read" do
    allow(bindings).to receive(:binding_for).and_raise(Errno::EACCES)

    expect(check(agent_id: nil)).to be_nil
  end
  it "refuses a file in a subdirectory of the round and the engine's summary.md" do
    expect(check(path: File.join(round_dir, "sub", "x.md"))).to include("verdict files")
    expect(check(path: File.join(round_dir, "summary.md"))).to include("verdict files")
  end

  it "skips a stale reviewer binding, asking tmux for the server only then" do
    allow(bindings).to receive(:stale?).and_return(true)

    expect(check(path: "/etc/passwd", agent_id: nil)).to be_nil
    expect(bindings).to have_received(:stale?).with(entry, hash_including(session: "proj", pane_slot: "proj:0.1", server_pid: kind_of(Proc)))
    expect(tmux).not_to have_received(:server_pid_for_pane)
  end

  it "skips a reviewer binding from another tmux server, through the real staleness rule" do
    real = Workspace::PaneBindings.new(path: File.join(tmpdir, "bindings.json"), error_output: StringIO.new)
    real.bind("%2", entry.merge("server_pid" => 99))
    other = described_class.new(pane_bindings: real, tmux: tmux, env: {"TMUX_PANE" => "%2"})

    expect(other.check(tool_name: "Write", tool_input: {"file_path" => "/etc/passwd"}, cwd: checkout, agent_id: "s")).to be_nil
  end

  it "refuses when the check itself fails on a live reviewer binding" do
    allow(Workspace::ReviewRoundPath).to receive(:verdict_path).and_raise(Errno::EACCES)

    expect(check).to include("could not be checked")
    expect(event_log).to have_received(:record).with(hash_including(data: hash_including("reason" => "check_failed")))
  end
end
