require "tmpdir"

RSpec.describe Workspace::AtomicFile do
  let(:dir) { Dir.mktmpdir }
  let(:path) { File.join(dir, "data.json") }

  after { FileUtils.remove_entry(dir) }

  def leftovers = Dir.children(dir) - ["data.json"]

  describe ".write" do
    it "writes the content with mode 0600 and leaves no temp file" do
      described_class.write(path, "hello")
      expect(File.read(path)).to eq("hello")
      expect(File.stat(path).mode & 0o777).to eq(0o600)
      expect(leftovers).to be_empty
    end

    it "replaces an existing file whole" do
      File.write(path, "old old old")
      described_class.write(path, "new")
      expect(File.read(path)).to eq("new")
    end

    it "uses the given mode" do
      described_class.write(path, "x", perm: 0o644)
      expect(File.stat(path).mode & 0o777).to eq(0o644)
    end

    it "names the temp file <path>.<pid>.tmp, with a tag when given" do
      seen = []
      renamer = ->(from, to) {
        seen << from
        File.rename(from, to)
      }
      described_class.write(path, "x", renamer: renamer)
      described_class.write(path, "x", renamer: renamer, tag: "t7")
      expect(seen).to eq(["#{path}.#{Process.pid}.tmp", "#{path}.#{Process.pid}.t7.tmp"])
    end

    it "takes the temp name from temp_name:" do
      seen = nil
      renamer = ->(from, to) {
        seen = from
        File.rename(from, to)
      }
      described_class.write(path, "x", renamer: renamer, temp_name: ->(p) { "#{p}.tmp-custom" })
      expect(seen).to eq("#{path}.tmp-custom")
    end

    it "fsyncs by default and skips it with fsync: false" do
      synced = []
      allow(File).to receive(:open).and_wrap_original do |original, *args, **opts, &block|
        original.call(*args, **opts) do |file|
          allow(file).to receive(:fsync) { synced << true }
          block.call(file)
        end
      end
      described_class.write(path, "x")
      described_class.write(path, "x", fsync: false)
      expect(synced.size).to eq(1)
    end

    it "writes in the given encoding" do
      described_class.write(path, "café", encoding: Encoding::UTF_8)
      expect(File.binread(path).bytes).to eq("café".bytes)
    end

    it "hands the temp path and content to writer: in place of the write" do
      calls = []
      writer = ->(temp, content) {
        calls << content
        File.write(temp, "via writer")
      }
      described_class.write(path, "x", writer: writer)
      expect(calls).to eq(["x"])
      expect(File.read(path)).to eq("via writer")
    end

    it "keeps the old file and removes the temp file when the rename fails" do
      File.write(path, "old")
      renamer = ->(_from, _to) { raise Errno::EXDEV }
      expect { described_class.write(path, "new", renamer: renamer) }.to raise_error(Errno::EXDEV)
      expect(File.read(path)).to eq("old")
      expect(leftovers).to be_empty
    end

    it "removes the temp file when writer: fails after creating it" do
      writer = ->(temp, _) {
        File.write(temp, "partial")
        raise Errno::ENOSPC
      }
      expect { described_class.write(path, "new", writer: writer) }.to raise_error(Errno::ENOSPC)
      expect(File.exist?(path)).to be(false)
      expect(leftovers).to be_empty
    end

    it "raises when the directory is missing" do
      expect { described_class.write(File.join(dir, "no", "f"), "x") }.to raise_error(Errno::ENOENT)
    end
  end
end
