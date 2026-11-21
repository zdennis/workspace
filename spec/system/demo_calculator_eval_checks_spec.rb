require "spec_helper"
require "tmpdir"
require "open3"
require "json"
require "fileutils"

load File.join(PROJECT_ROOT, "script", "demo_calculator", "eval_checks.rb")

RSpec.describe DemoCalculator::EvalChecks do
  def git(dir, *args)
    out, status = Open3.capture2e("git", "-C", dir, *args)
    raise "git #{args.join(" ")}: #{out}" unless status.success?
    out.strip
  end

  let(:tmp) { Dir.mktmpdir }
  let(:repo) { File.join(tmp, "repo") }
  let(:reference) { File.join(PROJECT_ROOT, "spec", "fixtures", "demo_calculator", "reference") }
  let(:acceptance) { File.join(PROJECT_ROOT, "demo", "calculator-acceptance") }

  after { FileUtils.rm_rf(tmp) }

  def commit(message)
    git(repo, "add", "-A")
    git(repo, "-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "-m", message)
    git(repo, "rev-parse", "HEAD")
  end

  # base holds the acceptance groups and the stub; good holds the reference.
  let!(:shas) do
    FileUtils.mkdir_p(repo)
    git(repo, "init", "-q")
    FileUtils.mkdir_p(File.join(repo, "demo"))
    FileUtils.cp_r(acceptance, File.join(repo, "demo", "calculator-acceptance"))
    FileUtils.mkdir_p(File.join(repo, "demo", "calculator"))
    File.write(File.join(repo, "demo", "calculator", "README.md"), "stub\n")
    base = commit("base")
    FileUtils.rm_rf(File.join(repo, "demo", "calculator-acceptance"))
    FileUtils.rm_rf(File.join(repo, "demo", "calculator"))
    FileUtils.cp_r(reference, File.join(repo, "demo", "calculator"))
    good = commit("good")
    mul = File.join(repo, "demo", "calculator", "lib", "calc.rb")
    File.write(mul, File.read(mul).tr("*", "+"))
    broken = commit("broken")
    {base: base, good: good, broken: broken}
  end

  let(:checks) { described_class.new(repo: repo) }

  def worktree_count
    git(repo, "worktree", "list").lines.size
  end

  it "passes groups 1..3 for the reference calculator" do
    result = checks.acceptance(base_sha: shas[:base], head: shas[:good], index: 3)
    expect(result).to eq(passed: [1, 2, 3], failed: [], regressions: [])
  end

  it "reports a regression when an earlier group fails" do
    result = checks.acceptance(base_sha: shas[:base], head: shas[:broken], index: 3)
    expect(result[:failed]).to include(2)
    expect(result[:regressions]).to include(2)
    expect(result[:regressions]).not_to include(3)
  end

  it "leaves no worktree behind, even when the run raises" do
    runner = lambda do |argv, env: {}, chdir: nil|
      raise "boom" if argv.first == "tar"
      described_class::DEFAULT_RUNNER.call(argv, env: env, chdir: chdir)
    end
    expect { described_class.new(repo: repo, runner: runner).acceptance(base_sha: shas[:base], head: shas[:good], index: 1) }
      .to raise_error("boom")
    checks.acceptance(base_sha: shas[:base], head: shas[:good], index: 1)
    expect(worktree_count).to eq(1)
  end

  describe "#lint" do
    it "counts offenses from the injected runner's JSON" do
      seen = nil
      runner = lambda do |argv, env: {}, chdir: nil|
        if argv.include?("standardrb")
          seen = [argv, env]
          [JSON.generate("summary" => {"offense_count" => 4}), false]
        else
          described_class::DEFAULT_RUNNER.call(argv, env: env, chdir: chdir)
        end
      end
      count = described_class.new(repo: repo, runner: runner).lint(head: shas[:good], gemfile: "/g/Gemfile")
      expect(count).to eq(4)
      expect(seen[0].last).to eq("demo/calculator")
      expect(seen[1]).to eq("BUNDLE_GEMFILE" => "/g/Gemfile")
      expect(worktree_count).to eq(1)
    end

    it "is nil when standardrb prints no JSON" do
      runner = lambda do |argv, env: {}, chdir: nil|
        argv.include?("standardrb") ? ["oops", false] : described_class::DEFAULT_RUNNER.call(argv, env: env, chdir: chdir)
      end
      expect(described_class.new(repo: repo, runner: runner).lint(head: shas[:good], gemfile: "g")).to be_nil
    end

    it "counts zero for a clean file with the real standardrb" do
      dir = File.join(tmp, "clean")
      FileUtils.mkdir_p(File.join(dir, "demo", "calculator"))
      File.write(File.join(dir, "demo", "calculator", "ok.rb"), "puts 1\n")
      git(repo, "worktree", "prune")
      FileUtils.cp_r(File.join(dir, "demo", "calculator", "ok.rb"), File.join(repo, "demo", "calculator", "ok.rb"))
      FileUtils.rm_f(Dir.glob(File.join(repo, "demo", "calculator", "{bin,lib}", "*")))
      head = commit("clean")
      count = checks.lint(head: head, gemfile: File.join(PROJECT_ROOT, "Gemfile"))
      expect(count).to eq(0)
    end
  end

  describe "#leak_check" do
    it "counts hook lines in the window and each transcript" do
      hook = File.join(tmp, "ws.jsonl")
      rotated = "#{hook}.1"
      line = ->(at, input) { JSON.generate("type" => "tool_started", "at" => at, "input" => input) + "\n" }
      File.write(hook, line.call("2026-01-01T10:05:00Z", "cat demo/calculator-acceptance/support.rb") + line.call("2026-01-01T12:00:00Z", "cat demo/calculator-acceptance/x") + line.call("2026-01-01T10:06:00Z", "ls"))
      File.write(rotated, line.call("2026-01-01T10:01:00Z", "ruby demo/calculator-acceptance/group_1_add_sub_test.rb"))
      transcript = File.join(tmp, "t.jsonl")
      File.write(transcript, "a calculator-acceptance b\nnothing\ncalculator-acceptance\n")
      result = checks.leak_check(hook_files: [hook, rotated], transcripts: [transcript, File.join(tmp, "missing")],
        from: "2026-01-01T10:00:00Z", to: "2026-01-01T11:00:00Z")
      expect(result).to eq(hook: 2, transcript: {transcript => 2, File.join(tmp, "missing") => nil})
    end
  end
end
