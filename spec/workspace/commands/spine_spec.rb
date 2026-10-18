require "spec_helper"
require "tmpdir"
require "stringio"
require "json"

RSpec.describe Workspace::Commands::Spine do
  around do |example|
    Dir.mktmpdir("spine-cmd") do |dir|
      @notes = File.realpath(dir)
      example.run
    end
  end

  let(:output) { StringIO.new }
  let(:notes) { instance_double(Workspace::Commands::Notes) }
  subject(:command) { described_class.new(notes: notes, output: output) }

  before { allow(notes).to receive(:info).with(name: "api").and_return({"workspace" => "api", "dir" => @notes}) }

  def write(relative, text)
    path = File.join(@notes, "spine", relative)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, text)
  end

  describe "#exists?" do
    it "is true for a spine/ folder, empty or not" do
      FileUtils.mkdir_p(File.join(@notes, "spine"))

      expect(command.exists?(name: "api")).to be(true)
    end

    it "is false when there is no spine/, it is a file, or it is a link" do
      expect(command.exists?(name: "api")).to be(false)
      File.write(File.join(@notes, "spine"), "x")
      expect(command.exists?(name: "api")).to be(false)
      File.delete(File.join(@notes, "spine"))
      FileUtils.mkdir_p(File.join(@notes, "elsewhere"))
      File.symlink(File.join(@notes, "elsewhere"), File.join(@notes, "spine"))
      expect(command.exists?(name: "api")).to be(false)
    end

    it "is false, not an error, when the notes directory can't be worked out" do
      allow(notes).to receive(:info).with(name: "gone").and_raise(Workspace::Error.new("no", code: "unknown_workspace"))

      expect(command.exists?(name: "gone")).to be(false)
    end

    it "creates nothing" do
      command.exists?(name: "api")

      expect(Dir.children(@notes)).to eq([])
    end
  end

  describe "#show with json" do
    it "prints one document: the envelope, the workspace and the tree" do
      write("goal.md", "---\ntitle: Ship it\n---\n")
      write("10-research.md", "---\nstatus: done\n---\n")

      command.show(name: "api", json: true)

      expect(output.string.lines.size).to eq(1)
      document = JSON.parse(output.string)
      expect(document.keys.first(4)).to eq(%w[schema_version ok workspace dir])
      expect(document).to include("schema_version" => 1, "ok" => true, "workspace" => "api", "dir" => File.join(@notes, "spine"), "exists" => true)
      expect(document["goal"]).to include("title" => "Ship it")
      expect(document["stages"].first).to include("path" => "research", "status" => "completed")
    end

    it "answers exists: false when there is no spine/" do
      command.show(name: "api", json: true)

      expect(JSON.parse(output.string)).to include("ok" => true, "exists" => false, "stages" => [])
    end

    it "answers exists: false when the notes directory is not there yet" do
      allow(notes).to receive(:info).with(name: "api").and_return({"dir" => File.join(@notes, "later")})

      command.show(name: "api", json: true)

      expect(JSON.parse(output.string)).to include("exists" => false, "dir" => File.join(@notes, "later", "spine"))
    end

    it "reads through a notes directory that is a link, and reports the real path" do
      link = File.join(@notes, "linked")
      File.symlink(@notes, link)
      allow(notes).to receive(:info).with(name: "api").and_return({"dir" => link})
      write("10-research.md", "---\nstatus: done\n---\n")

      command.show(name: "api", json: true)

      expect(JSON.parse(output.string)).to include("dir" => File.join(@notes, "spine"), "exists" => true)
    end

    it "answers ok whatever the files hold" do
      write("10-a.md", "\xFF\xFE\x00")
      write("20-b.md", "---\nstatus: ???\n")
      write("30-c.md", "")

      expect { command.show(name: "api", json: true) }.not_to raise_error
      expect(JSON.parse(output.string)["ok"]).to be true
    end

    it "lets the notes command's errors through" do
      allow(notes).to receive(:info).and_raise(Workspace::Error.new("Unknown workspace 'x'.", code: "unknown_workspace", details: {"name" => "x"}))

      expect { command.show(name: "x", json: true) }.to raise_error(Workspace::Error) { |e| expect(e.code).to eq("unknown_workspace") }
      expect(output.string).to eq("")
    end

    it "creates nothing" do
      command.show(name: "api", json: true)

      expect(Dir.children(@notes)).to eq([])
    end
  end

  describe "#show without json" do
    it "prints a short summary: stages, status, owner, counts, warnings" do
      write("goal.md", "---\ntitle: Ship it\n---\n")
      write("10-research.md", "---\nstatus: done\n---\n")
      write("30-implement.md", "---\nstatus: active\nowner: \"%6\"\n---\n## Done when\n- [x] a\n- [ ] b\n")
      write("30-implement/10-api.md", "---\nstatus: wip\n---\n")
      write("45-perf.md", "---\nstatus: x\n")
      write("notes.md", "x")

      command.show(name: "api")

      expect(output.string).to eq(<<~TEXT)
        api: 4 stages in #{File.join(@notes, "spine")}
        Goal: Ship it
        10 research  completed
        30 implement  in_progress (sub-stages in_progress)  owner %6  1/2 done
          10 api  in_progress
        45 perf  unknown  warnings: no_frontmatter
        Not stages: notes.md
      TEXT
    end

    it "says so when there is no spine/" do
      command.show(name: "api")

      expect(output.string).to eq("api: no spine/ in #{@notes}\n")
    end

    it "prints folder warnings" do
      FileUtils.mkdir_p(File.join(@notes, "elsewhere"))
      File.symlink(File.join(@notes, "elsewhere"), File.join(@notes, "spine"))

      command.show(name: "api")

      expect(output.string).to include("warning link: spine is a link")
    end
  end
end
