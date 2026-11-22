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

  let(:dry_series) do
    described_class.new(root: root, options: described_class.parse(["--id", id, "--base", base, "--dry-run"]), exec: exec, registry: registry, out: out, err: err,
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

  describe "a full run (steps 2 to 6)" do
    let(:live_registry) { DemoCalculator2::SeriesRegistry.new(registry_dir, alive: ->(*) { true }) }
    let(:written) { {} }
    let(:sleeps) { [] }
    let(:now) { [0] }
    let(:options) { described_class.parse(["--id", id, "--base", base, *("--take-over" if take_over), *extra_args]) }
    let(:extra_args) { [] }
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
        read_file: ->(path) { files[path] }, path_exists: ->(path) { existing.include?(path) },
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
        read_file: ->(path) { files[path] }, path_exists: ->(path) { existing.include?(path) }, run_logged: run_logged,
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
      let(:extra_args) { ["--sonnet"] }

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
          read_file: ->(path) { files[path] }, path_exists: ->(path) { existing.include?(path) }, write_file: ->(path, text) { written[path] = text }, run_logged: run_logged, sleeper: ->(_) {})
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
        expect(written).to be_empty
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
          expect(written).to be_empty
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
        expect(calls(*runs.first[:argv].first(1))).to be_empty
      end

      it "runs lane A's script from its worktree with the lane, id, out and wait arguments, and keeps the log" do
        full.call
        run = runs.first
        expect(run[:chdir]).to eq("/wt/a")
        expect(run[:log]).to eq("/wt/a/runs/s1/driver.log")
        expect(run[:argv]).to eq(["/wt/a/script/demo-calculator2", "run", "--lanes", "--lane-b", lane_b, "--id", "s1", "--wait", "--out", "runs/s1", "--workflow", "deliver-goal-fast"])
        expect(files["/wt/a/runs/s1/driver.log"]).to include("LOOP DONE")
      end

      it "leaves --workflow out for the script's own default" do
        series = described_class.new(root: root, options: described_class.parse(%w[--id s1 --workflow deliver-goal]), exec: exec, registry: live_registry, out: out, err: err,
          read_file: ->(path) { files[path] }, path_exists: ->(path) { existing.include?(path) }, write_file: ->(path, text) { written[path] = text }, run_logged: run_logged, sleeper: ->(_) {})
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
