require "spec_helper"
require "tmpdir"
require "stringio"
require "json"

RSpec.describe Workspace::Commands::Spine, "#set" do
  around do |example|
    Dir.mktmpdir("spine-set") do |dir|
      @root = File.realpath(dir)
      @notes = File.join(@root, "notes")
      @state = File.join(@root, "state")
      FileUtils.mkdir_p(@notes)
      example.run
    end
  end

  let(:output) { StringIO.new }
  let(:notes) { instance_double(Workspace::Commands::Notes) }
  let(:events) { [] }
  let(:event_log) do
    log = instance_double(Workspace::EventLog, latest_agent_states: {})
    allow(log).to receive(:record) { |**event| events << event }
    log
  end
  let(:env) { {} }
  let(:clock) { -> { Time.utc(2026, 10, 17, 22, 1, 0) } }
  subject(:command) { build_command }

  def build_command(**overrides)
    described_class.new(notes: notes, writer: Workspace::SpineWriter.new, event_log: event_log, lock_dir: File.join(@state, ".spine"),
      env: env, clock: clock, output: output, **overrides)
  end

  before { allow(notes).to receive(:info).with(name: "api").and_return({"workspace" => "api", "dir" => @notes}) }

  def write(relative, text)
    path = File.join(@notes, "spine", relative)
    FileUtils.mkdir_p(File.dirname(path))
    File.binwrite(path, text)
    path
  end

  def read(relative) = File.binread(File.join(@notes, "spine", relative))

  def answer = JSON.parse(output.string)

  def refusal(&block)
    block.call
    raise "no refusal"
  rescue Workspace::Error => e
    e
  end

  def revision_of(relative) = Workspace::SpineFile.read(File.join(@notes, "spine", relative)).revision

  describe "the answer" do
    before do
      write("40-verify.md", "---\nstatus: in_progress\n---\nBody\n")
      write("10-research.md", "---\nstatus: done\n---\n")
    end

    it "prints one document with the written stage and appends one spine_changed line" do
      command.set(name: "api", path: "verify", status: "done", json: true)

      expect(output.string.lines.size).to eq(1)
      row = answer["written"].first
      expect(answer).to include("schema_version" => 1, "ok" => true, "workspace" => "api", "unchanged" => [])
      expect(row).to eq("path" => "verify", "file" => "40-verify.md", "status" => "completed", "previous" => "in_progress",
        "revision" => revision_of("40-verify.md"), "updated" => "2026-10-17T22:01:00Z", "updated_by" => "person", "note" => nil, "owner" => nil)
      expect(events).to eq([{type: "spine_changed", project: "api", data: {"workspace" => "api", "path" => "verify", "status" => "completed",
                                                                           "previous" => "in_progress", "note" => nil, "owner" => nil, "by" => "person", "revision" => row["revision"]}}])
    end

    it "is seen by the next read: the new status and revision" do
      command.set(name: "api", path: "verify", status: "blocked", note: "needs a human", by: "alice")
      output.truncate(0)
      output.rewind

      command.show(name: "api", json: true)

      stage = answer["stages"].find { |s| s["path"] == "verify" }
      expect(stage).to include("status" => "blocked", "note" => "needs a human", "updated_by" => "alice", "updated" => "2026-10-17T22:01:00Z",
        "revision" => events.last[:data]["revision"])
    end

    it "lists a stage that already reads the status as unchanged and writes no event" do
      command.set(name: "api", path: "research", status: "completed", json: true)

      expect(answer["written"]).to eq([])
      expect(answer["unchanged"]).to eq([{"path" => "research", "file" => "10-research.md", "status" => "completed", "owner" => nil, "revision" => revision_of("10-research.md")}])
      expect(events).to be_empty
      expect(read("10-research.md")).to eq("---\nstatus: done\n---\n")
    end

    it "says so when only the note changed, and escapes an odd path in unknown_stage" do
      command.set(name: "api", path: "research", status: "completed", note: "fine")
      expect(output.string).to eq("api: research still completed, note changed\n")

      error = refusal { command.set(name: "api", path: "x\e[31m", status: "completed") }
      expect(error.message).not_to include("\e")
    end

    it "prints a line per stage without --json" do
      command.set(name: "api", path: "verify", status: "completed")

      expect(output.string).to eq("api: verify set to completed (was in_progress)\n")
    end
  end

  describe "refusals" do
    before { write("40-verify.md", "---\nstatus: in_progress\n---\n") }

    it "refuses unknown and an unrecognised status as invalid_status, before anything else" do
      allow(notes).to receive(:info).and_raise("not reached")

      %w[unknown nonsense].each do |word|
        error = refusal { command.set(name: "api", path: "verify", status: word) }
        expect(error.code).to eq("invalid_status")
        expect(error.details).to include("status" => word, "allowed" => Workspace::SpineFile::STATUSES)
      end
    end

    it "answers unknown_workspace before it takes any lock" do
      allow(notes).to receive(:info).with(name: "typo").and_raise(Workspace::Error.new("Unknown", code: "unknown_workspace"))

      error = refusal { command.set(name: "typo", path: "verify", status: "completed") }

      expect(error.code).to eq("unknown_workspace")
      expect(Dir.exist?(File.join(@state, ".spine"))).to be(false)
    end

    it "answers no_spine when there is no spine/ folder" do
      FileUtils.rm_rf(File.join(@notes, "spine"))

      error = refusal { command.set(name: "api", path: "verify", status: "completed") }

      expect(error.code).to eq("no_spine")
      expect(Dir.exist?(File.join(@notes, "spine"))).to be(false)
    end

    it "answers unknown_stage with the paths there are" do
      error = refusal { command.set(name: "api", path: "nope", status: "completed") }

      expect(error.code).to eq("unknown_stage")
      expect(error.details).to eq("path" => "nope", "stages" => ["verify"])
    end

    it "answers stale_revision with the current revision and status, and changes nothing" do
      error = refusal { command.set(name: "api", path: "verify", status: "completed", if_revision: "00000000") }

      expect(error.code).to eq("stale_revision")
      expect(error.details).to eq("revision" => revision_of("40-verify.md"), "status" => "in_progress")
      expect(read("40-verify.md")).to eq("---\nstatus: in_progress\n---\n")
      expect(events).to be_empty
    end

    it "writes when --if-revision matches" do
      command.set(name: "api", path: "verify", status: "completed", if_revision: revision_of("40-verify.md"))

      expect(read("40-verify.md")).to include("status: completed")
    end

    it "refuses a linked stage file as spine_unwritable and leaves its target alone" do
      target = File.join(@root, "elsewhere.md")
      File.write(target, "---\nstatus: blocked\n---\n")
      FileUtils.rm(File.join(@notes, "spine", "40-verify.md"))
      File.symlink(target, File.join(@notes, "spine", "40-verify.md"))

      error = refusal { command.set(name: "api", path: "verify", status: "completed") }

      expect(error.code).to eq("spine_unwritable")
      expect(error.details).to include("reason" => "link", "file" => "40-verify.md")
      expect(File.read(target)).to eq("---\nstatus: blocked\n---\n")
      expect(events).to be_empty
    end

    it "refuses a stage file that became a link after the spine was read" do
      target = File.join(@root, "elsewhere.md")
      File.write(target, "---\nstatus: blocked\n---\n")
      swapped = false
      writer = Workspace::SpineWriter.new
      allow(writer).to receive(:write).and_wrap_original do |original, path, **args|
        unless swapped
          swapped = true
          FileUtils.rm(path)
          File.symlink(target, path)
        end
        original.call(path, **args)
      end

      error = refusal { build_command(writer: writer).set(name: "api", path: "verify", status: "completed") }

      expect(error.code).to eq("spine_unwritable")
      expect(error.details).to include("reason" => "link", "file" => "40-verify.md")
      expect(File.read(target)).to eq("---\nstatus: blocked\n---\n")
    end

    it "refuses a file with no closing --- and names the reason" do
      write("40-verify.md", "---\nstatus: in_progress\nBody\n")

      error = refusal { command.set(name: "api", path: "verify", status: "completed") }

      expect(error.code).to eq("spine_unwritable")
      expect(error.details).to include("reason" => "no_frontmatter")
    end

    it "refuses a note or label that is not one short line" do
      [{note: "two\nlines"}, {note: "x" * 301}, {note: "bell\a"}, {by: "a\nb"}, {by: " "}].each do |extra|
        expect { command.set(name: "api", path: "verify", status: "completed", **extra) }.to raise_error(Workspace::UsageError)
      end
      expect(read("40-verify.md")).to eq("---\nstatus: in_progress\n---\n")
    end

    it "needs at least one of status, note and owner" do
      expect { command.set(name: "api", path: "verify") }.to raise_error(Workspace::UsageError, /at least one/)
    end

    it "refuses an owner that is not one line of at most 64 characters, or with --recursive" do
      [{owner: "a\nb"}, {owner: "x" * 65}, {owner: "bell\a"}].each do |extra|
        expect { command.set(name: "api", path: "verify", **extra) }.to raise_error(Workspace::UsageError)
      end
      expect { command.set(name: "api", path: "verify", owner: "%6", recursive: true) }.to raise_error(Workspace::UsageError, /recursive/)
      expect(read("40-verify.md")).to eq("---\nstatus: in_progress\n---\n")
    end

    it "accepts a note of exactly 300 characters" do
      command.set(name: "api", path: "verify", status: "completed", note: "x" * 300)

      expect(Workspace::SpineFile.read(File.join(@notes, "spine", "40-verify.md")).value("note")).to eq("x" * 300)
    end
  end

  describe "--by" do
    before { write("40-verify.md", "---\nstatus: in_progress\n---\n") }

    it "uses the label given" do
      command.set(name: "api", path: "verify", status: "completed", by: "review agent", json: true)

      expect(answer["written"].first["updated_by"]).to eq("review agent")
      expect(events.last[:data]["by"]).to eq("review agent")
    end

    context "from a pane the daemon logged as a coding agent" do
      let(:env) { {"TMUX_PANE" => "%6"} }

      it "defaults to the agent and the pane" do
        allow(event_log).to receive(:latest_agent_states).with("api").and_return({"%6" => {"kind" => "claude", "state" => "working"}})

        command.set(name: "api", path: "verify", status: "completed", json: true)

        expect(answer["written"].first["updated_by"]).to eq("claude %6")
        expect(read("40-verify.md")).to include("updated_by: claude %6\n")
      end

      it "is person for a pane that is a shell or unknown to the daemon" do
        allow(event_log).to receive(:latest_agent_states).with("api").and_return({"%6" => {"kind" => "shell"}})

        command.set(name: "api", path: "verify", status: "completed", json: true)

        expect(answer["written"].first["updated_by"]).to eq("person")
      end
    end

    it "is person without a pane, or with something that is not a pane id" do
      build_command(env: {"TMUX_PANE" => "6; rm"}).set(name: "api", path: "verify", status: "completed", json: true)

      expect(answer["written"].first["updated_by"]).to eq("person")
    end
  end

  describe "--recursive" do
    before do
      write("30-implement.md", "---\nstatus: in_progress\n---\n")
      write("30-implement/10-api.md", "---\nstatus: in_progress\n---\n")
      write("30-implement/20-docs.md", "---\nstatus: completed\nnote: kept\n---\n")
      write("30-implement/30-skip.md", "---\nstatus: skipped\n---\n")
      write("30-implement/40-ui.md", "---\nstatus: not_started\n---\n")
      write("30-implement/40-ui/10-form.md", "---\nstatus: blocked\n---\n")
      write("40-verify.md", "---\nstatus: not_started\n---\n")
    end

    it "writes a note alone to the stage and the sub-stages that are not done, keeping every status" do
      command.set(name: "api", path: "implement", note: "freeze", recursive: true, json: true)

      expect(answer["written"].map { |row| [row["path"], row["status"], row["note"]] }).to eq(
        [["implement", "in_progress", "freeze"], ["implement/api", "in_progress", "freeze"], ["implement/ui", "not_started", "freeze"], ["implement/ui/form", "blocked", "freeze"]]
      )
      expect(read("30-implement/20-docs.md")).to eq("---\nstatus: completed\nnote: kept\n---\n")
    end

    it "sets the stage and every sub-stage that is not completed or skipped, in tree order, one event each" do
      command.set(name: "api", path: "implement", status: "completed", recursive: true, json: true)

      expect(answer["written"].map { |row| row["path"] }).to eq(%w[implement implement/api implement/ui implement/ui/form])
      expect(events.map { |e| e[:data]["path"] }).to eq(%w[implement implement/api implement/ui implement/ui/form])
      expect(read("30-implement/20-docs.md")).to eq("---\nstatus: completed\nnote: kept\n---\n")
      expect(read("30-implement/30-skip.md")).to eq("---\nstatus: skipped\n---\n")
      expect(read("40-verify.md")).to eq("---\nstatus: not_started\n---\n")
      expect(read("30-implement/40-ui/10-form.md")).to include("status: completed\n")
    end

    it "leaves the sub-stages alone without --recursive" do
      command.set(name: "api", path: "implement", status: "completed", json: true)

      expect(answer["written"].map { |row| row["path"] }).to eq(["implement"])
      expect(read("30-implement/10-api.md")).to eq("---\nstatus: in_progress\n---\n")
    end

    it "stops at the first refusal and lists what was written in details.written" do
      File.binwrite(File.join(@notes, "spine", "30-implement/40-ui.md"), "---\nstatus: not_started\nno closing line\n")

      error = refusal { command.set(name: "api", path: "implement", status: "completed", recursive: true) }

      expect(error.code).to eq("spine_unwritable")
      expect(error.details["file"]).to eq("30-implement/40-ui.md")
      expect(error.details["written"].map { |row| row["path"] }).to eq(%w[implement implement/api])
      expect(read("30-implement/40-ui/10-form.md")).to eq("---\nstatus: blocked\n---\n")
      expect(events.size).to eq(2)
    end

    it "checks --if-revision on the named stage only" do
      command.set(name: "api", path: "implement", status: "completed", recursive: true, if_revision: revision_of("30-implement.md"), json: true)

      expect(answer["written"].size).to eq(4)
    end

    it "refuses a named stage that is a folder with no file, and skips one below it" do
      FileUtils.rm(File.join(@notes, "spine", "30-implement/40-ui.md"))

      command.set(name: "api", path: "implement", status: "completed", recursive: true, json: true)
      expect(answer["written"].map { |row| row["path"] }).to eq(%w[implement implement/api implement/ui/form])

      error = refusal { command.set(name: "api", path: "implement/ui", status: "in_progress") }
      expect(error.details).to include("reason" => "no_file")
    end
  end

  describe "--owner and --note without --status" do
    before { write("40-verify.md", "---\nstatus: in_progress\nnote: keep\n---\nBody\n") }

    it "sets only the owner, keeps status and note, and logs change owner" do
      command.set(name: "api", path: "verify", owner: "%6", json: true)

      expect(read("40-verify.md")).to eq("---\nstatus: in_progress\nnote: keep\nowner: \"%6\"\nupdated: 2026-10-17T22:01:00Z\nupdated_by: person\n---\nBody\n")
      expect(answer["written"].first).to include("status" => "in_progress", "previous" => "in_progress", "note" => "keep", "owner" => "%6")
      expect(events.map { |e| e[:data] }).to eq([{"workspace" => "api", "path" => "verify", "status" => "in_progress", "previous" => "in_progress",
                                                  "note" => "keep", "owner" => "%6", "by" => "person", "revision" => revision_of("40-verify.md"), "change" => "owner"}])
    end

    it "clears the owner with an empty value" do
      command.set(name: "api", path: "verify", owner: "you")
      command.set(name: "api", path: "verify", owner: "")

      expect(read("40-verify.md")).not_to include("owner:")
      expect(events.last[:data]).to include("owner" => nil, "change" => "owner")
    end

    it "changes only the note when given a note alone, with no change key" do
      command.set(name: "api", path: "verify", note: "new")

      expect(read("40-verify.md")).to start_with("---\nstatus: in_progress\nnote: new\n")
      expect(events.first[:data]).not_to have_key("change")
    end

    it "omits change when the owner changes with the status" do
      command.set(name: "api", path: "verify", status: "completed", owner: "you")
      expect(events.first[:data]).to include("status" => "completed", "owner" => "you")
      expect(events.first[:data]).not_to have_key("change")
    end

    it "lists an owner that is already set as unchanged" do
      command.set(name: "api", path: "verify", owner: "you")
      output.truncate(0)
      output.rewind
      command.set(name: "api", path: "verify", owner: "you", json: true)

      expect(answer["unchanged"].first).to include("owner" => "you")
      expect(events.size).to eq(1)
    end

    it "still refuses a stale revision" do
      error = refusal { command.set(name: "api", path: "verify", owner: "you", if_revision: "deadbeef") }
      expect(error.code).to eq("stale_revision")
    end

    it "says what changed in the plain line" do
      command.set(name: "api", path: "verify", owner: "you")
      expect(output.string).to eq("api: verify still in_progress, owner set to you\n")
    end
  end

  describe "the lock" do
    before { write("40-verify.md", "---\nstatus: not_started\n---\n") }

    it "lives in the state folder, never in the notes folder" do
      command.set(name: "api", path: "verify", status: "completed")

      expect(Dir.glob(File.join(@state, ".spine", "*.lock")).size).to eq(1)
      expect(Dir.glob(File.join(@notes, "**", "*.lock"))).to be_empty
    end

    it "answers spine_unwritable (lock_unavailable) when the lock folder can't be used" do
      FileUtils.mkdir_p(@state)
      File.write(File.join(@state, ".spine"), "in the way")

      error = refusal { command.set(name: "api", path: "verify", status: "completed") }

      expect(error.code).to eq("spine_unwritable")
      expect(error.details).to eq("reason" => "lock_unavailable")
    end

    it "gives up with spine_unwritable (lock_busy) when another writer holds it too long" do
      command.set(name: "api", path: "verify", status: "in_progress")
      lock = Dir.glob(File.join(@state, ".spine", "*.lock")).first

      File.open(lock, File::RDWR) do |held|
        held.flock(File::LOCK_EX)
        error = refusal { build_command(lock_wait: 0.1).set(name: "api", path: "verify", status: "completed") }

        expect(error.code).to eq("spine_unwritable")
        expect(error.details).to eq("reason" => "lock_busy")
      end
      expect(read("40-verify.md")).to include("status: in_progress")
    end

    it "lets two concurrent writers both land, one after the other, the second on top of the first" do
      started = Queue.new
      go = Queue.new
      workers = [%w[in_progress first], %w[blocked second]].map do |status, note|
        Thread.new do
          cmd = build_command(output: StringIO.new)
          started << true
          go.pop
          cmd.set(name: "api", path: "verify", status: status, note: note)
        end
      end
      2.times { started.pop }
      2.times { go << true }
      workers.each(&:join)

      first, second = events.map { |e| e[:data] }
      expect(events.size).to eq(2)
      expect(first["previous"]).to eq("not_started")
      expect(second["previous"]).to eq(first["status"])
      expect(second["status"]).not_to eq(first["status"])
      expect(read("40-verify.md")).to include("status: #{second["status"]}\n").and include("note: #{second["note"]}\n")
      expect(revision_of("40-verify.md")).to eq(second["revision"])
    end

    it "lets two processes both land" do
      readers, writers = 2.times.map { IO.pipe }.transpose
      pids = [%w[in_progress first], %w[blocked second]].each_with_index.map do |(status, note), index|
        fork do
          readers[index].read(1)
          appender = Object.new
          log_path = File.join(@root, "events.jsonl")
          appender.define_singleton_method(:latest_agent_states) { |_| {} }
          appender.define_singleton_method(:record) { |type:, project:, data:| File.open(log_path, "a") { |f| f.syswrite(JSON.generate({"type" => type, "data" => data}) + "\n") } }
          build_command(output: StringIO.new, event_log: appender).set(name: "api", path: "verify", status: status, note: note)
          exit!(0)
        rescue Exception # standard:disable Lint/RescueException
          exit!(1)
        end
      end
      writers.each { |w| w.write("x") }
      statuses = pids.map { |pid| Process.wait2(pid).last.exitstatus }

      expect(statuses).to eq([0, 0])
      expect(read("40-verify.md")).to match(/status: (in_progress|blocked)\n/)
      expect(Dir.children(File.join(@notes, "spine"))).to eq(["40-verify.md"])
      lines = File.readlines(File.join(@root, "events.jsonl")).map { |l| JSON.parse(l)["data"] }
      expect(lines.size).to eq(2)
      expect(lines.last["previous"]).to eq(lines.first["status"])
      expect(read("40-verify.md")).to include("status: #{lines.last["status"]}\n")
    end
  end

  it "is not available without a writer and a lock folder" do
    bare = described_class.new(notes: notes, output: output)

    expect { bare.set(name: "api", path: "verify", status: "completed") }.to raise_error(Workspace::Error, /not available/)
  end
end
