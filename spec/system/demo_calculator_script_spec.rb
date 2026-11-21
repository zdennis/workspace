require "spec_helper"
require "tmpdir"
require "open3"
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
  let(:fake_workspace) do
    path = File.join(tmp, "fake-workspace")
    File.write(path, <<~SH)
      #!/bin/sh
      echo "$@" >> #{log}
      if [ "$1 $2" = "work-queue list" ]; then echo '#{queue_json}'; fi
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

  def demo(root: work_dir, dry_run: false)
    described_class.new(root: root, workspace: fake_workspace, name: "ws", dry_run: dry_run, out: out)
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
    it "installs the source, queues the seven workflows in order, enables the queue and advances once" do
      demo.run
      calls = File.read(log).lines.map(&:strip)
      adds = calls.grep(/\Awork-queue add workflow /).map { |line| line[/calc-\d\d-[a-z-]+/] }
      expect(adds).to eq(DemoCalculator::WORKFLOW_IDS)
      expect(calls).to include("workflow install", "config set --scope workspace --name ws commands.test ruby")
      expect(calls.grep(/\Aconfig set workflows.sources /).first).to end_with("/demo/calculator/workflows")
      expect(calls.last(2)).to eq(["work-queue enable --name ws", "work-queue advance --name ws"])
    end
  end
end
