require "spec_helper"
require "tmpdir"

RSpec.describe Workspace::LibraryStore do
  around do |example|
    Dir.mktmpdir("library-store") do |dir|
      @dir = dir
      example.run
    end
  end

  subject(:store) { described_class.new(dir: File.join(@dir, "global"), scope: "global") }

  describe "#write and #find" do
    it "stores the body under kind/name.md and describes it from its first heading" do
      store.write("play", "kickoff", "# Kickoff play\n\nDo this.\n")

      entry = store.find("play", "kickoff")
      expect(entry).to include("kind" => "play", "name" => "kickoff", "ref" => "play/kickoff", "scope" => "global",
        "project" => nil, "path" => File.join(@dir, "global/play/kickoff.md"), "link" => nil, "readable" => true,
        "description" => "Kickoff play")
      expect(entry["updated_at"]).to match(/\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z\z/)
      expect(store.read("play", "kickoff")).to eq("# Kickoff play\n\nDo this.\n")
    end

    it "prefers the description frontmatter key over the heading" do
      store.write("prompt", "fix", "---\ntitle: x\ndescription: \"Fix the bug\"\n---\n# Heading\n")

      expect(store.find("prompt", "fix")["description"]).to eq("Fix the bug")
    end

    it "has no description for a file without heading or frontmatter" do
      store.write("prompt", "fix", "just text\n")

      expect(store.find("prompt", "fix")["description"]).to be_nil
    end

    it "returns nil for an entry that isn't there" do
      expect(store.find("play", "nope")).to be_nil
    end

    it "leaves no temp file behind" do
      store.write("play", "kickoff", "a")
      store.write("play", "kickoff", "b")

      expect(Dir.children(File.join(@dir, "global/play"))).to eq(["kickoff.md"])
      expect(store.read("play", "kickoff")).to eq("b")
    end
  end

  describe "#link" do
    it "stores a symlink and reports its target, replacing a copy" do
      source = File.join(@dir, "Source.md")
      File.write(source, "# Linked\n")
      store.write("play", "linked", "old copy")

      store.link("play", "linked", source)

      entry = store.find("play", "linked")
      expect(entry).to include("link" => source, "readable" => true, "description" => "Linked")
      expect(store.read("play", "linked")).to eq("# Linked\n")
    end

    it "reports a broken link as unreadable and read raises library_source_missing" do
      store.link("play", "gone", File.join(@dir, "missing.md"))

      entry = store.find("play", "gone")
      expect(entry).to include("readable" => false, "description" => nil, "link" => File.join(@dir, "missing.md"))
      expect { store.read("play", "gone") }.to raise_error(Workspace::Error) { |e|
        expect(e.code).to eq("library_source_missing")
        expect(e.details).to eq("ref" => "play/gone", "path" => store.path_for("play", "gone"))
      }
    end
  end

  describe "#entries" do
    it "lists by kind then name and ignores files with bad names" do
      store.write("prompt", "b", "x")
      store.write("play", "z", "x")
      store.write("play", "a", "x")
      File.write(File.join(@dir, "global/play/Bad Name.md"), "x")

      expect(store.entries.map { |e| e["ref"] }).to eq(%w[play/a play/z prompt/b])
      expect(store.entries(kind: "prompt").map { |e| e["ref"] }).to eq(%w[prompt/b])
    end

    it "is empty for a directory that doesn't exist" do
      expect(store.entries).to eq([])
    end
  end

  describe "an agent" do
    it "is a file like a play" do
      store.write("agent", "reviewer", "---\ndescription: Reviews diffs\n---\nYou review.\n")

      expect(store.find("agent", "reviewer")).to include("ref" => "agent/reviewer",
        "path" => File.join(@dir, "global/agent/reviewer.md"), "readable" => true, "description" => "Reviews diffs")
    end
  end

  describe "a skill" do
    def skill_source(name = "src-skill", body = "---\ndescription: Writes tests\n---\n# Tests\n")
      File.join(@dir, name).tap do |dir|
        FileUtils.mkdir_p(File.join(dir, "scripts"))
        File.write(File.join(dir, "SKILL.md"), body)
        File.write(File.join(dir, "scripts", "run.sh"), "echo hi\n")
      end
    end

    it "is a directory holding SKILL.md, described and read from that file" do
      store.copy_tree("skill", "tests", skill_source)

      entry = store.find("skill", "tests")
      expect(entry).to include("ref" => "skill/tests", "path" => File.join(@dir, "global/skill/tests"),
        "link" => nil, "readable" => true, "description" => "Writes tests")
      expect(store.read("skill", "tests")).to eq("---\ndescription: Writes tests\n---\n# Tests\n")
      expect(File.read(File.join(@dir, "global/skill/tests/scripts/run.sh"))).to eq("echo hi\n")
    end

    it "is written from a body as a directory with only SKILL.md" do
      store.write("skill", "tests", "# Tests\n")

      expect(Dir.children(store.path_for("skill", "tests"))).to eq(["SKILL.md"])
      expect(store.read("skill", "tests")).to eq("# Tests\n")
    end

    it "replaces a copied directory as a whole, leaving no old file behind" do
      store.copy_tree("skill", "tests", skill_source)
      store.write("skill", "tests", "# New\n")

      expect(Dir.children(store.path_for("skill", "tests"))).to eq(["SKILL.md"])
      expect(Dir.children(File.join(@dir, "global/skill"))).to eq(["tests"])
    end

    it "keeps the old directory when the new one can't be renamed into place" do
      store.copy_tree("skill", "tests", skill_source)
      allow(File).to receive(:rename).and_call_original
      allow(File).to receive(:rename).with(/tests\.tmp-/, store.path_for("skill", "tests")).and_raise(Errno::EACCES)

      expect { store.write("skill", "tests", "# New\n") }.to raise_error(Errno::EACCES)
      expect(store.read("skill", "tests")).to eq("---\ndescription: Writes tests\n---\n# Tests\n")
      expect(Dir.children(File.join(@dir, "global/skill"))).to eq(["tests"])
    end

    it "replaces a link with a copied directory or a body, leaving the link's target alone" do
      source = skill_source("linked")
      store.link("skill", "tests", source)

      store.copy_tree("skill", "tests", skill_source("other", "# Other\n"))
      expect(store.find("skill", "tests")).to include("link" => nil, "description" => "Other")
      store.link("skill", "tests", source)
      store.write("skill", "tests", "# Body\n")
      expect(store.find("skill", "tests")).to include("link" => nil)
      expect(store.read("skill", "tests")).to eq("# Body\n")
      expect(File.read(File.join(source, "SKILL.md"))).to eq("---\ndescription: Writes tests\n---\n# Tests\n")
      expect(Dir.children(File.join(@dir, "global/skill"))).to eq(["tests"])
    end

    it "links the source directory and replaces a copy with the link" do
      store.copy_tree("skill", "tests", skill_source)
      source = skill_source("other", "# Other\n")

      store.link("skill", "tests", source)

      expect(store.find("skill", "tests")).to include("link" => source, "readable" => true, "description" => "Other")
    end

    it "is unreadable without a SKILL.md" do
      FileUtils.mkdir_p(File.join(@dir, "global/skill/empty"))

      expect(store.find("skill", "empty")).to include("readable" => false, "description" => nil)
      expect { store.read("skill", "empty") }.to raise_error(Workspace::Error) { |e| expect(e.code).to eq("library_source_missing") }
    end

    it "is listed by its directory name" do
      store.copy_tree("skill", "tests", skill_source)
      store.write("agent", "reviewer", "x")
      store.write("play", "kickoff", "x")

      expect(store.entries.map { |e| e["ref"] }).to eq(%w[agent/reviewer play/kickoff skill/tests])
    end

    it "ignores a stray file in the skill directory, and lists a broken link to a skill as unreadable" do
      FileUtils.mkdir_p(File.join(@dir, "global/skill"))
      File.write(File.join(@dir, "global/skill/stray.md"), "x")
      store.link("skill", "gone", File.join(@dir, "missing"))

      expect(store.entries.map { |e| [e["ref"], e["readable"]] }).to eq([["skill/gone", false]])
    end

    it "deletes a copied directory, or only the link to one" do
      store.copy_tree("skill", "tests", skill_source)
      source = skill_source("linked")
      store.link("skill", "linked", source)

      store.delete("skill", "tests")
      store.delete("skill", "linked")

      expect(store.entries).to eq([])
      expect(File.exist?(File.join(source, "SKILL.md"))).to be true
    end
  end

  describe ".snapshot" do
    it "maps a file to its bytes and a directory to its files by relative path, through links" do
      dir = File.join(@dir, "tree")
      FileUtils.mkdir_p(File.join(dir, "a"))
      File.write(File.join(dir, "SKILL.md"), "x")
      File.write(File.join(dir, "a", ".hidden"), "y")
      File.symlink(dir, File.join(@dir, "link"))

      expect(described_class.snapshot(File.join(dir, "SKILL.md"))).to eq("x")
      expect(described_class.snapshot(File.join(@dir, "link"))).to eq("SKILL.md" => "x", "a/.hidden" => "y")
    end
  end

  describe "#delete" do
    it "removes a link without touching its target" do
      source = File.join(@dir, "Source.md")
      File.write(source, "keep")
      store.link("play", "linked", source)

      store.delete("play", "linked")

      expect(store.find("play", "linked")).to be_nil
      expect(File.read(source)).to eq("keep")
    end
  end
end
