require "spec_helper"
require "tmpdir"
require "json"
require "stringio"
require "shellwords"

load File.join(PROJECT_ROOT, "script", "demo-calculator2")

# The fork and the integrate decision of `run --lanes`, over a scripted `exec`: nothing here starts git or `workspace`.
RSpec.describe DemoCalculator2::Lanes do
  let(:tmp) { Dir.mktmpdir }
  let(:record_path) { File.join(tmp, "run.json") }
  let(:out) { StringIO.new }
  let(:err) { StringIO.new }
  let(:calls) { [] }
  let(:slept) { [] }
  let(:rules) { [] }
  let(:now) { [Time.utc(2026, 11, 21, 5, 24, 0)] }
  let(:clock) { -> { now[0] += 10 } }
  let(:branch) { "calc-demo/20261121T050000Z-b" }
  let(:sha) { "f" * 40 }
  let(:base) { "a" * 40 }
  let(:queue_state) { {"state" => "on", "daemon_running" => true, "items" => []} }
  let(:exec) do
    lambda do |argv, chdir:|
      calls << argv
      _, answer = rules.find { |prefix, _| argv.size >= prefix.size && prefix.each_with_index.all? { |part, index| part === argv[index] } }
      raise "unscripted command: #{argv.inspect}" unless answer
      answer.is_a?(Proc) ? answer.call(argv) : answer
    end
  end
  let(:lanes) do
    described_class.new(root: tmp, workspace: "ws-bin", lane_b: "ws-b", name: "ws", workflow: "deliver-goal-fast", out: out, err: err, clock: clock,
      sleeper: ->(seconds) { slept << seconds }, exec: exec, held_limit: 0, timeout: 10**9)
  end

  before do
    File.write(record_path, JSON.generate(record))
    on("git", "rev-parse", "HEAD") { ["integrated\n", true] }
    on("ws-bin", "workflow", "attempts") { [JSON.generate("attempts" => [{"started_at" => "2026-11-21T05:00:30Z"}]), true] }
    on("ws-bin", "capabilities") { [JSON.generate("features" => {"work_queue" => 2}), true] }
    on("ws-bin", "work-queue", "list") { [JSON.generate("queues" => [queue_state]), true] }
    on("ws-bin", "work-queue", "history") { |argv| [JSON.generate("entries" => history[argv.last]), true] }
  end

  after { FileUtils.rm_rf(tmp) }

  def on(*prefix, out: "", ok: true, &block)
    rules.unshift([prefix, block || [out, ok]])
  end

  def record
    items = %w[a1 a2 a3 a4 a5].map { |id| {"workflow" => "deliver-goal-fast", "id" => id} }
    {"stamp" => "20261121T050000Z", "branch" => "calc-demo/20261121T050000Z", "goals" => DemoCalculator2::LANES[:a], "items" => items,
     "acceptance_ref" => {"name" => DemoCalculator2::ACCEPTANCE_REF, "sha" => base, "removal_sha" => "r" * 40},
     "lanes" => {"workflow" => "deliver-goal-fast", "started_at" => "2026-11-21T05:00:00Z", "fork_after" => "03-div-zero",
                 "a" => {"workspace" => "ws", "goals" => DemoCalculator2::LANES[:a]},
                 "b" => {"workspace" => "ws-b", "path" => "/lane-b", "branch" => branch, "goals" => %w[06-json 07-repl], "items" => []}}}
  end

  def saved = JSON.parse(File.read(record_path))

  def history = @history ||= {"ws" => [], "ws-b" => []}

  def finished(*ids, lane: "ws", outcome: "succeeded")
    ids.each { |id| history[lane] << {"id" => id, "outcome" => outcome, "result" => {"run_id" => "run-#{id}"}} }
  end

  describe "#fork_check!" do
    def script_fork(head: sha, ref: base, checkout: true, ancestor: true, ref_found: true)
      on("git", "checkout", "-B", branch, sha) { ["", checkout] }
      on("git", "rev-parse", "HEAD") { ["#{head}\n", true] }
      on("git", "rev-parse", DemoCalculator2::ACCEPTANCE_REF) { ["#{ref}\n", ref_found] }
      on("git", "merge-base", "--is-ancestor", DemoCalculator2::ACCEPTANCE_REF, sha) { ["", ancestor] }
    end

    it "checks lane B out at the fork sha, then checks HEAD, the acceptance ref and its ancestry in lane B" do
      script_fork
      expect { lanes.fork_check!("/lane-b", branch, sha, base) }.not_to raise_error
      expect(calls.first).to eq(["git", "checkout", "-B", branch, sha])
      expect(calls.map { |argv| argv[1] }).to eq(%w[checkout rev-parse rev-parse merge-base])
    end

    it "stops the run when the checkout fails" do
      script_fork(checkout: false)
      expect { lanes.fork_check!("/lane-b", branch, sha, base) }.to raise_error(DemoCalculator2::ForkCheckFailed, /checkout -B .* failed/)
    end

    it "refuses when lane B's HEAD is not the fork sha" do
      script_fork(head: "e" * 40)
      expect { lanes.fork_check!("/lane-b", branch, sha, base) }.to raise_error(DemoCalculator2::ForkCheckFailed, /HEAD is eeeeeeeeeeee, not the fork point ffffffffffff/)
    end

    it "refuses when lane B cannot see the acceptance base ref" do
      script_fork(ref_found: false)
      expect { lanes.fork_check!("/lane-b", branch, sha, base) }.to raise_error(DemoCalculator2::ForkCheckFailed, /cannot see refs\/demo-calc2\/acceptance-base/)
    end

    it "refuses when the acceptance base ref is not the sha lane A's run recorded" do
      script_fork(ref: "9" * 40)
      expect { lanes.fork_check!("/lane-b", branch, sha, base) }.to raise_error(DemoCalculator2::ForkCheckFailed, /999999999999 in lane B, not aaaaaaaaaaaa/)
    end

    it "refuses when the acceptance base is not an ancestor of the fork sha" do
      script_fork(ancestor: false)
      expect { lanes.fork_check!("/lane-b", branch, sha, base) }.to raise_error(DemoCalculator2::ForkCheckFailed, /not an ancestor of the fork point/)
    end
  end

  describe "#wait_run: the fork" do
    before do
      on("ws-bin", "workflow", "attempts", "run-a3") do
        [JSON.generate("attempts" => [{"step" => "implement", "head" => {"before" => "1" * 40, "after" => "2" * 40}},
          {"step" => "acceptance", "head" => {"before" => sha, "after" => nil}}]), true]
      end
      on("git", "rev-parse", "--verify") { |argv| [argv.last.sub("^{commit}", "") + "\n", true] }
      on("git", "checkout", "-B", branch, "2" * 40) { ["", true] }
      on("git", "rev-parse", "HEAD") { ["#{"2" * 40}\n", true] }
      on("git", "rev-parse", DemoCalculator2::ACCEPTANCE_REF) { ["#{base}\n", true] }
      on("git", "merge-base", "--is-ancestor") { ["", true] }
      on("ws-bin", "config", "set") { ["", true] }
      on("ws-bin", "work-queue", "add") { |argv| [JSON.generate("results" => [{"id" => "b-#{argv[argv.index("--dedupe-key") + 1][/\d\d/]}"}]), true] }
      on("ws-bin", "work-queue", "enable") { ["", true] }
      on("ws-bin", "work-queue", "advance") { ["", true] }
      on("git", "merge") { ["", true] }
      on("sh", "-c") { ["", true] }
      on(/acceptance_runner\z/) { ["", true] }
    end

    it "forks lane B at the head the fork goal's run ended on, not at lane A's HEAD, then queues 06 and 07 with lane B's prompt" do
      finished("a1", "a2", "a3")
      lanes.wait_run(record_path)
      expect(calls).to include(["git", "checkout", "-B", branch, "2" * 40])
      expect(calls.index(["git", "checkout", "-B", branch, "2" * 40])).to be < calls.index { |argv| argv[1, 2] == %w[work-queue add] }
      expect(calls).to include(%w[ws-bin config set --scope workspace --name ws-b commands.test] + ["ruby demo/calculator2/test/calc_test.rb"],
        %w[ws-bin config set --scope workspace --name ws-b commands.lint] + ["bundle exec standardrb demo/calculator2"],
        %w[ws-bin work-queue enable --name ws-b], %w[ws-bin work-queue advance --name ws-b])
      adds = calls.select { |argv| argv[1, 2] == %w[work-queue add] }.select { |argv| argv.include?("--name") && argv.last == "ws-b" }
      expect(adds.map { |argv| argv[argv.index("--dedupe-key") + 1] }).to eq(%w[calculator2-demo:06-json calculator2-demo:07-repl])
      expect(adds.map { |argv| argv[argv.index("--prompt") + 1] }).to all(include("Earlier goals here means 01, 02 and 03. This branch holds only their work; do not read or build goals 04 or 05."))
      expect(adds.flat_map { |argv| argv.each_cons(2).filter_map { |key, value| value if key == "--input" } }).to include("acceptance=script/demo_calculator2/acceptance_runner_lanes")
      expect(saved["fork"]).to include("sha" => "2" * 40, "acceptance_base" => base, "goal" => "03-div-zero", "item" => "a3")
      expect(saved["fork"]["at"]).to match(/\A2026-11-21T/)
      expect(saved.dig("lanes", "b", "items").map { |item| item["goal"] }).to eq(%w[06-json 07-repl])
    end

    it "keeps polling while the fork goal's item is unfinished, then forks" do
      finished("a1", "a2")
      queue_state["items"] = [{"id" => "a3", "state" => "active"}]
      polls = 0
      on("ws-bin", "work-queue", "history") do |argv|
        polls += 1
        entries = history[argv.last].dup
        entries << {"id" => "a3", "outcome" => "succeeded", "result" => {"run_id" => "run-a3"}} if argv.last == "ws" && polls > 1
        [JSON.generate("entries" => entries), true]
      end
      on("ws-bin", "work-queue", "list") { [JSON.generate("queues" => [(calls.any? { |argv| argv[1] == "checkout" }) ? {"state" => "on", "items" => []} : queue_state]), true] }
      lanes.wait_run(record_path)
      expect(slept).to eq([15])
      expect(calls).to include(["git", "checkout", "-B", branch, "2" * 40])
    end

    it "forks when the fork goal's item finishes between the history read and the queue read" do
      finished("a1", "a2")
      reads = 0
      on("ws-bin", "work-queue", "history") do |argv|
        reads += 1
        entries = history[argv.last].dup
        entries << {"id" => "a3", "outcome" => "succeeded", "result" => {"run_id" => "run-a3"}} if argv.last == "ws" && reads > 1
        [JSON.generate("entries" => entries), true]
      end
      on("ws-bin", "work-queue", "list") { [JSON.generate("queues" => [{"state" => "on", "items" => []}]), true] }
      lanes.wait_run(record_path)
      expect(calls).to include(["git", "checkout", "-B", branch, "2" * 40])
      expect(slept).to be_empty
    end

    it "stops with fork_check when lane A drains and the fork goal's item never shows in the history" do
      finished("a1", "a2")
      on("ws-bin", "work-queue", "list") { [JSON.generate("queues" => [{"state" => "on", "items" => []}]), true] }
      lanes.wait_run(record_path)
      expect(out.string).to include("LOOP DONE: stopped reason=fork_check item=a3")
      expect(err.string).to include("drained before the fork goal's item finished")
    end

    it "prints one LOOP DONE line with reason=error and exits non-zero when a workspace command fails mid-wait" do
      finished("a1", "a2")
      on("ws-bin", "work-queue", "list") { ["", false] }
      record = lanes.wait_run(record_path)
      expect(out.string.lines.grep(/\ALOOP DONE/)).to eq(["LOOP DONE: stopped reason=error\n"])
      expect(err.string).to include("work-queue list failed")
      expect(saved["wait"]).to include("reason" => "error")
      expect(DemoCalculator2.wait_exit(record, err)).to eq(3)
    end

    it "stops with fork_check, and queues nothing in lane B, when a fork check fails" do
      finished("a1", "a2", "a3")
      on("git", "rev-parse", DemoCalculator2::ACCEPTANCE_REF) { ["#{"9" * 40}\n", true] }
      record = lanes.wait_run(record_path)
      expect(out.string).to include("LOOP DONE: stopped reason=fork_check item=a3")
      expect(err.string).to include("not aaaaaaaaaaaa as lane A's run recorded")
      expect(calls.select { |argv| argv[1, 2] == %w[work-queue add] }).to be_empty
      expect(record["wait"]).to include("reason" => "fork_check", "item" => "a3")
      expect(DemoCalculator2.wait_exit(record, err)).to eq(3)
    end

    it "stops with fork_check when the fork goal's item did not succeed" do
      finished("a1", "a2")
      finished("a3", outcome: "failed")
      lanes.wait_run(record_path)
      expect(out.string).to include("LOOP DONE: stopped reason=fork_check item=a3")
      expect(calls).not_to include(a_collection_starting_with("git", "checkout"))
    end

    it "stops with the wait's own reason when a queue is held past the limit" do
      finished("a1", "a2")
      queue_state["items"] = [{"id" => "a3", "state" => "held"}]
      lanes.wait_run(record_path)
      expect(out.string).to include("LOOP DONE: stopped reason=held item=a3")
    end

    it "stops on the timeout" do
      finished("a1", "a2")
      queue_state["items"] = [{"id" => "a3", "state" => "active"}]
      limited = described_class.new(root: tmp, workspace: "ws-bin", lane_b: "ws-b", name: "ws", out: out, err: err, clock: clock, sleeper: ->(_) {}, exec: exec, timeout: 5)
      limited.wait_run(record_path)
      expect(out.string).to include("LOOP DONE: stopped reason=timeout")
    end

    it "ends a clean run with one LOOP DONE line that carries the wall, the integration and the items" do
      finished("a1", "a2", "a3", "a4", "a5")
      finished("b-06", "b-07", lane: "ws-b")
      lanes.wait_run(record_path)
      expect(out.string.lines.grep(/\ALOOP DONE/).size).to eq(1)
      expect(out.string).to match(/^LOOP DONE: wall=\d+m\d\ds integration=clean first_pass=true items=7\/7$/)
    end
  end

  describe "#integrate_run" do
    def with_fork
      data = record.merge("fork" => {"at" => "2026-11-21T05:10:00Z", "sha" => sha, "acceptance_base" => base, "goal" => "03-div-zero", "item" => "a3"})
      data["lanes"]["b"]["items"] = [{"workflow" => "deliver-goal-fast", "id" => "b1", "goal" => "06-json"}, {"workflow" => "deliver-goal-fast", "id" => "b2", "goal" => "07-repl"}]
      File.write(record_path, JSON.generate(data))
    end

    before do
      with_fork
      finished("a1", "a2", "a3", "a4", "a5")
      finished("b1", "b2", lane: "ws-b")
      on("sh", "-c") { ["", true] }
      on(/acceptance_runner\z/) { ["", true] }
      on("git", "merge", "--no-ff", "--no-edit", branch) { ["", true] }
      on("ws-bin", "work-queue", "add") { [JSON.generate("results" => [{"id" => "int1"}]), true] }
      on("ws-bin", "work-queue", "enable") { ["", true] }
      on("ws-bin", "work-queue", "advance") { ["", true] }
    end

    it "records first pass for a clean merge whose test, lint and plain 07-repl acceptance each pass once" do
      lanes.integrate_run(record_path)
      expect(saved["integration"]).to include("merge" => "clean", "conflict" => false, "first_pass" => true, "test" => true, "lint" => true, "acceptance" => true, "head" => "integrated")
      expect(saved["integration"]).not_to have_key("integrate_run")
      expect(calls.select { |argv| argv.first.to_s.end_with?("acceptance_runner") }).to eq([[File.join(tmp, "script/demo_calculator2/acceptance_runner"), "demo/calculator2/goals/07-repl.md"]])
      expect(calls.map { |argv| argv[1, 2] }).not_to include(%w[work-queue add])
      expect(out.string).to match(/^LOOP DONE: wall=\d+m\d\ds integration=clean first_pass=true items=7\/7$/)
    end

    it "aborts a conflicted merge, records no first pass and queues integrate-branch in lane A with the plain acceptance runner" do
      on("git", "merge", "--no-ff", "--no-edit", branch) { ["CONFLICT", false] }
      on("git", "rev-parse", "-q", "--verify", "MERGE_HEAD") { ["abc\n", true] }
      on("git", "merge", "--abort") { ["", true] }
      finished("int1")
      lanes.integrate_run(record_path)
      expect(calls).to include(%w[git merge --abort])
      expect(saved["integration"]).to include("merge" => "conflict", "conflict" => true, "first_pass" => false)
      expect(saved["integration"]["integrate_run"]).to include("item" => "int1", "passed" => true, "outcome" => "succeeded")
      expect(saved["integration"]).to include("repair_workflow" => "integrate-branch")
      queued = calls.find { |argv| argv[1, 4] == %w[work-queue add workflow integrate-branch] }
      expect(queued).to include("branch=#{branch}", "goal=demo/calculator2/goals/07-repl.md", "acceptance=script/demo_calculator2/acceptance_runner", "--name", "ws")
      expect(calls).not_to include(a_collection_starting_with("sh", "-c"))
      expect(out.string).to match(/^LOOP DONE: wall=\d+m\d\ds integration=integrate first_pass=false items=7\/7$/)
    end

    it "does not abort a merge that failed without a conflict, and still records first_pass false" do
      on("git", "merge", "--no-ff", "--no-edit", branch) { ["error: local changes", false] }
      on("git", "rev-parse", "-q", "--verify", "MERGE_HEAD") { ["", false] }
      finished("int1")
      lanes.integrate_run(record_path)
      expect(calls).not_to include(%w[git merge --abort])
      expect(saved["integration"]).to include("merge" => "failed", "conflict" => false, "first_pass" => false)
    end

    it "makes a failing acceptance run on a clean merge not a first pass, keeping the merge and queueing integrate-merged" do
      on(/acceptance_runner\z/) { ["", false] }
      finished("int1")
      lanes.integrate_run(record_path)
      expect(calls).not_to include(%w[git merge --abort])
      expect(saved["integration"]).to include("merge" => "clean", "first_pass" => false, "test" => true, "lint" => true, "acceptance" => false)
      expect(calls.any? { |argv| argv[1, 4] == %w[work-queue add workflow integrate-merged] }).to be(true)
      expect(calls.any? { |argv| argv[1, 4] == %w[work-queue add workflow integrate-branch] }).to be(false)
      expect(saved["integration"]).to include("repair_workflow" => "integrate-merged")
    end

    it "prints the failing command and the last 40 lines of its output before queueing integrate-merged" do
      output = (1..60).map { |n| "line #{n}\n" }.join
      on(/acceptance_runner\z/) { [output, false] }
      finished("int1")
      lanes.integrate_run(record_path)
      expect(out.string).to match(/first-pass check acceptance failed: .*acceptance_runner .*07-repl\.md/)
      expect(out.string).to include("line 21\n", "line 60\n")
      expect(out.string).not_to include("line 20\n")
      expect(out.string.index("first-pass check acceptance failed")).to be < out.string.index("+ workspace work-queue add workflow integrate-merged")
    end

    it "stops on the first failing check and runs no later one" do
      on("sh", "-c", "ruby demo/calculator2/test/calc_test.rb") { ["", false] }
      finished("int1")
      lanes.integrate_run(record_path)
      expect(saved["integration"]).to include("first_pass" => false, "test" => false)
      expect(saved["integration"]).not_to have_key("lint")
    end

    def write_calc_test(*names)
      path = File.join(tmp, "demo/calculator2/test/calc_test.rb")
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, names.map { |name| "  def #{name}\n  end\n" }.join("\n"))
    end

    it "makes a duplicated test method name not a first pass and runs no test command after it" do
      write_calc_test("test_add", "test_sub", "test_add")
      finished("int1")
      lanes.integrate_run(record_path)
      expect(saved["integration"]).to include("merge" => "clean", "first_pass" => false, "test_names" => {"ok" => false, "duplicates" => ["test_add"]})
      expect(saved["integration"]).not_to have_key("test")
      expect(calls).not_to include(a_collection_starting_with("sh", "-c"))
      expect(calls.none? { |argv| argv.first.to_s.end_with?("acceptance_runner") }).to be(true)
      expect(out.string).to include("first-pass check test_names failed", "test_add")
    end

    it "records a clean test-name scan and goes on to the test command" do
      write_calc_test("test_add", "test_sub")
      lanes.integrate_run(record_path)
      expect(saved["integration"]).to include("first_pass" => true, "test_names" => {"ok" => true, "duplicates" => []}, "test" => true)
    end

    it "records a repair that did not pass apart from the first pass, and stops when integrate-branch is held" do
      on("git", "merge", "--no-ff", "--no-edit", branch) { ["CONFLICT", false] }
      on("git", "rev-parse", "-q", "--verify", "MERGE_HEAD") { ["abc\n", true] }
      on("git", "merge", "--abort") { ["", true] }
      queue_state["items"] = [{"id" => "int1", "state" => "held"}]
      record = lanes.integrate_run(record_path)
      expect(out.string).to include("LOOP DONE: stopped reason=held item=int1")
      expect(record["integration"]["integrate_run"]).to include("passed" => false)
      expect(record["integration"]["first_pass"]).to be(false)
    end

    it "stops with integrate_failed, names the failed item and exits non-zero when the repair run did not succeed" do
      on("git", "merge", "--no-ff", "--no-edit", branch) { ["CONFLICT", false] }
      on("git", "rev-parse", "-q", "--verify", "MERGE_HEAD") { ["abc\n", true] }
      on("git", "merge", "--abort") { ["", true] }
      finished("int1", outcome: "failed")
      record = lanes.integrate_run(record_path)
      expect(out.string.lines.grep(/\ALOOP DONE/)).to eq(["LOOP DONE: stopped reason=integrate_failed item=int1\n"])
      expect(record["wait"]).to include("reason" => "integrate_failed", "failed_item" => "int1")
      expect(DemoCalculator2.wait_exit(record, err)).to eq(3)
    end

    it "measures the closing line's wall from the start of lane A's first item, not from the harness start" do
      lanes.integrate_run(record_path)
      wall = out.string[/wall=(\d+)m(\d+)s/].then { |text| text.scan(/\d+/).then { |m, s| (m.to_i * 60) + s.to_i } }
      expect(wall).to be < Time.utc(2026, 11, 21, 5, 25, 0) - Time.utc(2026, 11, 21, 5, 0, 30)
      expect(wall).to be > Time.utc(2026, 11, 21, 5, 24, 0) - Time.utc(2026, 11, 21, 5, 0, 30) - 1
    end

    it "refuses a record that has no fork" do
      File.write(record_path, JSON.generate(record))
      expect { lanes.integrate_run(record_path) }.to raise_error(DemoCalculator::Refused, /has not forked/)
    end
  end

  describe "#write_out_exclude" do
    let(:common) { File.join(tmp, "common") }
    let(:record_path) { File.join(tmp, "runs", "w01", "run.json").tap { |path| FileUtils.mkdir_p(File.dirname(path)) } }
    let(:out_lanes) { lanes }
    let(:exclude_path) { File.join(common, "info", "exclude") }

    before do
      on("git", "rev-parse", "--git-common-dir") { ["#{common}\n", true] }
    end

    it "adds an anchored line for the out directory once and records it in run.json" do
      2.times { out_lanes.write_out_exclude(record_path) }
      expect(File.read(exclude_path)).to eq("/runs/w01/\n")
      expect(saved["out_exclude"]).to eq("path" => exclude_path, "line" => "/runs/w01/")
      expect(saved["lanes"]).to eq(JSON.parse(JSON.generate(record["lanes"])))
    end

    it "writes nothing when the out directory is outside the checkout" do
      elsewhere = Dir.mktmpdir
      outside = File.join(elsewhere, "run.json")
      File.write(outside, JSON.generate(record))
      out_lanes.write_out_exclude(outside)
      expect(File.exist?(exclude_path)).to be(false)
      expect(JSON.parse(File.read(outside))).not_to have_key("out_exclude")
    ensure
      FileUtils.rm_rf(elsewhere)
    end
  end

  describe "#write_attributes" do
    let(:dir) { File.join(tmp, "common") }
    let(:driver) { "ruby #{Shellwords.escape(described_class::DRIVER_SCRIPT)} %O %A %B" }

    before do
      on("git", "rev-parse", "--git-common-dir") { ["#{dir}\n", true] }
      on("git", "config") { ["", true] }
    end

    it "adds the driver line to the shared git dir's info/attributes once and sets the driver in the local config" do
      2.times { lanes.write_attributes }
      expect(File.read(File.join(dir, "info", "attributes"))).to eq("demo/calculator2/test/calc_test.rb merge=calc-demo-tests\n")
      expect(calls).to include(["git", "config", "--local", "merge.calc-demo-tests.driver", driver])
      expect(calls.map { |argv| argv[0, 4] }).to include(%w[git config --local merge.calc-demo-tests.name])
    end

    it "keeps a line already there and puts its own on a new line" do
      FileUtils.mkdir_p(File.join(dir, "info"))
      File.write(File.join(dir, "info", "attributes"), "*.txt -text")
      lanes.write_attributes
      expect(File.read(File.join(dir, "info", "attributes"))).to eq("*.txt -text\ndemo/calculator2/test/calc_test.rb merge=calc-demo-tests\n")
    end

    it "records what it wrote in run.json so cleanup can remove it" do
      lanes.write_attributes(record_path)
      expect(saved["merge_driver"]).to eq("attributes_path" => File.join(dir, "info", "attributes"), "attributes_line" => "demo/calculator2/test/calc_test.rb merge=calc-demo-tests",
        "config_section" => "merge.calc-demo-tests", "driver" => driver)
    end

    it "writes nothing on a dry run" do
      dry = described_class.new(root: tmp, workspace: "ws-bin", lane_b: "ws-b", name: "ws", out: out, err: err, clock: clock, sleeper: ->(_) {}, exec: exec, dry_run: true)
      dry.write_attributes(record_path)
      expect(calls.grep(%w[git config])).to be_empty
      expect(File.exist?(File.join(dir, "info", "attributes"))).to be(false)
    end
  end
end
