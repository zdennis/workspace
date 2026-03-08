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

    it "runs the hook in the specified chdir directory" do
      allow(project_settings).to receive(:hook_for)
        .with("myproject", "post_launch")
        .and_return("pwd")

      dir = Dir.mktmpdir
      begin
        runner.run("myproject", "post_launch", chdir: dir)
        expect(output.string).to include(File.realpath(dir))
      ensure
        FileUtils.remove_entry(dir)
      end
    end

    it "falls back to current directory when chdir does not exist" do
      allow(project_settings).to receive(:hook_for)
        .with("myproject", "post_launch")
        .and_return("pwd")

      runner.run("myproject", "post_launch", chdir: "/nonexistent/path")
      expect(output.string).to include(File.realpath(Dir.pwd))
    end

    it "runs in current directory when chdir is nil" do
      allow(project_settings).to receive(:hook_for)
        .with("myproject", "post_launch")
        .and_return("pwd")

      runner.run("myproject", "post_launch", chdir: nil)
      expect(output.string).to include(File.realpath(Dir.pwd))
    end
  end
end
