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

  it "counts a group as failed when it is missing at the base" do
    result = checks.acceptance(base_sha: shas[:base], head: shas[:good], index: 8)
    expect(result[:passed]).to eq((1..7).to_a)
    expect(result[:failed]).to eq([8])
  end

  it "kills a group that outlives the timeout and counts it as failed" do
    calc = File.join(repo, "demo", "calculator", "lib", "calc.rb")
    File.write(calc, "sleep 30\n" + File.read(calc))
    hanging = commit("hanging")
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    result = described_class.new(repo: repo, group_timeout: 2).acceptance(base_sha: shas[:base], head: hanging, index: 1)
    expect(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).to be < 20
    expect(result).to eq(passed: [], failed: [1], regressions: [])
    expect(worktree_count).to eq(1)
  end

  it "leaves no worktree behind, even when the run raises" do
    runner = lambda do |argv, env: {}, chdir: nil, timeout: nil|
      raise "boom" if argv.first == "tar"
      described_class::DEFAULT_RUNNER.call(argv, env: env, chdir: chdir)
    end
    expect { described_class.new(repo: repo, runner: runner).acceptance(base_sha: shas[:base], head: shas[:good], index: 1) }
      .to raise_error("boom")
    checks.acceptance(base_sha: shas[:base], head: shas[:good], index: 1)
    expect(worktree_count).to eq(1)
  end

  it "raises an Error naming the sha when the base has no acceptance directory" do
    expect { checks.acceptance(base_sha: "0" * 40, head: shas[:good], index: 1) }
      .to raise_error(described_class::Error, /#{"0" * 40}/)
    expect(worktree_count).to eq(1)
  end

  it "raises an Error when the worktree cannot be added" do
    expect { checks.acceptance(base_sha: shas[:base], head: "0" * 40, index: 1) }
      .to raise_error(described_class::Error, /worktree add failed/)
  end

  it "refuses a head or base_sha that starts with a dash" do
    expect { checks.acceptance(base_sha: shas[:base], head: "--force", index: 1) }
      .to raise_error(described_class::Error, /refusing/)
    expect { checks.acceptance(base_sha: "-x", head: shas[:good], index: 1) }
      .to raise_error(described_class::Error, /refusing/)
    expect { checks.lint(head: "--force", gemfile: "g") }.to raise_error(described_class::Error, /refusing/)
    expect(worktree_count).to eq(1)
  end

  describe "#lint" do
    it "counts offenses from the injected runner's JSON" do
      seen = nil
      runner = lambda do |argv, env: {}, chdir: nil, timeout: nil|
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
      runner = lambda do |argv, env: {}, chdir: nil, timeout: nil|
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
    def use(name, input)
      JSON.generate("type" => "assistant", "message" => {"content" => [{"type" => "tool_use", "name" => name, "input" => input}]}) + "\n"
    end

    it "counts reads of acceptance content in the window and in each transcript, not mentions" do
      hook = File.join(tmp, "ws.jsonl")
      rotated = "#{hook}.1"
      line = ->(at, input, tool = "Bash") { JSON.generate("type" => "tool_started", "at" => at, "tool" => tool, "input" => input) + "\n" }
      File.write(hook, line.call("2026-01-01T10:05:00Z", "cat demo/calculator-acceptance/support.rb") + line.call("2026-01-01T12:00:00Z", "cat demo/calculator-acceptance/x") + line.call("2026-01-01T10:06:00Z", "ls"))
      File.write(rotated, line.call("2026-01-01T10:01:00Z", "git log --stat -- demo/calculator-acceptance") +
        line.call("2026-01-01T10:02:00Z", "/w/demo/calculator-acceptance/group_1_add_sub_test.rb", "Read"))
      transcript = File.join(tmp, "t.jsonl")
      File.write(transcript, use("Bash", "command" => "cat demo/calculator-acceptance/group_1_add_sub_test.rb") +
        use("Bash", "command" => "git log --stat | grep calculator-acceptance") +
        use("Read", "file_path" => "/w/demo/calculator-acceptance/support.rb") +
        use("Bash", "command" => "git show abc:demo/calculator-acceptance/group_2_mul_div_test.rb") +
        JSON.generate("type" => "user", "message" => {"content" => [{"type" => "tool_result", "content" => "calculator-acceptance"}]}) + "\n")
      result = checks.leak_check(hook_files: [hook, rotated], transcripts: [transcript, File.join(tmp, "missing")],
        from: "2026-01-01T10:00:00Z", to: "2026-01-01T11:00:00Z")
      expect(result).to eq(hook: 2, transcript: {transcript => 3, File.join(tmp, "missing") => nil})
    end

    it "does not count a listing, a run of the groups, an echo or a line that is not JSON" do
      transcript = File.join(tmp, "t.jsonl")
      File.write(transcript, use("Bash", "command" => "ruby demo/calculator-acceptance/group_1_add_sub_test.rb") +
        use("Bash", "command" => "ls demo/calculator-acceptance") + use("Bash", "command" => "echo calculator-acceptance > notes") +
        "not json calculator-acceptance\n")
      expect(checks.leak_check(hook_files: [], transcripts: [transcript], from: nil)[:transcript]).to eq(transcript => 0)
    end

    it "counts hook lines at or after from when the window is open" do
      hook = File.join(tmp, "ws.jsonl")
      line = ->(at) { JSON.generate("at" => at, "tool" => "Bash", "input" => "cat demo/calculator-acceptance/x") + "\n" }
      File.write(hook, line.call("2026-01-01T09:00:00Z") + line.call("2026-01-01T10:30:00Z") + line.call("2030-01-01T00:00:00Z"))
      result = checks.leak_check(hook_files: [hook], transcripts: [], from: "2026-01-01T10:00:00Z", to: nil)
      expect(result).to eq(hook: 2, transcript: {})
    end

    it "ignores matching lines outside the window" do
      hook = File.join(tmp, "ws.jsonl")
      line = ->(at) { JSON.generate("at" => at, "tool" => "Bash", "input" => "cat demo/calculator-acceptance/x") + "\n" }
      File.write(hook, line.call("2026-01-01T09:59:59Z") + line.call("2026-01-01T11:00:01Z") + "not json calculator-acceptance\n")
      result = checks.leak_check(hook_files: [hook], transcripts: [], from: "2026-01-01T10:00:00Z", to: "2026-01-01T11:00:00Z")
      expect(result[:hook]).to eq(0)
    end
  end
end
