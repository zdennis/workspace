require "workspace"
require "stringio"

RSpec.describe Workspace::HookRunner do
  let(:output) { StringIO.new }
  let(:error_output) { StringIO.new }
  let(:project_settings) { instance_double(Workspace::ProjectSettings) }
  let(:runner) do
    described_class.new(
      project_settings: project_settings,
      output: output,
      error_output: error_output
    )
  end

  describe "#run" do
    it "returns true when no hook is defined" do
      allow(project_settings).to receive(:hook_for).with("myproject", "post_launch").and_return(nil)

      expect(runner.run("myproject", "post_launch")).to be true
      expect(output.string).to be_empty
    end

    it "executes the hook script and returns true on success" do
      allow(project_settings).to receive(:hook_for).with("myproject", "post_launch").and_return("echo hello")

      expect(runner.run("myproject", "post_launch")).to be true
      expect(output.string).to include("Running post_launch hook...")
      expect(output.string).to include("hello")
    end

    it "sets WORKSPACE_PROJECT environment variable" do
      allow(project_settings).to receive(:hook_for)
        .with("myproject", "post_launch")
        .and_return("echo $WORKSPACE_PROJECT")

      runner.run("myproject", "post_launch")
      expect(output.string).to include("myproject")
    end

    it "passes additional env variables" do
      allow(project_settings).to receive(:hook_for)
        .with("myproject", "post_launch")
        .and_return("echo $CUSTOM_VAR")

      runner.run("myproject", "post_launch", env: {"CUSTOM_VAR" => "custom_value"})
      expect(output.string).to include("custom_value")
    end

    it "returns false and warns on hook failure" do
      allow(project_settings).to receive(:hook_for)
        .with("myproject", "post_launch")
        .and_return("exit 1")

      expect(runner.run("myproject", "post_launch")).to be false
      expect(error_output.string).to include("Warning: post_launch hook failed (exit 1)")
    end

    it "prints stderr from failed hooks" do
      allow(project_settings).to receive(:hook_for)
        .with("myproject", "post_launch")
        .and_return("echo 'something went wrong' >&2; exit 1")

      runner.run("myproject", "post_launch")
      expect(error_output.string).to include("something went wrong")
    end
  end
end
