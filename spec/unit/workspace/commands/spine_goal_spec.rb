require "spec_helper"
require "tmpdir"
require "stringio"
require "json"

RSpec.describe Workspace::Commands::Spine, "#goal_set" do
  around do |example|
    Dir.mktmpdir("spine-goal") do |dir|
      @root = File.realpath(dir)
      @notes = File.join(@root, "notes")
      @state = File.join(@root, "state")
      FileUtils.mkdir_p(File.join(@notes, "spine"))
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
  subject(:command) do
    described_class.new(notes: notes, writer: Workspace::SpineWriter.new, event_log: event_log, lock_dir: File.join(@state, ".spine"),
      env: {}, output: output)
  end

  before { allow(notes).to receive(:info).with(name: "api").and_return({"workspace" => "api", "dir" => @notes}) }

  def goal_path = File.join(@notes, "spine", "goal.md")

  def read = File.binread(goal_path)

  def answer = JSON.parse(output.string)

  def refusal(&block)
    block.call
    raise "no refusal"
  rescue Workspace::Error => e
    e
  end

  it "makes goal.md with spine, title and a heading when it is missing, and records the event" do
    command.goal_set(name: "api", text: "Fix the OAuth refresh race", json: true)

    expect(read).to eq("---\nspine: 1\ntitle: Fix the OAuth refresh race\n---\n\n# Fix the OAuth refresh race\n")
    revision = Workspace::SpineFile.read(goal_path).revision
    expect(answer).to eq("schema_version" => 1, "ok" => true, "workspace" => "api",
      "goal" => {"file" => "goal.md", "title" => "Fix the OAuth refresh race", "revision" => revision}, "created" => true, "changed" => true)
    expect(events).to eq([{type: "spine_changed", project: "api", data: {"workspace" => "api", "change" => "goal", "title" => "Fix the OAuth refresh race",
                                                                         "created" => true, "by" => "person", "revision" => revision}}])
  end

  it "quotes a title a YAML reader would not take as text, and still reads it back" do
    command.goal_set(name: "api", text: "v2: 100% done # really")

    expect(Workspace::SpineFile.read(goal_path).value("title")).to eq("v2: 100% done # really")
  end

  it "reads back titles that start with YAML punctuation or end in a space-free quote" do
    ["- dash", "[list]", "'single'", "\"double\"", "#hash", "true", "123", "a \"quoted\" word"].each do |text|
      command.goal_set(name: "api", text: text)
      expect(Workspace::SpineFile.read(goal_path).value("title")).to eq(text)
    end
  end

  it "writes to the file that appeared while it was being made instead of replacing it" do
    real_link = File.method(:link)
    raced = false
    allow(File).to receive(:link) do |from, to|
      unless raced
        raced = true
        File.binwrite(to, "---\ntitle: Racer\nkeep: yes\n---\n")
        raise Errno::EEXIST
      end
      real_link.call(from, to)
    end

    command.goal_set(name: "api", text: "Mine")

    expect(read).to eq("---\ntitle: Mine\nkeep: yes\n---\n")
    expect(Dir.children(File.join(@notes, "spine"))).to eq(["goal.md"])
  end

  it "replaces the title and keeps every other byte, CRLF and BOM included" do
    original = "﻿---\r\nspine: 1\r\ntitle: Old\r\nunknown: [a, b]\r\n---\r\n\r\n# Old heading\r\nbody".b
    File.binwrite(goal_path, original)

    command.goal_set(name: "api", text: "New goal", json: true)

    expect(read).to eq(original.sub("title: Old".b, "title: New goal".b))
    expect(answer["created"]).to eq(false)
    expect(answer["goal"]["revision"]).to eq(Workspace::SpineFile.read(goal_path).revision)
    expect(events.first[:data]).to include("change" => "goal", "created" => false, "title" => "New goal")
  end

  it "adds title to an existing goal.md that has none" do
    File.binwrite(goal_path, "---\nspine: 1\n---\nbody\n")

    command.goal_set(name: "api", text: "Added")

    expect(read).to eq("---\nspine: 1\ntitle: Added\n---\nbody\n")
  end

  it "writes nothing and records nothing when the title already reads as asked" do
    File.binwrite(goal_path, "---\ntitle: Same\n---\n")
    mtime = File.mtime(goal_path)

    command.goal_set(name: "api", text: "Same")

    expect(File.mtime(goal_path)).to eq(mtime)
    expect(events).to be_empty
    expect(output.string).to include("already reads")
  end

  it "shows the new title in spine show" do
    command.goal_set(name: "api", text: "Shown")
    output.truncate(0)
    output.rewind

    command.show(name: "api", json: true)

    expect(answer["goal"]).to include("file" => "goal.md", "title" => "Shown")
  end

  it "refuses multi-line text, control characters, empty text and over-long text with a usage error" do
    ["one\ntwo", "tab\there", "bell\a", "line sep", "", "   ", "x" * 121].each do |text|
      expect { command.goal_set(name: "api", text: text) }.to raise_error(Workspace::UsageError)
    end
    expect(File.exist?(goal_path)).to be(false)
    expect { command.goal_set(name: "api", text: "x" * 120) }.not_to raise_error
  end

  it "refuses with no_spine when the workspace has no spine folder, and makes nothing" do
    FileUtils.rm_rf(File.join(@notes, "spine"))

    error = refusal { command.goal_set(name: "api", text: "Goal") }

    expect(error.code).to eq("no_spine")
    expect(Dir.exist?(File.join(@notes, "spine"))).to be(false)
  end

  it "refuses a symlinked goal.md, a dangling one too, and leaves the target alone" do
    target = File.join(@root, "elsewhere.md")
    File.binwrite(target, "---\ntitle: Elsewhere\n---\n")
    File.symlink(target, goal_path)

    expect(refusal { command.goal_set(name: "api", text: "Goal") }.details).to include("reason" => "link")
    expect(File.binread(target)).to eq("---\ntitle: Elsewhere\n---\n")

    File.delete(goal_path)
    File.symlink(File.join(@root, "nothing.md"), goal_path)
    expect(refusal { command.goal_set(name: "api", text: "Goal") }.details).to include("reason" => "link")
    expect(File.exist?(File.join(@root, "nothing.md"))).to be(false)
    expect(events).to be_empty
  end

  it "refuses a goal.md with no frontmatter block" do
    File.binwrite(goal_path, "# Just a heading\n")

    expect(refusal { command.goal_set(name: "api", text: "Goal") }.details).to include("reason" => "no_frontmatter")
    expect(read).to eq("# Just a heading\n")
  end

  it "honours --if-revision: stale_revision on a mismatch, a write on a match, stale for a missing file" do
    File.binwrite(goal_path, "---\ntitle: Old\n---\n")
    current = Workspace::SpineFile.read(goal_path).revision

    expect(refusal { command.goal_set(name: "api", text: "New", if_revision: "deadbeef") }.code).to eq("stale_revision")
    expect(read).to eq("---\ntitle: Old\n---\n")

    command.goal_set(name: "api", text: "New", if_revision: current.upcase)
    expect(Workspace::SpineFile.read(goal_path).value("title")).to eq("New")

    File.delete(goal_path)
    expect(refusal { command.goal_set(name: "api", text: "New", if_revision: current) }.code).to eq("stale_revision")
    expect(File.exist?(goal_path)).to be(false)
  end

  it "leaves no temp file behind" do
    command.goal_set(name: "api", text: "One")
    command.goal_set(name: "api", text: "Two")

    expect(Dir.children(File.join(@notes, "spine"))).to eq(["goal.md"])
  end

  it "labels the event with --by" do
    command.goal_set(name: "api", text: "Goal", by: "claude %6")

    expect(events.first[:data]["by"]).to eq("claude %6")
  end
end
