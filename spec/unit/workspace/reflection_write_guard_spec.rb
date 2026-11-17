require "tmpdir"

RSpec.describe Workspace::ReflectionWriteGuard do
  let(:tmpdir) { Dir.mktmpdir }
  let(:evidence) { File.join(tmpdir, "state", ".workflows", "evidence") }
  let(:run_dir) { File.join(evidence, "wr_1") }
  let(:target) { File.join(run_dir, "reflection.md") }
  let(:entry) do
    {"kind" => "reflection", "id" => "wr_1", "workspace" => "proj", "artifacts" => run_dir, "session" => "proj", "server_pid" => 7}
  end
  let(:bindings) { instance_double(Workspace::PaneBindings, binding_for: entry, stale?: false) }
  let(:event_log) { instance_double(Workspace::EventLog, record: nil) }
  let(:config) { instance_double(Workspace::Config, workflow_evidence_dir: evidence) }
  let(:tmux) { instance_double(Workspace::Tmux, session_name_for_pane: "proj", pane_slot: "proj:0.1", server_pid_for_pane: 7) }
  let(:guard) { described_class.new(pane_bindings: bindings, tmux: tmux, config: config, env: {"TMUX_PANE" => "%2"}, event_log: event_log) }

  before { FileUtils.mkdir_p(run_dir) }

  after { FileUtils.remove_entry(tmpdir) }

  def check(tool: "Write", path: target, agent_id: nil, input: nil, cwd: tmpdir)
    guard.check(tool_name: tool, tool_input: input || {"file_path" => path}, cwd: cwd, agent_id: agent_id)
  end

  it "allows reflection.md from the main thread and from a sub-agent, existing or not" do
    expect(check).to be_nil
    expect(check(agent_id: "sub1")).to be_nil
    File.write(target, "x")
    expect(check(tool: "Edit")).to be_nil
    expect(check(tool: "MultiEdit")).to be_nil
  end

  it "reads NotebookEdit's notebook_path and resolves a relative path against cwd" do
    expect(check(tool: "NotebookEdit", input: {"notebook_path" => target})).to be_nil
    expect(check(path: "reflection.md", cwd: run_dir)).to be_nil
  end

  it "refuses another file, a subdirectory, a path outside, and a missing path" do
    [File.join(run_dir, "reflection.prompt.md"), File.join(run_dir, "sub", "reflection.md"), File.join(evidence, "wr_2", "reflection.md"),
      File.join(tmpdir, "lib", "a.rb"), File.join(run_dir, "..", "reflection.md")].each do |path|
      expect(check(path: path)).to include("denied: this is a reflection pane for run wr_1", "reflection.md")
    end
    expect(check(input: {})).to include("denied")
    expect(check(input: {"file_path" => "#{target}\n"})).to include("denied")
  end

  it "refuses apply_patch, even aimed at the allowed path" do
    expect(check(tool: "apply_patch", input: {"command" => "x"})).to include("denied")
    expect(check(tool: "apply_patch", input: {"file_path" => target})).to include("denied")
  end

  it "refuses a path with a control character, a trailing slash, and MultiEdit with a bad path" do
    expect(check(path: "#{target}\u0007")).to include("denied")
    expect(check(path: "#{target}/")).to include("denied")
    expect(check(tool: "MultiEdit", path: File.join(run_dir, "other.md"))).to include("denied")
  end

  it "reads the key that belongs to the tool and refuses two keys that differ" do
    other = File.join(run_dir, "other.md")

    expect(check(tool: "NotebookEdit", input: {"file_path" => target, "notebook_path" => other})).to include("denied")
    expect(check(tool: "Write", input: {"file_path" => other, "notebook_path" => target})).to include("denied")
    expect(check(tool: "NotebookEdit", input: {"file_path" => target})).to include("denied")
    expect(check(tool: "Write", input: {"file_path" => target, "notebook_path" => target})).to be_nil
  end

  it "refuses a symlinked evidence directory" do
    FileUtils.remove_entry(File.join(tmpdir, "state", ".workflows", "evidence"))
    other = File.join(tmpdir, "other")
    FileUtils.mkdir_p(File.join(other, "wr_1"))
    File.symlink(other, evidence)

    expect(check).to include("denied")
  end

  it "names the allowed path and the way out in a denial, and records it" do
    message = check(path: File.join(run_dir, "other.md"))

    expect(message).to include(target, "workspace binding clear --pane %2", "close the pane")
    expect(event_log).to have_received(:record).with(hash_including(type: "reflection_write_denied", project: "proj",
      data: hash_including("run_id" => "wr_1", "reason" => "outside_file", "tool" => "Write")))
  end

  it "refuses a symlinked reflection.md" do
    elsewhere = File.join(tmpdir, "elsewhere.md")
    File.write(elsewhere, "x")
    File.symlink(elsewhere, target)

    expect(check).to include("denied")
  end

  it "refuses a symlinked run directory" do
    FileUtils.remove_entry(run_dir)
    other = File.join(tmpdir, "other")
    FileUtils.mkdir_p(other)
    File.symlink(other, run_dir)

    expect(check).to include("denied")
  end

  it "ignores the binding's artifacts: a write to another directory's reflection.md is refused" do
    other = File.join(tmpdir, "other")
    FileUtils.mkdir_p(other)
    allow(bindings).to receive(:binding_for).and_return(entry.merge("artifacts" => other))

    expect(check(path: File.join(other, "reflection.md"))).to include("denied")
    expect(check).to be_nil
  end

  it "refuses every write for a binding whose id is not a valid run id" do
    ["../x", "a/b", "", nil, 7].each do |id|
      allow(bindings).to receive(:binding_for).and_return(entry.merge("id" => id))

      expect(check(path: File.join(evidence, "x", "reflection.md"))).to include("not a valid run id")
    end
  end

  it "ignores other tools, unbound panes, run and reviewer panes and a pane with no TMUX_PANE" do
    expect(check(tool: "Read", path: "/etc/passwd")).to be_nil
    allow(bindings).to receive(:binding_for).and_return(nil)
    expect(check(path: "/etc/passwd")).to be_nil
    allow(bindings).to receive(:binding_for).and_return(entry.merge("kind" => "run", "role" => "reviewer"))
    expect(check(path: "/etc/passwd")).to be_nil
    allow(bindings).to receive(:binding_for).and_return(entry.merge("kind" => "run"))
    expect(check(path: "/etc/passwd")).to be_nil
    bare = described_class.new(pane_bindings: bindings, tmux: tmux, config: config, env: {})
    expect(bare.check(tool_name: "Write", tool_input: {}, cwd: tmpdir, agent_id: nil)).to be_nil
  end

  it "allows the call when the bindings can't be read" do
    allow(bindings).to receive(:binding_for).and_raise(Errno::EACCES)

    expect(check(path: "/etc/passwd")).to be_nil
  end

  it "skips a stale binding, asking tmux for the server only then" do
    allow(bindings).to receive(:stale?).and_return(true)

    expect(check(path: "/etc/passwd")).to be_nil
    expect(bindings).to have_received(:stale?).with(entry, hash_including(session: "proj", pane_slot: "proj:0.1", server_pid: kind_of(Proc)))
    expect(tmux).not_to have_received(:server_pid_for_pane)
  end

  it "skips a binding from another tmux server, through the real staleness rule" do
    real = Workspace::PaneBindings.new(path: File.join(tmpdir, "bindings.json"), error_output: StringIO.new)
    real.bind("%2", entry.merge("server_pid" => 99))
    other = described_class.new(pane_bindings: real, tmux: tmux, config: config, env: {"TMUX_PANE" => "%2"})

    expect(other.check(tool_name: "Write", tool_input: {"file_path" => "/etc/passwd"}, cwd: tmpdir, agent_id: nil)).to be_nil
  end

  it "refuses when the staleness check raises after a reflection binding was found" do
    allow(bindings).to receive(:stale?).and_raise(Errno::ECONNREFUSED)

    expect(check).to include("could not be checked")
    expect(event_log).to have_received(:record).with(hash_including(data: hash_including("reason" => "check_failed")))
  end

  it "refuses when the check itself fails on a live binding" do
    allow(Workspace::ReviewRoundPath).to receive(:linked_below?).and_raise(Errno::EACCES)

    expect(check).to include("could not be checked")
    expect(event_log).to have_received(:record).with(hash_including(data: hash_including("reason" => "check_failed")))
  end

  describe "#release" do
    let(:bindings) { instance_double(Workspace::PaneBindings, binding_for: entry, stale?: false, unbind: entry) }

    def release(hook, pane_id: "%2", reason: nil)
      guard.release(pane_id: pane_id, hook: hook, reason: reason)
    end

    it "unbinds on Stop when reflection.md is a regular file" do
      File.write(target, "x")
      release("Stop")

      expect(bindings).to have_received(:unbind).with("%2")
    end

    it "keeps the binding on Stop without the file, with a symlinked file, or with a directory" do
      release("Stop")
      File.symlink(File.join(tmpdir, "elsewhere"), target)
      File.write(File.join(tmpdir, "elsewhere"), "x")
      release("Stop")
      File.delete(target)
      FileUtils.mkdir_p(target)
      release("Stop")

      expect(bindings).not_to have_received(:unbind)
    end

    it "unbinds on SessionEnd whatever the file's state" do
      release("SessionEnd")

      expect(bindings).to have_received(:unbind).with("%2")
    end

    it "keeps the binding on a SessionEnd for clear and unbinds for any other reason" do
      release("SessionEnd", reason: "clear")
      expect(bindings).not_to have_received(:unbind)

      %w[logout prompt_input_exit other].each { |reason| release("SessionEnd", reason: reason) }
      expect(bindings).to have_received(:unbind).with("%2").exactly(3).times
    end

    it "keeps the binding on Stop when the run directory is a symlink" do
      FileUtils.remove_entry(run_dir)
      FileUtils.mkdir_p(File.join(tmpdir, "elsewhere"))
      File.write(File.join(tmpdir, "elsewhere", "reflection.md"), "x")
      File.symlink(File.join(tmpdir, "elsewhere"), run_dir)
      release("Stop")

      expect(bindings).not_to have_received(:unbind)
    end

    it "does nothing for other hooks, other binding kinds, stale bindings or no pane" do
      File.write(target, "x")
      release("UserPromptSubmit")
      release("Stop", pane_id: nil)
      allow(bindings).to receive(:stale?).and_return(true)
      release("SessionEnd")
      allow(bindings).to receive(:stale?).and_return(false)
      allow(bindings).to receive(:binding_for).and_return(entry.merge("kind" => "run"))
      release("SessionEnd")

      expect(bindings).not_to have_received(:unbind)
    end

    it "does not raise when the store raises" do
      allow(bindings).to receive(:unbind).and_raise(Errno::EACCES)

      expect { release("SessionEnd") }.not_to raise_error
    end
  end
end
