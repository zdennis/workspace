require "spec_helper"
require "tmpdir"
require "stringio"

load File.join(PROJECT_ROOT, "script", "demo_calculator2", "merge_test_methods")

RSpec.describe MergeTestMethods do
  def file(*methods, extra: "")
    "require \"minitest/autorun\"\n\nclass CalcTest < Minitest::Test\n#{methods.join("\n")}#{extra}end\n"
  end

  def test_method(name, body = "assert true", comment: nil)
    "#{"  # #{comment}\n" if comment}  def #{name}\n    #{body}\n  end\n"
  end

  let(:smoke) { test_method("test_smoke") }
  let(:ancestor) { file(smoke) }

  it "puts the methods theirs added, with their comments, before the final end of ours" do
    ours = file(smoke, test_method("test_add", "assert_equal 3, 1 + 2"))
    theirs = file(smoke, test_method("test_json", "assert true", comment: "lane B"))
    merged = described_class.merge(ancestor, ours, theirs)
    expect(merged).to eq(file(smoke, test_method("test_add", "assert_equal 3, 1 + 2"), test_method("test_json", "assert true", comment: "lane B")))
    expect(merged).to end_with("  end\nend\n")
  end

  it "keeps several added methods in theirs' order" do
    ours = file(smoke, test_method("test_mine"))
    theirs = file(smoke, test_method("test_a"), test_method("test_b"))
    expect(described_class.merge(ancestor, ours, theirs)).to eq(file(smoke, test_method("test_mine"), test_method("test_a"), test_method("test_b")))
  end

  it "returns ours itself when theirs added nothing" do
    ours = file(smoke, test_method("test_add"))
    expect(described_class.merge(ancestor, ours, ancestor)).to equal(ours)
  end

  it "skips an added method ours already has with the same body" do
    both = test_method("test_same")
    expect(described_class.merge(ancestor, file(smoke, both), file(smoke, both))).to eq(file(smoke, both))
  end

  it "conflicts when an added method has a different body in ours" do
    expect { described_class.merge(ancestor, file(smoke, test_method("test_x", "assert 1")), file(smoke, test_method("test_x", "assert 2"))) }
      .to raise_error(described_class::Conflict, /test_x/)
  end

  it "conflicts when theirs changes a method of the ancestor" do
    expect { described_class.merge(ancestor, ancestor, file(test_method("test_smoke", "refute true"))) }.to raise_error(described_class::Conflict, /test_smoke/)
  end

  it "conflicts when theirs defines the same new name twice" do
    expect { described_class.merge(ancestor, ancestor, file(smoke, test_method("test_a"), test_method("test_a"))) }.to raise_error(described_class::Conflict, /twice/)
  end

  it "conflicts when theirs removes a method of the ancestor" do
    expect { described_class.merge(ancestor, ancestor, file) }.to raise_error(described_class::Conflict, /removed or changed/)
  end

  it "conflicts when theirs adds a require or a class outside the methods" do
    theirs = "require \"set\"\n" + file(smoke, test_method("test_new"))
    expect { described_class.merge(ancestor, ancestor, theirs) }.to raise_error(described_class::Conflict, /outside the test methods/)
  end

  it "conflicts when the merged text does not parse" do
    broken = file(smoke, "  def test_bad\n    assert (\n  end\n")
    expect { described_class.merge(ancestor, ancestor, broken) }.to raise_error(described_class::Conflict, /does not parse/)
  end

  it "conflicts when ours has no final end at column 0" do
    expect { described_class.merge(ancestor, "class CalcTest\n" + smoke, file(smoke, test_method("test_new"))) }.to raise_error(described_class::Conflict, /final end/)
  end

  describe ".run" do
    let(:dir) { Dir.mktmpdir }
    let(:paths) { %w[o a b].map { |name| File.join(dir, name) } }
    let(:err) { StringIO.new }

    after { FileUtils.rm_rf(dir) }

    def write(ancestor, ours, theirs) = paths.zip([ancestor, ours, theirs]).each { |path, text| File.write(path, text) }

    it "writes the merge into the second path and returns 0" do
      write(ancestor, ancestor, file(smoke, test_method("test_new")))
      expect(described_class.run(paths, err: err)).to eq(0)
      expect(File.read(paths[1])).to eq(file(smoke, test_method("test_new")))
    end

    it "returns 1, says why and leaves ours alone on a conflict" do
      write(ancestor, ancestor, file)
      expect(described_class.run(paths, err: err)).to eq(1)
      expect(err.string).to include("merge_test_methods:")
      expect(File.read(paths[1])).to eq(ancestor)
    end

    it "returns 1 for a file it cannot read and 2 for the wrong argument count" do
      expect(described_class.run(paths, err: err)).to eq(1)
      expect(described_class.run([], err: err)).to eq(2)
    end
  end
end
