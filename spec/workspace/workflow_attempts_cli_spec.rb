require "spec_helper"
require "tmpdir"

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
end
