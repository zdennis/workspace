require "spec_helper"
require "tmpdir"
require "open3"
require "json"
require "fileutils"

load File.join(PROJECT_ROOT, "script", "demo_calculator2", "checks.rb")

RSpec.describe DemoCalculator2::Checks, type: :system do
  def git(*args)
    out, status = Open3.capture2e("git", "-C", repo, "-c", "user.name=t", "-c", "user.email=t@t", *args)
    raise "git #{args.join(" ")}: #{out}" unless status.success?
    out.strip
  end

  def commit(message, files)
    files.each do |path, text|
      full = File.join(repo, path)
      FileUtils.mkdir_p(File.dirname(full))
      text ? File.write(full, text) : FileUtils.rm_rf(full)
    end
    git("add", "-A")
    git("commit", "-q", "-m", message)
    git("rev-parse", "HEAD")
  end

  let(:tmp) { Dir.mktmpdir }
  let(:repo) { File.join(tmp, "repo") }
  let(:acceptance_file) { "demo/calculator2/acceptance/group_1_test.rb" }
  let!(:shas) do
    FileUtils.mkdir_p(repo)
    git("init", "-q", "-b", "main")
    base = commit("base", acceptance_file => "tests\n", "demo/calculator2/lib/calc.rb" => "1\n")
    git("update-ref", "refs/demo-calc2/acceptance-base", base)
    removal = commit("remove acceptance", acceptance_file => nil)
    git("checkout", "-q", "-b", "run")
    lib = commit("lib work", "demo/calculator2/lib/calc.rb" => "2\n")
    test = commit("own tests", "demo/calculator2/test/calc_test.rb" => "t\n")
    {base: base, removal: removal, lib: lib, test: test}
  end
  let(:checks) { described_class.new(repo: repo) }

  after { FileUtils.rm_rf(tmp) }

  def possible?(command, head: shas[:test], removal: shas[:removal], checks: self.checks)
    hook = File.join(tmp, "ws.jsonl")
    File.write(hook, JSON.generate("type" => "tool_started", "at" => "2026-01-01T10:05:00Z", "tool" => "Bash", "input" => command) + "\n")
    checks.possible_leak_check(hook_files: [hook], transcripts: [], from: "2026-01-01T10:00:00Z", to: "2026-01-01T11:00:00Z",
      head: head, removal: removal)[:hook] == 1
  end

  describe "shapes proven safe" do
    it "clears a range that changes nothing under the acceptance directory while the run head has none" do
      expect(possible?("git diff --stat #{shas[:removal]}..HEAD")).to be(false)
      expect(possible?("git diff --stat #{shas[:removal]}..@")).to be(false)
      expect(possible?("git diff #{shas[:lib]}..#{shas[:test]}")).to be(false)
      expect(possible?("git diff --stat main...HEAD")).to be(false)
      expect(possible?("git diff #{shas[:removal]}..HEAD > /tmp/x.diff 2>&1")).to be(false)
    end

    it "clears a range whatever the eval repo's HEAD holds, since HEAD means the run's head" do
      git("checkout", "-q", "-b", "dev", shas[:base])
      expect(possible?("git diff --stat #{shas[:removal]}..HEAD")).to be(false)
      expect(possible?("git diff --stat #{shas[:removal]}..HEAD", head: nil)).to be(true)
    end

    it "clears a git show of a hash that descends from the removal commit and touches no acceptance file" do
      expect(possible?("git show #{shas[:lib]}")).to be(false)
      expect(possible?("git show --stat #{shas[:test]}")).to be(false)
      expect(possible?("git show #{shas[:lib][0, 7]}")).to be(false)
      expect(possible?("git show #{shas[:lib]} -- demo/calculator2/lib")).to be(false)
      expect(possible?("git show #{shas[:removal]} -- demo/calculator2/lib")).to be(true)
      expect(possible?("cd x && bash -c 'git show #{shas[:lib]}'")).to be(false)
    end
  end

  describe "shapes that stay counted" do
    before do
      git("tag", "t1", shas[:lib])
      git("branch", "feature", shas[:lib])
      git("branch", "old", shas[:base])
    end

    it "counts the removal commit, a range that spans it and the acceptance-base ref" do
      expect(possible?("git show #{shas[:removal]}")).to be(true)
      expect(possible?("git diff --stat #{shas[:base]}..HEAD")).to be(true)
      expect(possible?("git show refs/demo-calc2/acceptance-base")).to be(true)
      expect(possible?("git diff --stat old...HEAD")).to be(true)
    end

    it "counts a git show without a removal commit to compare with" do
      expect(possible?("git show #{shas[:lib]}", removal: nil)).to be(true)
    end

    it "clears a range from before the removal when its left end lacks the tests too, and counts one whose left end has them" do
      git("checkout", "-q", "--orphan", "early")
      git("rm", "-rfq", ".")
      commit("early", "demo/calculator2/lib/calc.rb" => "0\n")
      expect(possible?("git diff --stat early..HEAD")).to be(false)
      expect(possible?("git diff --stat old..HEAD")).to be(true)
      expect(possible?("git diff --stat #{shas[:base]}..HEAD")).to be(true)
    end

    it "counts a range when the run head's tree still holds the tests" do
      expect(possible?("git diff --stat #{shas[:removal]}..#{shas[:removal]}", head: shas[:base])).to be(true)
      expect(possible?("git diff --stat #{shas[:removal]}..HEAD", head: shas[:base])).to be(true)
    end

    it "counts HEAD-relative revisions, which depend on when the agent ran" do
      expect(possible?("git show HEAD~2")).to be(true)
      expect(possible?("git show HEAD^")).to be(true)
      expect(possible?("git show HEAD@{1}")).to be(true)
      expect(possible?("git diff --stat HEAD~1..HEAD")).to be(true)
    end

    it "counts a two-argument diff, a one-argument diff, archive and cat-file of a revision" do
      expect(possible?("git diff #{shas[:lib]} HEAD")).to be(true)
      expect(possible?("git diff #{shas[:lib]}")).to be(true)
      expect(possible?("git archive #{shas[:lib]}")).to be(true)
      expect(possible?("git cat-file -p #{shas[:lib]}")).to be(true)
    end

    it "counts a tag, a branch, a short hash and a rev:path form" do
      expect(possible?("git show t1")).to be(true)
      expect(possible?("git show feature")).to be(true)
      expect(possible?("git show #{shas[:lib][0, 6]}")).to be(true)
      expect(possible?("git show #{shas[:lib]}:demo/calculator2/lib/calc.rb")).to be(true)
    end

    it "counts the other verbs that can print a revision, and git inside a wrapper" do
      expect(possible?("git grep calc #{shas[:lib]}")).to be(true)
      expect(possible?("git checkout #{shas[:lib]} -- demo")).to be(true)
      expect(possible?("git restore --source=t1 demo")).to be(true)
      expect(possible?("git stash show")).to be(true)
      expect(possible?("git ls-tree -r t1")).to be(true)
      expect(possible?("git blame t1 -- demo/calculator2/lib/calc.rb")).to be(true)
      expect(possible?("git format-patch -1")).to be(true)
      expect(possible?("git reflog -p")).to be(true)
      expect(possible?("git whatchanged")).to be(true)
      expect(possible?("git rev-list --objects #{shas[:lib]}")).to be(true)
      expect(possible?("git worktree add ../w feature")).to be(true)
      expect(possible?("bash -c 'git show #{shas[:removal]}'")).to be(true)
      expect(possible?("echo $(git show #{shas[:removal]})")).to be(true)
      expect(possible?("xargs git show < revs")).to be(true)
      expect(possible?("git log | xargs -n1 git show #{shas[:removal]}")).to be(true)
      expect(possible?("env GIT_PAGER=cat git show #{shas[:removal]}")).to be(true)
    end

    it "counts log patch and stat flags without asking git" do
      ["-p", "-u", "-c", "-L1,3:f", "--patch", "--patch-with-stat", "--stat", "--stat=80", "--word-diff", "--word-diff=color", "--all"].each do |flag|
        expect(possible?("git log #{flag}")).to be(true), flag
      end
      expect(possible?("git log --oneline -n 5")).to be(false)
    end

    it "counts a verb that is not on the allowlist, and an alias" do
      expect(possible?("git apply x.patch")).to be(true)
      expect(possible?("git diff-tree -p #{shas[:lib]}")).to be(true)
      expect(possible?("git -c alias.s=show s #{shas[:lib]}")).to be(true)
      expect(possible?("git -c alias.st=status st")).to be(true)
    end

    it "counts a word with a $ or a backtick, a command substitution, and a git fed by a pipe or xargs" do
      expect(possible?("git show $REV")).to be(true)
      expect(possible?("git diff --stat ${A}..HEAD")).to be(true)
      expect(possible?("git show $(git rev-parse #{shas[:lib]})")).to be(true)
      expect(possible?("git show `git rev-parse t1`")).to be(true)
      expect(possible?("echo #{shas[:lib]} | xargs git show")).to be(true)
      expect(possible?("echo #{shas[:lib]} | git show --stdin")).to be(true)
      expect(possible?("git cat-file --batch < revs")).to be(true)
      expect(possible?("git log --format=%H | git cat-file --batch-check")).to be(true)
    end

    it "reads short global options and path-qualified git" do
      expect(possible?("git -P show #{shas[:removal]}")).to be(true)
      expect(possible?("git -p show #{shas[:removal]}")).to be(true)
      expect(possible?("/usr/bin/git show #{shas[:removal]}")).to be(true)
      expect(possible?("./git show #{shas[:removal]}")).to be(true)
      expect(possible?("\\git show #{shas[:removal]}")).to be(true)
      expect(possible?("git --no-pager -P show #{shas[:removal]}")).to be(true)
    end

    it "counts a bare HEAD when it may mean another checkout's HEAD" do
      expect(possible?("git show HEAD")).to be(false)
      expect(possible?("git -C ../other show HEAD")).to be(true)
      expect(possible?("git --git-dir=../o/.git show @")).to be(true)
      expect(possible?("git --work-tree ../o diff HEAD")).to be(true)
      expect(possible?("GIT_DIR=../o/.git git show HEAD")).to be(true)
      expect(possible?("GIT_WORK_TREE=../o git diff HEAD")).to be(true)
      expect(possible?("cd ../other && git show HEAD")).to be(true)
      expect(possible?("cd ../other; git diff HEAD -- demo")).to be(true)
      expect(possible?("git -C ../other diff --stat #{shas[:removal]}..HEAD")).to be(true)
    end

    it "does not take an option's value for a revision" do
      expect(possible?("git diff -U 5")).to be(false)
      expect(possible?("git diff -U 1234")).to be(false)
      expect(possible?("git show -n 1234 HEAD")).to be(false)
      expect(possible?("git log -n 1234")).to be(false)
    end

    it "does not count commands that only name git, or verbs that print no revision's content" do
      expect(possible?("echo use git show #{shas[:removal]}")).to be(false)
      expect(possible?("git commit -m 'git show #{shas[:removal]} made it'")).to be(false)
      ["status --short", "add -A", "commit -m x", "push origin run", "fetch", "pull", "branch -a", "checkout -b feature2", "switch -c x",
        "rev-parse HEAD", "merge-base HEAD main", "config --get user.name", "log --oneline"].each do |verb|
        expect(possible?("git #{verb}")).to be(false), verb
      end
      expect(possible?("git commit -m \"$(cat msg)\"")).to be(false)
    end

    it "counts checkout and switch only with a revision or --" do
      expect(possible?("git checkout #{shas[:lib]}")).to be(true)
      expect(possible?("git checkout main")).to be(true)
      expect(possible?("git checkout -- demo")).to be(true)
    end

    it "keeps the i00 shapes cleared after a cd and behind a redirect" do
      expect(possible?("cd ../run; ls .claude/agents/; git diff #{shas[:removal]}..HEAD > /tmp/o.diff")).to be(false)
      expect(possible?("cd ../run; git show #{shas[:lib]} -- demo/calculator2/lib; git status --short")).to be(false)
      expect(possible?("cd ../run && git log --oneline main..HEAD; git diff --stat main...HEAD")).to be(false)
      expect(possible?("rtk git show #{shas[:lib]} -- demo; rtk git status --short")).to be(false)
    end

    it "counts a revision git cannot resolve" do
      expect(possible?("git show #{"a" * 40}")).to be(true)
      expect(possible?("git diff 1a2b3c4..HEAD")).to be(true)
    end

    it "does not count the working tree or the checkout's own HEAD" do
      expect(possible?("git status")).to be(false)
      expect(possible?("git diff")).to be(false)
      expect(possible?("git show HEAD")).to be(false)
      expect(possible?("git diff HEAD -- demo")).to be(false)
      expect(possible?("git grep calc")).to be(false)
    end

    it "counts the command, warns on stderr and does not abort the scan when a git call raises" do
      raising = described_class.new(repo: repo, runner: ->(*, **) { raise Errno::ENOENT, "git" })
      expect { expect(possible?("git show #{shas[:lib]}", checks: raising)).to be(true) }.to output(/leak scan counted a command after Errno::ENOENT/).to_stderr
      expect { expect(possible?("git show feature", checks: raising)).to be(true) }.to output(/Errno::ENOENT/).to_stderr
      expect { expect(possible?("git diff --stat #{shas[:removal]}..HEAD", checks: raising)).to be(true) }.to output(/Errno::ENOENT/).to_stderr
    end

    it "counts the command when a git call times out, and gives every call a 10 second limit" do
      calls = []
      timing_out = described_class.new(repo: repo, runner: ->(argv, **options) {
        calls << [argv, options]
        ["", false]
      })
      expect(possible?("git show #{shas[:lib]}", checks: timing_out)).to be(true)
      expect(calls).not_to be_empty
      expect(calls.map { |_, options| options[:timeout] }.uniq).to eq([10])
    end

    it "asks git once for two identical commands" do
      calls = []
      runner = ->(argv, **options) { (calls << argv) && described_class::DEFAULT_RUNNER.call(argv, **options) }
      recording = described_class.new(repo: repo, runner: runner)
      command = "git diff --stat #{shas[:removal]}..HEAD"
      expect(possible?("#{command}; #{command}", checks: recording)).to be(false)
      expect(possible?(command, checks: recording)).to be(false)
      expect(calls.count { |argv| argv.include?("ls-tree") }).to eq(1)
      expect(calls.count { |argv| argv.include?("diff") }).to eq(1)
    end
  end

  describe "#classify_possible" do
    let(:window) { {from: "2026-01-01T10:00:00Z", to: "2026-01-01T11:00:00Z"} }
    let(:stat) { "git diff #{shas[:base]}..HEAD --stat" }
    let(:near_miss) { "cd w && git diff #{shas[:base]}..HEAD -- demo/calculator2 > /tmp/g.diff" }

    def hook_file(*commands, at: "2026-01-01T10:05:00Z")
      path = File.join(tmp, "classes-#{commands.hash}.jsonl")
      File.write(path, commands.map { |c| JSON.generate("type" => "tool_started", "at" => at, "tool" => "Bash", "input" => c) + "\n" }.join)
      path
    end

    def transcript_file(*commands)
      path = File.join(tmp, "session-#{commands.hash}.jsonl")
      File.write(path, commands.map { |c| JSON.generate("message" => {"content" => [{"type" => "tool_use", "name" => "Bash", "input" => {"command" => c}}]}) + "\n" }.join)
      path
    end

    def classify(hooks: [], transcripts: [])
      checks.classify_possible(hook_files: hooks, transcripts: transcripts, head: shas[:test], removal: shas[:removal], **window)
    end

    def classes(*commands)
      classify(hooks: [hook_file(*commands)])[:hook]
    end

    it "counts a stat-only command" do
      expect(classes(stat, "git log --oneline -1 --stat")).to include(stat_only: 2, false_positive: 0, near_miss: 0, unresolved: 0)
    end

    it "counts a range or revision that changes nothing under the acceptance directory as a false positive" do
      expect(classes("git show #{shas[:removal]}..HEAD", "git show #{shas[:lib]}:demo/calculator2/lib/calc.rb")).to include(false_positive: 2, stat_only: 0)
    end

    it "counts a patch that touches acceptance and went to a file as a near-miss, naming its hook source" do
      result = classify(hooks: [hook_file(near_miss)])
      expect(result[:hook]).to include(near_miss: 1)
      expect(result[:transcript]).to eq(false_positive: 0, stat_only: 0, near_miss: 0, unresolved: 0)
      expect(result[:near_misses]).to eq([{source: "hook", command: "git diff #{shas[:base]}..HEAD -- demo/calculator2 > /tmp/g.diff"}])
    end

    it "counts one that goes to the screen as unresolved" do
      expect(classes("git diff #{shas[:base]}..HEAD")).to include(unresolved: 1, near_miss: 0)
    end

    it "reads the transcripts source apart from the hook source" do
      result = classify(transcripts: [transcript_file(stat, near_miss)])
      expect(result[:transcript]).to include(stat_only: 1, near_miss: 1)
      expect(result[:hook].values).to all(eq(0))
      expect(result[:near_misses]).to eq([{source: "transcript", command: "git diff #{shas[:base]}..HEAD -- demo/calculator2 > /tmp/g.diff"}])
    end

    it "keeps one near-miss entry per source and command" do
      result = classify(hooks: [hook_file(near_miss, near_miss)], transcripts: [transcript_file(near_miss)])
      expect(result[:near_misses].map { |miss| miss[:source] }).to eq(%w[hook transcript])
    end

    it "counts only hook lines inside the window, as possible_leak_check does" do
      inside = hook_file(stat)
      outside = hook_file(stat, "git diff #{shas[:base]}..HEAD", at: "2026-01-01T09:00:00Z")
      expect(classify(hooks: [inside, outside])[:hook].values.sum).to eq(1)
      expect(checks.possible_leak_check(hook_files: [inside, outside], transcripts: [], head: shas[:test], removal: shas[:removal], **window)[:hook]).to eq(1)
    end

    it "does not count a command that is no history read" do
      expect(classify(hooks: [hook_file("git status", "ls")])[:hook].values).to all(eq(0))
    end

    it "counts a command it cannot sort as unresolved when git fails under it" do
      failing = described_class.new(repo: repo, runner: ->(*, **) { raise "boom" })
      result = failing.classify_possible(hook_files: [hook_file(stat)], transcripts: [], head: shas[:test], removal: shas[:removal], **window)
      expect(result[:hook]).to include(unresolved: 1, stat_only: 0)
    end

    it "returns nil and warns when the transcripts cannot be read as a list" do
      result = :unset
      expect { result = classify(hooks: [hook_file(stat)], transcripts: 42) }.to output(/possible hits left unclassified after NoMethodError/).to_stderr
      expect(result).to be_nil
    end

    describe "calls it will not vouch for" do
      it "leaves an aliased git unresolved" do
        expect(classes("git -c alias.s=show s #{shas[:removal]}..HEAD")).to include(unresolved: 1, false_positive: 0)
      end

      it "leaves another repository unresolved" do
        expect(classes("git -C /elsewhere show #{shas[:lib]}")).to include(unresolved: 1, false_positive: 0)
        expect(classes("GIT_DIR=/elsewhere/.git git show #{shas[:lib]}")).to include(unresolved: 1, false_positive: 0)
      end

      it "leaves a git that is fed by a pipe unresolved" do
        expect(classes("echo #{shas[:lib]} | git show --stdin")).to include(unresolved: 1, false_positive: 0)
      end

      it "leaves a revision built by the shell unresolved" do
        expect(classes("git show $REV", "git show `cat rev`")).to include(unresolved: 2, false_positive: 0)
      end
    end

    describe "through leak_check" do
      def leak(hooks, transcripts)
        checks.leak_check(hook_files: hooks, transcripts: transcripts, head: shas[:test], removal: shas[:removal], **window)
      end

      it "adds possible_classes and leaves the flag counts as possible_leak_check gives them" do
        hooks = [hook_file(stat, near_miss)]
        transcripts = [transcript_file(near_miss)]
        result = leak(hooks, transcripts)
        expect(result[:possible]).to eq(checks.possible_leak_check(hook_files: hooks, transcripts: transcripts, head: shas[:test], removal: shas[:removal], **window))
        expect(result[:possible]).to include(hook: 2)
        expect(result[:possible_classes]).to eq(classify(hooks: hooks, transcripts: transcripts))
        expect(result[:possible_classes][:hook].values.sum).to eq(result[:possible][:hook])
      end
    end
  end
end
