require "spec_helper"
require "tmpdir"
require "fileutils"

RSpec.describe Workspace::WorkflowCheckIds do
  let(:dir) { Dir.mktmpdir("check-ids-spec-") }
  let(:plan_path) { File.join(dir, "IMPLEMENTATION_PLAN.md") }
  let(:plans) { instance_double(Workspace::PlanAccess, path_for: plan_path) }
  let(:check) { described_class.new(plans: plans) }

  after { FileUtils.rm_rf(dir) }

  def write(name, text)
    File.join(dir, name).tap { |path| File.write(path, text) }
  end

  def run(defined:, covered: nil, prefixes: ["R"], **options)
    check.call(prefixes: prefixes, defined: defined, covered: covered, base_dir: dir, **options)
  end

  def write_plan(details: "", tasks: "- [ ] T1 One\n", eol: "\n")
    text = "---\nplan: 1\n---\n\n# Plan\n\n## Tasks\n\n#{tasks}\n## Task details\n\n#{details}"
    File.write(plan_path, text.gsub("\n", eol))
  end

  describe "prefixes and ID forms" do
    it "passes when every R ID is named in the covered file" do
      defined = write("req.md", "R1 first\nR2 second\n")
      covered = write("cov.md", "covers R1 and R2\n")
      result = run(defined: defined, covered: covered)
      expect(result).to have_attributes(passed: true, defined: %w[R1 R2], covered: %w[R1 R2], missing: [], reason: nil,
        message: "check-ids: all 2 IDs covered")
    end

    it "names the IDs that are missing, in the defining file's order" do
      defined = write("req.md", "R3\nR1\nR2\n")
      covered = write("cov.md", "R1\n")
      result = run(defined: defined, covered: covered)
      expect(result).to have_attributes(passed: false, missing: %w[R3 R2], covered: %w[R1], reason: "uncovered",
        message: "check-ids: not in #{covered}: R3 R2")
    end

    it "handles the AC-n form" do
      defined = write("req.md", "AC-1 a\nAC-2 b\n")
      covered = write("cov.md", "AC-1 PASS\n")
      result = run(defined: defined, covered: covered, prefixes: ["AC"])
      expect(result.missing).to eq(%w[AC-2])
    end

    it "mixes comma-free repeated prefixes and keeps one order and one entry per ID" do
      defined = write("req.md", "R1 a\nAC-1 b\nR1 again\nAC-2 c\n")
      covered = write("cov.md", "R1 AC-1\n")
      result = run(defined: defined, covered: covered, prefixes: %w[R AC R])
      expect(result.defined).to eq(%w[R1 AC-1 AC-2])
      expect(result.missing).to eq(%w[AC-2])
    end

    it "treats AC-3 and AC3 as the same ID and reports the defining file's spelling" do
      defined = write("req.md", "AC-3 a\nAC4 b\n")
      covered = write("cov.md", "AC3 and AC-4\n")
      result = run(defined: defined, covered: covered, prefixes: ["AC"])
      expect(result).to have_attributes(passed: true, defined: %w[AC-3 AC4])
    end

    it "matches whole tokens only" do
      defined = write("req.md", "R1\nR10\n")
      expect(run(defined: defined, covered: write("a.md", "R10 R1a xR1\n")).missing).to eq(%w[R1])
      expect(run(defined: defined, covered: write("b.md", "R1. R10,\n")).passed).to be(true)
    end

    it "does not take R10 as defining R1 or R1a as an ID" do
      defined = write("req.md", "R1a nope\nR10 yes\n")
      expect(run(defined: defined, covered: write("cov.md", "R10\n")).defined).to eq(%w[R10])
    end

    it "counts a defining ID only at the start of a line" do
      defined = write("req.md", "see R1 for more\n  R2 indented\nR3 real\n")
      expect(run(defined: defined, covered: write("cov.md", "R3\n")).defined).to eq(%w[R3])
    end

    it "tolerates CRLF in both files" do
      defined = write("req.md", "R1 a\r\nR2 b\r\n")
      covered = write("cov.md", "R1\r\nR2\r\n")
      expect(run(defined: defined, covered: covered)).to have_attributes(passed: true, defined: %w[R1 R2])
    end

    it "passes with no IDs defined" do
      defined = write("req.md", "nothing numbered\n")
      result = run(defined: defined, covered: write("cov.md", ""))
      expect(result).to have_attributes(passed: true, defined: [], message: "check-ids: all 0 IDs covered")
    end

    it "refuses a prefix that is not letters" do
      defined = write("req.md", "R1\n")
      expect { run(defined: defined, covered: defined, prefixes: ["R."]) }.to raise_error(ArgumentError, /letters only/)
      expect { run(defined: defined, covered: defined, prefixes: []) }.to raise_error(ArgumentError)
    end

    it "wants exactly one of covered and plan details" do
      defined = write("req.md", "R1\n")
      expect { run(defined: defined) }.to raise_error(ArgumentError, /exactly one/)
      expect { run(defined: defined, covered: defined, plan_details_for: "app") }.to raise_error(ArgumentError, /exactly one/)
    end
  end

  describe "plan details" do
    let(:defined) { write("req.md", "R1\nR2\nR3\n") }

    it "passes when every R is in the Task details section" do
      write_plan(details: "### T1\nCovers R1, R2 and R3.\n")
      result = run(defined: defined, plan_details_for: "app")
      expect(result).to have_attributes(passed: true, message: "check-ids: all 3 IDs covered", covered_path: plan_path)
      expect(plans).to have_received(:path_for).with("app")
    end

    it "names the uncovered Rs with today's text" do
      write_plan(details: "### T1\nR1 only\n")
      expect(run(defined: defined, plan_details_for: "app")).to have_attributes(
        passed: false, reason: "uncovered", missing: %w[R2 R3], message: "In no task of ## Task details: R2 R3"
      )
    end

    it "does not count an R outside the section" do
      write_plan(tasks: "- [ ] T1 R2 R3 here\n", details: "R1\n")
      expect(run(defined: defined, plan_details_for: "app").missing).to eq(%w[R2 R3])
    end

    it "ends the section at a ## heading but not at ###" do
      write_plan(details: "### T1\nR1\n### T2\nR2\n## Notes\nR3\n")
      expect(run(defined: defined, plan_details_for: "app").missing).to eq(%w[R3])
    end

    it "reads a missing section as empty" do
      File.write(plan_path, "---\nplan: 1\n---\n\n## Tasks\n\n- [ ] T1 One R1 R2 R3\n")
      expect(run(defined: defined, plan_details_for: "app").missing).to eq(%w[R1 R2 R3])
    end

    it "tolerates CRLF in the plan" do
      write_plan(details: "### T1\nR1 R2 R3\n", eol: "\r\n")
      expect(run(defined: defined, plan_details_for: "app").passed).to be(true)
    end

    it "fails with no_plan when the plan file is missing, before reading the defined file" do
      result = run(defined: File.join(dir, "absent.md"), plan_details_for: "app")
      expect(result).to have_attributes(passed: false, reason: "no_plan", message: "check-ids: no plan with tasks at #{plan_path}")
    end

    it "fails with no_plan when the plan has no tasks, even with allow_missing" do
      write_plan(tasks: "", details: "R1\n")
      result = run(defined: File.join(dir, "absent.md"), plan_details_for: "app", allow_missing: true)
      expect(result).to have_attributes(passed: false, reason: "no_plan")
    end

    it "passes a plan with tasks when the defined file is absent and allow_missing is set" do
      write_plan(details: "### T1\nNothing\n")
      result = run(defined: "absent.md", plan_details_for: "app", allow_missing: true)
      expect(result).to have_attributes(passed: true, reason: "defined_absent", covered_path: plan_path)
    end
  end

  describe "a missing defined file" do
    it "passes with allow_missing, carrying defined_absent" do
      result = run(defined: "absent.md", covered: write("cov.md", "R1\n"), allow_missing: true)
      expect(result).to have_attributes(passed: true, reason: "defined_absent", defined: [], defined_path: File.join(dir, "absent.md"))
    end

    it "fails without allow_missing" do
      path = File.join(dir, "absent.md")
      result = run(defined: path, covered: write("cov.md", "R1\n"))
      expect(result).to have_attributes(passed: false, reason: "defined_absent", message: "check-ids: #{path} does not exist")
    end

    it "does not pass a link with allow_missing" do
      target = write("real.md", "R1\n")
      File.symlink(target, File.join(dir, "link.md"))
      result = run(defined: "link.md", covered: target, allow_missing: true)
      expect(result).to have_attributes(passed: false, reason: "defined_absent")
      expect(result.message).to include("is a link")
    end
  end

  describe "a missing covered file" do
    it "fails with covered_absent" do
      defined = write("req.md", "R1\n")
      path = File.join(dir, "nope.md")
      result = run(defined: defined, covered: path)
      expect(result).to have_attributes(passed: false, reason: "covered_absent", message: "check-ids: #{path} does not exist", defined: %w[R1])
    end
  end

  describe "paths" do
    it "resolves relative paths against base_dir and leaves absolute ones alone" do
      other = Dir.mktmpdir("check-ids-other-")
      begin
        File.write(File.join(other, "abs.md"), "R1\n")
        write("req.md", "R1\n")
        result = run(defined: "req.md", covered: File.join(other, "abs.md"))
        expect(result).to have_attributes(passed: true, defined_path: File.join(dir, "req.md"), covered_path: File.join(other, "abs.md"))
      ensure
        FileUtils.rm_rf(other)
      end
    end

    it "refuses a covered file that is a link" do
      target = write("real.md", "R1\n")
      File.symlink(target, File.join(dir, "link.md"))
      result = run(defined: target, covered: "link.md")
      expect(result).to have_attributes(passed: false, reason: "covered_absent")
      expect(result.message).to include("is a link")
    end

    it "refuses a directory" do
      defined = write("req.md", "R1\n")
      Dir.mkdir(File.join(dir, "sub"))
      expect(run(defined: defined, covered: "sub").message).to include("is not a regular file")
    end

    it "refuses a file over the size cap" do
      defined = write("req.md", "R1\n")
      stub_const("#{described_class}::MAX_BYTES", 8)
      covered = write("big.md", "R1 and a lot more text\n")
      expect(run(defined: defined, covered: covered).message).to include("is over 8 bytes")
    end
  end

  describe "line_regex" do
    let(:defined) { write("req.md", "AC-1 a\nAC-2 b\nAC-3 c\n") }

    it "counts an ID only on a line that names it and matches" do
      report = write("report.md", "| AC-1 | PASS |\n| AC-2 | FAIL |\nAC-3 is discussed in prose\r\n| AC-3 | PASS |\r\n")
      result = run(defined: defined, covered: report, prefixes: ["AC"], line_regex: /\bPASS\b/)
      expect(result).to have_attributes(passed: false, missing: %w[AC-2], covered: %w[AC-1 AC-3],
        message: "check-ids: no line of #{report} names these and matches /\\bPASS\\b/: AC-2")
    end

    it "fails an ID that prose mentions but no matching line names" do
      report = write("report.md", "AC-1 and AC-2 and AC-3 were all PASS in the end\n\nAC-1\n")
      result = run(defined: defined, covered: report, prefixes: ["AC"], line_regex: /^\|.*PASS/)
      expect(result.missing).to eq(%w[AC-1 AC-2 AC-3])
    end

    it "passes when each ID has a matching row" do
      report = write("report.md", "| AC-1 | PASS |\n| AC-2 | PASS |\n| AC3 | PASS |\n")
      expect(run(defined: defined, covered: report, prefixes: ["AC"], line_regex: /PASS/).passed).to be(true)
    end
  end

  it "reports regex_timeout when the line regex runs out of time" do
    defined = write("req.md", "R1\n")
    covered = write("cov.md", "#{"a" * 40}! R1\n")
    result = run(defined: defined, covered: covered, line_regex: Regexp.new('^(a+)+\1$', timeout: 0.05))
    expect([result.passed, result.reason, result.defined]).to eq([false, "regex_timeout", ["R1"]])
  end

  it "matches prefixes case-sensitively" do
    defined = write("req.md", "r1 lower\n")
    result = run(defined: defined, covered: defined)
    expect([result.passed, result.defined]).to eq([true, []])
  end

  it "fails a defined path that is a directory, even with allow_missing" do
    result = run(defined: dir, covered: dir, allow_missing: true)
    expect([result.passed, result.reason, result.message]).to match([false, "defined_absent", /is not a regular file/])
  end

  it "returns a frozen result" do
    defined = write("req.md", "R1\n")
    expect(run(defined: defined, covered: defined)).to be_frozen
  end
end
