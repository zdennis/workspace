require "spec_helper"
require "stringio"
require "json"

RSpec.describe Workspace::CLI::WorkQueue do
  let(:out) { StringIO.new }
  let(:err) { StringIO.new }
  let(:row) { {"outcome" => "added", "id" => "3fa9", "position" => 1, "kind" => "workflow"} }
  let(:command) do
    instance_double(Workspace::Commands::WorkQueue,
      add: [row], rm: [row], move: [row], enable: [row], disable: [row], resume: [row], skip: [row], cancel: [row], advance: [row],
      history_clear: [row], action_extra: {"queue" => "app", "revision" => 4},
      list: {"queues" => [{"workspace" => "app"}], "warnings" => []}, status: {"queues" => [], "warnings" => []},
      show: {"workspace" => "app", "item" => {"id" => "3fa9"}, "next_actions" => [], "warnings" => []},
      active: {"workspace" => "app", "item" => nil, "next_actions" => [], "warnings" => []},
      history_list: {"entries" => [], "next_actions" => [], "warnings" => []},
      history_show: {"workspace" => "app", "entry" => {"id" => "3fa9"}, "next_actions" => [], "warnings" => []})
  end

  def invocation
    @invocation ||= Workspace::CLI::Invocation.new(output: Workspace::OutputGate.new(out), error_output: err, exit_handler: FakeExitHandler, help_asked: false, quiet: false, env: {})
  end

  def run(*args, verb: "work-queue")
    described_class.new(work_queue_command: command, common: Workspace::CLI::Common.new).call(verb, args, invocation)
    nil
  rescue FakeSystemExit => e
    e.status
  end

  def usage_error(*args)
    expect { run(*args) }.to raise_error(Workspace::UsageError) { |e| return e.message }
  end

  describe "add" do
    it "queues a workflow item from its id, --ref, --prompt and each --input" do
      run("add", "workflow", "rpiv", "--ref", "PROJ-1", "--prompt", "Do it", "--input", "a=1", "--input", "b=x=y")

      expect(command).to have_received(:add).with(kind: "workflow", spec: {"workflow" => "rpiv", "ref" => "PROJ-1", "prompt" => "Do it", "inputs" => {"a" => "1", "b" => "x=y"}},
        name: nil, position: :bottom, headless: false, on_fail: "stop", dedupe_key: nil)
    end

    it "queues a go item with --text and --workflow" do
      run("add", "go", "Fix it", "--text", "--workflow", "bugfix")

      expect(command).to have_received(:add).with(hash_including(kind: "go", spec: {"argument" => "Fix it", "text" => true, "workflow" => "bugfix"}))
    end

    it "refuses a go item with neither ARG nor --text" do
      expect(usage_error("add", "go")).to include("needs an ARG")
      expect(usage_error("add", "go", "--text")).to include("needs an ARG")
    end

    {
      ["--top"] => :top,
      ["--after-current"] => :after_current,
      ["--before", "ab12"] => {before: "ab12"},
      ["--after", "ab12"] => {after: "ab12"}
    }.each do |flags, position|
      it "places the item for #{flags.join(" ")}" do
        run("add", "workflow", "rpiv", *flags)

        expect(command).to have_received(:add).with(hash_including(position: position))
      end
    end

    it "passes --headless, --on-fail, --dedupe-key and --name" do
      run("add", "workflow", "rpiv", "--headless", "--on-fail", "continue", "--dedupe-key", "k1", "--name", "other")

      expect(command).to have_received(:add).with(hash_including(headless: true, on_fail: "continue", dedupe_key: "k1", name: "other"))
    end

    it "prints a JSON action document with the queue and revision beside the results" do
      run("add", "workflow", "rpiv", "--json")

      doc = JSON.parse(out.string)
      expect(doc).to include("action" => "work-queue add", "status" => "ok", "queue" => "app", "revision" => 4)
      expect(doc["results"]).to eq([{"workspace" => "app"}.merge(row)])
    end

    it "refuses two positions" do
      expect(usage_error("add", "workflow", "rpiv", "--top", "--after", "x")).to include("Give only one of --top, --after-current, --before and --after")
    end

    it "refuses an unknown kind and a missing one" do
      expect(usage_error("add", "agent-run", "x")).to include("Unknown kind: agent-run")
      expect(usage_error("add")).to include("Missing kind")
    end

    it "refuses a workflow item with no id, and go flags on it" do
      expect(usage_error("add", "workflow")).to include("needs a workflow ID")
      expect(usage_error("add", "workflow", "rpiv", "--text")).to include("--text applies to 'add go'")
    end

    it "refuses workflow flags on a go item, --text with no text, a bad --on-fail and a bad --input" do
      expect(usage_error("add", "go", "X", "--ref", "1")).to include("--ref applies to 'add workflow'")
      expect(usage_error("add", "workflow", "rpiv", "--on-fail", "halt")).to include("Unknown --on-fail")
      expect(usage_error("add", "workflow", "rpiv", "--input", "novalue")).to include("KEY=VALUE")
    end
  end

  describe "move" do
    {
      ["--before", "b1"] => {before: "b1", after: nil, top: false, bottom: false},
      ["--after", "b1"] => {before: nil, after: "b1", top: false, bottom: false},
      ["--top"] => {before: nil, after: nil, top: true, bottom: false},
      ["--bottom"] => {before: nil, after: nil, top: false, bottom: true}
    }.each do |flags, expected|
      it "moves for #{flags.join(" ")}" do
        run("move", "3fa9", *flags)

        expect(command).to have_received(:move).with(id: "3fa9", name: nil, if_revision: nil, **expected)
      end
    end

    it "passes --if-revision as a number" do
      run("move", "3fa9", "--top", "--if-revision", "7")

      expect(command).to have_received(:move).with(hash_including(if_revision: 7))
    end

    it "refuses no position, two positions, no id and a bad revision" do
      expect(usage_error("move", "3fa9")).to include("Give exactly one of --before, --after, --top and --bottom")
      expect(usage_error("move", "3fa9", "--top", "--bottom")).to include("Give exactly one")
      expect(usage_error("move", "--top")).to include("needs an item ID")
      expect(usage_error("move", "3fa9", "--top", "--if-revision", "x")).to include("whole number")
    end
  end

  describe "the other actions" do
    it "cancels the current item, or one by id, with --and-continue" do
      run("cancel")
      run("cancel", "3fa9", "--and-continue")

      expect(command).to have_received(:cancel).with(id: nil, name: nil, and_continue: false)
      expect(command).to have_received(:cancel).with(id: "3fa9", name: nil, and_continue: true)
    end

    it "skips the held item or one by id" do
      run("skip")
      run("skip", "3fa9")

      expect(command).to have_received(:skip).with(id: nil, name: nil)
      expect(command).to have_received(:skip).with(id: "3fa9", name: nil)
    end

    it "removes every id given" do
      run("rm", "a1", "b2", "--name", "other")

      expect(command).to have_received(:rm).with(ids: %w[a1 b2], name: "other")
      expect(usage_error("rm")).to include("needs at least one item ID")
    end

    %w[enable disable resume advance].each do |verb|
      it "calls #{verb} for the named workspace" do
        run(verb, "--name", "other")

        expect(command).to have_received(verb.to_sym).with(name: "other")
      end
    end

    it "answers to wq" do
      run("enable", verb: "wq")

      expect(command).to have_received(:enable).with(name: nil)
    end

    it "refuses a flag that does not belong to the verb" do
      expect(usage_error("enable", "--top")).to include("--top does not apply to 'work-queue enable'")
      expect(usage_error("cancel", "--and-continue", "--project")).to include("does not apply")
      expect(usage_error("bogus")).to include("Unknown work-queue subcommand")
    end
  end

  describe "reads" do
    it "lists a project read-only for --project, with and without a name" do
      run("list", "--project")
      run("status", "--project", "api")

      expect(command).to have_received(:list).with(name: nil, project: true)
      expect(command).to have_received(:status).with(name: nil, project: "api")
      expect(usage_error("list", "--name", "a", "--project")).to include("Give only one of --name and --project")
    end

    it "shows and reads the active item" do
      run("show", "3fa9", "--name", "other")
      run("active")

      expect(command).to have_received(:show).with(id: "3fa9", name: "other")
      expect(command).to have_received(:active).with(name: nil)
      expect(usage_error("show")).to include("needs an item ID")
    end

    it "wraps the command's Hash in a JSON document under --json" do
      run("show", "3fa9", "--json")

      expect(JSON.parse(out.string)).to eq("schema_version" => 1, "ok" => true, "item" => {"id" => "3fa9"}, "warnings" => [],
        "workspace" => "app", "next_actions" => [])
    end

    it "prints nothing itself without --json" do
      run("list")

      expect(out.string).to eq("")
    end
  end

  describe "history" do
    it "lists with --since, --before, --state and --project, parsing dates" do
      run("history", "list", "--since", "2026-01-02", "--before", "2026-02-03T04:05:06Z", "--state", "failed", "--project")

      expect(command).to have_received(:history_list).with(name: nil, project: true, since: Time.parse("2026-01-02"),
        before: Time.utc(2026, 2, 3, 4, 5, 6), state: "failed")
    end

    it "shows one finished item" do
      run("history", "show", "3fa9")

      expect(command).to have_received(:history_show).with(id: "3fa9", name: nil)
    end

    it "clears with --before or --all, and --yes" do
      run("history", "clear", "--before", "2026-01-02", "--yes")
      run("history", "clear", "--all", "--json", "--yes")

      expect(command).to have_received(:history_clear).with(name: nil, before: Time.parse("2026-01-02"), all: false, yes: true, json: false)
      expect(command).to have_received(:history_clear).with(name: nil, before: nil, all: true, yes: true, json: true)
    end

    it "refuses clear with neither or both of --before and --all" do
      expect(usage_error("history", "clear")).to include("Give exactly one of --before DATE and --all")
      expect(usage_error("history", "clear", "--all", "--before", "2026-01-02")).to include("Give exactly one")
    end

    it "refuses a bad date, an unknown state, an unknown sub-verb and a missing one" do
      expect(usage_error("history", "list", "--since", "yesterday")).to include("--since needs a date")
      expect(usage_error("history", "list", "--state", "weird")).to include("Unknown state")
      expect(usage_error("history", "nope")).to include("Unknown history subcommand")
      expect(usage_error("history")).to include("Missing history subcommand")
      expect(usage_error("history", "show", "3fa9", "--all")).to include("--all does not apply to 'work-queue history show'")
    end
  end

  describe "advance and cancel --and-continue status" do
    def rows_of(*outcomes)
      outcomes.map { |o| {"outcome" => o, "id" => "aa", "position" => nil, "kind" => "workflow"} }
    end

    def doc
      JSON.parse(out.string)
    end

    it "is failed with exit 1 when the only row is a launch_failed" do
      allow(command).to receive(:advance).and_return(rows_of("launch_failed"))

      expect(run("advance", "--json")).to eq(1)
      expect(doc).to include("status" => "failed")
      expect(doc["results"].first).to include("outcome" => "launch_failed")
    end

    it "is partial with exit 3 when some rows failed and others did not" do
      allow(command).to receive(:advance).and_return(rows_of("succeeded", "launch_failed"))

      expect(run("advance", "--json")).to eq(3)
      expect(doc["status"]).to eq("partial")
    end

    %w[claim_lost interrupted].each do |outcome|
      it "counts #{outcome} as a failure without --json too" do
        allow(command).to receive(:advance).and_return(rows_of(outcome))

        expect(run("advance")).to eq(1)
      end
    end

    %w[failed cancelled].each do |outcome|
      it "counts a #{outcome} run the queue paused for as a failure" do
        resume = [Workspace::NextAction.build("work-queue resume", "--name", "app")]
        allow(command).to receive(:advance).and_return([rows_of(outcome).first.merge("next_actions" => resume)])

        expect(run("advance", "--json")).to eq(1)
        expect(doc["status"]).to eq("failed")
      end

      it "does not count a #{outcome} run under on_fail continue, where the queue did not pause" do
        allow(command).to receive(:advance).and_return(rows_of(outcome, "started"))

        expect(run("advance", "--json")).to be_nil
        expect(doc["status"]).to eq("ok")
      end
    end

    it "does not count a held item or a started one" do
      allow(command).to receive(:advance).and_return(rows_of("held", "started", "unchanged"))

      expect(run("advance", "--json")).to be_nil
      expect(doc["status"]).to eq("ok")
    end

    it "does not count the cancel row itself, but a failed pass row after it" do
      allow(command).to receive(:cancel).and_return(rows_of("cancelled", "started"))
      expect(run("cancel", "--and-continue", "--json")).to be_nil

      allow(command).to receive(:cancel).and_return(rows_of("cancelled", "launch_failed"))
      out.truncate(0)
      out.rewind
      expect(run("cancel", "--and-continue", "--json")).to eq(3)
      expect(doc["status"]).to eq("partial")
    end

    it "leaves a plain cancel alone" do
      allow(command).to receive(:cancel).and_return(rows_of("cancelled"))

      expect(run("cancel", "--json")).to be_nil
    end
  end

  describe "help" do
    it "mentions the wq alias, and nothing about a daemon moving the queue" do
      run
      run("advance", "--help")
      run("list", "--help")

      expect(out.string).to include("`wq` is another name")
      expect(out.string).not_to match(/daemon/i)
    end

    it "keeps the overview paragraph out of the headings, so --help --json reads it as one description" do
      run

      description = out.string.lines.map(&:chomp).drop_while { |l| !l.empty? }.take_while { |l| l != "Subcommands:" }
      expect(description.reject(&:empty?).grep(/\A\S.*:\z/)).to eq([])
    end
    it "prints the family page for a bare work-queue" do
      run

      expect(out.string).to start_with("Usage: workspace work-queue add workflow")
    end

    it "prints a verb's page for --help" do
      run("move", "--help")

      expect(out.string).to eq(Workspace::HelpPages.render(Workspace::HelpPages::WORK_QUEUE.fetch("move")).join("\n") + "\n")
    end
  end
end
