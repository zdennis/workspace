require "spec_helper"
require "tmpdir"
require "fileutils"

RSpec.describe Workspace::WorkflowExpectFail do
  # Stands in for WorkflowCheck: writes +stdout+ and +stderr+ to the log (as the real one merges them)
  # and answers +result+, recording each call.
  fake_checker = Class.new do
    attr_reader :calls

    def initialize(result:, stdout: "", stderr: "")
      @result = result
      @stdout = stdout
      @stderr = stderr
      @calls = []
    end

    def call(**args)
      @calls << args
      File.write(args[:log], @stdout + @stderr)
      @result
    end
  end

  let(:dir) { Dir.mktmpdir("expect-fail-spec-") }
  let(:tmp_root) { File.join(dir, "tmp").tap { |path| FileUtils.mkdir_p(path) } }
  let(:checkout) { File.join(dir, "checkout").tap { |path| FileUtils.mkdir_p(path) } }
  let(:lineage_value) { Workspace::WorkspaceLineage::Lineage.new(name: "app", path: checkout, is_worktree: false, worktree: nil) }
  let(:lineage) { instance_double(Workspace::WorkspaceLineage, resolve: lineage_value) }
  let(:test_command) { "bundle exec rspec" }
  let(:commands_config) { instance_double(Workspace::CommandsConfig, for_project: {test: test_command, lint: nil}) }
  let(:checker) { fake_checker.new(result: {exit_code: 1, timed_out: false}, stdout: "1 example, 1 failure\n") }

  subject(:expect_fail) { described_class.new(lineage: lineage, commands_config: commands_config, checker: checker, tmp_root: tmp_root) }

  after { FileUtils.rm_rf(dir) }

  def match_file(text)
    File.join(checkout, "failure.txt").tap { |path| File.write(path, text) }
  end

  it "passes when the tests fail, and hands back their output" do
    result = expect_fail.call(cwd: checkout, files: ["spec/a_spec.rb"])

    expect(result.passed).to be(true)
    expect(result.message).to eq("expect-fail: the tests failed as expected (exit 1)")
    expect(result.output).to eq("1 example, 1 failure\n")
  end

  it "runs commands.test in the checkout with the files shell-escaped and appended" do
    expect_fail.call(cwd: checkout, files: ["spec/a b_spec.rb", "spec/$(touch x)_spec.rb", "spec/it's_spec.rb"])

    expect(checker.calls.size).to eq(1)
    expect(checker.calls.first[:command]).to eq("bundle exec rspec spec/a\\ b_spec.rb spec/\\$\\(touch\\ x\\)_spec.rb spec/it\\'s_spec.rb")
    expect(checker.calls.first[:cwd]).to eq(checkout)
  end

  it "gives the runner the default limit, or the one asked for" do
    expect_fail.call(cwd: checkout, files: ["spec/a_spec.rb"])
    expect_fail.call(cwd: checkout, files: ["spec/a_spec.rb"], timeout: 840)

    expect(checker.calls.map { |call| call[:timeout] }).to eq([240, 840])
  end

  it "keeps its log in a temporary directory under tmp_root and removes it" do
    expect_fail.call(cwd: checkout, files: ["spec/a_spec.rb"])

    expect(checker.calls.first[:log]).to start_with(tmp_root)
    expect(Dir.children(tmp_root)).to be_empty
  end

  it "reads commands.test for the workspace of the checkout, a worktree's own name first" do
    worktree = Workspace::WorkspaceLineage::Lineage.new(name: "app", path: checkout, is_worktree: true, worktree: "app.worktree-fix")
    allow(lineage).to receive(:resolve).with(cwd: checkout).and_return(worktree)

    expect_fail.call(cwd: checkout, files: ["spec/a_spec.rb"])

    expect(commands_config).to have_received(:for_project).with("app.worktree-fix")
  end

  it "refuses an empty file list without running anything" do
    result = expect_fail.call(cwd: checkout, files: [])

    expect(result.passed).to be(false)
    expect(result.message).to start_with("expect-fail: no test files given")
    expect(checker.calls).to be_empty
  end

  it "refuses when commands.test is unset" do
    allow(commands_config).to receive(:for_project).and_return({test: nil, lint: nil})

    result = expect_fail.call(cwd: checkout, files: ["spec/a_spec.rb"])

    expect(result.passed).to be(false)
    expect(result.message).to eq("expect-fail: commands.test is unset for app; set it: workspace config set commands.test \"<test command>\" --name app")
    expect(checker.calls).to be_empty
  end

  it "keeps only the last bytes of a long output, says it was cut, and still decides on all of it" do
    long = fake_checker.new(result: {exit_code: 1, timed_out: false}, stdout: "early failure\n" + ("." * 100) + "\nlast line\n")
    path = match_file("early failure")

    result = described_class.new(lineage: lineage, commands_config: commands_config, checker: long, tmp_root: tmp_root, output_keep: 20, block: 16)
      .call(cwd: checkout, files: ["spec/a_spec.rb"], match_file: path)

    expect(result.passed).to be(true)
    expect(result.cut).to be(true)
    expect(result.output).to eq("#{"." * 9}\nlast line\n")
  end

  it "does not cut an output within the limit" do
    result = expect_fail.call(cwd: checkout, files: ["spec/a_spec.rb"])

    expect(result.cut).to be(false)
  end

  it "refuses passing tests" do
    passing = fake_checker.new(result: {exit_code: 0, timed_out: false}, stdout: "1 example, 0 failures\n")

    result = described_class.new(lineage: lineage, commands_config: commands_config, checker: passing, tmp_root: tmp_root)
      .call(cwd: checkout, files: ["spec/a_spec.rb"])

    expect(result.passed).to be(false)
    expect(result.message).to eq("expect-fail: the tests passed (exit 0); a fail-first test must fail before the fix")
    expect(result.output).to eq("1 example, 0 failures\n")
  end

  it "refuses tests that ran past the limit, naming it" do
    slow = fake_checker.new(result: {exit_code: nil, timed_out: true})

    result = described_class.new(lineage: lineage, commands_config: commands_config, checker: slow, tmp_root: tmp_root)
      .call(cwd: checkout, files: ["spec/a_spec.rb"], timeout: 840)

    expect(result.passed).to be(false)
    expect(result.message).to eq("expect-fail: tests ran past 840s and were stopped")
  end

  it "refuses tests that could not start" do
    broken = fake_checker.new(result: {exit_code: nil, timed_out: false, error: "could not run the check (Errno::ENOENT)"})

    result = described_class.new(lineage: lineage, commands_config: commands_config, checker: broken, tmp_root: tmp_root)
      .call(cwd: checkout, files: ["spec/a_spec.rb"])

    expect(result.passed).to be(false)
    expect(result.message).to eq("expect-fail: the tests could not run: could not run the check (Errno::ENOENT)")
  end

  context "with --match-file" do
    let(:checker) { fake_checker.new(result: {exit_code: 1, timed_out: false}, stdout: "Failure: expected 3, got 2\n", stderr: "warning: deprecated\n") }

    it "passes when the output holds the file's trimmed text" do
      result = expect_fail.call(cwd: checkout, files: ["spec/a_spec.rb"], match_file: match_file("\n  expected 3, got 2  \n\n"))

      expect(result.passed).to be(true)
      expect(result.message).to include("with the text of")
    end

    it "matches text found only on stderr" do
      result = expect_fail.call(cwd: checkout, files: ["spec/a_spec.rb"], match_file: match_file("warning: deprecated"))

      expect(result.passed).to be(true)
    end

    it "reads a relative match file from the checkout" do
      match_file("expected 3")

      result = expect_fail.call(cwd: checkout, files: ["spec/a_spec.rb"], match_file: "failure.txt")

      expect(result.passed).to be(true)
    end

    it "refuses when the text is missing from the output" do
      path = match_file("expected 4, got 2")

      result = expect_fail.call(cwd: checkout, files: ["spec/a_spec.rb"], match_file: path)

      expect(result.passed).to be(false)
      expect(result.message).to eq("expect-fail: the tests failed (exit 1) but their output does not hold the text of #{path} (trimmed, as one exact substring)")
    end

    it "refuses a missing match file without running anything" do
      path = File.join(checkout, "nope.txt")

      result = expect_fail.call(cwd: checkout, files: ["spec/a_spec.rb"], match_file: path)

      expect(result.passed).to be(false)
      expect(result.message).to eq("expect-fail: match file #{path} is missing")
      expect(checker.calls).to be_empty
    end

    it "refuses a match file that is only whitespace without running anything" do
      path = match_file(" \n\t\n")

      result = expect_fail.call(cwd: checkout, files: ["spec/a_spec.rb"], match_file: path)

      expect(result.passed).to be(false)
      expect(result.message).to eq("expect-fail: match file #{path} is empty")
      expect(checker.calls).to be_empty
    end

    it "finds text that straddles two blocks of the log" do
      straddling = fake_checker.new(result: {exit_code: 1, timed_out: false}, stdout: "#{"x" * 6}expected 3, got 2#{"y" * 6}")

      result = described_class.new(lineage: lineage, commands_config: commands_config, checker: straddling, tmp_root: tmp_root, block: 8)
        .call(cwd: checkout, files: ["spec/a_spec.rb"], match_file: match_file("expected 3, got 2"))

      expect(result.passed).to be(true)
    end

    it "finds text that ends the log exactly, read in blocks" do
      ending = fake_checker.new(result: {exit_code: 1, timed_out: false}, stdout: "1234567expected 3")

      result = described_class.new(lineage: lineage, commands_config: commands_config, checker: ending, tmp_root: tmp_root, block: 4)
        .call(cwd: checkout, files: ["spec/a_spec.rb"], match_file: match_file("expected 3"))

      expect(result.passed).to be(true)
    end

    it "refuses a match file over the cap without running anything" do
      path = match_file("x" * (described_class::MATCH_MAX + 1))

      result = expect_fail.call(cwd: checkout, files: ["spec/a_spec.rb"], match_file: path)

      expect(result.message).to eq("expect-fail: match file #{path} is over #{described_class::MATCH_MAX} bytes")
      expect(checker.calls).to be_empty
    end

    it "refuses a match file that is a link, and one that is a directory, without running anything" do
      target = match_file("expected 3")
      link = File.join(checkout, "link.txt")
      File.symlink(target, link)

      expect(expect_fail.call(cwd: checkout, files: ["a"], match_file: link).message).to eq("expect-fail: match file #{link} is a link; give the file itself")
      expect(expect_fail.call(cwd: checkout, files: ["a"], match_file: checkout).message).to eq("expect-fail: match file #{checkout} is not a regular file")
      expect(checker.calls).to be_empty
    end

    it "still refuses passing tests whose output holds the text" do
      passing = fake_checker.new(result: {exit_code: 0, timed_out: false}, stdout: "expected 3, got 2\n")

      result = described_class.new(lineage: lineage, commands_config: commands_config, checker: passing, tmp_root: tmp_root)
        .call(cwd: checkout, files: ["spec/a_spec.rb"], match_file: match_file("expected 3"))

      expect(result.passed).to be(false)
      expect(result.message).to start_with("expect-fail: the tests passed")
    end
  end
end
