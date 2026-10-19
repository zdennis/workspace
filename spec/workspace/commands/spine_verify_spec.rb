require "spec_helper"
require "tmpdir"
require "stringio"
require "json"

RSpec.describe Workspace::Commands::Spine, "#verify and the check kept by #set" do
  around do |example|
    Dir.mktmpdir("spine-verify") do |dir|
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
    log = instance_double(Workspace::EventLog, latest_agent_states: {"%27" => {"kind" => "claude"}})
    allow(log).to receive(:record) { |**event| events << event }
    log
  end
  let(:env) { {"TMUX_PANE" => "%27"} }
  let(:clock) { -> { Time.utc(2026, 10, 19, 18, 56, 28) } }
  subject(:command) do
    described_class.new(notes: notes, writer: Workspace::SpineWriter.new, event_log: event_log, lock_dir: File.join(@state, ".spine"),
      env: env, clock: clock, output: output)
  end

  before { allow(notes).to receive(:info).with(name: "api").and_return({"workspace" => "api", "dir" => @notes}) }

  def write(text, relative = "40-verify.md")
    path = File.join(@notes, "spine", relative)
    FileUtils.mkdir_p(File.dirname(path))
    File.binwrite(path, text)
  end

  def read(relative = "40-verify.md") = File.binread(File.join(@notes, "spine", relative))

  def parsed(relative = "40-verify.md") = Workspace::SpineFile.read(File.join(@notes, "spine", relative))

  def answer = JSON.parse(output.string)

  def refusal(&block)
    block.call
    raise "no refusal"
  rescue Workspace::Error => e
    e
  end

  let(:body) { "# Verify\n\n## Done when\n- [x] Tests pass\n" }

  def stage_text(status: "completed", check: "pending", extra: "")
    lines = ["---", "spine: 1", "status: #{status}"]
    lines << "check: #{check}" if check
    lines << extra unless extra.empty?
    lines << "updated: 2026-10-01T00:00:00Z" << "updated_by: person" << "---"
    lines.join("\n") + "\n#{body}"
  end

  describe "#verify" do
    before { write(stage_text) }

    it "writes the four check lines and nothing else, and records a check change" do
      before_bytes = read
      command.verify(name: "api", path: "verify", verdict: "passed", note: "74 commands classed", json: true)

      doc = answer
      expect(doc).to include("ok" => true, "path" => "verify", "check" => "passed", "previous_check" => "pending", "checked_by" => "claude %27",
        "checked_at" => "2026-10-19T18:56:28Z", "check_note" => "74 commands classed", "changed" => true, "revision" => parsed.revision)
      expect(read).to eq(before_bytes.sub("check: pending\n", "check: passed\n").sub("---\n#", "checked_by: claude %27\nchecked_at: 2026-10-19T18:56:28Z\ncheck_note: \"74 commands classed\"\n---\n#"))
      file = parsed
      expect(file.status).to eq("completed")
      expect(file.value("updated")).to eq("2026-10-01T00:00:00Z")
      expect(events).to eq([{type: "spine_changed", project: "api", data: {
        "workspace" => "api", "path" => "verify", "change" => "check", "check" => "passed", "previous_check" => "pending",
        "status" => "completed", "check_note" => "74 commands classed", "by" => "claude %27", "revision" => file.revision
      }}])
    end

    it "takes --by over the pane, and defaults to person without an agent pane" do
      command.verify(name: "api", path: "verify", verdict: "failed", note: "item 2 missing", by: "checker-1")
      expect(parsed.value("checked_by")).to eq("checker-1")
      expect(parsed.check).to eq("failed")
      expect(output.string).to include("check failed (was pending) by checker-1")

      other = described_class.new(notes: notes, writer: Workspace::SpineWriter.new, event_log: event_log, lock_dir: File.join(@state, ".spine"),
        env: {}, clock: clock, output: StringIO.new)
      other.verify(name: "api", path: "verify", verdict: "passed", note: "fixed")
      expect(parsed.value("checked_by")).to eq("person")
    end

    it "quotes a note that is not plain words and replaces an earlier verdict" do
      command.verify(name: "api", path: "verify", verdict: "failed", note: "bad: 2 of 3")
      command.verify(name: "api", path: "verify", verdict: "passed", note: "all 3 fine", by: "claude %9")
      file = parsed
      expect(file.check).to eq("passed")
      expect(file.value("check_note")).to eq("all 3 fine")
      expect(read.scan("check_note:").size).to eq(1)
    end

    it "writes nothing and records nothing when the lines already read as asked" do
      command.verify(name: "api", path: "verify", verdict: "passed", note: "ok")
      bytes = read
      events.clear
      later = described_class.new(notes: notes, writer: Workspace::SpineWriter.new, event_log: event_log, lock_dir: File.join(@state, ".spine"),
        env: env, clock: -> { Time.utc(2026, 10, 19, 19, 0, 0) }, output: output)
      output.truncate(0)
      output.rewind

      later.verify(name: "api", path: "verify", verdict: "passed", note: "ok", json: true)

      expect(answer).to include("changed" => false, "checked_at" => "2026-10-19T18:56:28Z")
      expect(read).to eq(bytes)
      expect(events).to be_empty
    end

    it "refuses a stage that has not opted in, writing nothing" do
      write(stage_text(check: nil))
      bytes = read
      error = refusal { command.verify(name: "api", path: "verify", verdict: "passed", note: "ok") }
      expect(error.code).to eq("check_not_required")
      expect(error.details).to include("workspace" => "api", "path" => "verify")
      expect(read).to eq(bytes)
    end

    it "refuses a stage whose claim is not completed" do
      write(stage_text(status: "in_progress", check: "required"))
      error = refusal { command.verify(name: "api", path: "verify", verdict: "passed", note: "ok") }
      expect(error.code).to eq("stage_not_completed")
      expect(error.details).to include("status" => "in_progress")
    end

    it "names a check value that is not one of the four, and writes nothing" do
      write(stage_text(check: "bogus"))
      error = refusal { command.verify(name: "api", path: "verify", verdict: "passed", note: "ok") }
      expect(error.code).to eq("check_not_required")
      expect(error.details).to include("value" => "bogus")
      expect(error.message).to include("check: bogus")
    end

    it "accepts a completed stage whose check still reads required" do
      write(stage_text(check: "required"))
      command.verify(name: "api", path: "verify", verdict: "passed", note: "ok")
      expect(parsed.check).to eq("passed")
    end

    it "refuses a stale revision before the other refusals" do
      write(stage_text(check: nil))
      error = refusal { command.verify(name: "api", path: "verify", verdict: "passed", note: "ok", if_revision: "deadbeef") }
      expect(error.code).to eq("stale_revision")
    end

    it "honours a current --if-revision" do
      command.verify(name: "api", path: "verify", verdict: "passed", note: "ok", if_revision: parsed.revision)
      expect(parsed.check).to eq("passed")
    end

    it "refuses an unknown stage and a missing spine" do
      expect(refusal { command.verify(name: "api", path: "nope", verdict: "passed", note: "ok") }.code).to eq("unknown_stage")
      FileUtils.rm_rf(File.join(@notes, "spine"))
      expect(refusal { command.verify(name: "api", path: "verify", verdict: "passed", note: "ok") }.code).to eq("no_spine")
    end

    it "raises usage errors for a bad verdict, an empty or long note, and a multi-line label" do
      [{verdict: "maybe", note: "x"}, {verdict: "passed", note: ""}, {verdict: "passed", note: nil}, {verdict: "passed", note: "a" * 301},
        {verdict: "passed", note: "a\nb"}, {verdict: "passed", note: "ok", by: "x\ny"}, {verdict: "passed", note: "ok", by: ""}].each do |args|
        expect { command.verify(name: "api", path: "verify", **args) }.to raise_error(Workspace::UsageError)
      end
    end
  end

  describe "#set on a stage that has opted in" do
    it "sets check pending when completing, and clears the verdict lines when the status changes again" do
      write(stage_text(status: "in_progress", check: "required"))
      command.set(name: "api", path: "verify", status: "completed")
      expect(parsed.check).to eq("pending")

      command.verify(name: "api", path: "verify", verdict: "failed", note: "item 2 missing")
      expect(parsed.check).to eq("failed")

      command.set(name: "api", path: "verify", status: "in_progress")
      file = parsed
      expect(file.check).to eq("required")
      expect(%w[checked_by checked_at].map { |key| file.value(key) }).to all(be_nil)
      expect(file.frontmatter.keys).not_to include("checked_by", "checked_at")
      expect(file.value("check_note")).to eq("item 2 missing")
    end

    it "clears check_note when a passed verdict is reopened, and the kept failure note when completed again" do
      write(stage_text(check: "passed", extra: "checked_by: someone\ncheck_note: fine"))
      command.set(name: "api", path: "verify", status: "in_progress")
      expect(parsed.frontmatter.keys).not_to include("check_note")

      write(stage_text(check: "failed", extra: "checked_by: someone\ncheck_note: bad"))
      command.set(name: "api", path: "verify", status: "in_progress")
      expect(parsed.value("check_note")).to eq("bad")
      command.set(name: "api", path: "verify", status: "blocked")
      expect(parsed.value("check_note")).to eq("bad")
      command.set(name: "api", path: "verify", status: "completed")
      expect(parsed.frontmatter.keys).not_to include("check_note")
      expect(parsed.check).to eq("pending")
    end

    it "clears a passed verdict when the stage is completed again after a reopening" do
      write(stage_text(check: "passed", extra: "checked_by: someone\nchecked_at: 2026-10-01T00:00:00Z\ncheck_note: fine"))
      command.set(name: "api", path: "verify", status: "blocked")
      command.set(name: "api", path: "verify", status: "completed")
      file = parsed
      expect(file.check).to eq("pending")
      expect(file.value("checked_by")).to be_nil
    end

    it "leaves the check alone when the status does not change" do
      write(stage_text(check: "passed", extra: "checked_by: someone\ncheck_note: fine"))
      command.set(name: "api", path: "verify", status: "completed", note: "re-read")
      file = parsed
      expect(file.check).to eq("passed")
      expect(file.value("checked_by")).to eq("someone")
    end

    it "reports the check on the written row and the event" do
      write(stage_text(status: "in_progress", check: "required"))
      command.set(name: "api", path: "verify", status: "completed", json: true)
      expect(answer["written"].first).to include("check" => "pending")
      expect(events.last[:data]).to include("check" => "pending")
    end
  end

  describe "#set on a stage that has not opted in" do
    it "writes no check lines" do
      write(stage_text(status: "in_progress", check: nil))
      command.set(name: "api", path: "verify", status: "completed", json: true)
      expect(read).not_to include("check")
      expect(answer["written"].first).not_to have_key("check")
      expect(events.last[:data]).not_to have_key("check")
    end
  end

  describe "#show --json" do
    it "lists the check fields, null when absent" do
      write(stage_text(check: "passed", extra: "checked_by: claude %27\nchecked_at: 2026-10-19T18:56:28Z\ncheck_note: fine"))
      write(stage_text(check: nil), "50-review.md")
      command.show(name: "api", json: true)
      stages = answer["stages"]
      expect(stages[0]).to include("check" => "passed", "checked_by" => "claude %27", "checked_at" => "2026-10-19T18:56:28Z", "check_note" => "fine")
      expect(stages[1]).to include("check" => nil, "checked_by" => nil, "checked_at" => nil, "check_note" => nil)
    end
  end
end
