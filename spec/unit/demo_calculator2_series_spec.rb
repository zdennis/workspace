require "spec_helper"
require "digest"
require "json"
require "stringio"
require "tmpdir"

require File.join(PROJECT_ROOT, "script", "demo_calculator2", "series")

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
  let(:wanted_driver) { DemoCalculator2::SharedValues::DRIVER_COMMAND }
  let(:exec) do
    SeriesExecFake.new
      .on(%w[git show-ref], "", false)
      .on(%w[git worktree list], "worktree /repo\nHEAD abc\n\n")
      .on(%w[workspace list], ["workspace"].to_json)
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
      read_file: ->(path) { files[path] }, path_exists: ->(path) { existing.include?(path) })
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
      exec.on(%w[workspace list], ["workspace.worktree-calc2-demo-s1-b"].to_json)
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
      other = described_class.new(root: root, options: described_class.parse(%w[--id s1 --take-over]), exec: exec, registry: registry, read_file: ->(path) { files[path] }, path_exists: ->(_) { true })
      expect { other.preflight }.to raise_error(described_class::Refused, /owning checkout is unknown/)
    end

    it "matches a going run's worktree to the owner through realpath" do
      real = Dir.mktmpdir("owner", dir)
      link = File.join(dir, "link")
      File.symlink(real, link)
      exec.on(%w[git config --local --get merge.calc-demo-tests.driver], absolute_driver(link) + "\n")
      runs << {"id" => "wr_9", "workflow" => "deliver-goal", "workspace" => "w03", "state" => "running", "worktree" => File.realpath(real)}
      takeover = described_class.new(root: root, options: described_class.parse(%w[--id s1 --take-over]), exec: exec, registry: registry, path_exists: ->(_) { true })
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

  describe "#call" do
    it "prints the report and returns 0 on a clean preflight" do
      expect(series.call).to eq(0)
      expect(out.string).to include("preflight ok", "would add git-config:merge.calc-demo-tests.driver", "exclude:/runs/s1/")
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
        read_file: ->(path) { files[path] }, path_exists: ->(path) { existing.include?(path) })
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
end
