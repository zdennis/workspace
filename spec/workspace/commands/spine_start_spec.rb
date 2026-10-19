require "spec_helper"
require "tmpdir"
require "stringio"
require "json"

RSpec.describe Workspace::Commands::SpineStart do
  around do |example|
    Dir.mktmpdir("spine-start") do |dir|
      @root = File.realpath(dir)
      @notes = File.join(@root, "notes")
      FileUtils.mkdir_p(@notes)
      example.run
    end
  end

  let(:output) { StringIO.new }
  let(:steps) { [] }
  let(:notes) { instance_double(Workspace::Commands::Notes, checkout_root: "/src/api") }
  let(:events) { [] }
  let(:event_log) do
    instance_double(Workspace::EventLog, latest_agent_states: {}).tap do |log|
      allow(log).to receive(:record) { |**event| events << event }
    end
  end
  let(:spine) do
    Workspace::Commands::Spine.new(notes: notes, writer: Workspace::SpineWriter.new, event_log: event_log, lock_dir: File.join(@root, "state"),
      clock: -> { Time.utc(2026, 10, 18, 9, 0, 0) }, output: StringIO.new)
  end
  let(:pane_rows) { [{"pane_id" => "%20", "kind" => "shell", "state" => "idle"}, {"pane_id" => "%21", "kind" => "claude", "state" => "idle"}] }
  let(:snapshot_client) { instance_double(Workspace::AgentSnapshotClient) }
  let(:sender) { instance_double(Workspace::Commands::Send) }
  let(:binder) { instance_double(Workspace::Commands::Binding, live: nil) }
  let(:runner) { instance_double(Workspace::Commands::Run, call: "%23") }
  let(:main_agent) { instance_double(Workspace::MainAgent, spawn_command: "codex --from-config") }
  let(:ready) { Workspace::AgentReadiness::Result.new(ready: true, pane: "0.2", pane_id: "%23", label: "Codex") }
  let(:readiness) { instance_double(Workspace::AgentReadiness, deadline_in: 9.0, wait: ready) }
  let(:sessions) { ["api"] }
  let(:tmux) { instance_double(Workspace::Tmux, custom_socket_option: nil, session_name_for: "api") }
  let(:library) do
    Workspace::Library.allocate.tap do |lib|
      allow(lib).to receive(:play) { |ref, cwd:| {"ref" => "play/#{ref.sub(%r{\Aplay/}, "")}", "path" => "/lib/#{ref}.md"} }
      allow(lib).to receive(:pack) { |ref, cwd:| [{"ref" => "play/#{ref}", "path" => "/builtin/#{ref}.md"}, "body"] }
    end
  end
  let(:composer) { instance_double(Workspace::InstructionComposer, compose: {"packs" => [], "text" => "## From pack spine (built-in)\n\nKeep it current.\n"}) }
  let(:launcher) { double("launcher") }
  let(:panes) do
    Workspace::PaneDispatch.new(snapshot_client: snapshot_client, sender: sender, binder: binder, library: library,
      runner: runner, readiness: readiness, main_agent: main_agent, tmux: tmux, prompt_timeout: 30)
  end
  subject(:command) { described_class.new(spine: spine, panes: panes, library: library, composer: composer, notes: notes, output: output) }

  before do
    allow(notes).to receive(:info).with(name: "api").and_return({"workspace" => "api", "dir" => @notes})
    allow(tmux).to receive(:sessions).with(strict: true) { sessions }
    allow(snapshot_client).to receive(:fetch).with("api", timeout: 1.0) { {"panes" => pane_rows} }
    allow(sender).to receive(:locate) { |_ws, spec| {id: spec, session: "api"} }
    allow(sender).to receive(:deliver) do |name:, pane:, body:|
      steps << [:deliver, pane, stage_text("40-verify.md")]
      {"pane" => pane, "submitted" => true}
    end
    allow(binder).to receive(:bind) { |workspace:, pane:, **fields| steps << [:bind, pane, fields] }
    write("10-research.md", "---\nstatus: completed\nkind: research\n---\n")
    write("40-verify.md", "---\ntitle: Verify \"it\"\nstatus: not_started\nkind: verify\ndepends_on: [research]\n---\nBody\n")
  end

  def write(relative, text)
    path = File.join(@notes, "spine", relative)
    FileUtils.mkdir_p(File.dirname(path))
    File.binwrite(path, text)
  end

  def stage_text(relative) = File.binread(File.join(@notes, "spine", relative))

  def stage_file(relative = "40-verify.md") = Workspace::SpineFile.read(File.join(@notes, "spine", relative))

  def start(**args) = command.start(name: "api", path: "verify", launch: launcher, **args)

  def refusal
    yield
    raise "no refusal"
  rescue Workspace::Error => e
    e
  end

  it "writes status and owner before the brief is typed, then binds the pane with the spine pack" do
    doc = start

    deliver = steps.find { |step| step[0] == :deliver }
    expect(deliver[1]).to eq("%21")
    expect(deliver[2]).to include("status: in_progress", "owner: \"%21\"", "updated_by: claude %21")
    expect(steps.map(&:first)).to eq(%i[deliver bind])
    expect(steps.last[2]).to eq("kind" => "play", "id" => "play/spine", "packs" => ["spine"], "focus" => "spine stage verify")
    expect(doc).to eq("schema_version" => 1, "ok" => true, "workspace" => "api", "path" => "verify", "file" => "40-verify.md",
      "outcome" => "sent", "reason" => nil, "pane" => "%21", "owner" => "%21", "status" => "in_progress", "previous" => "not_started",
      "revision" => stage_file.revision, "play" => nil, "message" => nil)
    expect(events.map { |e| e[:data].slice("path", "status", "owner", "by") }).to eq([{"path" => "verify", "status" => "in_progress", "owner" => "%21", "by" => "claude %21"}])
  end

  it "types a brief that names the stage and its file, quotes the title as data, and carries the spine pack" do
    start

    body = nil
    expect(sender).to have_received(:deliver) { |**args| body = args[:body] }
    expect(body).to include("## From pack spine", "stage verify", "titled \"Verify \\\"it\\\"\"", File.join(@notes, "spine", "40-verify.md").to_json)
    expect(composer).to have_received(:compose).with(packs: ["spine"], cwd: "/src/api")
  end

  it "picks the play from --play, then the file's play:, then the stage's kind" do
    pane_rows << {"pane_id" => "%22", "kind" => "claude", "state" => "idle"}
    write("20-plan.md", "---\nstatus: not_started\nkind: plan\n---\n")
    expect(command.start(name: "api", path: "plan", launch: launcher)["play"]).to eq("play/implementation-plan")

    write("30-build.md", "---\nstatus: not_started\nplay: team-build\n---\n")
    expect(command.start(name: "api", path: "build", launch: launcher, pane: "%22")["play"]).to eq("play/team-build")
    expect(start(play: "custom", pane: "%22")["play"]).to eq("play/custom")
    bound = steps.reverse.find { |step| step[0] == :bind }
    expect(bound[2]).to include("id" => "play/custom", "packs" => ["spine"], "focus" => "spine stage verify")
  end

  describe "refusals leave the file untouched and type nothing" do
    before { @before = stage_text("40-verify.md") }

    after do
      expect(stage_text("40-verify.md")).to eq(@before)
      expect(sender).not_to have_received(:deliver)
      expect(events).to eq([])
    end

    it "refuses a completed or skipped stage with stage_done" do
      write("40-verify.md", "---\nstatus: skipped\n---\n")
      @before = stage_text("40-verify.md")

      error = refusal { start }
      expect(error.code).to eq("stage_done")
      expect(error.message).to include("spine set api verify --status in_progress")
    end

    it "refuses a stage whose depends_on stage is not done by its file, with waits_on" do
      write("10-research.md", "---\nstatus: in_progress\n---\n")

      error = refusal { start }
      expect(error.code).to eq("stage_waiting")
      expect(error.details["waits_on"]).to eq(["research"])
    end

    it "refuses a stage whose dependency claims completed but has no passing check, naming why" do
      write("10-research.md", "---\nstatus: completed\ncheck: pending\n---\n")
      error = refusal { start }
      expect(error.code).to eq("stage_waiting")
      expect(error.details).to include("waits_on" => ["research"], "reasons" => {"research" => "check_pending"})
      expect(error.message).to include("research: check_pending")

      write("10-research.md", "---\nstatus: completed\ncheck: failed\n---\n")
      expect(refusal { start }.details["reasons"]).to eq("research" => "check_failed")
    end

    it "refuses a stage whose folder-only dependency has a sub-stage still being checked" do
      FileUtils.rm_f(File.join(@notes, "spine", "10-research.md"))
      write("10-research/10-a.md", "---\nstatus: completed\ncheck: required\n---\n")
      error = refusal { start }
      expect(error.code).to eq("stage_waiting")
      expect(error.details).to include("waits_on" => ["research"], "reasons" => {})
    end

    it "refuses a stale --if-revision" do
      expect(refusal { start(if_revision: "00000000") }.code).to eq("stale_revision")
    end

    it "refuses a pane that waits on a person or works on something else" do
      pane_rows[1]["state"] = "waiting"
      expect(refusal { start }.code).to eq("pane_busy")
      pane_rows[1]["state"] = "working"
      expect(refusal { start }.details["state"]).to eq("working")
    end

    it "refuses another pane while the owner pane works on the stage" do
      write("40-verify.md", @before.sub("kind: verify", "owner: \"%21\""))
      @before = stage_text("40-verify.md")
      pane_rows[1]["state"] = "working"

      error = refusal { start(pane: "%22") }
      expect(error.code).to eq("stage_owned")
      expect(error.details["owner"]).to eq("%21")
      expect(refusal { start(spawn: "codex") }.code).to eq("stage_owned")
      expect(runner).not_to have_received(:call)
    end

    it "refuses a pane with no coding agent, and a workspace with no agent pane" do
      expect(refusal { start(pane: "%20") }.code).to eq("no_agent_pane")
      pane_rows.pop
      expect(refusal { start }.code).to eq("no_agent_pane")
    end

    it "refuses --pane and --spawn when there is no session" do
      sessions.clear
      expect(refusal { start(pane: "%21") }.code).to eq("no_session")
      expect(refusal { start(spawn: "claude") }.code).to eq("no_session")
    end

    it "refuses when the agent daemon does not answer" do
      allow(snapshot_client).to receive(:fetch).and_raise(Workspace::AgentSnapshotClient::Unavailable.new("down", reason: :no_daemon))
      expect(refusal { start }.code).to eq("no_daemon")
    end
  end

  it "goes ahead with a matching --if-revision and reports the revision after the write" do
    before = stage_file.revision

    doc = start(if_revision: before.upcase)

    expect(doc["outcome"]).to eq("sent")
    expect(doc["revision"]).to eq(stage_file.revision).and(satisfy { |rev| rev != before })
  end

  it "says already_working and writes nothing when the owner pane already works on the stage" do
    write("40-verify.md", "---\nstatus: in_progress\nowner: \"%21\"\n---\n")
    before = stage_text("40-verify.md")
    pane_rows[1]["state"] = "working"

    doc = start

    expect(doc).to include("outcome" => "already_working", "pane" => "%21", "owner" => "%21", "status" => "in_progress", "revision" => stage_file.revision)
    expect(stage_text("40-verify.md")).to eq(before)
    expect(sender).not_to have_received(:deliver)
  end

  it "sends to the stage's owner when it is a live agent pane" do
    pane_rows << {"pane_id" => "%30", "kind" => "codex", "state" => "idle"}
    write("40-verify.md", "---\nstatus: blocked\nnote: waiting\nowner: \"%30\"\n---\n")

    doc = start

    expect(doc).to include("outcome" => "sent", "pane" => "%30", "previous" => "blocked", "status" => "in_progress")
    expect(stage_file.value("note")).to be_nil
  end

  describe "a failed delivery" do
    before { allow(sender).to receive(:deliver).and_raise(Workspace::Error.new("not submitted", code: "not_submitted")) }

    it "leaves the file as written and says how to set it back, binding nothing" do
      doc = start

      expect(doc).to include("ok" => false, "outcome" => "failed", "reason" => "not_submitted", "pane" => "%21", "owner" => "%21", "status" => "in_progress")
      expect(doc["message"]).to include("not submitted", "workspace spine set api verify --status not_started --owner ''")
      expect(stage_file.status).to eq("in_progress")
      expect(binder).not_to have_received(:bind)
    end
  end

  describe "--spawn" do
    it "waits for the new agent, then writes it as the owner, types and binds" do
      doc = start(spawn: "codex")

      expect(runner).to have_received(:call).with("api", "codex --from-config", split: true)
      expect(readiness).to have_received(:wait).with("api", deadline: 9.0, only_pane: "%23")
      expect(steps.first[2]).to include("owner: \"%23\"", "updated_by: codex %23")
      expect(doc).to include("outcome" => "spawned", "pane" => "%23", "owner" => "%23")
    end

    it "names the new pane when the write under the lock refuses after the split" do
      allow(readiness).to receive(:wait) do
        write("40-verify.md", "---\nstatus: completed\n---\n")
        ready
      end

      error = refusal { start(spawn: "codex") }
      expect(error.code).to eq("stage_done")
      expect(error.details["pane"]).to eq("%23")
      expect(error.message).to include("new pane %23 was left open")
      expect(sender).not_to have_received(:deliver)
    end

    it "writes and types nothing when the new agent is not ready" do
      before = stage_text("40-verify.md")
      allow(readiness).to receive(:wait).and_return(Workspace::AgentReadiness::Result.new(ready: false, reason: "timeout", pane: nil, pane_id: "%23", label: "Codex"))

      doc = start(spawn: "codex")

      expect(doc).to include("ok" => false, "outcome" => "failed", "reason" => "prompt_not_sent", "pane" => "%23", "status" => "not_started")
      expect(stage_text("40-verify.md")).to eq(before)
      expect(sender).not_to have_received(:deliver)
    end
  end

  describe "with no session" do
    before { sessions.clear }

    it "writes in_progress, launches with the play and the brief, then records the owner and binds it" do
      write("40-verify.md", "---\nstatus: not_started\nkind: research\n---\n")
      seen = nil
      allow(launcher).to receive(:call) do |ws, play, brief|
        seen = [ws, play, brief, stage_file.status]
        {ok: true, reason: nil, message: nil, pane: "%40"}
      end

      doc = start

      expect(seen[0..1]).to eq(["api", "play/research"])
      expect(seen[2]).to include("stage verify")
      expect(seen[3]).to eq("in_progress")
      expect(doc).to include("outcome" => "launched", "pane" => "%40", "owner" => "%40", "status" => "in_progress", "previous" => "not_started", "play" => "play/research")
      expect(stage_file.value("owner")).to eq("%40")
      expect(steps.last).to eq([:bind, "%40", {"kind" => "play", "id" => "play/research", "instructions" => "/builtin/research.md",
                                               "packs" => ["spine"], "focus" => "spine stage verify"}])
    end

    it "reports a launch that failed, with how to set the stage back" do
      allow(launcher).to receive(:call).and_return(ok: false, reason: "prompt_not_sent", message: "never ready", pane: nil)

      doc = start

      expect(doc).to include("ok" => false, "outcome" => "failed", "reason" => "prompt_not_sent", "status" => "in_progress")
      expect(doc["message"]).to include("never ready", "--status not_started")
    end
  end

  it "re-checks under the write lock: a stage completed since it was read is refused" do
    allow(spine).to receive(:write_one).and_wrap_original do |original, **args, &block|
      write("40-verify.md", "---\nstatus: completed\n---\n")
      original.call(**args, &block)
    end

    expect(refusal { start }.code).to eq("stage_done")
    expect(sender).not_to have_received(:deliver)
  end
end
