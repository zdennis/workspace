require "tmpdir"
require "stringio"

RSpec.describe Workspace::ProjectConfig do
  let(:tmpdir) { Dir.mktmpdir }
  let(:output) { StringIO.new }
  let(:config) { Workspace::Config.new(workspace_dir: tmpdir) }
  let(:git) { Workspace::Git.new }

  before do
    allow(config).to receive(:tmuxinator_dir).and_return(tmpdir)
    allow(config).to receive(:config_path_for) { |name| File.join(tmpdir, "workspace.#{name}.yml") }
  end

  after { FileUtils.remove_entry(tmpdir) }

  describe "#resolve_project_arg" do
    subject(:pc) { described_class.new(config: config, output: output, git: git) }

    it "resolves a path to [name, root]" do
      name, root = pc.resolve_project_arg(".")
      expect(name).to eq(File.basename(Dir.pwd))
      expect(root).to eq(File.expand_path("."))
    end

    it "returns [name, nil] for a plain name" do
      name, root = pc.resolve_project_arg("my-project")
      expect(name).to eq("my-project")
      expect(root).to be_nil
    end
  end

  describe "#create" do
    subject(:pc) { described_class.new(config: config, output: output, git: git) }

    it "raises error when template is missing" do
      allow(config).to receive(:project_template_path).and_return(File.join(tmpdir, "nonexistent.yml"))
      expect { pc.create("test", "/tmp/test") }.to raise_error(Workspace::Error, /Template not found/)
    end

    it "creates a config file from the template" do
      template_path = File.join(tmpdir, "project-template.yml")
      File.write(template_path, "name: {{PROJECT_NAME}}\nroot: {{PROJECT_ROOT}}\nconfig: {{CONFIG_PATH}}\n")
      allow(config).to receive(:project_template_path).and_return(template_path)

      result = pc.create("myapp", "/home/user/myapp")
      expect(result).to eq("myapp")

      content = File.read(File.join(tmpdir, "workspace.myapp.yml"))
      expect(content).to include("name: myapp")
      expect(content).to include("root: /home/user/myapp")
      expect(content).to include("config: #{File.join(tmpdir, "workspace.myapp.yml")}")
    end

    it "skips creation when config already exists" do
      File.write(File.join(tmpdir, "workspace.existing.yml"), "name: existing\n")
      result = pc.create("existing", "/tmp/existing")
      expect(result).to eq("existing")
      expect(output.string).to include("Config already exists")
    end
  end

  describe "#create_worktree" do
    subject(:pc) { described_class.new(config: config, output: output, git: git) }

    it "creates a worktree config with all placeholders substituted" do
      template_path = File.join(tmpdir, "project-worktree-template.yml")
      File.write(template_path, [
        "name: {{TMUX_SESSION_NAME}}",
        "root: {{WORKTREE_PATH}}",
        "project: {{PROJECT_NAME}}",
        "branch: {{WORKTREE_BRANCH}}",
        "display: {{DISPLAY_NAME}}",
        "config: {{CONFIG_PATH}}"
      ].join("\n") + "\n")
      allow(config).to receive(:worktree_template_path).and_return(template_path)

      result = pc.create_worktree("myapp", "PROJ-123", "/tmp/worktrees/PROJ-123", "PROJ-123")

      expect(result).to eq("myapp.worktree-PROJ-123")
      content = File.read(File.join(tmpdir, "workspace.myapp.worktree-PROJ-123.yml"))
      expect(content).to include("name: myapp-wt-PROJ-123")
      expect(content).to include("root: /tmp/worktrees/PROJ-123")
      expect(content).to include("project: myapp")
      expect(content).to include("branch: PROJ-123")
      expect(content).to include("display: myapp/PROJ-123")
    end

    it "raises error when worktree template is missing" do
      allow(config).to receive(:worktree_template_path).and_return(File.join(tmpdir, "nonexistent.yml"))
      expect {
        pc.create_worktree("myapp", "branch", "/tmp/wt", "branch")
      }.to raise_error(Workspace::Error, /Worktree template not found/)
    end
  end

  describe "#exists?" do
    subject(:pc) { described_class.new(config: config, output: output, git: git) }

    it "returns true when config file exists" do
      File.write(File.join(tmpdir, "workspace.myapp.yml"), "name: myapp\n")
      expect(pc.exists?("myapp")).to be true
    end

    it "returns false when config file does not exist" do
      expect(pc.exists?("nonexistent")).to be false
    end
  end

  describe "#available_projects" do
    subject(:pc) { described_class.new(config: config, output: output, git: git) }

    it "returns sorted project names excluding templates" do
      File.write(File.join(tmpdir, "workspace.beta.yml"), "")
      File.write(File.join(tmpdir, "workspace.alpha.yml"), "")
      File.write(File.join(tmpdir, "workspace.project-worktree-template.yml"), "")
      File.write(File.join(tmpdir, "workspace.project-template.yml"), "")
      File.write(File.join(tmpdir, "other-tool.yml"), "")

      expect(pc.available_projects).to eq(["alpha", "beta"])
    end
  end
end
