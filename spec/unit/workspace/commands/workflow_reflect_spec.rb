require "spec_helper"
require "tmpdir"
require "stringio"
require "json"
require "digest"

RSpec.describe Workspace::Commands::WorkflowReflect do
  around do |example|
    Dir.mktmpdir("wf-reflect-cmd") do |dir|
      @dir = File.realpath(dir)
      example.run
    end
  end

  let(:runs_dir) { File.join(@dir, "runs") }
  let(:evidence) { File.join(@dir, "evidence") }
  let(:run_dir) { File.join(evidence, "wr_1") }
  let(:output) { StringIO.new }
  let(:store) { Workspace::WorkflowRunStore.new(dir: runs_dir, archive_dir: File.join(@dir, "archive")) }
  let(:reflection) { instance_double(Workspace::WorkflowReflection, compose: "INSTRUCTIONS\n") }
  let(:ready) { Workspace::AgentReadiness::Result.new(ready: true, pane: "0.2", pane_id: "%23", label: "Claude Code") }
  let(:spawned) { Workspace::PaneDispatch::Spawned.new(pane: "%23", ready: ready, label: "Claude Code", closed: false) }
  let(:delivered) { [] }
  let(:panes) do
    instance_double(Workspace::PaneDispatch, spawn: spawned, close_unused: true, not_ready_message: "not ready", not_ready_details: {"pane_id" => "%23", "pane_closed" => true}).tap do |dispatch|
      allow(dispatch).to receive(:deliver) { |_ws, pane, **opts| delivered << [pane, opts] }
    end
  end
  let(:binder) { instance_double(Workspace::Commands::Binding, bind: {}, reflecting: nil) }
  let(:bindings) { instance_double(Workspace::PaneBindings, pane_for: nil, unbind: nil) }
  let(:main_agent) { instance_double(Workspace::MainAgent, kind: "claude") }
  let(:run_hash) {
    {"id" => "wr_1", "workspace" => "api", "state" => "completed", "pane" => "%5", "created_at" => "2026-11-17T10:00:00Z",
     "current" => "build", "definition" => {"steps" => [{"id" => "build"}]}, "steps" => {"build" => {"state" => "done", "attempts" => []}}}
  }
  subject(:command) do
    described_class.new(store: store, reflection: reflection, panes: panes, binder: binder, bindings: bindings, main_agent: main_agent,
      evidence_dir: evidence, output: output)
  end

  before { write_run(run_hash) }

  def write_run(hash)
    FileUtils.mkdir_p(runs_dir)
    File.write(File.join(runs_dir, "#{hash["id"]}.json"), JSON.generate(hash))
    File.write(File.join(runs_dir, "#{hash["id"]}.events.jsonl"), "{\"type\":\"x\"}\n")
  end

  def run_digests
    Dir[File.join(runs_dir, "*")].sort.to_h { |path| [File.basename(path), Digest::SHA256.file(path).hexdigest] }
  end

  it "spawns a split pane, binds it as a reflection and types one line into it only" do
    doc = command.call(run: "wr_1")
    expect(panes).to have_received(:spawn).with("api", "claude")
    expect(binder).to have_received(:bind).with(workspace: "api", pane: "%23", kind: "reflection", id: "wr_1", artifacts: run_dir,
      instructions: File.join(run_dir, "reflection.prompt.md"))
    expect(delivered.map(&:first)).to eq(["%23"])
    expect(delivered.first.last[:body]).to include("wr_1", File.join(run_dir, "reflection.prompt.md"))
    expect(File.read(File.join(run_dir, "reflection.prompt.md"))).to eq("INSTRUCTIONS\n")
    expect(doc).to include("pane" => "%23", "path" => File.join(run_dir, "reflection.md"), "exists" => false)
    expect(output.string).to include("pane %23", File.join(run_dir, "reflection.md"), "binding clear --pane %23")
  end

  it "leaves the run's file and events as they were" do
    before = run_digests
    command.call(run: "wr_1")
    expect(run_digests).to eq(before)
  end

  it "never takes the run lock or changes the run" do
    expect(store).not_to receive(:change)
    expect(store).not_to receive(:record_event)
    command.call(run: "wr_1")
  end

  it "uses the agent given, else the workspace's main agent" do
    command.call(run: "wr_1", agent: "codex")
    expect(panes).to have_received(:spawn).with("api", "codex")
  end

  it "refuses an agent kind it does not know before anything is made" do
    expect { command.call(run: "wr_1", agent: "vim") }.to raise_error(Workspace::UsageError, /Unknown agent/)
    expect(panes).not_to have_received(:spawn)
  end

  it "raises unknown_run for a run that does not exist" do
    expect { command.call(run: "wr_nope") }.to raise_error(Workspace::Error) { |e| expect(e.code).to eq("unknown_run") }
  end

  it "refuses a run that is not finished and writes nothing" do
    write_run(run_hash.merge("state" => "running"))
    expect { command.call(run: "wr_1") }.to raise_error(Workspace::Error) { |e|
      expect(e.code).to eq("run_not_finished")
      expect(e.details).to include("run_id" => "wr_1", "state" => "running")
    }
    expect(panes).not_to have_received(:spawn)
    expect(File.exist?(run_dir)).to be(false)
  end

  it "refuses a second reflection while a live pane holds the first, writing and spawning nothing" do
    allow(bindings).to receive(:pane_for).with("reflection", "wr_1").and_return("%30")
    allow(binder).to receive(:reflecting).with(pane: "%30").and_return({"kind" => "reflection"})
    expect { command.call(run: "wr_1") }.to raise_error(Workspace::Error) { |e|
      expect(e.code).to eq("reflection_in_progress")
      expect(e.details).to include("run_id" => "wr_1", "pane" => "%30")
      expect(e.details["use"]).to include("binding clear --pane %30")
    }
    expect(panes).not_to have_received(:spawn)
    expect(File.exist?(File.join(run_dir, "reflection.prompt.md"))).to be(false)
  end

  it "clears a stale reflection binding for the run and goes on" do
    allow(bindings).to receive(:pane_for).with("reflection", "wr_1").and_return("%30")
    command.call(run: "wr_1")
    expect(bindings).to have_received(:unbind).with("%30")
    expect(panes).to have_received(:spawn)
  end

  it "prints an existing reflection.md escaped, and launches nothing" do
    FileUtils.mkdir_p(run_dir)
    File.write(File.join(run_dir, "reflection.md"), "Good run\n\e[31mred\e[0m\n")
    doc = command.call(run: "wr_1")
    expect(output.string).to include(File.join(run_dir, "reflection.md"), "Good run", "\\e[31mred")
    expect(output.string).not_to include("\e")
    expect(doc).to include("exists" => true, "text" => "Good run\n\e[31mred\e[0m\n", "truncated" => false)
    expect(panes).not_to have_received(:spawn)
    expect(delivered).to be_empty
  end

  it "refuses an evidence directory reached through a link" do
    FileUtils.mkdir_p(evidence)
    FileUtils.mkdir_p(File.join(@dir, "elsewhere"))
    File.symlink(File.join(@dir, "elsewhere"), run_dir)
    expect { command.call(run: "wr_1") }.to raise_error(Workspace::Error) { |e| expect(e.code).to eq("evidence_dir_linked") }
    expect(Dir.children(File.join(@dir, "elsewhere"))).to be_empty
  end

  it "closes the new pane and types nothing when it is the run's own pane" do
    allow(panes).to receive(:spawn).and_return(Workspace::PaneDispatch::Spawned.new(pane: "%5", ready: ready, label: "Claude Code", closed: false))
    expect { command.call(run: "wr_1") }.to raise_error(Workspace::Error) { |e|
      expect(e.code).to eq("pane_bound_to_run")
      expect(e.details).to include("pane" => "%5", "run_id" => "wr_1")
    }
    expect(panes).to have_received(:close_unused).with("api", "%5")
    expect(delivered).to be_empty
    expect(binder).not_to have_received(:bind)
  end

  it "treats a parked pane and a run binding as the run's pane too" do
    write_run(run_hash.merge("pane" => nil, "parked" => {"pane" => "%23"}))
    expect { command.call(run: "wr_1") }.to raise_error(Workspace::Error) { |e| expect(e.code).to eq("pane_bound_to_run") }
    write_run(run_hash.merge("pane" => nil))
    allow(bindings).to receive(:pane_for).with("run", "wr_1").and_return("%23")
    expect { command.call(run: "wr_1") }.to raise_error(Workspace::Error) { |e| expect(e.code).to eq("pane_bound_to_run") }
    expect(delivered).to be_empty
  end

  it "raises agent_not_ready with the pane's details when the agent is not ready" do
    not_ready = Workspace::AgentReadiness::Result.new(ready: false, pane: "0.2", pane_id: "%23", label: "Claude Code", reason: "timeout")
    allow(panes).to receive(:spawn).and_return(Workspace::PaneDispatch::Spawned.new(pane: "%23", ready: not_ready, label: "Claude Code", closed: true))
    expect { command.call(run: "wr_1") }.to raise_error(Workspace::Error) { |e|
      expect(e.code).to eq("agent_not_ready")
      expect(e.message).to eq("not ready")
      expect(e.details).to include("pane_id" => "%23")
    }
    expect(delivered).to be_empty
    expect(binder).not_to have_received(:bind)
  end

  it "unbinds and closes the new pane when delivery fails, and re-raises" do
    allow(panes).to receive(:deliver).and_raise(Workspace::Error.new("busy", code: "pane_busy"))
    expect { command.call(run: "wr_1") }.to raise_error(Workspace::Error) { |e| expect(e.code).to eq("pane_busy") }
    expect(bindings).to have_received(:unbind).with("%23")
    expect(panes).to have_received(:close_unused).with("api", "%23")
  end

  it "unbinds and closes the new pane when binding fails" do
    allow(binder).to receive(:bind).and_raise(Workspace::Error.new("no pane", code: "no_such_pane"))
    expect { command.call(run: "wr_1") }.to raise_error(Workspace::Error)
    expect(bindings).to have_received(:unbind).with("%23")
    expect(delivered).to be_empty
  end

  it "prints one JSON document when asked" do
    command.call(run: "wr_1", json: true)
    expect(JSON.parse(output.string)).to eq("schema_version" => 1, "ok" => true, "run" => "wr_1", "pane" => "%23",
      "path" => File.join(run_dir, "reflection.md"), "instructions" => File.join(run_dir, "reflection.prompt.md"), "exists" => false)
  end

  it "prints the existing text as JSON" do
    FileUtils.mkdir_p(run_dir)
    File.write(File.join(run_dir, "reflection.md"), "done\n")
    command.call(run: "wr_1", json: true)
    expect(JSON.parse(output.string)).to eq("schema_version" => 1, "ok" => true, "run" => "wr_1", "path" => File.join(run_dir, "reflection.md"),
      "exists" => true, "text" => "done\n", "truncated" => false)
  end

  it "caps an existing reflection.md and says it was cut" do
    FileUtils.mkdir_p(run_dir)
    File.write(File.join(run_dir, "reflection.md"), "a" * (described_class::MAX_TEXT_BYTES + 10))
    doc = command.call(run: "wr_1", json: true)
    expect(doc["truncated"]).to be(true)
    expect(doc["text"].bytesize).to eq(described_class::MAX_TEXT_BYTES)
  end

  describe "a reflection.md that is not a regular file" do
    def expect_refused
      expect { command.call(run: "wr_1") }.to raise_error(Workspace::Error) { |e|
        expect(e.code).to eq("reflection_path_not_file")
        expect(e.details).to include("run_id" => "wr_1", "path" => File.join(run_dir, "reflection.md"))
      }
      expect(panes).not_to have_received(:spawn)
      expect(bindings).not_to have_received(:pane_for)
      expect(File.exist?(File.join(run_dir, "reflection.prompt.md"))).to be(false)
    end

    before { FileUtils.mkdir_p(run_dir) }

    it "is refused for a symlink" do
      File.write(File.join(@dir, "target"), "x")
      File.symlink(File.join(@dir, "target"), File.join(run_dir, "reflection.md"))
      expect_refused
    end

    it "is refused for a dangling link" do
      File.symlink(File.join(@dir, "missing"), File.join(run_dir, "reflection.md"))
      expect_refused
    end

    it "is refused for a directory" do
      Dir.mkdir(File.join(run_dir, "reflection.md"))
      expect_refused
    end
  end

  describe "which runs may be reflected on" do
    %w[completed failed cancelled].each do |state|
      it "allows #{state}" do
        write_run(run_hash.merge("state" => state))
        expect(command.call(run: "wr_1")).to include("exists" => false)
      end
    end

    %w[going parked waiting_you reviewing].each do |state|
      it "refuses #{state}" do
        write_run(run_hash.merge("state" => state))
        expect { command.call(run: "wr_1") }.to raise_error(Workspace::Error) { |e| expect(e.code).to eq("run_not_finished") }
      end
    end

    it "escapes and caps the state it names" do
      write_run(run_hash.merge("state" => "\e[31m" + "x" * 100))
      expect { command.call(run: "wr_1") }.to raise_error(Workspace::Error) { |e|
        expect(e.message).not_to include("\e")
        expect(e.details["state"].length).to be <= 40
        expect(e.details["state"]).not_to include("\e")
      }
    end
  end

  it "answers unknown_run, with run_id, for an id that is not a run id" do
    expect { command.call(run: "../x") }.to raise_error(Workspace::Error) { |e|
      expect(e.code).to eq("unknown_run")
      expect(e.details).to include("run_id")
    }
    expect(panes).not_to have_received(:spawn)
  end
end
