RSpec.describe Workspace::Config do
  describe "default paths" do
    subject(:config) { described_class.new }

    it "returns the workspace installation directory" do
      expect(config.workspace_dir).to eq(File.expand_path("../..", __dir__))
    end

    it "returns the tmuxinator config directory" do
      expect(config.tmuxinator_dir).to eq(File.expand_path("~/.config/tmuxinator"))
    end

    it "returns the state file path" do
      expect(config.state_file).to eq(File.expand_path("~/.workspace-state.json"))
    end

    it "returns the project template path" do
      expect(config.project_template_path).to eq(
        File.join(File.expand_path("~/.config/tmuxinator"), "workspace.project-template.yml")
      )
    end

    it "returns the worktree template path" do
      expect(config.worktree_template_path).to eq(
        File.join(File.expand_path("~/.config/tmuxinator"), "workspace.project-worktree-template.yml")
      )
    end

    it "returns the window-tool binary name" do
      expect(config.window_tool).to eq("window-tool")
    end
  end

  describe "custom workspace_dir" do
    it "propagates the custom directory" do
      config = described_class.new(workspace_dir: "/tmp/custom-workspace")
      expect(config.workspace_dir).to eq("/tmp/custom-workspace")
    end
  end

  describe "#config_path_for" do
    subject(:config) { described_class.new }

    it "builds the expected config file path" do
      expect(config.config_path_for("my-project")).to eq(
        File.join(File.expand_path("~/.config/tmuxinator"), "workspace.my-project.yml")
      )
    end
  end
end
