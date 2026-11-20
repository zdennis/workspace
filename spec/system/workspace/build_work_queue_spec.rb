require "spec_helper"
require "stringio"
require "tmpdir"
require "fileutils"
require "json"

RSpec.describe "Workspace.build_cli work queue wiring" do
  it "wires WorkQueueStarters over the real command objects and answers work-queue and wq" do
    Dir.mktmpdir("workspace-wq-build") do |home|
      out = StringIO.new
      expect(Workspace::WorkQueueStarters).to receive(:new).with(
        workflow: an_instance_of(Workspace::Commands::Workflow), workflow_start: an_instance_of(Workspace::Commands::WorkflowStart),
        go: an_instance_of(Workspace::Commands::Go), workflow_project: an_instance_of(Workspace::WorkflowProject),
        catalog: an_instance_of(Workspace::WorkflowCatalog)
      ).and_return(instance_double(Workspace::WorkQueueStarters, to_h: {}))

      cli = Workspace.build_cli(output: out, error_output: StringIO.new, input: StringIO.new, env: {"HOME" => home}, exit_handler: FakeExitHandler)
      cli.run(["work-queue", "--help"])
      cli.run(["wq", "move", "--help"])

      expect(out.string).to include("Usage: workspace work-queue add workflow")
      expect(out.string).to include("Usage: workspace work-queue move ITEM")
    end
  end

  it "answers a real work-queue list --json against a workspace in a throwaway home" do
    Dir.mktmpdir("workspace-wq-real") do |home|
      saved = ENV.to_h
      begin
        ENV.replace("HOME" => home, "PATH" => ENV["PATH"])
        FileUtils.mkdir_p(File.join(home, ".config", "tmuxinator"))
        FileUtils.mkdir_p(File.join(home, "app"))
        File.write(File.join(home, ".config", "tmuxinator", "workspace.app.yml"), "name: workspace.app\nroot: #{File.join(home, "app")}\nwindows:\n  - main: echo\n")
        out = StringIO.new
        cli = Workspace.build_cli(output: out, error_output: StringIO.new, input: StringIO.new, env: {"HOME" => home}, exit_handler: FakeExitHandler)

        cli.run(["work-queue", "list", "--name", "app", "--json"])

        doc = JSON.parse(out.string)
        expect(doc).to include("ok" => true)
        expect(doc["queues"].first).to include("workspace" => "app", "state" => "off", "items" => [])
      ensure
        ENV.replace(saved)
      end
    end
  end
end
