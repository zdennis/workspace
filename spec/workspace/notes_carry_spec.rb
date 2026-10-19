require "spec_helper"
require "tmpdir"

RSpec.describe Workspace::NotesCarry do
  around do |example|
    Dir.mktmpdir("notes-carry") do |dir|
      @dir = File.realpath(dir)
      example.run
    end
  end

  let(:from) { File.join(@dir, "main-notes") }
  let(:to) { File.join(@dir, "new-notes") }
  let(:spine_init) { instance_double(Workspace::Commands::SpineInit) }
  let(:clock) { -> { Time.utc(2026, 10, 19, 12, 0, 0) } }
  subject(:carry) { described_class.new(spine_init: spine_init, clock: clock) }

  before do
    FileUtils.mkdir_p([from, to])
    allow(spine_init).to receive(:add_missing_ship).and_return("outcome" => "added", "files" => ["60-ship.md"])
  end

  def put(root, rel, text = rel)
    path = File.join(root, rel)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, text)
  end

  def run(**opts)
    carry.call(from: from, to: to, name: "api.worktree-x", **opts)
  end

  it "moves the plan and the spine, renaming the originals and adding the ship stage" do
    put(from, "IMPLEMENTATION_PLAN.md", "plan\n")
    put(from, "spine/goal.md", "goal\n")
    put(from, "spine/10-research/10-a.md", "a\n")

    result = run

    expect(result).to include("plan" => "moved", "spine" => "moved", "ship" => "added", "carried" => [], "warnings" => [])
    expect(File.read(File.join(to, "IMPLEMENTATION_PLAN.md"))).to eq("plan\n")
    expect(File.read(File.join(to, "spine/10-research/10-a.md"))).to eq("a\n")
    expect(Dir.children(from).sort).to eq(%w[IMPLEMENTATION_PLAN.md.moved-20261019T120000Z spine.moved-20261019T120000Z])
    expect(File.read(File.join(from, "spine.moved-20261019T120000Z/goal.md"))).to eq("goal\n")
    expect(spine_init).to have_received(:add_missing_ship).with(name: "api.worktree-x", spine_dir: File.join(to, "spine"))
  end

  it "answers none for a plan and spine that are not there" do
    expect(run).to include("plan" => "none", "spine" => "none", "ship" => nil, "warnings" => [])
    expect(spine_init).not_to have_received(:add_missing_ship)
  end

  it "numbers a renamed original when the stamped name is taken" do
    put(from, "IMPLEMENTATION_PLAN.md")
    put(from, "IMPLEMENTATION_PLAN.md.moved-20261019T120000Z", "older")

    run

    expect(Dir.children(from)).to include("IMPLEMENTATION_PLAN.md.moved-20261019T120000Z-1")
    expect(File.read(File.join(from, "IMPLEMENTATION_PLAN.md.moved-20261019T120000Z"))).to eq("older")
  end

  it "skips a plan and a spine that clash with the new directory, leaving both sides as they were" do
    put(from, "IMPLEMENTATION_PLAN.md", "old\n")
    put(from, "spine/goal.md", "old\n")
    put(to, "IMPLEMENTATION_PLAN.md", "new\n")
    put(to, "spine/goal.md", "new\n")

    result = run

    expect(result).to include("plan" => "skipped", "spine" => "skipped", "ship" => nil)
    expect(result["warnings"].map { |w| w["code"] }).to eq(%w[notes_clash notes_clash])
    expect(File.read(File.join(to, "IMPLEMENTATION_PLAN.md"))).to eq("new\n")
    expect(File.read(File.join(to, "spine/goal.md"))).to eq("new\n")
    expect(Dir.children(from).sort).to eq(%w[IMPLEMENTATION_PLAN.md spine])
  end

  it "fills an empty spine/ in the new directory" do
    put(from, "spine/goal.md")
    FileUtils.mkdir_p(File.join(to, "spine"))

    expect(run["spine"]).to eq("moved")
    expect(File.exist?(File.join(to, "spine/goal.md"))).to be(true)
  end

  it "never follows a link: a linked plan or spine is skipped with a warning, and nothing is written" do
    secret = File.join(@dir, "secret.md")
    File.write(secret, "secret")
    File.symlink(secret, File.join(from, "IMPLEMENTATION_PLAN.md"))
    other = File.join(@dir, "otherdir")
    FileUtils.mkdir_p(other)
    File.symlink(other, File.join(from, "spine"))

    result = run

    expect(result).to include("plan" => "skipped", "spine" => "skipped")
    expect(result["warnings"].map { |w| w["code"] }).to eq(%w[notes_link notes_link])
    expect(Dir.children(to)).to eq([])
    expect(File.symlink?(File.join(from, "spine"))).to be(true)
  end

  it "leaves out links inside a moved spine, with a warning" do
    put(from, "spine/goal.md")
    File.symlink(File.join(@dir, "secret.md"), File.join(from, "spine/link.md"))

    result = run

    expect(result["spine"]).to eq("moved")
    expect(Dir.children(File.join(to, "spine"))).to eq(["goal.md"])
    expect(result["warnings"].map { |w| w["code"] }).to eq(["notes_link"])
  end

  it "does not write through a linked plan target in the new directory" do
    put(from, "IMPLEMENTATION_PLAN.md")
    victim = File.join(@dir, "victim.md")
    File.symlink(victim, File.join(to, "IMPLEMENTATION_PLAN.md"))

    expect(run["plan"]).to eq("skipped")
    expect(File.exist?(victim)).to be(false)
  end

  it "copies the named notes, keeping the original and nested paths" do
    put(from, "research-login.md", "findings\n")
    put(from, "deep/er/note.md", "deep\n")

    result = run(carry_notes: ["research-login.md", "deep/er/note.md", "research-login.md"])

    expect(result["carried"]).to eq([{"path" => "research-login.md", "outcome" => "copied"}, {"path" => "deep/er/note.md", "outcome" => "copied"}])
    expect(File.read(File.join(to, "deep/er/note.md"))).to eq("deep\n")
    expect(File.read(File.join(from, "research-login.md"))).to eq("findings\n")
  end

  it "reports a missing note and goes on" do
    put(from, "b.md")

    result = run(carry_notes: ["a.md", "b.md", "b.md/x"])

    expect(result["carried"].map { |c| c["outcome"] }).to eq(%w[missing copied missing])
    expect(result["warnings"].map { |w| w["code"] }).to eq(%w[carry_note_missing carry_note_missing])
  end

  it "skips a note whose name is taken in the new directory, leaving theirs" do
    put(from, "a.md", "mine")
    put(to, "a.md", "theirs")

    result = run(carry_notes: ["a.md"])

    expect(result["carried"]).to eq([{"path" => "a.md", "outcome" => "skipped"}])
    expect(File.read(File.join(to, "a.md"))).to eq("theirs")
    expect(result["warnings"].first["code"]).to eq("carry_note_clash")
  end

  it "never follows a link for a note: the file, a folder on the way, or a link planted in the new directory" do
    secret = File.join(@dir, "secret.md")
    File.write(secret, "secret")
    File.symlink(secret, File.join(from, "link.md"))
    other = File.join(@dir, "otherdir")
    put(other, "inner.md")
    File.symlink(other, File.join(from, "dir"))
    put(from, "sub/real.md")
    outside = File.join(@dir, "outside")
    FileUtils.mkdir_p(outside)
    File.symlink(outside, File.join(to, "sub"))

    result = run(carry_notes: ["link.md", "dir/inner.md", "sub/real.md"])

    expect(result["carried"].map { |c| c["outcome"] }).to eq(%w[skipped skipped skipped])
    expect(result["warnings"].map { |w| w["code"] }).to eq(%w[carry_note_link carry_note_link carry_note_link])
    expect(Dir.children(outside)).to eq([])
  end

  it "refuses a note path outside the notes directory, and a directory" do
    put(from, "folder/a.md")
    File.write(File.join(@dir, "out.md"), "x")

    result = run(carry_notes: ["../out.md", File.join(@dir, "out.md"), "folder", ""])

    expect(result["carried"].map { |c| c["outcome"] }).to eq(%w[skipped skipped skipped skipped])
    expect(result["warnings"].map { |w| w["code"] }).to eq(%w[carry_note_invalid carry_note_invalid carry_note_not_file carry_note_invalid])
    expect(Dir.children(to)).to eq([])
  end

  it "writes nothing on a dry run and reports would_ outcomes, even for a clash and a missing note" do
    put(from, "IMPLEMENTATION_PLAN.md")
    put(from, "spine/goal.md")
    put(from, "a.md")
    put(from, "b.md")
    put(to, "b.md")

    result = run(carry_notes: ["a.md", "b.md", "c.md"], dry_run: true)

    expect(result).to include("plan" => "would_move", "spine" => "would_move", "ship" => "would_add")
    expect(result["carried"].map { |c| c["outcome"] }).to eq(%w[would_copy skipped missing])
    expect(Dir.children(from).sort).to eq(%w[IMPLEMENTATION_PLAN.md a.md b.md spine])
    expect(Dir.children(to)).to eq(["b.md"])
    expect(spine_init).not_to have_received(:add_missing_ship)
  end

  it "says present on a dry run when the spine already has a ship stage" do
    put(from, "spine/60-ship.md")

    expect(run(dry_run: true)["ship"]).to eq("present")
  end

  it "creates the new directory when it is not there yet" do
    FileUtils.rm_rf(to)
    put(from, "IMPLEMENTATION_PLAN.md")

    expect(run["plan"]).to eq("moved")
    expect(File.exist?(File.join(to, "IMPLEMENTATION_PLAN.md"))).to be(true)
  end

  it "carries nothing when both directories are the same one" do
    put(from, "IMPLEMENTATION_PLAN.md")

    result = carry.call(from: from, to: from, name: "api", carry_notes: ["a.md"])

    expect(result).to include("plan" => "skipped", "spine" => "skipped")
    expect(result["carried"]).to eq([{"path" => "a.md", "outcome" => "skipped"}])
    expect(result["warnings"].first["code"]).to eq("same_notes_dir")
    expect(Dir.children(from)).to eq(["IMPLEMENTATION_PLAN.md"])
  end

  it "carries nothing when one directory holds the other" do
    put(from, "spine/goal.md")
    inner = File.join(from, "spine/new")

    result = carry.call(from: from, to: inner, name: "api")

    expect(result).to include("plan" => "skipped", "spine" => "skipped")
    expect(result["warnings"].first["code"]).to eq("same_notes_dir")
    expect(Dir.children(File.join(from, "spine"))).to eq(["goal.md"])
  end

  it "carries nothing when the new directory is the spine folder under another case" do
    put(from, "spine/goal.md")

    result = carry.call(from: from, to: File.join(from, "SPINE/x"), name: "api")

    expect(result["warnings"].first["code"]).to eq("same_notes_dir")
  end

  it "carries nothing when the new directory is the plan file under another case" do
    put(from, "IMPLEMENTATION_PLAN.md", "plan\n")

    result = carry.call(from: from, to: File.join(from, "implementation_plan.md/x"), name: "api")

    expect(result["warnings"].first["code"]).to eq("same_notes_dir")
  end

  it "carries when the new directory is inside the main one, as the default <main notes>/<branch> is" do
    put(from, "IMPLEMENTATION_PLAN.md", "plan\n")
    put(from, "a.md", "a\n")
    inner = File.join(from, "feature-x")

    result = carry.call(from: from, to: inner, name: "api.worktree-x", carry_notes: ["a.md"])

    expect(result).to include("plan" => "moved", "warnings" => [])
    expect(result["carried"]).to eq([{"path" => "a.md", "outcome" => "copied"}])
    expect(File.read(File.join(inner, "IMPLEMENTATION_PLAN.md"))).to eq("plan\n")
  end

  it "warns when add_missing_ship answers skipped" do
    put(from, "spine/goal.md")
    allow(spine_init).to receive(:add_missing_ship).and_return("outcome" => "skipped", "files" => [])

    result = run

    expect(result["ship"]).to eq("skipped")
    expect(result["warnings"].map { |w| w["code"] }).to eq(["ship_not_added"])
  end

  it "keeps a moved spine and warns when the ship stage cannot be added" do
    put(from, "spine/goal.md")
    allow(spine_init).to receive(:add_missing_ship).and_raise(Workspace::Error.new("no template", code: "unknown_template"))

    result = run

    expect(result).to include("spine" => "moved", "ship" => "skipped")
    expect(result["warnings"].map { |w| w["code"] }).to eq(["ship_not_added"])
  end

  it "needs no spine_init and no name: the ship stage is then nil" do
    put(from, "spine/goal.md")

    expect(described_class.new.call(from: from, to: to)).to include("spine" => "moved", "ship" => nil)
  end
end
