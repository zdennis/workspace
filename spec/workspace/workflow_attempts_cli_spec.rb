require "spec_helper"
require "tmpdir"
require "fileutils"

RSpec.describe "workspace workflow attempts through build_cli" do
  around do |example|
    Dir.mktmpdir("wf-attempts-cli") do |dir|
      saved = ENV.to_h
      begin
        ENV.replace("HOME" => File.realpath(dir), "PATH" => File.dirname(RbConfig.ruby))
        example.run
      ensure
        ENV.replace(saved)
      end
    end
  end

  it "reads a run from the real run store" do
    config = Workspace::Config.new
    store = Workspace::WorkflowRunStore.new(dir: config.workflow_runs_dir, archive_dir: config.workflow_archive_dir, id_generator: -> { "wr_2611010900abcd" })
    store.create("workflow" => "rpiv", "workspace" => "app", "state" => "running", "current" => "plan", "definition" => {"steps" => [{"id" => "plan"}]},
      "steps" => {"plan" => {"attempts" => [{"n" => 1, "outcome" => "failed", "code" => "check_failed"}]}})
    out = StringIO.new

    Workspace.build_cli(output: out, error_output: StringIO.new, input: StringIO.new, env: {}).run(["workflow", "attempts", "wr_2611010900abcd", "--json"])

    row = JSON.parse(out.string)["attempts"].first
    expect(row).to include("step" => "plan", "attempt" => 1, "outcome" => "failed", "code" => "check_failed")
  end
  it "wires the evidence copier into the attempt record and the run store" do
    out = StringIO.new
    cli = Workspace.build_cli(output: out, error_output: StringIO.new, input: StringIO.new, env: {})
    command = cli.instance_variable_get(:@workflow_command)
    record = command.instance_variable_get(:@engine).instance_variable_get(:@attempt_record)
    config = Workspace::Config.new
    art = File.join(ENV.fetch("HOME"), "art")
    FileUtils.mkdir_p(art)
    File.write(File.join(art, "plan.md"), "plan")
    attempt = {"n" => 1}

    record.finish(run: {"id" => "wr_wired", "artifacts_dir" => art, "worktree" => art}, step: {"id" => "plan", "produces" => ["plan.md"]}, attempt: attempt)

    expect(attempt["evidence"].first).to include("name" => "plan.1.out.0.plan.md", "sha256" => Digest::SHA256.hexdigest("plan"))
    expect(File.read(File.join(config.workflow_evidence_dir, "wr_wired", "plan.1.out.0.plan.md"))).to eq("plan")
    expect(command.instance_variable_get(:@store).instance_variable_get(:@evidence)).to be_a(Workspace::WorkflowEvidence)
  end
end
