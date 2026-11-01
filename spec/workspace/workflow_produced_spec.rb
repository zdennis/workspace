require "spec_helper"
require "tmpdir"
require "fileutils"

RSpec.describe Workspace::WorkflowProduced do
  around do |example|
    Dir.mktmpdir("wf-produced") do |dir|
      @dir = File.realpath(dir)
      example.run
    end
  end

  def path(name) = File.join(@dir, name)

  describe ".strict?" do
    it "is true only for a Hash carrying the marker" do
      expect(described_class.strict?("produces_check" => "strict")).to be(true)
      expect(described_class.strict?("produces_check" => "other")).to be(false)
      expect(described_class.strict?({})).to be(false)
    end

    it "is false for a definition that is not a Hash" do
      expect(described_class.strict?(nil)).to be(false)
      expect(described_class.strict?("strict")).to be(false)
      expect(described_class.strict?(["produces_check"])).to be(false)
    end
  end

  describe ".inspect_file in strict mode" do
    it "passes a non-empty regular file" do
      File.write(path("a.md"), "x")

      result = described_class.inspect_file(path("a.md"), strict: true)

      expect([result.exists, result.rule]).to eq([true, nil])
    end

    it "names an empty file, a directory and a symlink" do
      File.write(path("empty.md"), "")
      Dir.mkdir(path("dir"))
      File.write(path("real.md"), "x")
      File.symlink(path("real.md"), path("link.md"))

      rules = %w[empty.md dir link.md].map { |name| described_class.inspect_file(path(name), strict: true).rule }

      expect(rules).to eq(%w[empty not_regular_file symlink])
    end

    it "reports a dangling symlink as existing, with the symlink rule" do
      File.symlink(path("nowhere"), path("dangling.md"))

      result = described_class.inspect_file(path("dangling.md"), strict: true)

      expect([result.exists, result.rule]).to eq([true, "symlink"])
    end

    it "reports nothing at the path as missing" do
      result = described_class.inspect_file(path("none.md"), strict: true)

      expect([result.exists, result.rule, result.mtime]).to eq([false, nil, nil])
    end

    it "reports a path through a file (ENOTDIR) as missing" do
      File.write(path("file"), "x")

      result = described_class.inspect_file(path("file/inner.md"), strict: true)

      expect(result.exists).to be(false)
    end
  end

  describe ".inspect_file in legacy mode" do
    it "counts an empty file, a symlink and a directory as there, with a mtime" do
      File.write(path("empty.md"), "")
      File.write(path("real.md"), "x")
      File.symlink(path("real.md"), path("link.md"))
      Dir.mkdir(path("dir"))

      results = %w[empty.md link.md dir].map { |name| described_class.inspect_file(path(name), strict: false) }

      expect(results.map { |each| [each.exists, each.rule] }).to eq([[true, nil]] * 3)
      expect(results.map(&:mtime)).to all(be_a(Time))
    end

    it "reports a missing path as missing" do
      expect(described_class.inspect_file(path("none.md"), strict: false).exists).to be(false)
    end

    it "reports a file whose mtime can't be read as missing" do
      File.write(path("a.md"), "x")
      allow(File).to receive(:mtime).and_raise(Errno::EACCES)

      result = described_class.inspect_file(path("a.md"), strict: false)

      expect([result.exists, result.mtime]).to eq([false, nil])
    end
  end

  describe "Result#current?" do
    let(:time) { Time.utc(2026, 10, 4, 12) }

    it "is true with no attempt start for a passing file" do
      expect(described_class::Result.new(true, nil, time).current?(nil)).to be(true)
    end

    it "compares the mtime with the attempt start" do
      expect(described_class::Result.new(true, nil, time).current?(time)).to be(true)
      expect(described_class::Result.new(true, nil, time - 1).current?(time)).to be(false)
    end

    it "is false for a missing file or one that breaks a rule" do
      expect(described_class::Result.new(false, nil, nil).current?(nil)).to be_falsey
      expect(described_class::Result.new(true, "empty", time).current?(nil)).to be(false)
    end
  end
end
