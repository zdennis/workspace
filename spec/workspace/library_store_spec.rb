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
