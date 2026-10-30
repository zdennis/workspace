require "spec_helper"
require "fileutils"
require "json"
require "tmpdir"

RSpec.describe Workspace::NotePath do
  rows = JSON.parse(File.read(File.expand_path("../fixtures/note_paths.json", __dir__)))
  path_of = ->(row) { row["path"].is_a?(Hash) ? row["path"]["bytes"].pack("C*") : row["path"] }

  describe ".segments" do
    rows.select { |row| row["layer"] == "shape" }.each do |row|
      path = path_of.call(row)
      if row["valid"]
        it "accepts #{path.inspect[0, 40]}" do
          expect(described_class.segments(path)).to eq(path.split("/"))
        end
      else
        it "refuses #{path.inspect[0, 40]} (#{row["reason"]})" do
          expect { described_class.segments(path) }.to raise_error(described_class::Refused) { |e| expect(e.reason).to match(Regexp.new(row["reason_match"])) }
        end
      end
    end

    it "refuses a string in another encoding" do
      expect { described_class.segments("a.md".encode(Encoding::UTF_16LE)) }
        .to raise_error(described_class::Refused, /UTF-8/)
    end

    it "accepts a binary-tagged string holding valid UTF-8 bytes" do
      expect(described_class.segments("a.md".b)).to eq(["a.md"])
    end

    it "refuses a value that is not a string" do
      expect { described_class.segments(nil) }.to raise_error(described_class::Refused, /string/)
    end

    it "carries a reason" do
      expect { described_class.segments("a.txt") }
        .to raise_error(described_class::Refused) { |e| expect(e.reason).to match(/\.md/) }
    end
  end

  describe ".resolve" do
    around do |example|
      Dir.mktmpdir do |root|
        @root = File.realpath(root)
        @dir = File.join(@root, "notes")
        @outside = File.join(@root, "outside")
        FileUtils.mkdir_p([@dir, @outside])
        File.write(File.join(@dir, "findings.md"), "x")
        File.write(File.join(@dir, "data.txt"), "x")
        FileUtils.mkdir(File.join(@dir, "folder.md"))
        File.write(File.join(@outside, "secret.md"), "x")
        File.symlink(File.join(@dir, "findings.md"), File.join(@dir, "link.md"))
        example.run
      end
    end

    rows.select { |row| row["layer"] == "fs" }.each do |row|
      it "refuses #{row["path"]} (#{row["reason"]})" do
        expect { described_class.resolve(row["path"], @dir) }.to raise_error(described_class::Refused) { |e| expect(e.reason).to match(Regexp.new(row["reason_match"])) }
      end
    end

    it "refuses a name that is too long for the filesystem" do
      allow(File).to receive(:realpath).and_call_original
      allow(File).to receive(:realpath).with(File.join(@dir, "findings.md")).and_raise(Errno::ENAMETOOLONG)
      expect { described_class.resolve("findings.md", @dir) }.to raise_error(described_class::Refused, /too long/)
    end

    it "refuses on any other system error" do
      allow(File).to receive(:realpath).and_call_original
      allow(File).to receive(:realpath).with(File.join(@dir, "findings.md")).and_raise(Errno::EIO)
      expect { described_class.resolve("findings.md", @dir) }.to raise_error(described_class::Refused, /EIO/)
    end

    it "returns the path as given for an existing note" do
      FileUtils.mkdir_p(File.join(@dir, "a"))
      File.write(File.join(@dir, "a", "b.md"), "x")
      expect(described_class.resolve("a/b.md", @dir)).to eq("a/b.md")
      expect(described_class.resolve("findings.md", @dir)).to eq("findings.md")
    end

    it "shows the case mismatch is refused on a case-insensitive volume" do
      skip "volume is case-sensitive" unless File.exist?(File.join(@dir, "FINDINGS.md"))
      expect(File.realpath(File.join(@dir, "FINDINGS.md"))).to eq(File.join(@dir, "findings.md"))
      expect { described_class.resolve("FINDINGS.md", @dir) }
        .to raise_error(described_class::Refused, /case/)
    end

    it "refuses a directory link that points inside the dir" do
      FileUtils.mkdir_p(File.join(@dir, "real"))
      File.write(File.join(@dir, "real", "n.md"), "x")
      File.symlink(File.join(@dir, "real"), File.join(@dir, "alias"))
      expect { described_class.resolve("alias/n.md", @dir) }.to raise_error(described_class::Refused, /symlink/)
    end

    it "refuses a link that points outside the dir" do
      File.symlink(File.join(@outside, "secret.md"), File.join(@dir, "out.md"))
      expect { described_class.resolve("out.md", @dir) }.to raise_error(described_class::Refused)
    end

    it "accepts a notes dir that is itself a link" do
      File.symlink(@dir, File.join(@root, "dirlink"))
      expect(described_class.resolve("findings.md", File.join(@root, "dirlink"))).to eq("findings.md")
    end

    it "refuses a symlink loop" do
      File.symlink(File.join(@dir, "loop2.md"), File.join(@dir, "loop1.md"))
      File.symlink(File.join(@dir, "loop1.md"), File.join(@dir, "loop2.md"))
      expect { described_class.resolve("loop1.md", @dir) }.to raise_error(described_class::Refused, /symbolic links/)
    end

    it "refuses a path through a file" do
      expect { described_class.resolve("findings.md/x.md", @dir) }.to raise_error(described_class::Refused, /not a directory/)
    end

    it "refuses in an unreadable directory" do
      skip "running as root" if Process.uid.zero?
      locked = File.join(@dir, "locked")
      FileUtils.mkdir(locked)
      File.write(File.join(locked, "n.md"), "x")
      File.chmod(0o000, locked)
      expect { described_class.resolve("locked/n.md", @dir) }.to raise_error(described_class::Refused, /permission/)
    ensure
      File.chmod(0o755, locked) if locked && File.exist?(locked)
    end

    it "refuses a missing notes dir" do
      expect { described_class.resolve("findings.md", File.join(@root, "nope")) }
        .to raise_error(described_class::Refused, /does not exist/)
    end

    it "refuses a nil notes dir" do
      expect { described_class.resolve("findings.md", nil) }.to raise_error(described_class::Refused, /does not exist/)
    end

    it "checks the shape before the filesystem" do
      expect { described_class.resolve("../outside/secret.md", @dir) }.to raise_error(described_class::Refused, /dot/)
    end
  end

  describe ".url_path" do
    it "joins the segments without encoding" do
      expect(described_class.url_path(%w[a b-c.md])).to eq("a/b-c.md")
    end
  end
end
