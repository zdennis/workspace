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
      plain_dir = File.realpath(Dir.mktmpdir("plain-project"))
      begin
        Dir.chdir(plain_dir) do
          name, root = pc.resolve_project_arg(".")
          expect(name).to eq(File.basename(plain_dir))
          expect(root).to eq(plain_dir)
        end
      ensure
        FileUtils.remove_entry(plain_dir)
      end
    end

    it "strips leading periods from directory names" do
      name, root = pc.resolve_project_arg("/tmp/.bin-zdennis")
      expect(name).to eq("bin-zdennis")
      expect(root).to eq("/tmp/.bin-zdennis")
    end

    it "prefixes with repo name for paths inside .worktrees/" do
      name, root = pc.resolve_project_arg("/path/to/repo-a/.worktrees/MYJIRA-123")
      expect(name).to eq("repo-a-myjira-123")
      expect(root).to eq("/path/to/repo-a/.worktrees/MYJIRA-123")
    end

    it "prefixes with repo name for .worktrees/ paths with a trailing slash" do
      name, root = pc.resolve_project_arg("/path/to/repo-a/.worktrees/MYJIRA-123/")
      expect(name).to eq("repo-a-myjira-123")
      expect(root).to eq("/path/to/repo-a/.worktrees/MYJIRA-123")
    end

    it "strips leading dots from worktree name in .worktrees/ paths" do
      name, root = pc.resolve_project_arg("/path/to/repo-a/.worktrees/.hidden-branch")
      expect(name).to eq("repo-a-hidden-branch")
      expect(root).to eq("/path/to/repo-a/.worktrees/.hidden-branch")
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

      expect(result).to eq("myapp.worktree-proj-123")
      content = File.read(File.join(tmpdir, "workspace.myapp.worktree-proj-123.yml"))
      expect(content).to include("name: myapp-wt-proj-123")
      expect(content).to include("root: /tmp/worktrees/PROJ-123")
      expect(content).to include("project: myapp")
      expect(content).to include("branch: PROJ-123")
      expect(content).to include("display: myapp/PROJ-123")
    end

    context "with a {{PRE_WINDOW}} line in the template" do
      before do
        template_path = File.join(tmpdir, "project-worktree-template.yml")
        File.write(template_path, "name: {{TMUX_SESSION_NAME}}\n{{PRE_WINDOW}}\nwindows: []\n")
        allow(config).to receive(:worktree_template_path).and_return(template_path)
      end

      def written = File.read(File.join(tmpdir, "workspace.myapp.worktree-proj-123.yml"))

      it "exports WORKSPACE_TASK in every pane when given a task id" do
        pc.create_worktree("myapp", "PROJ-123", "/tmp/wt", "PROJ-123", task_id: "ab12cd34")

        expect(written).to eq("name: myapp-wt-proj-123\npre_window: export WORKSPACE_TASK=ab12cd34\nwindows: []\n")
        expect(YAML.safe_load(written)["pre_window"]).to eq("export WORKSPACE_TASK=ab12cd34")
      end

      it "drops the line without a task id" do
        pc.create_worktree("myapp", "PROJ-123", "/tmp/wt", "PROJ-123")

        expect(written).to eq("name: myapp-wt-proj-123\nwindows: []\n")
      end
    end

    describe "#check_agent_kind!" do
      it "raises template_outdated for a template with no Claude Code pane" do
        path = File.join(tmpdir, "t.yml")
        File.write(path, "panes:\n  - echo hi\n")
        allow(config).to receive(:worktree_template_path).and_return(path)

        expect { pc.check_agent_kind!("codex") }.to raise_error(Workspace::Error) { |e| expect(e.code).to eq("template_outdated") }
        expect { pc.check_agent_kind!("claude") }.not_to raise_error
      end
    end

    context "with an agent kind" do
      let(:template_path) { File.join(tmpdir, "project-worktree-template.yml") }

      def written = File.read(File.join(tmpdir, "workspace.myapp.worktree-proj-123.yml"))

      before { allow(config).to receive(:worktree_template_path).and_return(template_path) }

      it "swaps the Claude Code pane for the agent's executable" do
        File.write(template_path, "windows:\n  - w:\n      panes:\n        - echo hi\n        - claude --dangerously-skip-permissions --continue || claude --dangerously-skip-permissions\n")

        pc.create_worktree("myapp", "PROJ-123", "/tmp/wt", "PROJ-123", agent_kind: "codex")

        expect(written).to eq("windows:\n  - w:\n      panes:\n        - echo hi\n        - codex\n")
      end

      it "leaves the template alone for claude" do
        File.write(template_path, "panes:\n  - claude --dangerously-skip-permissions\n")

        pc.create_worktree("myapp", "PROJ-123", "/tmp/wt", "PROJ-123", agent_kind: "claude")

        expect(written).to include("claude --dangerously-skip-permissions")
      end

      it "refuses a template with no Claude Code pane" do
        File.write(template_path, "panes:\n  - echo hi\n")

        expect { pc.create_worktree("myapp", "PROJ-123", "/tmp/wt", "PROJ-123", agent_kind: "codex") }
          .to raise_error(Workspace::Error, /workspace init --force/)
      end
    end

    it "names a worktree's config the way create_worktree does" do
      expect(pc.worktree_config_name("MyApp", "PROJ-123")).to eq("myapp.worktree-proj-123")
    end

    it "raises error when worktree template is missing" do
      allow(config).to receive(:worktree_template_path).and_return(File.join(tmpdir, "nonexistent.yml"))
      expect {
        pc.create_worktree("myapp", "branch", "/tmp/wt", "branch")
      }.to raise_error(Workspace::Error, /Worktree template not found/)
    end
  end

  describe "#remove" do
    subject(:pc) { described_class.new(config: config, output: output, git: git) }

    it "announces the removal by default" do
      path = File.join(tmpdir, "workspace.myapp.yml")
      File.write(path, "x")
      pc.remove("myapp")
      expect(output.string).to include("Removed config: #{path}")
      expect(File.exist?(path)).to be(false)
    end

    it "with quiet: true, writes nothing and still removes the file" do
      path = File.join(tmpdir, "workspace.myapp.yml")
      File.write(path, "x")
      pc.remove("myapp", quiet: true)
      expect(output.string).to eq("")
      expect(File.exist?(path)).to be(false)
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

  describe "#project_root_for" do
    subject(:pc) { described_class.new(config: config, output: output, git: git) }

    it "returns the root from the tmuxinator config" do
      File.write(File.join(tmpdir, "workspace.myapp.yml"), "name: myapp\nroot: /home/user/myapp\n")
      expect(pc.project_root_for("myapp")).to eq("/home/user/myapp")
    end

    it "returns nil when config does not exist" do
      expect(pc.project_root_for("nonexistent")).to be_nil
    end

    it "returns nil when config is corrupt YAML" do
      File.write(File.join(tmpdir, "workspace.bad.yml"), ": :\n  - {\n")
      expect(pc.project_root_for("bad")).to be_nil
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

  describe "lowercase names" do
    subject(:pc) { described_class.new(config: config, output: output, git: git) }

    let(:template_path) { File.join(tmpdir, "project-template.yml") }
    let(:worktree_template_path) { File.join(tmpdir, "project-worktree-template.yml") }
    let(:root) { Dir.mktmpdir("notes-root") }
    let(:other_root) { Dir.mktmpdir("other-root") }

    before do
      File.write(template_path, "name: {{PROJECT_NAME}}\nroot: {{PROJECT_ROOT}}\n")
      File.write(worktree_template_path, "name: {{TMUX_SESSION_NAME}}\nroot: {{WORKTREE_PATH}}\n")
      allow(config).to receive_messages(project_template_path: template_path, worktree_template_path: worktree_template_path)
    end

    after do
      FileUtils.remove_entry(root)
      FileUtils.remove_entry(other_root)
    end

    it "writes a new config under a lowercase name" do
      expect(pc.create("Notes", root)).to eq("notes")
      expect(Dir.glob(File.join(tmpdir, "workspace.*.yml")).map { |f| File.basename(f) }).to eq(["workspace.notes.yml"])
    end

    it "names a path argument in lowercase" do
      dir = File.join(root, "MyApp")
      FileUtils.mkdir_p(dir)
      expect(pc.resolve_project_arg(dir)).to eq(["myapp", dir])
    end

    it "refuses a new name that differs only in case from another workspace's" do
      File.write(File.join(tmpdir, "workspace.Notes.yml"), "name: Notes\nroot: #{other_root}\n")

      expect { pc.create("notes", root) }.to raise_error(Workspace::Error) { |e|
        expect(e.code).to eq("workspace_name_case_conflict")
        expect(e.message).to include("'Notes'").and include("next time its agentd starts")
        expect(e.details).to include("existing" => "Notes", "name" => "notes", "existing_root" => other_root)
      }
      expect(Dir.glob(File.join(tmpdir, "workspace.*.yml")).size).to eq(1)
    end

    it "reuses the mixed-case config of the same workspace (same root)" do
      File.write(File.join(tmpdir, "workspace.Notes.yml"), "name: Notes\nroot: #{root}\n")

      expect(pc.create("notes", root)).to eq("Notes")
      expect(pc.resolve_project_arg(root).last).to eq(root)
      expect(Dir.glob(File.join(tmpdir, "workspace.*.yml")).size).to eq(1)
    end

    it "reuses the variant with the same root when several differ only in case" do
      allow(pc).to receive_messages(available_projects: %w[NOTES Notes])
      allow(pc).to receive(:project_root_for).with("NOTES").and_return(other_root)
      allow(pc).to receive(:project_root_for).with("Notes").and_return(root)

      expect(pc.settle_new_name("notes", root)).to eq("Notes")
    end

    it "refuses when the existing config has no readable root" do
      File.write(File.join(tmpdir, "workspace.Notes.yml"), "name: Notes\n")

      expect { pc.settle_new_name("notes", root) }.to raise_error(Workspace::Error, /root unknown/)
    end

    it "does not refuse the exact existing name" do
      File.write(File.join(tmpdir, "workspace.notes.yml"), "name: notes\nroot: #{root}\n")
      expect(pc.create("notes", other_root)).to eq("notes")
    end

    it "writes a worktree config in lowercase and refuses a case-only clash with another directory" do
      expect(pc.create_worktree("MyApp", "Feat-1", "/tmp/wt/Feat-1", "Feat-1", quiet: true)).to eq("myapp.worktree-feat-1")

      File.write(File.join(tmpdir, "workspace.MyApp.worktree-FEAT-2.yml"), "root: /tmp/wt/two\n")
      expect { pc.create_worktree("myapp", "feat-2", "/tmp/wt/other", "feat-2", quiet: true) }
        .to raise_error(Workspace::Error) { |e| expect(e.code).to eq("workspace_name_case_conflict") }
    end

    it "reuses an existing mixed-case worktree config for the same worktree directory" do
      wt = File.join(root, "Feat-1")
      FileUtils.mkdir_p(wt)
      File.write(File.join(tmpdir, "workspace.MyApp.worktree-Feat-1.yml"), "root: #{wt}\n")

      expect(pc.create_worktree("MyApp", "Feat-1", wt, "Feat-1", quiet: true)).to eq("MyApp.worktree-Feat-1")
    end

    it "#existing_name finds the on-disk spelling ignoring case" do
      File.write(File.join(tmpdir, "workspace.Notes.yml"), "name: Notes\n")
      expect(pc.existing_name("notes")).to eq("Notes")
      expect(pc.existing_name("other")).to be_nil
    end
  end
end
