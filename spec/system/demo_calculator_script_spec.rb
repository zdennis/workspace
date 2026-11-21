require "spec_helper"
require "tmpdir"
require "open3"
require "digest"
require "stringio"

load File.join(PROJECT_ROOT, "script", "demo-calculator")

RSpec.describe DemoCalculator::Demo do
  def git(dir, *args)
    out, status = Open3.capture2e("git", "-C", dir, *args)
    raise "git #{args.join(" ")}: #{out}" unless status.success?
    out
  end

  # A main checkout with the demo committed on main, and a linked worktree on a demo branch.
  let(:tmp) { Dir.mktmpdir }
  let(:main_dir) { File.join(tmp, "main") }
  let(:work_dir) { File.join(tmp, "work") }
  let(:log) { File.join(tmp, "calls.log") }
  let(:queue_json) { '{"queues":[]}' }
  let(:sources) { "" }
  let(:states) { File.join(tmp, "queue-states") }
  let(:event_log) { File.join(tmp, "events.jsonl") }
  let(:capabilities_json) { %({"version":"9.9.9","features":{"work_queue":2},"paths":{"event_log":"#{event_log}"}}) }
  let(:fake_workspace) do
    path = File.join(tmp, "fake-workspace")
    File.write(path, <<~SH)
      #!/bin/sh
      echo "$@" >> #{log}
      if [ "$1 $2" = "work-queue list" ]; then
        if [ -f #{states} ]; then
          n=$(grep -c '^work-queue list' #{log})
          line=$(sed -n "${n}p" #{states}); [ -n "$line" ] || line=$(tail -n 1 #{states}); echo "$line"
        else echo '#{queue_json}'; fi
      fi
      if [ "$1 $2 $3" = "config get workflows.sources" ]; then echo '#{sources}'; fi
      if [ "$1 $2" = "work-queue add" ]; then echo '{"results":[{"id":"item-'"$4"'","outcome":"added"}]}'; fi
      if [ "$1" = "capabilities" ]; then echo '#{capabilities_json}'; fi
    SH
    File.chmod(0o755, path)
    path
  end
  let(:out) { StringIO.new }

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

  let(:clock) { -> { Time.utc(2026, 11, 21, 4, 5, 6) } }

  def demo(root: work_dir, dry_run: false, base: nil, out_dir: nil, **options)
    described_class.new(root: root, workspace: fake_workspace, name: "ws", dry_run: dry_run, out: out, base: base, out_dir: out_dir, clock: clock, **options)
  end

  it "keeps the live files and the template in step, so a fresh checkout is already reset" do
    %w[bin lib test USAGE.md].each do |entry|
      expect(`diff -r #{PROJECT_ROOT}/demo/calculator/#{entry} #{PROJECT_ROOT}/demo/calculator/template/#{entry}`).to eq("")
    end
  end

  describe "#reset" do
    it "restores the stub, commits it and leaves a second reset with nothing to do" do
      File.write(File.join(work_dir, "demo/calculator/lib/calc.rb"), "# a run's work\n")
      FileUtils.touch(File.join(work_dir, "demo/calculator/test/extra_test.rb"))
      git(work_dir, "add", "--all")
      git(work_dir, "commit", "-q", "-m", "a run's commit")
      demo.reset
      expect(File.read(File.join(work_dir, "demo/calculator/lib/calc.rb"))).to eq(File.read(File.join(PROJECT_ROOT, "demo/calculator/template/lib/calc.rb")))
      expect(File.exist?(File.join(work_dir, "demo/calculator/test/extra_test.rb"))).to be(false)
      expect(git(work_dir, "log", "--format=%s", "-1")).to eq("Reset the calculator demo to its stub\n")
      head = git(work_dir, "rev-parse", "HEAD")
      demo.reset
      expect(git(work_dir, "rev-parse", "HEAD")).to eq(head)
      expect(git(work_dir, "status", "--porcelain")).to eq("")
    end

    it "empties the queue: disables it, then clears and resumes" do
      demo.reset
      expect(File.read(log).lines.map(&:strip)).to eq(["work-queue list --json --name ws", "work-queue disable --name ws", "work-queue resume --name ws"])
    end

    it "changes nothing under --dry-run" do
      File.write(File.join(work_dir, "demo/calculator/lib/calc.rb"), "# a run's work\n")
      demo(dry_run: true).reset
      expect(File.read(File.join(work_dir, "demo/calculator/lib/calc.rb"))).to eq("# a run's work\n")
      expect(File.exist?(log)).to be(false)
    end

    it "refuses in the main checkout" do
      expect { demo(root: main_dir).reset }.to raise_error(DemoCalculator::Refused, /on main/)
    end

    it "refuses a worktree with no branch" do
      git(work_dir, "checkout", "-q", "--detach")
      expect { demo.reset }.to raise_error(DemoCalculator::Refused, /on HEAD/)
    end
  end

  describe ".queue_clearing" do
    it "cancels the active item, skips the held one and removes the queued ones" do
      items = [{"id" => "a1", "state" => "active"}, {"id" => "b2", "state" => "queued"}, {"id" => "c3", "state" => "queued"}, {"id" => "d4", "state" => "held"}]
      commands = described_class.queue_clearing(items, name_args: ["--name", "ws"])
      expect(commands).to eq([
        %w[work-queue disable --name ws], %w[work-queue cancel a1 --name ws], %w[work-queue skip d4 --name ws],
        %w[work-queue rm b2 c3 --name ws], %w[work-queue resume --name ws]
      ])
    end
  end

  describe "#run" do
    let(:record_path) { File.join(work_dir, "tmp/demo-calculator/runs/20261121T040506Z/run.json") }
    let(:head_sha) { git(work_dir, "rev-parse", "HEAD").strip }

    it "installs the source, queues the seven workflows in order, enables the queue and advances once" do
      demo.run
      calls = File.read(log).lines.map(&:strip)
      adds = calls.grep(/\Awork-queue add workflow /).map { |line| line[/calc-\d\d-[a-z-]+/] }
      expect(adds).to eq(DemoCalculator::WORKFLOW_IDS)
      expect(calls).to include("workflow install", "config set --scope workspace --name ws commands.test ruby")
      expect(calls.grep(/\Aconfig set workflows.sources /).first).to end_with("/demo/calculator/workflows")
      expect(calls.last(3)).to eq(["work-queue enable --name ws", "work-queue advance --name ws", "capabilities --json"])
    end

    it "leaves HEAD on calc-demo/<stamp>, with the acceptance removal as the first commit after the base" do
      base = head_sha
      demo.run
      expect(git(work_dir, "rev-parse", "--abbrev-ref", "HEAD").strip).to eq("calc-demo/20261121T040506Z")
      subjects = git(work_dir, "log", "--format=%s", "#{base}..HEAD").lines.map(&:strip).reverse
      expect(subjects.first).to eq("Remove the acceptance tests from the run branch")
      expect(File.exist?(File.join(work_dir, "demo/calculator-acceptance"))).to be(false)
      first = git(work_dir, "rev-list", "--reverse", "#{base}..HEAD").lines.first.strip
      expect(git(work_dir, "show", "--name-status", "--format=", first).lines.map { |l| l.split.first }.uniq).to eq(["D"])
    end

    it "writes a run record with the base, items, workspace and definition hashes" do
      base = head_sha
      demo.run
      record = JSON.parse(File.read(record_path))
      expect(record).to include("stamp" => "20261121T040506Z", "base_sha" => base, "branch" => "calc-demo/20261121T040506Z", "wait" => nil)
      expect(record["workspace"]).to eq("sha" => head_sha, "version" => "9.9.9")
      expect(record["items"].map { |i| i["workflow"] }).to eq(DemoCalculator::WORKFLOW_IDS)
      expect(record["items"].first["id"]).to eq("item-calc-01-add-sub")
      expect(record["definitions"].keys).to eq(DemoCalculator::WORKFLOW_IDS)
      expect(record["definitions"]["calc-01-add-sub"]).to eq(Digest::SHA256.file(File.join(work_dir, "demo/calculator/workflows/calc-01-add-sub.yml")).hexdigest)
    end

    it "writes the record to --out" do
      demo(out_dir: File.join(tmp, "elsewhere")).run
      expect(File.exist?(File.join(tmp, "elsewhere", "run.json"))).to be(true)
    end

    it "branches from --base" do
      git(work_dir, "commit", "-q", "--allow-empty", "-m", "later")
      first = git(work_dir, "rev-parse", "HEAD~1").strip
      demo(base: first).run
      expect(git(work_dir, "log", "--format=%s").lines.map(&:strip)).not_to include("later")
    end

    it "refuses a dirty tree" do
      File.write(File.join(work_dir, "demo/calculator/USAGE.md"), "edited\n")
      expect { demo.run }.to raise_error(DemoCalculator::Refused, /uncommitted/)
      expect(git(work_dir, "rev-parse", "--abbrev-ref", "HEAD").strip).to eq("demo-branch")
    end

    it "refuses a branch that already exists" do
      git(work_dir, "branch", "calc-demo/20261121T040506Z")
      expect { demo.run }.to raise_error(DemoCalculator::Refused, /already exists/)
    end

    it "refuses an unknown --base with the queue untouched" do
      expect { demo(base: "no-such-ref").run }.to raise_error(DemoCalculator::Refused, /rev-parse/)
      expect(File.exist?(log)).to be(false)
      expect(git(work_dir, "rev-parse", "--abbrev-ref", "HEAD").strip).to eq("demo-branch")
    end

    it "refuses a calc-demo/* HEAD without --base, naming --base and the previous record's base_sha" do
      FileUtils.mkdir_p(File.dirname(record_path))
      File.write(record_path, JSON.generate("base_sha" => "abc123"))
      git(work_dir, "add", "-f", "tmp")
      git(work_dir, "commit", "-q", "-m", "record")
      git(work_dir, "switch", "-q", "-c", "calc-demo/older")
      expect { demo.run }.to raise_error(DemoCalculator::Refused, /--base.*abc123/)
      expect { demo(base: "main").run }.not_to raise_error
    end

    it "changes nothing under --dry-run but says what it would do" do
      demo(dry_run: true).run
      expect(git(work_dir, "rev-parse", "--abbrev-ref", "HEAD").strip).to eq("demo-branch")
      expect(File.exist?(File.join(work_dir, "demo/calculator-acceptance"))).to be(true)
      expect(File.exist?(record_path)).to be(false)
      expect(File.exist?(log)).to be(false)
      expect(out.string).to include("git switch -c calc-demo/20261121T040506Z HEAD", "git rm -r demo/calculator-acceptance", "would write #{record_path}")
    end
    context "with workflows.sources already set" do
      let(:own) { File.join(work_dir, "demo/calculator/workflows") }
      let(:stale) { "/gone/other-demo/demo/calculator/workflows" }
      let(:sets) { File.read(log).lines.map(&:strip).grep(/\Aconfig set workflows.sources /) }

      context "with another checkout's entry among unrelated ones" do
        let(:sources) { "/a/team,#{stale},/b/mine" }

        it "replaces the stale entry with its own and keeps the rest in order" do
          demo.run
          expect(sets).to eq(["config set workflows.sources /a/team,/b/mine,#{own}"])
        end
      end

      context "with its own entry after a stale one" do
        let(:sources) { "#{stale},/a/team,#{own}" }

        it "drops the stale entry and writes the remaining list" do
          demo.run
          expect(sets).to eq(["config set workflows.sources /a/team,#{own}"])
        end
      end

      context "with a trailing slash and a near-miss path" do
        let(:sources) { "/a/other-demo/calculator/workflows,#{stale}/" }

        it "replaces only the real demo entry" do
          demo.run
          expect(sets).to eq(["config set workflows.sources /a/other-demo/calculator/workflows,#{own}"])
        end
      end

      context "when the list is already right" do
        let(:sources) { "/a/team,#{own}" }

        it "does not write it again" do
          demo.run
          expect(sets).to be_empty
        end
      end
    end
    describe "--wait" do
      let(:now) { [Time.utc(2026, 11, 21, 4, 5, 6)] }
      let(:clock) { -> { now.first } }
      let(:sleeper) { ->(seconds) { now[0] += seconds } }
      let(:record) { JSON.parse(File.read(record_path)) }

      def queue(state, *items, daemon: false)
        rows = items.map { |id, item_state| %({"id":"#{id}","state":"#{item_state}"}) }.join(",")
        %({"queues":[{"state":"#{state}","daemon_running":#{daemon},"items":[#{rows}]}]})
      end

      def wait_demo(**options)
        demo(wait: true, poll: 15, sleeper: sleeper, **options)
      end

      def calls = File.read(log).lines.map(&:strip)

      def run_waiting(*lines, **options)
        File.write(states, lines.join("\n") + "\n")
        wait_demo(**options).run
      end

      it "advances by hand without auto-advance, until the queue is empty, and records why it stopped" do
        run_waiting(queue("on", ["a", "queued"]), queue("on", ["a", "queued"]), queue("on", ["a", "active"]), queue("on"))
        expect(calls.count("work-queue advance --name ws")).to be > 1
        expect(record["wait"]).to eq("reason" => "empty", "item" => nil, "stopped_at" => now.first.utc.iso8601)
      end

      it "does not advance when the daemon does" do
        run_waiting(queue("on", ["a", "queued"], daemon: true), queue("on", ["a", "active"], daemon: true), queue("on", daemon: true))
        expect(calls.count("work-queue advance --name ws")).to eq(1)
        expect(record["wait"]["reason"]).to eq("empty")
      end

      it "stops when the queue is paused" do
        run_waiting(queue("paused", ["a", "held"], daemon: true))
        expect(record["wait"]).to include("reason" => "paused", "item" => "a")
      end

      it "stops on an item held past the limit by the held event's time, not the first sighting" do
        File.write(event_log, JSON.generate("timestamp" => "2026-11-21T03:30:00.000Z", "type" => "work_queue_item_held", "data" => {"id" => "a"}) + "\n")
        run_waiting(queue("on", ["a", "held"], daemon: true))
        expect(record["wait"]).to include("reason" => "held", "item" => "a")
        expect(calls.grep(/work-queue list/).size).to eq(2)
      end

      it "falls back to the first sighting of a hold when there is no event" do
        run_waiting(queue("on", ["a", "held"], daemon: true), held_limit: 60)
        expect(record["wait"]).to include("reason" => "held", "item" => "a")
        expect(calls.grep(/work-queue list/).size).to be > 2
      end

      it "stops when the queue is disabled with items left, instead of polling until timeout" do
        run_waiting(queue("off", ["a", "queued"]), timeout: 3600)
        expect(record["wait"]).to include("reason" => "disabled", "item" => nil)
        expect(calls.grep(/work-queue list/).size).to eq(2)
      end

      it "stops on timeout" do
        run_waiting(queue("on", ["a", "active"], daemon: true), timeout: 45)
        expect(record["wait"]).to include("reason" => "timeout", "item" => nil)
      end

      it "only says it would wait under --dry-run" do
        wait_demo(dry_run: true).run
        expect(out.string).to include("would wait for the queue")
      end
    end
  end
end
