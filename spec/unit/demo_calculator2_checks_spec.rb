require "spec_helper"

load File.join(PROJECT_ROOT, "script", "demo-calculator2")

RSpec.describe DemoCalculator2::Checks do
  let(:long) { "assert_equal 42, run_calc('6 * 7').strip, 'multiplication'" }
  let(:calls) { [] }
  let(:answers) { {} }
  let(:runner) do
    lambda do |argv, **_|
      calls << argv
      key = argv.drop(3).first(2).join(" ")
      answers.fetch(key, ["", true])
    end
  end
  let(:checks) { described_class.new(repo: "/repo", runner: runner) }

  describe "#diff_scan" do
    let(:answers) do
      {"diff --name-status" => ["A\tdemo/calculator2/acceptance/new.rb\n", true],
       "ls-tree -r" => ["demo/calculator2/acceptance/group_1.rb\n", true],
       "show aaa:demo/calculator2/acceptance/group_1.rb" => ["  #{long}\n", true],
       "diff -U0" => ["+++ b/demo/calculator2/test/t.rb\n+#{long}\n", true]}
    end

    it "reports touched acceptance paths and added lines copied from the tests at the base" do
      expect(checks.diff_scan(base_sha: "aaa", head: "hhh")).to eq(paths: ["demo/calculator2/acceptance/new.rb"], copied: [long])
    end

    it "diffs from the removal commit when given one" do
      checks.diff_scan(base_sha: "aaa", head: "hhh", since: "rrr")
      expect(calls.find { |argv| argv.include?("--name-status") }).to include("rrr..hhh")
    end

    it "excludes the acceptance directory from the content diff" do
      checks.diff_scan(base_sha: "aaa", head: "hhh")
      expect(calls.find { |argv| argv.include?("-U0") }.last(2)).to eq([".", ":(exclude)demo/calculator2/acceptance"])
    end

    it "is nil when git fails" do
      answers["diff --name-status"] = ["", false]
      expect(checks.diff_scan(base_sha: "aaa", head: "hhh")).to be_nil
    end

    it "refuses a revision that looks like an option" do
      expect { checks.diff_scan(base_sha: "--output=x", head: "hhh") }.to raise_error(DemoCalculator::EvalChecks::Error)
    end
  end

  describe "#leak_check" do
    it "counts reads of the acceptance directory, not runs of the acceptance runner" do
      Dir.mktmpdir do |dir|
        hook = File.join(dir, "ws.jsonl")
        lines = ["cat demo/calculator2/acceptance/group_1_add_sub_test.rb", "ls demo/calculator2/acceptance",
          "ruby script/demo_calculator2/acceptance_runner demo/calculator2/goals/01-add-sub.md", "ls demo/calculator2/goals"]
        File.write(hook, lines.map { |c| JSON.generate("type" => "tool_started", "tool" => "Bash", "input" => c, "at" => "2026-01-01T00:00:00Z") }.join("\n") + "\n")
        expect(checks.leak_check(hook_files: [hook], transcripts: [], from: "2025-12-31T00:00:00Z")).to include(hook: 2, transcript: {})
      end
    end
  end

  describe "#leak_check possible leaks" do
    def count(*commands)
      Dir.mktmpdir do |dir|
        hook = File.join(dir, "ws.jsonl")
        File.write(hook, commands.map { |c| JSON.generate("type" => "tool_started", "tool" => "Bash", "input" => c, "at" => "2026-01-01T00:00:00Z") }.join("\n") + "\n")
        checks.leak_check(hook_files: [hook], transcripts: [], from: "2025-12-31T00:00:00Z")
      end
    end

    it "reports history commands as possible, apart from the definite reads" do
      result = count("git log -p", "git log --all --oneline", "git show HEAD~3", "git diff abc1234 -- lib", "git -C /x cat-file -p main:demo/calculator2/lib/calc.rb",
        "cd x && git archive HEAD~1", "git show HEAD~2:demo/calculator2/acceptance/group_1_add_sub_test.rb")
      expect(result).to include(hook: 1, possible: {hook: 6, transcript: {}})
    end

    it "does not report plain history or working tree commands" do
      result = count("git log --oneline", "git log -n 5", "git status", "git diff", "git diff --cached", "git show HEAD", "git show HEAD:lib/x.rb", "git diff HEAD -- lib", "ls")
      expect(result[:possible]).to eq(hook: 0, transcript: {})
    end

    it "counts a possible leak in a session transcript, sub-agent included" do
      Dir.mktmpdir do |dir|
        line = ->(cmd) { JSON.generate("message" => {"content" => [{"type" => "tool_use", "name" => "Bash", "input" => {"command" => cmd}}]}) + "\n" }
        path = File.join(dir, "s.jsonl")
        File.write(path, line.call("git log --patch"))
        FileUtils.mkdir_p(File.join(dir, "s", "subagents"))
        File.write(File.join(dir, "s", "subagents", "agent-1.jsonl"), line.call("git show 1a2b3c4d"))
        expect(checks.leak_check(hook_files: [], transcripts: [path], from: nil)[:possible]).to eq(hook: 0, transcript: {path => 2})
      end
    end
  end

  describe "#acceptance" do
    it "runs the runner with the acceptance sha as the ref and reports the item's pass" do
      expect(checks.acceptance(base_sha: "aaa", head: "hhh", goal: "03-div-zero")).to eq(passed: ["03-div-zero"], failed: [], regressions: [])
      argv = calls.find { |a| a.first == "ruby" }
      expect(argv.last).to eq("demo/calculator2/goals/03-div-zero.md")
      expect(argv).not_to include("--dag")
    end

    it "passes --dag to the runner for a lane that lacks some goals" do
      checks.acceptance(base_sha: "aaa", head: "hhh", goal: "06-json", dag: true)
      argv = calls.find { |a| a.first == "ruby" }
      expect(argv[argv.index { |part| part.end_with?("acceptance_runner") } + 1]).to eq("--dag")
    end
  end
end
