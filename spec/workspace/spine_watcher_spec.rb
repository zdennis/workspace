require "tmpdir"

RSpec.describe Workspace::SpineWatcher do
  let(:notes) { Dir.mktmpdir }
  let(:spine) { File.join(notes, "spine") }
  let(:now) { [0.0] }
  let(:resolved) { [notes] }
  let(:recent_lines) { [] }
  let(:recorded) { [] }
  let(:event_log) do
    instance_double(Workspace::EventLog, recent: recent_lines).tap do |log|
      allow(log).to receive(:record) { |**args| recorded << args && true }
    end
  end
  let(:watcher) do
    described_class.new(workspace: "ws", dir_resolver: ->(_) { resolved.first }, event_log: event_log,
      clock: -> { now.first }, wall_clock: -> { Time.utc(2026, 10, 17, 12) })
  end

  before { FileUtils.mkdir_p(spine) }

  after { FileUtils.remove_entry(notes) }

  def stage(name, status: "in_progress", note: nil, owner: nil, updated: nil, updated_by: nil, body: "Body\n")
    lines = ["---", "spine: 1", "status: #{status}"]
    lines << "note: #{note}" if note
    lines << "owner: #{owner}" if owner
    lines << "updated: #{updated}" if updated
    lines << "updated_by: #{updated_by}" if updated_by
    path = File.join(spine, name)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, (lines + ["---", body]).join("\n"))
    @edits = (@edits || 0) + 1
    File.utime(Time.at(1_000_000 + @edits), Time.at(1_000_000 + @edits), path)
  end

  def tick(seconds)
    now[0] += seconds
    watcher.poll
  end

  def settle
    tick(0.25)
    tick(0.5)
  end

  def revision(name) = Workspace::SpineFile.read(File.join(spine, name)).revision

  it "records a hand-edited status once the folder settles, by file, with the revision" do
    stage("40-verify.md", status: "in_progress")
    watcher.baseline

    stage("40-verify.md", status: "completed")
    expect(tick(0.25)).to be(false)
    expect(recorded).to be_empty

    expect(tick(0.5)).to be(true)
    expect(recorded).to eq([{type: "spine_changed", project: "ws", data: {
      "workspace" => "ws", "path" => "verify", "status" => "completed", "previous" => "in_progress",
      "note" => nil, "owner" => nil, "by" => "file", "revision" => revision("40-verify.md")
    }}])
  end

  it "records nothing for what was there at the start" do
    stage("40-verify.md")
    watcher.baseline
    settle
    expect(recorded).to be_empty
  end

  it "names updated_by as the source when updated moved in the change" do
    stage("40-verify.md", updated: "2026-10-17T10:00:00Z", updated_by: "person")
    watcher.baseline

    stage("40-verify.md", status: "completed", updated: "2026-10-17T11:00:00Z", updated_by: "claude %6")
    settle

    expect(recorded.first[:data]).to include("by" => "claude %6")
  end

  it "says file when updated did not move" do
    stage("40-verify.md", updated: "2026-10-17T10:00:00Z", updated_by: "person")
    watcher.baseline

    stage("40-verify.md", status: "completed", updated: "2026-10-17T10:00:00Z", updated_by: "person")
    settle

    expect(recorded.first[:data]).to include("by" => "file")
  end

  it "records a changed note" do
    stage("40-verify.md")
    watcher.baseline

    stage("40-verify.md", note: "two nits")
    settle

    expect(recorded.first[:data]).to include("status" => "in_progress", "previous" => "in_progress", "note" => "two nits")
  end

  it "records a hand-edited owner as change owner, with the owner after" do
    stage("40-verify.md", owner: "you")
    watcher.baseline

    stage("40-verify.md", owner: "claude")
    settle

    expect(recorded.map { |r| r[:data] }).to eq([{
      "workspace" => "ws", "path" => "verify", "status" => "in_progress", "previous" => "in_progress", "note" => nil,
      "owner" => "claude", "by" => "file", "revision" => revision("40-verify.md"), "change" => "owner"
    }])
  end

  it "records an owner change that comes with a status change without change" do
    stage("40-verify.md", owner: "you")
    watcher.baseline

    stage("40-verify.md", status: "completed", owner: "claude")
    settle

    expect(recorded.first[:data]).to include("status" => "completed", "owner" => "claude")
    expect(recorded.first[:data]).not_to have_key("change")
  end

  it "skips an owner change that is a spine set write" do
    stage("40-verify.md")
    watcher.baseline

    stage("40-verify.md", owner: "you")
    recent_lines << {"path" => "verify", "revision" => revision("40-verify.md")}
    settle

    expect(recorded).to be_empty
  end

  it "coalesces a burst of saves into one line per stage" do
    stage("30-implement.md", status: "not_started")
    stage("40-verify.md", status: "not_started")
    watcher.baseline

    stage("30-implement.md", status: "in_progress")
    tick(0.25)
    stage("30-implement.md", status: "completed")
    stage("40-verify.md", status: "in_progress")
    tick(0.25)
    tick(0.5)
    tick(0.5)

    expect(recorded.map { |r| r[:data].values_at("path", "previous", "status") }).to eq([
      %w[implement not_started completed], %w[verify not_started in_progress]
    ])
  end

  it "records nothing for edits that leave status and note alone" do
    stage("40-verify.md", body: "one\n")
    watcher.baseline

    stage("40-verify.md", body: "two\n")
    settle

    expect(recorded).to be_empty
  end

  it "records added and removed stage files" do
    stage("30-implement.md")
    watcher.baseline

    stage("40-verify.md")
    File.delete(File.join(spine, "30-implement.md"))
    settle

    expect(recorded.map { |r| r[:data] }).to contain_exactly(
      {"workspace" => "ws", "path" => "verify", "change" => "added"},
      {"workspace" => "ws", "path" => "implement", "change" => "removed"}
    )
  end

  it "records sub-stages by their path" do
    stage("30-implement.md")
    stage("30-implement/10-api.md", status: "not_started")
    watcher.baseline

    stage("30-implement/10-api.md", status: "completed")
    settle

    expect(recorded.first[:data]).to include("path" => "implement/api", "status" => "completed")
  end

  context "when the change is a spine set write" do
    it "writes no second line when the log holds that write's revision" do
      stage("40-verify.md")
      watcher.baseline

      stage("40-verify.md", status: "completed", updated: "2026-10-17T11:00:00Z", updated_by: "person")
      recent_lines << {"path" => "verify", "revision" => revision("40-verify.md"), "by" => "person"}
      settle

      expect(recorded).to be_empty
      expect(event_log).to have_received(:recent).with(type: "spine_changed", project: "ws", since: Time.utc(2026, 10, 17, 11, 58))
    end

    it "still records a later hand edit, even back to bytes an earlier write had" do
      stage("40-verify.md", status: "in_progress")
      watcher.baseline
      earlier = revision("40-verify.md")
      recent_lines << {"path" => "verify", "revision" => earlier, "by" => "person"}
      recent_lines << {"path" => "verify", "revision" => "feedface", "by" => "file"}

      stage("40-verify.md", status: "blocked")
      settle
      stage("40-verify.md", status: "in_progress")
      settle

      expect(recorded.map { |r| r[:data]["status"] }).to eq(%w[blocked in_progress])
    end

    it "takes the write as the state, so a later edit names it as the previous status" do
      stage("40-verify.md")
      watcher.baseline
      stage("40-verify.md", status: "completed")
      recent_lines << {"path" => "verify", "revision" => revision("40-verify.md"), "by" => "person"}
      settle

      recent_lines.clear
      stage("40-verify.md", status: "blocked")
      settle

      expect(recorded.map { |r| r[:data].values_at("previous", "status") }).to eq([%w[completed blocked]])
    end
  end

  it "does not follow a linked stage file or spine folder" do
    outside = Dir.mktmpdir
    File.write(File.join(outside, "40-verify.md"), "---\nstatus: in_progress\n---\n")
    File.symlink(File.join(outside, "40-verify.md"), File.join(spine, "40-verify.md"))
    watcher.baseline

    File.write(File.join(outside, "40-verify.md"), "---\nstatus: completed\n---\n")
    File.utime(Time.at(5_000_000), Time.at(5_000_000), File.join(outside, "40-verify.md"))
    settle

    expect(recorded).to be_empty
  ensure
    FileUtils.remove_entry(outside)
  end

  it "treats a stage file that can no longer be read as unchanged, not removed" do
    stage("40-verify.md")
    watcher.baseline

    File.binwrite(File.join(spine, "40-verify.md"), "---\nstatus: completed\n---\n\xFF\xFE")
    settle

    expect(recorded).to be_empty
  end

  it "skips a workspace whose notes directory is unresolved, then baselines once it resolves" do
    resolved[0] = nil
    watcher.baseline
    expect(tick(1)).to be(false)

    resolved[0] = notes
    stage("40-verify.md")
    tick(6)
    settle

    expect(recorded).to be_empty
    expect(event_log).not_to have_received(:recent)
  end

  it "treats a notes directory that raises as unresolved" do
    watcher = described_class.new(workspace: "ws", dir_resolver: ->(_) { raise Workspace::Error, "no" }, event_log: event_log,
      clock: -> { now.first })
    watcher.baseline
    now[0] += 10
    expect(watcher.poll).to be(false)
  end

  it "reports a stage file added to a spine that did not exist" do
    FileUtils.remove_entry(spine)
    watcher.baseline

    stage("40-verify.md")
    settle

    expect(recorded.map { |r| r[:data] }).to eq([{"workspace" => "ws", "path" => "verify", "change" => "added"}])
  end
end
