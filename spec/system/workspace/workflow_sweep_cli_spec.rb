require "spec_helper"
require "tmpdir"
require "fileutils"

RSpec.describe "workspace workflow sweep through build_cli" do
  around do |example|
    Dir.mktmpdir("wf-sweep-cli") do |dir|
      saved = ENV.to_h
      begin
        ENV.replace("HOME" => File.realpath(dir), "PATH" => File.dirname(RbConfig.ruby))
        example.run
      ensure
        ENV.replace(saved)
      end
    end
  end

  let(:config) { Workspace::Config.new }
  let(:store) { Workspace::WorkflowRunStore.new(dir: config.workflow_runs_dir, archive_dir: config.workflow_archive_dir, id_generator: -> { "wr_2611010900abcd" }) }
  let(:out) { StringIO.new }
  let(:err) { StringIO.new }
  let(:cli) do
    Workspace.build_cli(output: out, error_output: err, input: StringIO.new, env: {}, exit_handler: FakeExitHandler)
  end

  before do
    store.create("workflow" => "rpiv", "workspace" => "app", "state" => "running", "current" => "plan", "worktree" => ENV.fetch("HOME"),
      "definition" => {"steps" => [{"id" => "plan", "timeout" => nil}]},
      "steps" => {"plan" => {"state" => "running", "attempts" => [{"n" => 1, "started_at" => "2026-10-04T12:00:00.000Z"}]}})
  end

  def events
    File.readlines(store.events_path("wr_2611010900abcd")).map { |line| JSON.parse(line) }
  rescue Errno::ENOENT
    []
  end

  it "records a run whose pane is gone, once, and prints one action document" do
    cli.run(["workflow", "sweep", "--json"])
    first = JSON.parse(out.string)
    out.truncate(0)
    out.rewind
    cli.run(["workflow", "sweep", "--json"])
    second = JSON.parse(out.string)

    expect(first).to include("action" => "workflow sweep", "status" => "ok")
    expect(first["results"].first).to include("run_id" => "wr_2611010900abcd", "outcome" => "recorded", "cause" => "pane_gone", "step" => "plan", "attempt" => 1)
    expect(second["results"].first).to include("outcome" => "nothing", "reason" => "already_recorded")
    expect(events.count { |each| each["type"] == "step_stalled" }).to eq(1)
  end

  it "prints a line for a gone pane on the first pass only" do
    cli.run(["workflow", "sweep"])
    out.truncate(0)
    out.rewind
    cli.run(["workflow", "sweep"])

    expect(out.string).not_to include("already_recorded")
    expect(out.string).to include("Looked at 1 run; nothing to report.")
  end

  it "changes nothing with --dry-run, and says so in the status" do
    cli.run(["workflow", "sweep", "--dry-run", "--json"])

    document = JSON.parse(out.string)
    expect(document).to include("status" => "dry_run")
    expect(document["results"].first).to include("outcome" => "dry_run", "action" => "record")
    expect(events.map { |each| each["type"] }).not_to include("step_stalled")
  end

  it "prints a line for a run it noted, and a count" do
    cli.run(["workflow", "sweep"])

    expect(out.string).to include("wr_2611010900abcd  app  step plan  recorded: pane")
    expect(out.string).to include("Looked at 1 run; 1 reported above.")
  end

  it "writes no count line under --json, even to stderr, and fills summary with counts by outcome" do
    cli.run(["workflow", "sweep", "--json"])

    expect(err.string).not_to include("Looked at")
    expect(JSON.parse(out.string)["summary"]).to eq("recorded" => 1)
  end

  it "reports an unreadable run file as a failed result, with the partial exit 3" do
    File.write(File.join(config.workflow_runs_dir, "wr_bad.json"), "{")

    expect { cli.run(["workflow", "sweep", "--json"]) }.to raise_error(FakeSystemExit) { |e| expect(e.status).to eq(3) }

    document = JSON.parse(out.string)
    expect(document["status"]).to eq("partial")
    expect(document["results"].find { |each| each["outcome"] == "failed" }).to include("reason" => "unreadable_run", "run_id" => "wr_bad")
  end

  it "refuses a RUN together with --name" do
    expect { cli.run(["workflow", "sweep", "wr_2611010900abcd", "--name", "app"]) }.to raise_error(FakeSystemExit)
    expect(err.string).to match(/RUN or --name/)
  end

  it "answers unknown_run for a run that does not exist" do
    expect { cli.run(["workflow", "sweep", "wr_2611010900ffff", "--json"]) }.to raise_error(FakeSystemExit)
    expect(JSON.parse(out.string)).to include("ok" => false, "code" => "unknown_run")
  end
end
