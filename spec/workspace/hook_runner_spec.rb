require "workspace"
require "stringio"
require "tmpdir"

RSpec.describe Workspace::HookRunner do
  let(:output) { StringIO.new }
  let(:error_output) { StringIO.new }
  let(:project_settings) { instance_double(Workspace::ProjectSettings) }
  let(:project_config) { instance_double(Workspace::ProjectConfig) }
  let(:runner) do
    described_class.new(
      project_settings: project_settings,
      project_config: project_config,
      output: output,
      error_output: error_output
    )
  end

  before do
    allow(project_config).to receive(:project_root_for).and_return(nil)
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

    it "runs the hook in the project root directory" do
      allow(project_settings).to receive(:hook_for)
        .with("myproject", "post_launch")
        .and_return("pwd")

      dir = Dir.mktmpdir
      begin
        allow(project_config).to receive(:project_root_for).with("myproject").and_return(dir)
        runner.run("myproject", "post_launch")
        expect(output.string).to include(File.realpath(dir))
      ensure
        FileUtils.remove_entry(dir)
      end
    end

    it "falls back to current directory when project root does not exist" do
      allow(project_settings).to receive(:hook_for)
        .with("myproject", "post_launch")
        .and_return("pwd")

      allow(project_config).to receive(:project_root_for).with("myproject").and_return("/nonexistent/path")
      runner.run("myproject", "post_launch")
      expect(output.string).to include(File.realpath(Dir.pwd))
    end

    it "runs in current directory when project root is nil" do
      allow(project_settings).to receive(:hook_for)
        .with("myproject", "post_launch")
        .and_return("pwd")

      allow(project_config).to receive(:project_root_for).with("myproject").and_return(nil)
      runner.run("myproject", "post_launch")
      expect(output.string).to include(File.realpath(Dir.pwd))
    end
  end
end
