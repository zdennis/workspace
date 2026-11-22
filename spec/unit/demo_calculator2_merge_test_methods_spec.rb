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

  it "takes theirs' change to a test method ours left as the ancestor had it" do
    ours = file(smoke, test_method("test_mine"))
    theirs = file(test_method("test_smoke", "refute false"))
    expect(described_class.merge(ancestor, ours, theirs)).to eq(file(test_method("test_smoke", "refute false"), test_method("test_mine")))
  end

  it "conflicts when both sides change the same method differently" do
    expect { described_class.merge(ancestor, file(test_method("test_smoke", "assert 1")), file(test_method("test_smoke", "assert 2"))) }
      .to raise_error(described_class::Conflict, "both sides changed test_smoke (theirs changed it, ours changed it)")
  end

  it "keeps a method both sides changed the same way" do
    same = file(test_method("test_smoke", "assert 1"))
    expect(described_class.merge(ancestor, same, same)).to equal(same)
  end

  describe "helpers and requires (what lane B's --json and REPL goals add)" do
    def helper(name, args, body) = "  def #{name}(#{args})\n    #{body}\n  end\n"

    let(:run_calc) { helper("run_calc", "expression", "Open3.capture3(BIN, expression)") }
    let(:ancestor) { file(run_calc, smoke) }

    it "adds a new require after ours' last one, and a new helper before the final end" do
      theirs = "require \"json\"\n" + file(run_calc, smoke, helper("run_repl", "input", "Open3.capture3(BIN, stdin_data: input)"), test_method("test_repl"))
      merged = described_class.merge(ancestor, file(run_calc, smoke, test_method("test_mine")), theirs)
      expect(merged).to eq("require \"minitest/autorun\"\nrequire \"json\"\n" +
        file(run_calc, smoke, test_method("test_mine"), helper("run_repl", "input", "Open3.capture3(BIN, stdin_data: input)"), test_method("test_repl")).delete_prefix("require \"minitest/autorun\"\n"))
    end

    it "does not add a require ours already has" do
      ours = "require \"json\"\n" + file(run_calc, smoke)
      expect(described_class.merge(ancestor, ours, "require \"json\"\n" + file(run_calc, smoke))).to equal(ours)
    end

    it "takes theirs' widened helper when ours left it alone" do
      wide = helper("run_calc", "*args", "Open3.capture3(BIN, *args)")
      merged = described_class.merge(ancestor, file(run_calc, smoke, test_method("test_mine")), file(wide, smoke, test_method("test_json")))
      expect(merged).to eq(file(wide, smoke, test_method("test_mine"), test_method("test_json")))
    end

    it "conflicts when both sides change the helper" do
      ours = file(helper("run_calc", "x", "x"), smoke)
      theirs = file(helper("run_calc", "*args", "args"), smoke)
      expect { described_class.merge(ancestor, ours, theirs) }.to raise_error(described_class::Conflict, /both sides changed run_calc/)
    end

    it "treats a one-line endless helper as its own block, not part of the test after it" do
      theirs = file(run_calc, smoke, "  def two = 2\n", test_method("test_b"))
      merged = described_class.merge(ancestor, ancestor, theirs)
      expect(merged.scan("def test_b").size).to eq(1)
      expect(merged).to eq(file(run_calc, smoke, "  def two = 2\n", test_method("test_b")))
    end

    it "names a class method with its self., so two of them do not collide" do
      theirs = file(run_calc, smoke, helper("self.a", "", "1"), helper("self.b", "", "2"))
      expect(described_class.merge(ancestor, ancestor, theirs)).to eq(theirs)
    end

    it "conflicts when a def starts inside another method, as in a heredoc" do
      theirs = file(run_calc, smoke, "  def test_text\n    <<~RUBY\n  def inner\n    RUBY\n  end\n")
      expect { described_class.merge(ancestor, ancestor, theirs) }.to raise_error(described_class::Conflict, "inner starts inside test_text, so the methods cannot be told apart")
    end

    it "conflicts when theirs adds a require and ours has none to put it after" do
      expect { described_class.merge(ancestor, "class CalcTest < Minitest::Test\n#{run_calc}#{smoke}end\n", "require \"json\"\n" + file(run_calc, smoke)) }
        .to raise_error(described_class::Conflict, /no top-level require/)
    end
  end

  it "conflicts when theirs defines the same new name twice" do
    expect { described_class.merge(ancestor, ancestor, file(smoke, test_method("test_a"), test_method("test_a"))) }.to raise_error(described_class::Conflict, /twice/)
  end

  it "conflicts when ours defines the same name twice" do
    ours = file(smoke, test_method("test_a"), test_method("test_a", "assert 1"))
    expect { described_class.merge(ancestor, ours, file(smoke, test_method("test_b"))) }.to raise_error(described_class::Conflict, /ours defines test_a twice/)
  end

  describe ".duplicate_names" do
    it "returns a duplicate in a file that passes ruby -c" do
      text = file(smoke, test_method("test_a"), test_method("test_a", "assert 1"))
      expect { RubyVM::InstructionSequence.compile(text) }.not_to raise_error
      expect(described_class.duplicate_names(text)).to eq(["test_a"])
    end

    it "returns nothing when every name is unique" do
      expect(described_class.duplicate_names(file(smoke, test_method("test_a")))).to eq([])
    end
  end

  it "drops a method theirs removed and ours left alone, with its blank line" do
    ancestor = file(smoke, test_method("test_old"), test_method("test_kept"))
    ours = file(smoke, test_method("test_old"), test_method("test_kept"), test_method("test_mine"))
    merged = described_class.merge(ancestor, ours, file(smoke, test_method("test_kept")))
    expect(merged).to eq(file(smoke, test_method("test_kept"), test_method("test_mine")))
  end

  it "drops the last method of the class when theirs removed it, leaving a file that parses" do
    ancestor = file(smoke, test_method("test_old"))
    merged = described_class.merge(ancestor, ancestor, file(smoke))
    expect(merged).to eq(file(smoke))
  end

  it "keeps out a method both sides removed" do
    ancestor = file(smoke, test_method("test_old"))
    expect(described_class.merge(ancestor, file(smoke, test_method("test_mine")), file(smoke))).to eq(file(smoke, test_method("test_mine")))
  end

  it "conflicts when theirs changes a method ours removed" do
    ancestor = file(smoke, test_method("test_old"))
    expect { described_class.merge(ancestor, file(smoke), file(smoke, test_method("test_old", "refute false"))) }
      .to raise_error(described_class::Conflict, "both sides changed test_old (theirs changed it, ours removed it)")
  end

  it "conflicts when theirs removes a method ours changed" do
    expect { described_class.merge(ancestor, file(test_method("test_smoke", "assert 1")), file) }
      .to raise_error(described_class::Conflict, "both sides changed test_smoke (theirs removed it, ours changed it)")
  end

  it "conflicts when theirs adds a class or any other line outside the methods" do
    theirs = file(smoke, test_method("test_new")) + "class Other\nend\n"
    expect { described_class.merge(ancestor, ancestor, theirs) }.to raise_error(described_class::Conflict, /outside the methods/)
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
      ours = file(test_method("test_smoke", "assert 1"))
      write(ancestor, ours, file(test_method("test_smoke", "assert 2")))
      expect(described_class.run(paths, err: err)).to eq(1)
      expect(err.string).to include("merge_test_methods: both sides changed test_smoke")
      expect(File.read(paths[1])).to eq(ours)
    end

    it "returns 1 for a file it cannot read and 2 for the wrong argument count" do
      expect(described_class.run(paths, err: err)).to eq(1)
      expect(described_class.run([], err: err)).to eq(2)
    end
  end
end
