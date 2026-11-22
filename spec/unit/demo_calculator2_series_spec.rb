require "spec_helper"
require "digest"
require "json"
require "stringio"
require "tmpdir"

require File.join(PROJECT_ROOT, "script", "demo_calculator2", "series")
require File.join(PROJECT_ROOT, "script", "demo_calculator2", "lanes")

# An exec that answers by the longest argv prefix registered with `on`, and records every call.
class SeriesExecFake
  attr_reader :calls

  def initialize
    @table = []
    @calls = []
  end

  def on(prefix, out = "", ok = true)
    @table.unshift([prefix, out, ok])
    self
  end

  def call(argv, **)
    @calls << argv
    _, out, ok = @table.select { |prefix, _, _| argv.first(prefix.size) == prefix }.max_by { |prefix, _, _| prefix.size }
    raise "no answer for #{argv.join(" ")}" if out.nil?
    [out.respond_to?(:call) ? out.call : out, ok]
  end
end

RSpec.describe DemoCalculator2::Series do
  let(:root) { "/repo" }
  let(:dir) { Dir.mktmpdir("series-spec") }
  let(:registry_dir) { File.join(dir, "demo-calc2") }
  let(:registry) { DemoCalculator2::SeriesRegistry.new(registry_dir, read_only: true, alive: ->(*) { true }) }
  let(:out) { StringIO.new }
  let(:err) { StringIO.new }
  let(:take_over) { false }
  let(:base) { "main" }
  let(:id) { "s1" }
  let(:options) { described_class.parse(["--id", id, "--base", base, *("--take-over" if take_over)]) }
  let(:definition) { "id: x\n" }
  let(:files) { {} }
  let(:existing) { ["/live"] }
  let(:unreadable) { [] }
  let(:realpath) { ->(path) { path } }
  let(:wanted_driver) { DemoCalculator2::SharedValues::DRIVER_COMMAND }
  let(:exec) do
    SeriesExecFake.new
      .on(%w[git show-ref], "", false)
      .on(%w[git worktree list], "worktree /repo\nHEAD abc\n\n")
      .on(%w[workspace list], [{"name" => "workspace", "directory" => "/repo"}].to_json)
      .on(%w[git rev-parse main], "aaa\n")
      .on(%w[git rev-parse origin/main], "aaa\n")
      .on(%w[git rev-parse --git-common-dir], "/repo/.git\n")
      .on(%w[gh run list], [{"conclusion" => "success", "status" => "completed"}].to_json)
      .on(%w[workspace lock status], {"locks" => {"test-db" => {"holder" => nil, "queue" => []}}}.to_json)
      .on(%w[workspace workflow status], -> { {"runs" => runs}.to_json })
      .on(%w[git config --local --get], "", false)
      .on(%w[workspace config show], {"keys" => [{"key" => "workflows.sources", "effective" => []}]}.to_json)
      .on(%w[workspace workflow show], {"ok" => false, "code" => "unknown_workflow"}.to_json, false)
      .on(%w[git show], definition)
  end
  let(:runs) { [] }
  let(:series) do
    described_class.new(root: root, options: options, exec: exec, registry: registry, out: out, err: err,
      read_file: ->(path) { files[path] }, path_exists: ->(path) { existing.include?(path) }, readable_dir: ->(path) { !unreadable.include?(path) })
  end

  let(:dry_series) do
    described_class.new(root: root, options: described_class.parse(["--id", id, "--base", base, "--dry-run"]), exec: exec, registry: registry, out: out, err: err,
      read_file: ->(path) { files[path] }, path_exists: ->(path) { existing.include?(path) }, readable_dir: ->(path) { !unreadable.include?(path) })
  end
  after { FileUtils.remove_entry(dir) }

  def absolute_driver(path) = "ruby #{path}/script/demo_calculator2/merge_test_methods %O %A %B"

  def refusal
    series.preflight
    nil
  rescue DemoCalculator2::Series::Refused => e
    e.message
  end

  describe ".parse" do
    it "reads every option into a frozen value" do
      o = described_class.parse(%w[--id a1 --lanes 2 --workflow deliver-goal-fast --sonnet --base dev --keep --evidence-dir /e --scoreboard /s --dry-run --take-over])
      expect(o).to be_frozen
      expect(o.to_h).to include(id: "a1", lanes: 2, workflow: "deliver-goal-fast", sonnet: true, base: "dev", keep: true, evidence_dir: "/e", scoreboard: "/s", dry_run: true, take_over: true)
    end

    it "defaults the workflow to deliver-goal-fast" do
      expect(described_class.parse(%w[--id a1]).workflow).to eq("deliver-goal-fast")
    end

    it "defaults the base to main and takes --forget without --id" do
      expect(described_class.parse(%w[--id a1]).base).to eq("main")
      expect(described_class.parse(%w[--forget a1]).forget).to eq("a1")
    end

    it "needs an id or --forget and refuses other lane counts" do
      expect { described_class.parse([]) }.to raise_error(OptionParser::MissingArgument)
      expect { described_class.parse(%w[--id a --lanes 3]) }.to raise_error(OptionParser::InvalidArgument)
    end
  end

  describe "#preflight refusals" do
    it "passes when nothing is wrong" do
      expect(refusal).to be_nil
    end

    %w[b B 1a a-b a_b].each do |bad|
      it "refuses the id #{bad.inspect}" do
        bad_series = described_class.new(root: root, options: described_class.parse(["--id", bad]), exec: exec, registry: registry)
        expect { bad_series.preflight }.to raise_error(DemoCalculator2::Series::Refused, /must be lowercase/)
      end
    end

    it "refuses an id whose run ref exists" do
      exec.on(%w[git show-ref --verify --quiet refs/demo-calc2-runs/s1-b], "", true)
      expect(refusal).to match(%r{refs/demo-calc2-runs/s1-b exists})
    end

    it "refuses an id with a worktree" do
      exec.on(%w[git worktree list], "worktree /repo\n\nworktree /x/.worktrees/calc2-demo-s1\n")
      expect(refusal).to match(/worktree calc2-demo-s1 exists/)
    end

    it "refuses an id with a workspace" do
      exec.on(%w[workspace list], [{"name" => "workspace.worktree-calc2-demo-s1-b", "directory" => "/elsewhere"}].to_json)
      expect(refusal).to match(/workspace calc2-demo-s1 exists/)
    end

    it "refuses an id in the registry" do
      DemoCalculator2::SeriesRegistry.new(registry_dir, pid: 1, host: "h").register("s1")
      expect(refusal).to match(/in the series registry/)
    end

    it "refuses when main is not origin/main, only for base main" do
      exec.on(%w[git rev-parse origin/main], "bbb\n")
      expect(refusal).to match(/main is not origin\/main/)
    end

    context "with another base" do
      let(:base) { "feature" }

      it "skips the main check and reads CI of that base" do
        exec.on(%w[git rev-parse origin/main], "bbb\n")
        expect(refusal).to be_nil
        expect(exec.calls).to include(%w[gh run list --branch feature -L 1 --json conclusion,status])
      end
    end

    it "refuses when CI is not green" do
      exec.on(%w[gh run list], [{"conclusion" => "failure", "status" => "completed"}].to_json)
      expect(refusal).to match(/not a success \(completed\/failure\)/)
    end

    it "refuses when CI has no run" do
      exec.on(%w[gh run list], "[]")
      expect(refusal).to match(/none found/)
    end

    context "when a workflows.sources entry is not a readable directory" do
      let(:gone) { "/gone/demo/calculator2/workflows" }
      let(:unreadable) { [gone] }

      before { exec.on(%w[workspace config show], {"keys" => [{"key" => "workflows.sources", "effective" => [gone]}]}.to_json) }

      it "refuses, naming the entry and the exact command that removes it" do
        expect(refusal).to eq("workflows.sources lists #{gone}, which is not a readable directory; `workspace workflow install` fails on it, " \
          "and --take-over does not remove it. Remove it: workspace config unset workflows.sources")
      end

      it "names the set command that keeps the other entries" do
        exec.on(%w[workspace config show], {"keys" => [{"key" => "workflows.sources", "effective" => ["/live", gone, "owner/repo/flows"]}]}.to_json)
        expect(refusal).to end_with("Remove it: workspace config set workflows.sources /live,owner/repo/flows")
      end

      it "lists it among a dry run's refusals" do
        expect(dry_series.call).to eq(1)
        expect(out.string + err.string).to include("#{gone}, which is not a readable directory")
      end
    end

    it "does not check a GitHub source as a directory" do
      exec.on(%w[workspace config show], {"keys" => [{"key" => "workflows.sources", "effective" => ["owner/repo/flows", "https://github.com/o/r/tree/main/f"]}]}.to_json)
      expect(refusal.to_s).not_to match(/readable director/)
    end

    it "passes a sources list whose entries are all readable directories" do
      exec.on(%w[workspace config show], {"keys" => [{"key" => "workflows.sources", "effective" => ["/live"]}]}.to_json)
      expect(refusal.to_s).not_to match(/readable directory/)
    end

    it "refuses when test-db is held" do
      exec.on(%w[workspace lock status], {"locks" => {"test-db" => {"holder" => {"pid" => 1}, "queue" => []}}}.to_json)
      expect(refusal).to match(/test-db lock is held/)
    end

    it "refuses when a going integrate-branch run uses test-db" do
      runs << {"id" => "wr_1", "workflow" => "integrate-branch", "workspace" => "w", "state" => "running", "worktree" => "/w"}
      expect(refusal).to match(/uses the test-db lock/)
    end

    it "ignores a finished integrate-branch run" do
      runs << {"id" => "wr_1", "workflow" => "integrate-branch", "workspace" => "w", "state" => "completed", "worktree" => "/w"}
      expect(refusal).to be_nil
    end

    context "with a driver that belongs to a live checkout" do
      before { exec.on(%w[git config --local --get merge.calc-demo-tests.driver], absolute_driver("/live") + "\n") }

      it "refuses without --take-over, naming key, value, owner and the flag" do
        expect(refusal).to include("git-config:merge.calc-demo-tests.driver", "/live", "--take-over")
      end

      context "with --take-over" do
        let(:take_over) { true }

        it "refuses while the owning workspace has a going run" do
          runs << {"id" => "wr_9", "workflow" => "deliver-goal", "workspace" => "w03", "state" => "waiting", "worktree" => "/live"}
          expect(refusal).to match(/workspace w03 has a going run \(wr_9\)/)
        end

        it "passes with no going run and reports the take-over" do
          runs << {"id" => "wr_9", "workflow" => "deliver-goal", "workspace" => "w03", "state" => "completed", "worktree" => "/live"}
          report = series.preflight
          row = report.shared.find { |r| r.key == DemoCalculator2::SharedValues::DRIVER_KEY }
          expect(row.state).to eq(:foreign_live)
          expect(row.action).to match(/would take over .* from \/live/)
        end
      end
    end

    it "passes a dangling w03-style driver path and reports would replace" do
      exec.on(%w[git config --local --get merge.calc-demo-tests.driver], absolute_driver("/gone") + "\n")
      row = series.preflight.shared.find { |r| r.key == DemoCalculator2::SharedValues::DRIVER_KEY }
      expect(row.state).to eq(:dangling)
      expect(row.action).to match(/would replace .*\/gone is gone|would replace/)
    end

    it "refuses a live calculator2 sources entry ahead of ours whose definitions differ" do
      exec.on(%w[workspace config show], {"keys" => [{"key" => "workflows.sources", "effective" => ["/live/demo/calculator2/workflows"]}]}.to_json)
      existing << "/live/demo/calculator2/workflows"
      expect(refusal).to include("workflows.sources:", "--take-over")
    end

    it "passes a live sources entry whose definitions are the base's" do
      exec.on(%w[workspace config show], {"keys" => [{"key" => "workflows.sources", "effective" => ["/live/demo/calculator2/workflows"]}]}.to_json)
      existing << "/live/demo/calculator2/workflows"
      DemoCalculator2::DEFINITION_IDS.each { |def_id| files["/live/demo/calculator2/workflows/#{def_id}.yml"] = definition }
      expect(refusal).to be_nil
    end

    it "refuses when a resolved definition differs from the base's copy" do
      exec.on(%w[workspace workflow show deliver-goal-fast], {"ok" => true, "workflow" => {"sha256" => Digest::SHA256.hexdigest("other"), "path" => "/p/deliver-goal-fast.yml", "source" => "source:1"}}.to_json)
      expect(refusal).to match(/deliver-goal-fast resolves to \/p\/deliver-goal-fast.yml \(source:1\), which differs/)
    end

    it "passes a resolved definition equal to the base's copy" do
      exec.on(%w[workspace workflow show], {"ok" => true, "workflow" => {"sha256" => Digest::SHA256.hexdigest(definition), "path" => "/p/x.yml", "source" => "source:1"}}.to_json)
      expect(refusal).to be_nil
    end

    {
      "workspace list" => %w[workspace list],
      "workspace workflow status" => %w[workspace workflow status],
      "workspace lock status" => %w[workspace lock status],
      "workspace config show" => %w[workspace config show],
      "workspace workflow show" => %w[workspace workflow show],
      "gh run list" => %w[gh run list],
      "git worktree list" => %w[git worktree list],
      "git rev-parse main" => %w[git rev-parse main],
      "git rev-parse origin/main" => %w[git rev-parse origin/main],
      "git rev-parse --git-common-dir" => %w[git rev-parse --git-common-dir],
      "git show" => %w[git show]
    }.each do |name, prefix|
      it "refuses, naming the command, when #{name} fails" do
        exec.on(prefix, "", false)
        expect(refusal).to include(prefix.first(2).join(" "))
      end
    end

    {
      "workspace list" => %w[workspace list],
      "workspace workflow status" => %w[workspace workflow status],
      "workspace lock status" => %w[workspace lock status],
      "workspace config show" => %w[workspace config show],
      "workspace workflow show" => %w[workspace workflow show],
      "gh run list" => %w[gh run list]
    }.each do |name, prefix|
      it "refuses, naming the command, when #{name} prints no JSON" do
        exec.on(prefix, "Note: not json", true)
        exec.on(prefix, "Note: not json", false) if prefix.first(3) == %w[workspace workflow show]
        expect(refusal).to include(prefix.first(2).join(" "))
      end
    end

    it "refuses when the JSON has the wrong shape" do
      exec.on(%w[workspace lock status], "{}")
      expect(refusal).to match(/lock status.*did not name the locks/)
    end

    it "refuses --take-over when the owner of a foreign value is unknown" do
      exec.on(%w[git config --local --get merge.calc-demo-tests.driver], "ruby /somewhere/else %O %A %B\n")
      expect(refusal).to include("--take-over")
      other = described_class.new(root: root, options: described_class.parse(%w[--id s1 --take-over]), exec: exec, registry: registry, read_file: ->(path) { files[path] }, path_exists: ->(_) { true }, readable_dir: ->(_) { true })
      expect { other.preflight }.to raise_error(described_class::Refused, /owning checkout is unknown/)
    end

    it "matches a going run's worktree to the owner through realpath" do
      real = Dir.mktmpdir("owner", dir)
      link = File.join(dir, "link")
      File.symlink(real, link)
      exec.on(%w[git config --local --get merge.calc-demo-tests.driver], absolute_driver(link) + "\n")
      runs << {"id" => "wr_9", "workflow" => "deliver-goal", "workspace" => "w03", "state" => "running", "worktree" => File.realpath(real)}
      takeover = described_class.new(root: root, options: described_class.parse(%w[--id s1 --take-over]), exec: exec, registry: registry, path_exists: ->(_) { true }, readable_dir: ->(_) { true })
      expect { takeover.preflight }.to raise_error(described_class::Refused, /has a going run \(wr_9\)/)
    end

    it "refuses wrong-shape JSON from lock status and workflow status" do
      exec.on(%w[workspace lock status], "[]")
      expect(refusal).to match(/lock status.*JSON object/)
      exec.on(%w[workspace lock status], {"locks" => {}}.to_json)
      exec.on(%w[workspace workflow status], "[]")
      expect(refusal).to match(/workflow status.*JSON object/)
      exec.on(%w[workspace workflow status], {"runs" => ["x"]}.to_json)
      expect(refusal).to match(/did not name the runs/)
    end

    it "still lets an unknown_workflow answer through" do
      expect(refusal).to be_nil
    end

    it "reports stale registry ids without removing them" do
      DemoCalculator2::SeriesRegistry.new(registry_dir, pid: 1, host: "h").register("old")
      stale = described_class.new(root: root, options: options, exec: exec, out: out, err: err,
        registry: DemoCalculator2::SeriesRegistry.new(registry_dir, read_only: true, alive: ->(*) { false }), read_file: ->(path) { files[path] })
      expect(stale.preflight.stale).to eq(["old"])
      expect(DemoCalculator2::SeriesRegistry.new(registry_dir, read_only: true).entries.keys).to eq(["old"])
    end
  end

  describe "#preflight with another checkout's sources entry" do
    let(:theirs) { "/other/demo/calculator2/workflows" }
    let(:existing) { ["/live", theirs] }

    before { exec.on(%w[workspace config show], {"keys" => [{"key" => "workflows.sources", "effective" => [theirs]}]}.to_json) }

    it "names that entry's checkout in the refusal" do
      expect(refusal).to include("workflows.sources:/repo/demo/calculator2/workflows is already #{theirs.inspect}", "belongs to the checkout /other")
    end

    context "with --take-over and a going run in that checkout" do
      let(:take_over) { true }
      let(:runs) { [{"id" => "r1", "state" => "going", "workspace" => "other-ws", "worktree" => "/other"}] }

      it "refuses naming the run and the workspace" do
        expect(refusal).to match(/belongs to \/other, whose workspace other-ws has a going run \(r1\)/)
      end
    end
  end

  describe "#call" do
    it "prints the report and returns 0 on a clean dry run" do
      expect(dry_series.call).to eq(0)
      expect(out.string).to include("preflight ok", "would add git-config:merge.calc-demo-tests.driver", "exclude:/runs/s1/")
    end

    context "with another base" do
      let(:base) { "feature" }

      it "shows the base as the run's --stub-ref in step 6" do
        expect(dry_series.call).to eq(0)
        expect(out.string).to match(/^  6\. run .* --lane-b calc2-demo-s1-b .* --stub-ref feature$/)
      end
    end

    it "prints steps 2 to 9 on a dry run, with the names and paths a real series would use" do
      expect(dry_series.call).to eq(0)
      text = out.string
      expect(text).to include(
        "  2. register s1 in #{registry_dir}/series.json",
        "workspace start calc2-demo-s1 --base main --headless --yes --json",
        "workspace start calc2-demo-s1-b --base main --headless --yes --json",
        "  3. skipped, no --sonnet",
        "  4. wait for an idle Claude Code pane in both lanes: poll every 5s, at most 300s",
        "  5. write the shared values",
        "  6. run <lane A path>/script/demo-calculator2 run --lanes --lane-b calc2-demo-s1-b --id s1 --wait --out runs/s1",
        "runs/s1/driver.log",
        "  7. save evidence",
        "  8. pin refs/demo-calc2-runs/s1 and refs/demo-calc2-runs/s1-b",
        "kill calc2-demo-s1 and calc2-demo-s1-b",
        "refs/demo-calc2/acceptance/s1",
        "  9. print the scoreboard row on stdout, then print `LOOP DONE: series s1 ...`"
      )
      expect(text.lines.grep(/^  [2-9]\. /).size).to eq(8)
      expect(text).to match(/^ {7}\S.*: (nothing, equal|write )/)
      expect(text).to include("drop the line again")
    end

    it "prints the sonnet steps, the scoreboard target and the kept line when asked" do
      options = described_class.parse(%w[--id s1 --dry-run --sonnet --keep --scoreboard board.md])
      described_class.new(root: root, options: options, exec: exec, registry: registry, out: out, err: err,
        read_file: ->(path) { files[path] }, path_exists: ->(path) { existing.include?(path) }, readable_dir: ->(path) { !unreadable.include?(path) }).call
      expect(out.string).to include("agent.commands.claude claude-sonnet", "template apply calc2-demo-s1-b --relaunch",
        "8. kept: --keep", "9. append the scoreboard row to #{root}/board.md")
    end

    it "lists every refusal on a dry run, still prints the rows and the plan, and returns 1" do
      exec.on(%w[gh run list], "[]").on(%w[git rev-parse origin/main], "bbb\n")
      expect(dry_series.call).to eq(1)
      text = out.string
      expect(text).to include("preflight found 2 problem(s)", "git-config:merge.calc-demo-tests.driver", "  2. register s1", "  9. print the scoreboard")
      expect(text).to match(/would refuse:\n  - main is not origin\/main.*\n  - the latest CI run on main is not a success/)
      expect(err.string).to eq("")
    end

    it "shows a key whose read failed as unreadable and still lists the rest" do
      exec.on(%w[git rev-parse --git-common-dir], "", false)
      expect(dry_series.call).to eq(1)
      expect(out.string).to include("attributes:", "now ?; ? (`git rev-parse --git-common-dir` failed)", "merge.calc-demo-tests.driver: now nil; would add")
      expect(out.string).to include("unknown, ? (`git rev-parse --git-common-dir` failed)")
    end

    it "still stops a real run at the first refusal" do
      exec.on(%w[gh run list], "[]").on(%w[git rev-parse origin/main], "bbb\n")
      expect(series.call).to eq(1)
      expect(err.string).to include("main is not origin/main")
      expect(err.string).not_to include("CI run")
      expect(out.string).to eq("")
    end

    it "prints a refusal to err and returns 1" do
      exec.on(%w[gh run list], "[]")
      expect(series.call).to eq(1)
      expect(err.string).to match(/series refused: .*CI|latest CI run/)
    end

    it "returns 1 with a corrupt registry" do
      FileUtils.mkdir_p(registry_dir)
      File.write(File.join(registry_dir, "series.json"), "{nope")
      expect(series.call).to eq(1)
      expect(err.string).to match(/not valid JSON/)
    end
  end

  describe "dry run" do
    it "calls only allowlisted argv and creates no file" do
      dry = described_class.new(root: root, options: described_class.parse(%w[--id s1 --dry-run]), exec: exec, registry: registry, out: out, err: err,
        read_file: ->(path) { files[path] }, path_exists: ->(path) { existing.include?(path) }, readable_dir: ->(path) { !unreadable.include?(path) })
      expect(dry.call).to eq(0)
      expect(exec.calls).not_to be_empty
      expect(Dir.children(dir)).to be_empty
    end
  end

  describe "the registry in a dry run" do
    it "refuses a registry that is not read-only" do
      writable = DemoCalculator2::SeriesRegistry.new(registry_dir)
      expect { described_class.new(root: root, options: described_class.parse(%w[--id s1 --dry-run]), exec: exec, registry: writable) }.to raise_error(ArgumentError, /read-only/)
    end
  end

  describe described_class::ReadOnlyExec do
    let(:inner) { SeriesExecFake.new.on([], "ok") }
    let(:guarded) { described_class.new(inner) }

    [
      %w[git rev-parse HEAD], %w[git show-ref --verify x], %w[git config --local --get k], %w[git worktree list --porcelain],
      %w[git for-each-ref refs/x], %w[git merge-base a b], %w[git show main:f], %w[gh run list -L 1],
      %w[workspace status], %w[workspace list --all], %w[workspace lock status --json], %w[workspace config get k], %w[workspace config show --json],
      %w[workspace snapshot], %w[workspace workflow show x --json], %w[workflow status].unshift("workspace")
    ].each do |argv|
      it "allows #{argv.join(" ")}" do
        expect(guarded.call(argv, chdir: "/")).to eq(["ok", true])
      end
    end

    [
      %w[git config merge.x.driver y], %w[git config --get-all k], %w[git config k --get], %w[git config --local merge.x y], %w[git show --output=/tmp/x main:f], %w[git show main:f --output /tmp/x], %w[git update-ref refs/x abc], %w[git worktree add p], %w[git config --unset k],
      %w[gh run rerun 1], %w[workspace kill x], %w[workspace start x], %w[workspace config set k v], %w[workspace lock release x],
      %w[workspace workflow cancel x], %w[rm -rf /]
    ].each do |argv|
      it "refuses #{argv.join(" ")}" do
        expect { guarded.call(argv, chdir: "/") }.to raise_error(DemoCalculator2::Series::DryRunWrite)
        expect(inner.calls).to be_empty
      end
    end
  end

  describe "a full run (steps 2 to 6)" do
    let(:live_registry) { DemoCalculator2::SeriesRegistry.new(registry_dir, alive: ->(*) { true }) }
    let(:written) { {} }
    let(:sleeps) { [] }
    let(:now) { [0] }
    let(:options) { described_class.parse(["--id", id, "--base", base, *("--take-over" if take_over), *extra_args]) }
    let(:extra_args) { ["--keep"] }
    let(:snapshot_states) { [] }
    let(:run_output) { ["LOOP DONE: wall=1m integration=clean first_pass=true items=7/7\n", 0] }
    let(:tmux_command) { "claude-sonnet --dangerously-skip-permissions --continue || claude-sonnet --dangerously-skip-permissions" }
    let(:lane_a) { "workspace.worktree-calc2-demo-s1" }
    let(:lane_b) { "workspace.worktree-calc2-demo-s1-b" }
    let(:sources) { File.join(root, "demo/calculator2/workflows") }
    let(:started) { [] }
    let(:runs) { [] }
    let(:run_logged) do
      lambda do |argv, chdir:, log:|
        runs << {argv: argv, chdir: chdir, log: log}
        exec.calls << ["run", *argv]
        files[log] = run_output[0]
        run_output[1]
      end
    end
    let(:full) do
      described_class.new(root: root, options: options, exec: exec, registry: live_registry, out: out, err: err,
        read_file: ->(path) { files[path] }, path_exists: ->(path) { existing.include?(path) }, readable_dir: ->(path) { !unreadable.include?(path) }, realpath: realpath,
        write_file: ->(path, text) { written[path] = text }, run_logged: run_logged, clock: -> { now[0] }, sleeper: ->(s) {
          sleeps << s
          now[0] += s
        })
    end

    def start_doc(name, path) = {"workspace" => "workspace.worktree-#{name}", "path" => path, "branch" => name}.to_json

    before do
      exec
        .on(%w[workspace start calc2-demo-s1], -> {
          started << live_registry.entries.dig("s1", "workspaces").dup
          start_doc("calc2-demo-s1", "/wt/a")
        })
        .on(%w[workspace start calc2-demo-s1-b], -> {
          started << live_registry.entries.dig("s1", "workspaces").dup
          start_doc("calc2-demo-s1-b", "/wt/b")
        })
        .on(%w[git rev-parse HEAD], "aaa\n")
        .on(%w[git config --local], "")
        .on(%w[workspace config set], "")
        .on(%w[workspace template apply], "")
        .on(%w[workspace tmux show], -> { {"windows" => [{"panes" => [{"kind" => "banner", "command" => "echo"}, {"kind" => "claude", "command" => tmux_command}]}]}.to_json })
        .on(%w[workspace snapshot], -> { snapshot })
    end

    def snapshot
      state = snapshot_states.shift || "idle"
      members = [lane_a, lane_b].map { |name| {"workspace" => name, "running" => true, "panes" => [{"kind" => "claude", "state" => state}]} }
      {"projects" => [{"members" => members}]}.to_json
    end

    def config_writes = calls("git", "config", "--local").reject { |argv| argv[3] == "--get" }

    def calls(*prefix) = exec.calls.select { |argv| argv.first(prefix.size) == prefix }

    it "starts both lanes, each recorded before the next command, then checks heads, waits, writes and runs, in that order" do
      expect(full.call).to eq(0)
      expect(started).to eq([[], [lane_a]])
      expect(live_registry.entries["s1"]["workspaces"]).to eq([lane_a, lane_b])
      kinds = exec.calls.filter_map do |argv|
        if argv.first(2) == %w[workspace start] then "start #{argv[2]}"
        elsif argv.first(3) == %w[git rev-parse HEAD] then "head"
        elsif argv.first(2) == %w[workspace snapshot] then "snapshot"
        elsif argv.first(3) == %w[git config --local] && argv[3] != "--get" then "git config"
        elsif argv.first(3) == %w[workspace config set] then "config set"
        elsif argv.first == "run" then "run"
        end
      end.chunk_while { |a, b| a == b }.map(&:first)
      expect(kinds).to eq(["start calc2-demo-s1", "start calc2-demo-s1-b", "head", "snapshot", "config set", "git config", "run"])
      expect(calls("workspace", "start", "calc2-demo-s1").first).to eq(%w[workspace start calc2-demo-s1 --base main --headless --yes --json])
    end

    context "when the run starts" do
      let(:recorded_at_run) { [] }
      let(:run_logged) do
        lambda do |argv, chdir:, log:|
          recorded_at_run << live_registry.entries.dig("s1", "sources").dup
          exec.calls << ["run", *argv]
          files[log] = run_output[0]
          run_output[1]
        end
      end

      it "has already recorded each lane's own sources entry" do
        expect(full.call).to eq(0)
        expect(recorded_at_run).to eq([["/wt/a/demo/calculator2/workflows", "/wt/b/demo/calculator2/workflows"]])
      end
    end

    context "when a lane's path goes through a symlink" do
      let(:realpath) { ->(path) { path.sub("/wt/", "/private/wt/") } }

      it "records both spellings, so the one the run writes is dropped" do
        full.call
        expect(live_registry.entries["s1"]["sources"]).to eq(%w[/wt/a /private/wt/a /wt/b /private/wt/b].map { |path| "#{path}/demo/calculator2/workflows" })
      end
    end

    it "stops when a lane is not at the base sha" do
      exec.on(%w[git rev-parse HEAD], "bbb\n")
      expect(full.call).to eq(3)
      expect(err.string).to match(/is at bbb, not main \(aaa\)/)
      expect(calls("workspace", "snapshot")).to be_empty
    end

    it "stops when the second start fails, after recording what the first made" do
      exec.on(%w[workspace start calc2-demo-s1-b], "", false)
      expect(full.call).to eq(3)
      expect(live_registry.entries["s1"]["workspaces"]).to eq([lane_a])
      expect(calls("workspace", "snapshot")).to be_empty
    end

    it "runs the finish hook after a stop" do
      exec.on(%w[git rev-parse HEAD], "bbb\n")
      expect(full).to receive(:finish)
      full.call
    end

    it "stops with 3, prints the message and still runs the finish hook when a write fails in step 5" do
      failing = described_class.new(root: root, options: options, exec: exec, registry: live_registry, out: out, err: err,
        read_file: ->(path) { files[path] }, path_exists: ->(path) { existing.include?(path) }, readable_dir: ->(path) { !unreadable.include?(path) }, run_logged: run_logged,
        write_file: ->(*) { raise Errno::EACCES, "info/attributes" }, sleeper: ->(_) {})
      expect(failing).to receive(:finish)
      expect(failing.call).to eq(3)
      expect(err.string).to include("series s1 stopped:", "info/attributes", "Errno::EACCES")
      expect(runs).to be_empty
    end

    it "does not run the finish hook when preflight refuses" do
      exec.on(%w[gh run list], "[]")
      expect(full).not_to receive(:finish)
      expect(full.call).to eq(1)
      expect(calls("workspace", "start")).to be_empty
    end

    context "with --sonnet" do
      let(:extra_args) { ["--keep", "--sonnet"] }

      it "sets the launcher per lane, applies the template with a relaunch and reads the pane command back" do
        expect(full.call).to eq(0)
        expect(calls("workspace", "config", "set", "--scope")).to eq([lane_a, lane_b].map { |name| %W[workspace config set --scope workspace --name #{name} agent.commands.claude claude-sonnet] })
        expect(calls("workspace", "template", "apply")).to eq([lane_a, lane_b].map { |name| ["workspace", "template", "apply", name, "--relaunch"] })
        expect(calls("workspace", "tmux", "show").first).to eq(["workspace", "tmux", "show", "--name", lane_a, "--json"])
      end

      it "stops when the pane still runs another command" do
        exec.on(%w[workspace tmux show], {"windows" => [{"panes" => [{"kind" => "claude", "command" => "claude-dev --continue"}]}]}.to_json)
        expect(full.call).to eq(3)
        expect(err.string).to match(/does not run claude-sonnet/)
        expect(calls("workspace", "snapshot")).to be_empty
      end

      it "sets nothing without the flag" do
        plain = described_class.new(root: root, options: described_class.parse(%w[--id s1]), exec: exec, registry: live_registry, out: out, err: err,
          read_file: ->(path) { files[path] }, path_exists: ->(path) { existing.include?(path) }, readable_dir: ->(path) { !unreadable.include?(path) }, write_file: ->(path, text) { written[path] = text }, run_logged: run_logged, sleeper: ->(_) {})
        plain.call
        expect(calls("workspace", "config", "set", "--scope")).to be_empty
        expect(calls("workspace", "template")).to be_empty
      end
    end

    describe "the idle wait" do
      it "polls every 5s until both lanes have an idle Claude pane" do
        snapshot_states.concat(%w[working working])
        expect(full.call).to eq(0)
        expect(sleeps).to eq([5])
      end

      it "stops after 300s, before any shared value is written or the run starts" do
        snapshot_states.concat(["working"] * 1000)
        expect(full.call).to eq(3)
        expect(sleeps.sum).to be_between(295, 300)
        expect(err.string).to match(/no idle Claude Code pane in .* after 300s/)
        expect(config_writes).to be_empty
        expect(runs).to be_empty
        expect(written.keys).to eq(["/wt/a/runs/s1/command.txt"])
      end
    end

    describe "the shared values" do
      it "registers and writes each absent value: config, attributes line, exclude line and the sources entry" do
        expect(full.call).to eq(0)
        expect(calls("git", "config", "--local", "merge.calc-demo-tests.driver")).to eq([%W[git config --local merge.calc-demo-tests.driver #{wanted_driver}]])
        expect(calls("git", "config", "--local", "merge.calc-demo-tests.name").size).to eq(1)
        expect(calls("workspace", "config", "set", "workflows.sources")).to eq([["workspace", "config", "set", "workflows.sources", sources]])
        expect(written["/repo/.git/info/attributes"]).to eq("#{described_class::ATTRIBUTES_LINE}\n")
        expect(written["/repo/.git/info/exclude"]).to eq("/runs/s1/\n")
        expect(live_registry.shared.keys).to include("exclude:/runs/s1/", "attributes:#{described_class::ATTRIBUTES_LINE}", DemoCalculator2::SharedValues::DRIVER_KEY, "workflows.sources:#{sources}")
        expect(live_registry.shared.values.map { |entry| entry["added_by"] }.uniq).to eq(["s1"])
      end

      it "writes the sources entry before the other values" do
        full.call
        writes = exec.calls.select { |argv| argv.first(3) == %w[workspace config set] && argv[3] == "workflows.sources" || argv.first(3) == %w[git config --local] && argv[3] != "--get" }
        expect(writes.first[3]).to eq("workflows.sources")
      end

      context "when every value is already equal" do
        before do
          exec.on(%w[git config --local --get merge.calc-demo-tests.driver], wanted_driver)
          exec.on(%w[git config --local --get merge.calc-demo-tests.name], described_class::NAME_VALUE)
          exec.on(%w[workspace config show], {"keys" => [{"key" => "workflows.sources", "effective" => [sources]}]}.to_json)
          files["/repo/.git/info/attributes"] = "#{described_class::ATTRIBUTES_LINE}\n"
          files["/repo/.git/info/exclude"] = "/runs/s1/\n"
        end

        it "writes nothing and records each as preexisting" do
          expect(full.call).to eq(0)
          expect(config_writes).to be_empty
          expect(calls("workspace", "config", "set", "workflows.sources")).to be_empty
          expect(written.keys).to eq(["/wt/a/runs/s1/command.txt"])
          expect(live_registry.shared.values.map { |entry| entry["added_by"] }.uniq).to eq(["preexisting"])
        end
      end

      context "when the driver is dangling" do
        let(:old) { absolute_driver("/gone") }

        before { exec.on(%w[git config --local --get merge.calc-demo-tests.driver], old) }

        it "replaces it and records the old value" do
          expect(full.call).to eq(0)
          expect(calls("git", "config", "--local", "merge.calc-demo-tests.driver")).to eq([%W[git config --local merge.calc-demo-tests.driver #{wanted_driver}]])
          expect(live_registry.shared[DemoCalculator2::SharedValues::DRIVER_KEY]["replaced"]).to eq("value" => old, "owner_path" => "/gone")
        end
      end

      context "when another checkout's sources entry is live and --take-over is given" do
        let(:take_over) { true }
        let(:theirs) { "/other/demo/calculator2/workflows" }
        let(:existing) { ["/live", theirs] }

        before { exec.on(%w[workspace config show], {"keys" => [{"key" => "workflows.sources", "effective" => [theirs]}]}.to_json) }

        it "writes our entry first and keeps theirs" do
          expect(full.call).to eq(0)
          expect(calls("workspace", "config", "set", "workflows.sources")).to eq([["workspace", "config", "set", "workflows.sources", "#{sources},#{theirs}"]])
        end
      end

      context "when a value became foreign_live after preflight" do
        it "stops with no run and keeps the workspaces recorded" do
          reads = 0
          exec.on(%w[git config --local --get merge.calc-demo-tests.driver], -> { ((reads += 1) == 1) ? "" : "ruby /live/script/demo_calculator2/merge_test_methods %O %A %B" })
          expect(full.call).to eq(3)
          expect(err.string).to match(%r{already .*belongs to the checkout /live})
          expect(runs).to be_empty
          expect(config_writes).to be_empty
          expect(live_registry.entries["s1"]["workspaces"]).to eq([lane_a, lane_b])
        end
      end
    end

    describe "the run" do
      it "gives the run's log to the runner, which appends to it as the run goes, instead of capturing the output" do
        full.call
        expect(calls(*runs.first[:argv].first(2))).to be_empty
      end

      it "runs lane A's script from its worktree with the lane, id, out and wait arguments, and keeps the log" do
        full.call
        run = runs.first
        expect(run[:chdir]).to eq("/wt/a")
        expect(run[:log]).to eq("/wt/a/runs/s1/driver.log")
        expect(run[:argv]).to eq(["/wt/a/script/demo-calculator2", "run", "--lanes", "--lane-b", lane_b, "--id", "s1", "--wait", "--out", "runs/s1", "--workflow", "deliver-goal-fast"])
        expect(files["/wt/a/runs/s1/driver.log"]).to include("LOOP DONE")
      end

      it "leaves --stub-ref out for base main, the run's own default" do
        full.call
        expect(runs.first[:argv]).not_to include("--stub-ref")
      end

      context "with another base" do
        let(:base) { "feature" }

        before { exec.on(%w[git rev-parse feature], "aaa\n") }

        it "passes the base as the run's --stub-ref, so lane B may start from it" do
          expect(full.call).to eq(0)
          expect(runs.first[:argv].last(2)).to eq(%w[--stub-ref feature])
        end
      end

      it "leaves --workflow out for the script's own default" do
        series = described_class.new(root: root, options: described_class.parse(%w[--id s1 --workflow deliver-goal]), exec: exec, registry: live_registry, out: out, err: err,
          read_file: ->(path) { files[path] }, path_exists: ->(path) { existing.include?(path) }, readable_dir: ->(path) { !unreadable.include?(path) }, write_file: ->(path, text) { written[path] = text }, run_logged: run_logged, sleeper: ->(_) {})
        series.call
        expect(runs.first[:argv]).not_to include("--workflow")
      end

      context "when the run stops" do
        let(:run_output) { ["LOOP DONE: stopped reason=timeout\n", 3] }

        it "returns 3, names the line and still writes driver.log" do
          expect(full.call).to eq(3)
          expect(err.string).to include("stopped reason=timeout")
          expect(files["/wt/a/runs/s1/driver.log"]).to include("stopped reason=timeout")
        end
      end

      context "when the run exits non-zero although its log says 7/7" do
        let(:run_output) { ["LOOP DONE: wall=1m integration=clean first_pass=true items=7/7\n", 1] }

        it "returns 3" do
          expect(full.call).to eq(3)
        end
      end

      context "when the run ends without all seven items" do
        let(:run_output) { ["LOOP DONE: wall=1m integration=clean first_pass=true items=6/7\n", 0] }

        it "returns 3" do
          expect(full.call).to eq(3)
        end
      end
    end
    describe "steps 7 to 9 (evidence, pin, clean, report)" do
      let(:extra_args) { [] }
      let(:written) { files }
      let(:copies) { [] }
      let(:existing) { ["/live", "/wt/a/runs/s1"] }
      let(:run_dir) { "/wt/a/runs/s1" }
      let(:branch_a) { "calc-demo/20260101T000000Z-s1" }
      let(:branch_b) { "calc-demo/20260101T000000Z-s1-b" }
      let(:run_json) do
        {"stamp" => "20260101T000000Z", "branch" => branch_a, "base_sha" => "aaa", "fork" => {"run_id" => "wr_fork"},
         "lanes" => {"workflow" => "deliver-goal-fast", "a" => {"workspace" => lane_a}, "b" => {"workspace" => lane_b, "branch" => branch_b}}}
      end
      let(:eval_json) do
        {"header" => {"model" => "sonnet"}, "leak" => {"hook" => 0, "transcript" => {"/t/a" => 0, "/t/b" => 0}},
         "rows" => %w[01-add 02-sub 03-mul 04-div 05-pow 06-mod 07-repl].each_with_index.map { |goal, index| {"goal" => goal, "ran" => true, "wall" => 60.0 * (index + 1)} },
         "totals" => {"items" => 7, "items_run" => 7, "states" => {"completed" => 7}, "first_pass" => 7, "accept_loops" => 1, "review_rounds" => 2, "cost_usd" => 4.5, "lint" => 0, "partial" => []},
         "lanes" => {"wall" => 600.0, "sequential" => 900.0, "critical_path" => {"span" => 500.0}, "integration" => {"merge" => "clean", "first_pass" => true, "wall" => 30.0}}}
      end
      let(:full) do
        described_class.new(root: root, options: options, exec: exec, registry: live_registry, out: out, err: err,
          read_file: ->(path) { files[path] }, path_exists: ->(path) { existing.include?(path) }, readable_dir: ->(path) { !unreadable.include?(path) }, realpath: realpath,
          write_file: ->(path, text) { written[path] = text }, run_logged: run_logged, clock: -> { now[0] }, sleeper: ->(s) { now[0] += s },
          copy_dir: ->(from, to) {
            exec.calls << ["copy", from, to]
            copies << [from, to]
          })
      end

      before do
        files["#{run_dir}/run.json"] = JSON.generate(run_json)
        files["#{run_dir}/eval.json"] = JSON.generate(eval_json)
        exec
          .on(["/wt/a/script/demo-calculator2", "eval"], "the eval table\n")
          .on(%w[workspace work-queue history list], {"entries" => [{"result" => {"run_id" => "wr_1"}}]}.to_json)
          .on(%w[workspace workflow attempts], {"attempts" => []}.to_json)
          .on(%w[workspace workflow trace], {"transitions" => []}.to_json)
          .on(["git", "rev-parse", branch_a], "head-a\n")
          .on(["git", "rev-parse", branch_b], "head-b\n")
          .on(%w[git update-ref], "")
          .on(%w[git branch -D], "")
          .on(%w[workspace kill], "{}")
          .on(%w[workspace config unset], "")
          .on(%w[workspace config show], -> { {"keys" => [{"key" => "workflows.sources", "effective" => sources_now}]}.to_json })
      end

      def sources_now = (exec.calls.any? { |argv| argv.first(4) == %w[workspace config set workflows.sources] }) ? [sources] : []

      def index_of(*prefix) = exec.calls.index { |argv| argv.first(prefix.size) == prefix }

      context "when the run stopped" do
        let(:run_output) { ["LOOP DONE: stopped reason=timeout\n", 3] }

        it "still saves the evidence in lane A's runs directory" do
          expect(full.call).to eq(3)
          expect(files.keys).to include("#{run_dir}/eval.txt", "#{run_dir}/work-queue-history-a.json", "#{run_dir}/work-queue-history-b.json",
            "#{run_dir}/attempts-wr_1.json", "#{run_dir}/trace-wr_1.json", "#{run_dir}/attempts-wr_fork.json", "#{run_dir}/command.txt")
          expect(files["#{run_dir}/command.txt"]).to include("series --id s1")
          expect(calls("/wt/a/script/demo-calculator2").first).to eq(["/wt/a/script/demo-calculator2", "eval", "--run", run_dir])
        end

        it "pins both lane heads, then copies the evidence, then kills, then deletes the branches and the acceptance ref" do
          full.call
          expect(calls("git", "update-ref", "refs/demo-calc2-runs/s1")).to eq([["git", "update-ref", "refs/demo-calc2-runs/s1", "head-a"]])
          expect(calls("git", "update-ref", "refs/demo-calc2-runs/s1-b")).to eq([["git", "update-ref", "refs/demo-calc2-runs/s1-b", "head-b"]])
          expect(copies).to eq([[run_dir, "/repo/tmp/demo-calculator2/series/s1"]])
          order = [index_of("git", "update-ref", "refs/demo-calc2-runs/s1-b"), index_of("copy"), index_of("workspace", "kill"), index_of("git", "branch", "-D"), index_of("git", "update-ref", "-d")]
          expect(order).to eq(order.sort)
          expect(order).not_to include(nil)
        end

        it "kills only the workspaces in the registry entry and deletes only the recorded branches" do
          full.call
          expect(calls("workspace", "kill")).to eq([["workspace", "kill", "--name", lane_a, "--force", "--json"], ["workspace", "kill", "--name", lane_b, "--force", "--json"]])
          expect(calls("git", "branch")).to eq([["git", "branch", "-D", branch_a], ["git", "branch", "-D", branch_b]])
          expect(calls("git", "update-ref", "-d")).to eq([["git", "update-ref", "-d", "refs/demo-calc2/acceptance/s1"]])
        end

        it "deregisters the id and ends on one LOOP DONE line" do
          full.call
          expect(live_registry.entries).to eq({})
          expect(out.string.lines.last).to eq("LOOP DONE: series s1 stopped reason=timeout\n")
          expect(out.string.scan("LOOP DONE").size).to eq(1)
        end
      end

      context "when the registry becomes unreadable during the run" do
        let(:run_output) { ["LOOP DONE: stopped reason=timeout\n", 3] }
        let(:run_logged) do
          lambda do |argv, chdir:, log:|
            File.write(File.join(registry_dir, "series.json"), "not json")
            files[log] = run_output[0]
            run_output[1]
          end
        end

        it "still returns 3, saves, copies, kills nothing it cannot prove is its own and ends on one LOOP DONE line" do
          expect(full.call).to eq(3)
          expect(err.string).to include("is not valid JSON")
          expect(copies.size).to eq(1)
          expect(calls("workspace", "kill")).to be_empty
          expect(out.string.scan("LOOP DONE").size).to eq(1)
        end
      end

      context "when the stop reason spans several lines" do
        it "keeps the first line, stripped" do
          exec.on(%w[workspace start calc2-demo-s1-b], -> { raise "  first line \nsecond line" })
          expect(full.call).to eq(3)
          expect(out.string.lines.last).to eq("LOOP DONE: series s1 stopped reason=first line\n")
        end
      end

      context "when eval fails" do
        before { exec.on(["/wt/a/script/demo-calculator2", "eval"], "", false) }

        it "reports it, still saves the rest and still copies run.json and driver.log" do
          expect(full.call).to eq(0)
          expect(err.string).to include("eval failed")
          expect(files.keys).to include("#{run_dir}/attempts-wr_1.json", "#{run_dir}/command.txt")
          expect(files.keys).not_to include("#{run_dir}/eval.txt")
          expect(copies).to eq([[run_dir, "/repo/tmp/demo-calculator2/series/s1"]])
          expect(files["#{run_dir}/run.json"]).not_to be_nil
          expect(files["#{run_dir}/driver.log"]).to include("LOOP DONE")
          expect(calls("workspace", "kill").size).to eq(2)
        end
      end

      context "when an evidence command fails" do
        before { exec.on(%w[workspace work-queue history list], "", false) }

        it "reports it and goes on with the rest" do
          full.call
          expect(err.string).to include("work-queue history of #{lane_a} failed")
          expect(files.keys).to include("#{run_dir}/trace-wr_fork.json", "#{run_dir}/command.txt")
        end
      end

      context "when the copy fails" do
        let(:full) do
          described_class.new(root: root, options: options, exec: exec, registry: live_registry, out: out, err: err,
            read_file: ->(path) { files[path] }, path_exists: ->(path) { existing.include?(path) }, readable_dir: ->(path) { !unreadable.include?(path) }, realpath: realpath,
            write_file: ->(path, text) { written[path] = text }, run_logged: run_logged, sleeper: ->(_) {}, copy_dir: ->(*) { raise Errno::ENOSPC })
        end

        it "kills nothing and keeps the id registered" do
          full.call
          expect(calls("workspace", "kill")).to be_empty
          expect(calls("git", "branch")).to be_empty
          expect(live_registry.entries).to have_key("s1")
          expect(err.string).to include("the evidence was not copied")
          expect(out.string.lines.last).to start_with("LOOP DONE: series s1")
        end
      end

      context "with --evidence-dir" do
        let(:extra_args) { ["--evidence-dir", "/elsewhere/s1"] }

        it "copies there" do
          full.call
          expect(copies).to eq([[run_dir, "/elsewhere/s1"]])
        end
      end

      context "with --keep" do
        let(:extra_args) { ["--keep"] }

        it "kills nothing, deletes nothing, keeps the id and still saves the evidence" do
          expect(full.call).to eq(0)
          expect(calls("workspace", "kill")).to be_empty
          expect(calls("git", "branch")).to be_empty
          expect(calls("git", "update-ref")).to be_empty
          expect(copies).to be_empty
          expect(live_registry.entries).to have_key("s1")
          expect(files.keys).to include("#{run_dir}/eval.txt")
          expect(out.string).to include("the id stays registered")
          expect(out.string.lines.last).to start_with("LOOP DONE: series s1 wall=1m")
        end
      end

      context "when run.json names a workspace or branch this series did not record" do
        let(:run_json) { super().merge("branch" => "calc-demo/20260101T000000Z-other").tap { |doc| doc["lanes"] = doc["lanes"].merge("a" => {"workspace" => "workspace.worktree-calc2-demo-other"}) } }

        it "refuses the kill and the branch delete, and goes on" do
          full.call
          expect(err.string).to include("workspace.worktree-calc2-demo-other is not in series s1's registry entry")
          expect(err.string).to include("calc-demo/20260101T000000Z-other is not a calc-demo/<stamp>-s1[-b] branch of this series")
          expect(calls("workspace", "kill").map { |argv| argv[3] }).to eq([lane_a, lane_b])
          expect(calls("git", "branch")).to eq([["git", "branch", "-D", branch_b]])
        end
      end

      context "when a branch could not be pinned" do
        before { exec.on(["git", "update-ref", "refs/demo-calc2-runs/s1-b"], "", false) }

        it "does not delete that branch" do
          full.call
          expect(calls("git", "branch")).to eq([["git", "branch", "-D", branch_a]])
        end
      end

      describe "the undo of the shared values" do
        let(:exclude) { "/runs/s1/" }

        it "always removes its own exclude line" do
          files["/repo/.git/info/exclude"] = "mine\n"
          DemoCalculator2::SeriesRegistry.new(registry_dir, pid: 1, host: "h").register("other")
          full.call
          expect(files["/repo/.git/info/exclude"]).to eq("mine\n")
        end

        it "leaves the attributes line, the driver config and the sources entry while another id is registered" do
          DemoCalculator2::SeriesRegistry.new(registry_dir, pid: 1, host: "h").register("other")
          full.call
          expect(files["/repo/.git/info/attributes"]).to eq("#{described_class::ATTRIBUTES_LINE}\n")
          expect(calls("git", "config", "--local", "--unset")).to be_empty
          expect(calls("workspace", "config", "unset")).to be_empty
          expect(calls("workspace", "config", "set", "workflows.sources").size).to eq(1)
          expect(live_registry.entries.keys).to eq(["other"])
        end

        it "removes the registry-added values when it is the last id" do
          full.call
          expect(files["/repo/.git/info/attributes"]).to eq("")
          expect(calls("git", "config", "--local", "--unset").map(&:last)).to contain_exactly("merge.calc-demo-tests.driver", "merge.calc-demo-tests.name")
          expect(calls("workspace", "config", "unset")).to eq([%w[workspace config unset workflows.sources]])
          expect(live_registry.shared).to eq({})
        end

        context "when lane A's run added its own checkout's sources entry" do
          let(:lane_entry) { "/wt/a/demo/calculator2/workflows" }

          # The effective list after every set and unset so far, plus the entry the run's own configure appends.
          def live_list
            ran = exec.calls.index { |argv| argv.first == "run" }
            last = exec.calls.rindex { |argv| [%w[workspace config set workflows.sources], %w[workspace config unset workflows.sources]].include?(argv.first(4)) }
            list = (last && exec.calls[last][2] == "set") ? exec.calls[last][4].split(",") : []
            list += [lane_entry] if ran && (last.nil? || last < ran)
            list
          end

          before do
            exec.on(%w[workspace config set workflows.sources], "")
            exec.on(%w[workspace config show], -> { {"keys" => [{"key" => "workflows.sources", "effective" => live_list}]}.to_json })
          end

          it "drops it with the rest when it is the last id" do
            full.call
            expect(live_list).to eq([])
          end

          it "drops it while another id is registered, leaving the shared entry" do
            DemoCalculator2::SeriesRegistry.new(registry_dir, pid: 1, host: "h").register("other")
            full.call
            expect(live_list).to eq([sources])
          end

          context "with a trailing slash" do
            let(:lane_entry) { "/wt/a/demo/calculator2/workflows/" }

            it "still drops it" do
              full.call
              expect(live_list).to eq([])
            end
          end
        end

        it "drops only its own entry from a longer sources list" do
          exec.on(%w[workspace config show], -> { {"keys" => [{"key" => "workflows.sources", "effective" => ["/other/demo/calculator2/workflows", sources]}]}.to_json })
          exec.on(%w[workspace config show], -> { {"keys" => [{"key" => "workflows.sources", "effective" => (sources_now.empty? ? [] : ["/other/demo/calculator2/workflows", sources])}]}.to_json })
          full.call
          expect(calls("workspace", "config", "set", "workflows.sources").last).to eq(%w[workspace config set workflows.sources /other/demo/calculator2/workflows])
        end

        context "when it replaced a driver whose checkout is gone" do
          before { exec.on(%w[git config --local --get merge.calc-demo-tests.driver], absolute_driver("/gone")) }

          it "unsets the driver" do
            full.call
            expect(calls("git", "config", "--local", "--unset").map(&:last)).to include("merge.calc-demo-tests.driver")
            expect(calls("git", "config", "--local", "merge.calc-demo-tests.driver", absolute_driver("/gone"))).to be_empty
          end
        end

        context "when it took over a driver whose checkout exists" do
          let(:take_over) { true }

          before { exec.on(%w[git config --local --get merge.calc-demo-tests.driver], absolute_driver("/live")) }

          it "restores the old driver" do
            full.call
            expect(calls("git", "config", "--local", "merge.calc-demo-tests.driver").last).to eq(["git", "config", "--local", "merge.calc-demo-tests.driver", absolute_driver("/live")])
            expect(calls("git", "config", "--local", "--unset").map(&:last)).not_to include("merge.calc-demo-tests.driver")
          end
        end

        context "when the attributes line and the driver were already there" do
          before do
            files["/repo/.git/info/attributes"] = "#{described_class::ATTRIBUTES_LINE}\n"
            exec.on(%w[git config --local --get merge.calc-demo-tests.driver], wanted_driver)
          end

          it "leaves them" do
            full.call
            expect(files["/repo/.git/info/attributes"]).to eq("#{described_class::ATTRIBUTES_LINE}\n")
            expect(calls("git", "config", "--local", "--unset").map(&:last)).to eq(["merge.calc-demo-tests.name"])
          end
        end
      end

      describe "the scoreboard" do
        let(:columns) { ["id", "git sha (base)", "date (UTC)", "wall (series)", "01", "02", "03", "04", "05", "06", "07", "first_pass", "items", "cost", "leaks", "nudges", "failure class(es)", "evidence"] }

        def cells(row) = row.chomp.delete_prefix("| ").delete_suffix(" |").split(" | ")

        it "prints a Markdown row when no file is given" do
          full.call
          row = out.string.lines.find { |line| line.start_with?("| s1 ") }
          expect(cells(row).size).to eq(columns.size)
          expect(cells(row)).to eq(["s1", "aaa", "2026-01-01 00:00", "10m00s", "1m00s", "2m00s", "3m00s", "4m00s", "5m00s", "6m00s", "7m00s",
            "yes (7/7 goals; integration yes)", "7/7", "≈$4.50", "0 confirmed", "?", "concurrent=0", "/repo/tmp/demo-calculator2/series/s1"])
        end

        context "with --scoreboard and another series running" do
          let(:extra_args) { ["--scoreboard", "board.md"] }

          it "appends one row to the file with the concurrent count" do
            files["/repo/board.md"] = "| header |\n"
            DemoCalculator2::SeriesRegistry.new(registry_dir, pid: 1, host: "h").register("other")
            full.call
            lines = files["/repo/board.md"].lines
            expect(lines.first).to eq("| header |\n")
            expect(cells(lines.last)).to include("s1", "concurrent=1")
            expect(out.string).not_to include("| s1 ")
          end
        end

        it "builds the row from fixture documents" do
          row = described_class.scoreboard_row(eval_json, run_json, concurrent: 2, id: "w9", evidence: "e/w9")
          expect(cells(row)).to include("w9", "concurrent=2", "e/w9", "yes (7/7 goals; integration yes)")
        end

        it "says no when integration did not pass first time, and marks a partial cost" do
          doc = eval_json.merge("totals" => eval_json["totals"].merge("partial" => ["cost_usd"]), "lanes" => {"wall" => 60.0, "integration" => {"first_pass" => false}})
          expect(cells(described_class.scoreboard_row(doc, run_json, concurrent: 0))).to include("no (7/7 goals; integration no)", "≥$4.50")
        end

        it "does not call an unreadable transcript a zero" do
          leaks = lambda do |transcript|
            cells(described_class.scoreboard_row(eval_json.merge("leak" => {"hook" => 1, "transcript" => transcript}), run_json, concurrent: 0))[14]
          end
          expect(leaks.call({"/a" => 2, "/b" => nil})).to eq("3 confirmed (1 of 2 unreadable)")
          expect(leaks.call({"/a" => nil})).to eq("?")
          expect(leaks.call({})).to eq("1 confirmed")
        end

        it "uses ? for everything eval and run.json do not have" do
          row = cells(described_class.scoreboard_row(nil, nil, concurrent: 0))
          expect(row.size).to eq(columns.size)
          expect(row.values_at(0, 1, 2, 3, 4, 10, 11, 12, 13, 14, 15, 17)).to eq(["?"] * 5 + ["?", "? (? goals; integration ?)", "?", "?", "?", "?", "?"])
          expect(row[16]).to eq("concurrent=0")
        end
      end

      describe "--forget" do
        let(:options) { described_class.parse(%w[--forget s1]) }
        let(:alive) { false }
        let(:live_registry) { DemoCalculator2::SeriesRegistry.new(registry_dir, alive: ->(*) { alive }) }

        before do
          live_registry.register("s1", workspaces: [lane_a, lane_b])
          exec.on(%w[git worktree list], "worktree /repo\n\nworktree /wt/a/../a\n".sub("/wt/a/../a", "/x/.worktrees/calc2-demo-s1"))
          files["/x/.worktrees/calc2-demo-s1/runs/s1/run.json"] = JSON.generate(run_json)
          existing << "/x/.worktrees/calc2-demo-s1/runs/s1"
        end

        it "drops the lane sources entry the crashed series recorded" do
          lane_entry = "/x/.worktrees/calc2-demo-s1/demo/calculator2/workflows"
          live_registry.record("s1", sources: [lane_entry])
          exec.on(%w[workspace config set workflows.sources], "")
          exec.on(%w[workspace config show], -> {
            dropped = exec.calls.any? { |argv| [%w[workspace config set workflows.sources], %w[workspace config unset workflows.sources]].include?(argv.first(4)) }
            {"keys" => [{"key" => "workflows.sources", "effective" => dropped ? [] : [lane_entry]}]}.to_json
          })
          expect(full.call).to eq(0)
          expect(calls("workspace", "config", "unset")).to eq([%w[workspace config unset workflows.sources]])
          expect(live_registry.entries).to be_empty
        end

        context "when the series' process is still alive" do
          let(:alive) { true }

          it "refuses with exit 1 and touches nothing" do
            expect(full.call).to eq(1)
            expect(err.string).to include("series s1 is still running")
            expect(calls("workspace", "kill")).to be_empty
            expect(live_registry.entries).to have_key("s1")
            expect(out.string).not_to include("LOOP DONE")
          end
        end

        it "adds no scoreboard row and says so" do
          forgetting = described_class.new(root: root, options: described_class.parse(%w[--forget s1 --scoreboard board.md]), exec: exec, registry: live_registry, out: out, err: err,
            read_file: ->(path) { files[path] }, path_exists: ->(path) { existing.include?(path) }, readable_dir: ->(path) { !unreadable.include?(path) }, write_file: ->(path, text) { files[path] = text }, copy_dir: ->(*) {})
          expect(forgetting.call).to eq(0)
          expect(files).not_to have_key("/repo/board.md")
          expect(out.string).not_to include("| s1 ")
          expect(out.string.lines.last).to include("no scoreboard row")
        end

        it "runs steps 8 and 9 for the registered entry and returns 0" do
          expect(full.call).to eq(0)
          expect(calls("workspace", "kill").map { |argv| argv[3] }).to eq([lane_a, lane_b])
          expect(calls("workspace", "work-queue")).to be_empty
          expect(copies.first.first).to eq("/x/.worktrees/calc2-demo-s1/runs/s1")
          expect(live_registry.entries).to eq({})
          expect(out.string.lines.last).to start_with("LOOP DONE: series s1 stopped reason=forgotten")
        end

        it "refuses an id that is not registered" do
          live_registry.remove("s1")
          expect(full.call).to eq(1)
          expect(err.string).to include("s1 is not in the series registry")
        end
      end
    end
    describe "the values it writes, against Lanes" do
      let(:root) { dir }
      let(:common) { File.join(dir, ".git") }
      let(:store_class) do
        Class.new do
          attr_reader :writes

          def initialize(inner)
            @inner = inner
            @live = {}
            @writes = []
          end

          def call(argv, **opts)
            return @inner.call(argv, **opts) unless argv.first(3) == %w[git config --local]
            if argv[3] == "--get"
              value = @live[argv[4]]
              [value ? "#{value}\n" : "", !value.nil?]
            else
              @writes << argv
              @live[argv[3]] = argv[4]
              ["", true]
            end
          end
        end
      end

      it "leaves a later Lanes#write_attributes and #write_out_exclude nothing to write" do
        exec.on(%w[git rev-parse --git-common-dir], "#{common}\n")
        store = store_class.new(exec)
        series = described_class.new(root: dir, options: options, exec: store, registry: live_registry, out: out, err: err,
          run_logged: run_logged, sleeper: ->(_) {}, read_file: ->(path) { files[path] || (File.file?(path) ? File.read(path) : nil) })
        expect(series.call).to eq(0)
        after_series = %w[attributes exclude].to_h { |name| [name, File.read(File.join(common, "info", name))] }
        written_config = store.writes.dup
        expect(written_config.map { |argv| argv[3] }).to contain_exactly("merge.calc-demo-tests.name", "merge.calc-demo-tests.driver")

        lanes = DemoCalculator2::Lanes.new(root: dir, workspace: "ws", lane_b: "ws-b", name: "ws", out_dir: "runs/s1", exec: store, out: StringIO.new, err: StringIO.new)
        lanes.write_attributes
        lanes.write_out_exclude(nil)

        expect(store.writes).to eq(written_config)
        expect(%w[attributes exclude].to_h { |name| [name, File.read(File.join(common, "info", name))] }).to eq(after_series)
      end

      it "uses the one constant for each value" do
        expect(described_class::ATTRIBUTES_LINE).to equal(DemoCalculator2::SharedValues::ATTRIBUTES_LINE)
        expect(DemoCalculator2::Lanes::ATTRIBUTES_LINE).to equal(DemoCalculator2::SharedValues::ATTRIBUTES_LINE)
        expect(described_class::NAME_VALUE).to equal(DemoCalculator2::SharedValues::NAME_VALUE)
      end
    end
  end

  describe DemoCalculator2::Series::RealExec do
    it "answers stdout and success, keeping stderr apart" do
      exec = described_class.new
      allow(Open3).to receive(:capture3).with("workspace", "x", chdir: "/r").and_return(["{}", "a note", instance_double(Process::Status, success?: true)])
      expect(exec.call(%w[workspace x], chdir: "/r")).to eq(["{}", true])
      expect(exec.last_stderr).to eq("a note")
    end

    it "answers a failure for a program that cannot start" do
      exec = described_class.new
      allow(Open3).to receive(:capture3).and_raise(Errno::ENOENT)
      expect(exec.call(%w[nope], chdir: "/r")).to eq(["", false])
    end
  end
end
