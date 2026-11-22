require "spec_helper"
require "tmpdir"
require "open3"
require "json"
require "stringio"

load File.join(PROJECT_ROOT, "script", "demo-calculator2")

RSpec.describe "script/demo-calculator2" do
  def git(dir, *args)
    out, status = Open3.capture2e("git", "-C", dir, *args)
    raise "git #{args.join(" ")}: #{out}" unless status.success?
    out
  end

  let(:tmp) { Dir.mktmpdir }
  let(:main_dir) { File.join(tmp, "main") }
  let(:work_dir) { File.join(tmp, "work") }
  let(:log) { File.join(tmp, "calls.log") }
  let(:fake_workspace) do
    path = File.join(tmp, "fake-workspace")
    File.write(path, <<~SH)
      #!/bin/sh
      echo "$@" >> #{log}
      if [ "$1 $2" = "work-queue list" ]; then echo '{"queues":[]}'; fi
      if [ "$1 $2" = "work-queue add" ]; then echo '{"results":[{"id":"item-'"$(echo "$@" | sed 's/.*calculator2-demo:\\([0-9]*\\).*/\\1/')"'","outcome":"added"}]}'; fi
      if [ "$1" = "capabilities" ]; then echo '{"version":"9.9.9","features":{"work_queue":2},"paths":{}}'; fi
    SH
    File.chmod(0o755, path)
    path
  end
  let(:out) { StringIO.new }
  let(:err) { StringIO.new }
  let(:clock) { -> { Time.utc(2026, 11, 21, 4, 5, 6) } }
  let(:config) { DemoCalculator2.config }

  before do
    FileUtils.mkdir_p(main_dir)
    git(main_dir, "init", "-q", "-b", "main")
    git(main_dir, "config", "user.email", "t@example.com")
    git(main_dir, "config", "user.name", "T")
    FileUtils.cp_r(File.join(PROJECT_ROOT, "demo"), main_dir)
    git(main_dir, "add", "--all")
    git(main_dir, "commit", "-q", "-m", "demo")
    git(main_dir, "worktree", "add", "-q", "-b", "demo-branch", work_dir)
  end

  after { FileUtils.rm_rf(tmp) }

  def demo(**options)
    DemoCalculator::Demo.new(root: work_dir, workspace: fake_workspace, name: "ws", out: out, err: err, clock: clock, config: config, **options)
  end

  describe "run" do
    it "points the acceptance ref at the run's base, which stays an ancestor of the run branch" do
      base = git(work_dir, "rev-parse", "HEAD").strip
      demo.run
      expect(git(work_dir, "rev-parse", "refs/demo-calc2/acceptance-base").strip).to eq(base)
      git(work_dir, "merge-base", "--is-ancestor", base, "HEAD")
      expect(git(work_dir, "ls-tree", "-r", "--name-only", "refs/demo-calc2/acceptance-base", "demo/calculator2/acceptance")).to include("group_1_add_sub_test.rb")
    end

    it "removes the acceptance tests and README on the run branch, as its first commit" do
      demo.run
      expect(git(work_dir, "rev-parse", "--abbrev-ref", "HEAD").strip).to eq("calc-demo/20261121T040506Z")
      expect(File.exist?(File.join(work_dir, "demo/calculator2/acceptance"))).to be(false)
      expect(File.exist?(File.join(work_dir, "demo/calculator2/README.md"))).to be(false)
      expect(git(work_dir, "log", "--format=%s", "-1")).to eq("Remove the acceptance tests from the run branch\n")
    end

    it "installs the workflow source, sets the test and lint commands and queues the seven goals in order" do
      demo.run
      calls = File.read(log).lines.map(&:strip)
      expect(calls.grep(/\Aconfig set workflows.sources /).first).to end_with("/demo/calculator2/workflows")
      expect(calls).to include("workflow install",
        "config set --scope workspace --name ws commands.test ruby demo/calculator2/test/calc_test.rb",
        "config set --scope workspace --name ws commands.lint bundle exec standardrb demo/calculator2")
      adds = calls.grep(/\Awork-queue add workflow deliver-goal /)
      expect(adds.map { |line| line[%r{goals/(0\d-[a-z-]+)\.md}, 1] }).to eq(DemoCalculator2::GOALS)
      expect(adds.first).to include("--input acceptance=script/demo_calculator2/acceptance_runner", "--input goal=demo/calculator2/goals/01-add-sub.md")
      expect(calls.last(2)).to eq(["work-queue enable --name ws", "work-queue advance --name ws"])
    end

    it "writes run.json with the acceptance ref and one deliver-goal item per goal" do
      base = git(work_dir, "rev-parse", "HEAD").strip
      record = demo.run
      path = File.join(work_dir, "tmp/demo-calculator2/runs/20261121T040506Z/run.json")
      expect(JSON.parse(File.read(path))).to eq(record)
      expect(record["acceptance_ref"]).to eq("name" => "refs/demo-calc2/acceptance-base", "sha" => base, "removal_sha" => git(work_dir, "rev-parse", "HEAD").strip)
      expect(git(work_dir, "log", "--format=%s", "-1", record["acceptance_ref"]["removal_sha"])).to eq("Remove the acceptance tests from the run branch\n")
      expect(record["items"].map { |item| item["workflow"] }.uniq).to eq(["deliver-goal"])
      expect(record["items"].size).to eq(7)
    end

    it "queues only the chosen goals and records them and the stub ref in run.json" do
      picked = DemoCalculator2.config(stub_ref: "demo-branch", goals: DemoCalculator2.pick_goals("01"))
      record = DemoCalculator::Demo.new(root: work_dir, workspace: fake_workspace, name: "ws", out: out, err: err, clock: clock, config: picked).run
      expect(record["items"].size).to eq(1)
      expect(record).to include("stub_ref" => "demo-branch", "goals" => ["01-add-sub"])
      expect(File.read(log).scan("work-queue add").size).to eq(1)
    end

    it "changes nothing under --dry-run but says what it would do" do
      demo(dry_run: true).run
      expect(File.exist?(log)).to be(false)
      expect(git(work_dir, "rev-parse", "--abbrev-ref", "HEAD").strip).to eq("demo-branch")
      expect(git(work_dir, "for-each-ref", "refs/demo-calc2/")).to eq("")
      expect(out.string).to include("+ git update-ref refs/demo-calc2/acceptance-base", "+ workspace config set --scope workspace --name ws commands.test ruby demo/calculator2/test/calc_test.rb")
    end
  end

  describe "preflight and ordering" do
    let(:config) { DemoCalculator2.config.dup.tap { |c| c.stub_ref = stub_ref } }
    let(:stub_ref) { "no-such-stub" }

    it "refuses run before switching branch, moving the ref or touching the queue when the stub ref is missing" do
      expect { demo.run }.to raise_error(DemoCalculator::Refused, /no-such-stub does not name a commit/)
      expect(git(work_dir, "rev-parse", "--abbrev-ref", "HEAD").strip).to eq("demo-branch")
      expect(git(work_dir, "for-each-ref", "refs/demo-calc2/")).to eq("")
      expect(File.exist?(log)).to be(false)
    end

    it "refuses reset the same way, leaving the files and queue alone" do
      File.write(File.join(work_dir, "demo/calculator2/lib/calc.rb"), "# changed\n")
      expect { demo.reset }.to raise_error(DemoCalculator::Refused, /no-such-stub/)
      expect(File.read(File.join(work_dir, "demo/calculator2/lib/calc.rb"))).to eq("# changed\n")
      expect(File.exist?(log)).to be(false)
    end

    it "refuses when the stub ref lacks a stub path" do
      git(main_dir, "branch", "bare", "main")
      git(main_dir, "worktree", "add", "-q", File.join(tmp, "bare"), "bare")
      git(File.join(tmp, "bare"), "rm", "-r", "-q", "demo/calculator2/lib")
      git(File.join(tmp, "bare"), "-c", "user.email=t@e.c", "-c", "user.name=T", "commit", "-q", "-m", "drop lib")
      config.stub_ref = "bare"
      expect { demo.reset }.to raise_error(DemoCalculator::Refused, %r{bare has no demo/calculator2/lib})
    end

    context "with the real stub ref" do
      let(:stub_ref) { "main" }

      it "reads the queue only after it has switched to the run branch" do
        seen = File.join(tmp, "branch-at-list.log")
        File.write(fake_workspace, File.read(fake_workspace).sub("echo \"$@\" >> #{log}", "echo \"$@\" >> #{log}\nif [ \"$1 $2\" = \"work-queue list\" ]; then git -C #{work_dir} rev-parse --abbrev-ref HEAD >> #{seen}; fi"))
        demo.run
        expect(File.read(seen).lines.map(&:strip).uniq).to eq(["calc-demo/20261121T040506Z"])
      end

      it "clears the queue only after it has switched to the run branch" do
        seen = File.join(tmp, "branch-at-clear.log")
        File.write(fake_workspace, File.read(fake_workspace).sub("echo \"$@\" >> #{log}", "echo \"$@\" >> #{log}\nif [ \"$1 $2\" = \"work-queue disable\" ]; then git -C #{work_dir} rev-parse --abbrev-ref HEAD >> #{seen}; fi"))
        demo.run
        expect(File.exist?(seen)).to be(true)
        expect(File.read(seen).lines.map(&:strip).uniq).to eq(["calc-demo/20261121T040506Z"])
      end
    end
  end

  describe "run --wait" do
    def paused_workspace
      File.write(fake_workspace, <<~SH)
        #!/bin/sh
        echo "$@" >> #{log}
        case "$1 $2 $3" in
          "work-queue list --json"*) echo '{"queues":[{"workspace":"ws","state":"paused","items":[{"id":"i2","state":"queued"}]}]}' ;;
          "work-queue history list") echo '{"entries":[{"id":"i1","outcome":"completed"},{"id":"i0","outcome":"failed"}]}' ;;
        esac
        case "$1 $2" in
          "work-queue add") echo '{"results":[{"id":"x"}]}' ;;
          "capabilities --json") echo '{"version":"9","features":{"work_queue":2},"paths":{}}' ;;
        esac
        exit 0
      SH
    end

    it "records the failed item from the history when the queue pauses, and exits 3 with the reason" do
      paused_workspace
      record = demo(wait: true, sleeper: ->(_) {}).run
      expect(record["wait"]).to include("reason" => "paused", "failed_item" => "i0")
      expect(JSON.parse(File.read(File.join(work_dir, "tmp/demo-calculator2/runs/20261121T040506Z/run.json")))["wait"]["failed_item"]).to eq("i0")
      expect(DemoCalculator2.wait_exit(record, err)).to eq(3)
      expect(err.string).to include("did not drain: paused", "failed item i0")
    end

    it "exits 0 only when the queue drained, or when nothing was waited for" do
      expect(DemoCalculator2.wait_exit({"wait" => {"reason" => "empty"}}, err)).to eq(0)
      expect(DemoCalculator2.wait_exit({"wait" => nil}, err)).to eq(0)
      expect(DemoCalculator2.wait_exit(nil, err)).to eq(0)
      %w[held timeout advance_failed disabled].each { |reason| expect(DemoCalculator2.wait_exit({"wait" => {"reason" => reason}}, err)).to eq(3) }
    end
  end

  describe "reset" do
    it "restores the stub from main and commits it" do
      File.write(File.join(work_dir, "demo/calculator2/lib/calc.rb"), "# changed\n")
      FileUtils.touch(File.join(work_dir, "demo/calculator2/lib/extra.rb"))
      demo.reset
      expect(git(work_dir, "status", "--porcelain")).to eq("")
      expect(File.read(File.join(work_dir, "demo/calculator2/lib/calc.rb"))).to eq(git(main_dir, "show", "main:demo/calculator2/lib/calc.rb"))
      expect(File.exist?(File.join(work_dir, "demo/calculator2/lib/extra.rb"))).to be(false)
    end

    it "changes nothing under --dry-run" do
      File.write(File.join(work_dir, "demo/calculator2/lib/calc.rb"), "# changed\n")
      demo(dry_run: true).reset
      expect(File.read(File.join(work_dir, "demo/calculator2/lib/calc.rb"))).to eq("# changed\n")
    end
  end

  describe "main" do
    it "prints help and exits 1 for an unknown verb" do
      expect(DemoCalculator2.main(%w[bogus], out: out, err: err, root: work_dir)).to eq(1)
      expect(err.string).to include("reset|run|eval")
    end

    it "refuses to run in the main checkout" do
      expect(DemoCalculator2.main(%w[reset --dry-run], out: out, err: err, root: main_dir)).to eq(1)
      expect(err.string).to include("demo-calculator2: refusing")
    end

    it "says plainly when eval has no run record" do
      expect(DemoCalculator2.main(%w[eval], out: out, err: err, root: work_dir)).to eq(1)
      expect(err.string).to include("no run record under tmp/demo-calculator2/runs")
    end

    it "refuses --stub-ref without a value instead of taking the next flag as the ref" do
      expect(DemoCalculator2.main(%w[run --stub-ref --goals 01], out: out, err: err, root: work_dir)).to eq(1)
      expect(err.string).to include("demo-calculator2:", "--stub-ref")
    end

    it "refuses a repeated or empty --goals before touching anything" do
      expect(DemoCalculator2.main(%w[run --dry-run --goals 01,01], out: out, err: err, root: work_dir)).to eq(1)
      expect(err.string).to include("more than once")
      err.truncate(0)
      expect(DemoCalculator2.main(["run", "--dry-run", "--goals", ""], out: out, err: err, root: work_dir)).to eq(1)
      expect(err.string).to include("names no goal")
    end
  end
  describe "run --lanes" do
    let(:lane_b_dir) { File.join(tmp, "lane-b") }
    let(:snapshot) { File.join(tmp, "snapshot.json") }
    let(:pane) { {"kind" => "claude", "state" => "idle"} }
    let(:running) { true }
    let(:fake_workspace) do
      path = File.join(tmp, "fake-workspace")
      File.write(path, <<~SH)
        #!/bin/sh
        echo "$@" >> #{log}
        if [ "$1" = "snapshot" ]; then cat #{snapshot}; fi
        if [ "$1 $2" = "work-queue list" ]; then echo '{"queues":[{"workspace":"x","state":"off","items":[]}]}'; fi
        if [ "$1 $2" = "work-queue add" ]; then echo '{"results":[{"id":"item-'"$(echo "$@" | sed 's/.*calculator2-demo:([0-9]*).*/\1/')"'","outcome":"added"}]}'; fi
        if [ "$1" = "capabilities" ]; then echo '{"version":"9.9.9","features":{"work_queue":2},"paths":{}}'; fi
      SH
      File.chmod(0o755, path)
      path
    end
    let(:lane_args) { %w[run --lanes --lane-b ws-b --workflow deliver-goal-fast --name ws] }

    def main(*argv) = DemoCalculator2.main(argv, out: out, err: err, root: work_dir)

    def calls = File.exist?(log) ? File.read(log).lines.map(&:strip) : []

    def info_attributes = File.join(git(work_dir, "rev-parse", "--git-common-dir").strip.then { |dir| File.expand_path(dir, work_dir) }, "info", "attributes")

    def attributes_text = File.exist?(info_attributes) ? File.read(info_attributes) : ""

    before do
      git(main_dir, "worktree", "add", "-q", "-b", "lane-b", lane_b_dir, "main")
      File.write(snapshot, JSON.generate("projects" => [{"members" => [{"workspace" => "workspace.worktree-ws-b", "running" => running, "path" => lane_b_dir, "panes" => [pane]}]}]))
      ENV["WORKSPACE_BIN"] = fake_workspace
    end

    after { ENV.delete("WORKSPACE_BIN") }

    it "prints a dry run with the group coverage check, the sources entry, the merge driver line and the fork, and changes nothing" do
      expect(main(*lane_args, "--goals", "01,06", "--dry-run")).to eq(0), err.string
      expect(out.string).to include("group coverage of each item's own check (acceptance_runner_lanes):", "lane A: 01 groups 1", "lane B: 06 groups 1,2,3,6",
        "covered only by the plain 07-repl run after the merge (groups 1..7): 4,5,7",
        "+ workspace config set workflows.sources ", "calc_test.rb merge=calc-demo-tests", "would wait for lane A's 01-add-sub, then in lane B: git checkout -B calc-demo/")
      expect(out.string).to match(%r{ workspace work-queue add workflow deliver-goal-fast .*goals/01-add-sub\.md})
      expect(out.string).not_to include("goals/06-json.md --")
      expect(File.exist?(log)).to be(false)
      expect(attributes_text).not_to include("merge=calc-demo-tests")
      expect(git(work_dir, "rev-parse", "--abbrev-ref", "HEAD").strip).to eq("demo-branch")
    end

    it "covers every group by some item's own check when all seven goals run, so the integration-only list is none" do
      expect(main(*lane_args, "--dry-run")).to eq(0), err.string
      expect(out.string).to include("covered only by the plain 07-repl run after the merge (groups 1..7): none")
    end

    it "queues only 01-05 in lane A under the fast workflow and the lanes' runner, empties lane B's queue, adds the merge driver line and records the lanes" do
      expect(main(*lane_args)).to eq(0), err.string
      adds = calls.grep(/\Awork-queue add workflow /)
      expect(adds.map { |line| line[%r{goals/(0\d-[a-z-]+)\.md}, 1] }).to eq(DemoCalculator2::LANES[:a])
      expect(adds).to all(include("deliver-goal-fast", "acceptance=script/demo_calculator2/acceptance_runner_lanes", "--name ws"))
      expect(calls).to include("work-queue disable --name ws-b", "work-queue resume --name ws-b")
      expect(calls.grep(/\Aconfig set workflows.sources /).size).to eq(1)
      expect(File.read(info_attributes).lines.map(&:strip)).to include("demo/calculator2/test/calc_test.rb merge=calc-demo-tests")
      expect(git(work_dir, "config", "--local", "merge.calc-demo-tests.driver")).to include("merge_test_methods %O %A %B")
      record = JSON.parse(File.read(Dir.glob(File.join(work_dir, "tmp/demo-calculator2/runs/*/run.json")).first))
      branch = record["branch"]
      expect(record.dig("out_exclude", "line")).to match(%r{\A/.+/\z})
      expect(File.read(record.dig("out_exclude", "path")).lines.map(&:strip)).to include(record.dig("out_exclude", "line"))
      expect(record["lanes"]).to include("workflow" => "deliver-goal-fast", "fork_after" => "03-div-zero")
      expect(record["lanes"]["a"]).to eq("workspace" => "ws", "goals" => DemoCalculator2::LANES[:a])
      expect(record["lanes"]["b"]).to include("workspace" => "ws-b", "path" => lane_b_dir, "branch" => "#{branch}-b", "goals" => %w[06-json 07-repl], "items" => [])
      expect(record["goals"]).to eq(DemoCalculator2::LANES[:a])
      expect(record["items"].map { |item| item["workflow"] }.uniq).to eq(["deliver-goal-fast"])
      expect(record).not_to have_key("fork")
      expect(git(lane_b_dir, "rev-parse", "--abbrev-ref", "HEAD").strip).to eq("lane-b")
    end

    it "re-adds the workflows.sources entry on every run, so a removed entry comes back" do
      main(*lane_args)
      expect(calls.grep(/\Aconfig set workflows.sources /).first).to end_with("/demo/calculator2/workflows")
    end

    it "finds lane B by its full project-prefixed name as well as by its short name" do
      expect(main(*lane_args.map { |each| (each == "ws-b") ? "workspace.worktree-ws-b" : each })).to eq(0), err.string
      expect(calls).to include("work-queue disable --name workspace.worktree-ws-b")
    end

    context "when lane B is not ready" do
      def refused_before_anything_changes(message)
        expect(main(*lane_args)).to eq(1)
        expect(err.string).to include(message)
        expect(git(work_dir, "rev-parse", "--abbrev-ref", "HEAD").strip).to eq("demo-branch")
        expect(calls.grep(/work-queue (add|enable|advance)/)).to be_empty
        expect(attributes_text).not_to include("merge=calc-demo-tests")
      end

      context "with a pane that is working" do
        let(:pane) { {"kind" => "claude", "state" => "working"} }

        it("refuses") { refused_before_anything_changes("has no idle Claude Code pane") }
      end

      context "with a workspace that is not running" do
        let(:running) { false }

        it("refuses") { refused_before_anything_changes("is not running") }
      end

      it "refuses a name that only ends the same way as the reported workspace" do
        expect(main(*lane_args.map { |each| (each == "ws-b") ? "s-b" : each })).to eq(1)
        expect(err.string).to include("no workspace named s-b")
      end

      it "refuses a checkout with uncommitted changes" do
        File.write(File.join(lane_b_dir, "stray.txt"), "x")
        refused_before_anything_changes("uncommitted changes")
      end

      it "allows files under --out inside lane A's checkout, and leaves them out of the run's commits" do
        FileUtils.mkdir_p(File.join(work_dir, "runs/w01"))
        File.write(File.join(work_dir, "runs/w01/driver.log"), "log\n")
        expect(main(*lane_args, "--out", "runs/w01")).to eq(0), err.string
        expect(git(work_dir, "log", "--format=%H", "--name-only")).not_to include("runs/")
      end

      it "allows files under an absolute --out inside lane B's checkout" do
        FileUtils.mkdir_p(File.join(lane_b_dir, "runs"))
        File.write(File.join(lane_b_dir, "runs/x.log"), "log\n")
        expect(main(*lane_args, "--out", File.join(lane_b_dir, "runs"))).to eq(0), err.string
      end

      it "still refuses another untracked file in lane A's checkout when --out is inside it" do
        FileUtils.mkdir_p(File.join(work_dir, "runs/w01"))
        File.write(File.join(work_dir, "stray.txt"), "x")
        expect(main(*lane_args, "--out", "runs/w01")).to eq(1)
        expect(err.string).to include("uncommitted changes")
      end

      it "still refuses another untracked file in lane B's checkout when --out is outside it" do
        File.write(File.join(lane_b_dir, "stray.txt"), "x")
        expect(main(*lane_args, "--out", "runs/w01")).to eq(1)
        expect(err.string).to include("uncommitted changes")
      end

      it "refuses a checkout that is past main" do
        File.write(File.join(lane_b_dir, "extra.txt"), "x")
        git(lane_b_dir, "add", "extra.txt")
        git(lane_b_dir, "-c", "user.email=t@e.c", "-c", "user.name=T", "commit", "-q", "-m", "ahead of main")
        refused_before_anything_changes("is not on main")
      end
    end

    it "refuses --lanes without --lane-b, and a goal list with no lane A goal at or before 03 or no lane B goal" do
      expect(main("run", "--lanes", "--name", "ws", "--dry-run")).to eq(1)
      expect(err.string).to include("needs --lane-b")
      err.truncate(0)
      expect(main(*lane_args, "--goals", "05,06", "--dry-run")).to eq(1)
      expect(err.string).to include("needs a lane A goal")
      err.truncate(0)
      expect(main(*lane_args, "--goals", "01,02", "--dry-run")).to eq(1)
      expect(err.string).to include("a lane B goal")
    end

    it "refuses a workflow that is not one a goal runs as" do
      expect(main("run", "--workflow", "integrate-branch", "--dry-run")).to eq(1)
      expect(err.string).to include("needs one of deliver-goal, deliver-goal-fast")
    end

    it "refuses integrate under --dry-run, since it would merge and queue" do
      expect(main("integrate", "--dry-run")).to eq(1)
      expect(err.string).to include("takes no --dry-run")
    end

    it "refuses integrate off a run branch" do
      expect(main("integrate")).to eq(1)
      expect(err.string).to include("integrate runs on lane A's run branch")
    end
  end

  describe "run with --workflow" do
    it "queues every goal under the named workflow and records its definitions" do
      DemoCalculator::Demo.new(root: work_dir, workspace: fake_workspace, name: "ws", out: out, err: err, clock: clock,
        config: DemoCalculator2.config(workflow_id: "deliver-goal-fast")).run
      adds = File.read(log).lines.grep(/\Awork-queue add workflow /)
      expect(adds.size).to eq(7)
      expect(adds).to all(start_with("work-queue add workflow deliver-goal-fast "))
      expect(adds).to all(include("acceptance=script/demo_calculator2/acceptance_runner "))
    end
  end
end
