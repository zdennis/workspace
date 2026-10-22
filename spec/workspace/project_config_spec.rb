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

    describe "#agent_pane_command" do
      it "is the template's Claude Code pane for claude, the executable for another kind, and nil when unknown" do
        path = File.join(tmpdir, "t.yml")
        File.write(path, "panes:\n  - claude --dangerously-skip-permissions --continue || claude --dangerously-skip-permissions  \n")
        allow(config).to receive(:worktree_template_path).and_return(path)

        expect(pc.agent_pane_command("claude")).to eq("claude --dangerously-skip-permissions --continue || claude --dangerously-skip-permissions")
        expect(pc.agent_pane_command("codex")).to eq("codex")
        expect(pc.agent_pane_command("vim")).to be_nil
      end

      it "is nil for claude when the template is missing or has no Claude Code pane" do
        path = File.join(tmpdir, "t.yml")
        allow(config).to receive(:worktree_template_path).and_return(path)
        expect(pc.agent_pane_command("claude")).to be_nil

        File.write(path, "panes:\n  - echo hi\n")
        expect(pc.agent_pane_command("claude")).to be_nil
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

    context "with configured agent commands" do
      let(:template_path) { File.join(tmpdir, "project-worktree-template.yml") }
      let(:claude_line) { "claude --dangerously-skip-permissions --continue || claude --dangerously-skip-permissions" }
      let(:settings) { {} }
      let(:project_settings) { instance_double(Workspace::ProjectSettings, load_global: settings) }
      let(:agent_commands) { Workspace::AgentCommands.new(config_resolver: Workspace::ConfigResolver.new(project_settings: project_settings)) }
      subject(:pc) { described_class.new(config: config, output: output, git: git, agent_commands: agent_commands) }

      def written = File.read(File.join(tmpdir, "workspace.myapp.worktree-proj-123.yml"))

      def pane = YAML.safe_load(written).fetch("panes").last

      before do
        allow(project_settings).to receive(:load).and_return({})
        allow(config).to receive(:worktree_template_path).and_return(template_path)
        File.write(template_path, "panes:\n  - echo hi\n  - #{claude_line}\n")
      end

      it "writes exactly the template's line when the command is the default" do
        pc.create_worktree("myapp", "PROJ-123", "/tmp/wt", "PROJ-123")

        expect(written).to eq("panes:\n  - echo hi\n  - #{claude_line}\n")
      end

      context "with a configured claude command" do
        let(:settings) { {"agent" => {"commands" => {"claude" => "claude-dev"}}} }

        it "replaces claude in both halves of the chain" do
          pc.create_worktree("myapp", "PROJ-123", "/tmp/wt", "PROJ-123")

          expect(pane).to eq("claude-dev --dangerously-skip-permissions --continue || claude-dev --dangerously-skip-permissions")
        end

        it "types an absolute-path command verbatim in both halves of the chain" do
          settings.replace("agent" => {"commands" => {"claude" => "/abs/claude-dev"}})

          pc.create_worktree("myapp", "PROJ-123", "/tmp/wt", "PROJ-123")

          expect(pane).to eq("/abs/claude-dev --dangerously-skip-permissions --continue || /abs/claude-dev --dangerously-skip-permissions")
        end

        it "types a path with a space as written, without shell quoting" do
          settings.replace("agent" => {"commands" => {"claude" => "/Users/me/my bin/claude-dev"}})

          pc.create_worktree("myapp", "PROJ-123", "/tmp/wt", "PROJ-123")

          expect(pane).to eq("/Users/me/my bin/claude-dev --dangerously-skip-permissions --continue || /Users/me/my bin/claude-dev --dangerously-skip-permissions")
        end

        it "reads the project layer over the global one" do
          allow(project_settings).to receive(:load).with("myapp").and_return({"agent" => {"commands" => {"claude" => "claude-proj"}}})

          pc.create_worktree("myapp", "PROJ-123", "/tmp/wt", "PROJ-123")

          expect(pane).to start_with("claude-proj --dangerously")
        end
      end

      context "with a configured codex command" do
        let(:settings) { {"agent" => {"kind" => "codex", "commands" => {"codex" => "codex --yolo"}}} }

        it "writes it for agent.kind with no explicit kind" do
          pc.create_worktree("myapp", "PROJ-123", "/tmp/wt", "PROJ-123")

          expect(pane).to eq("codex --yolo")
        end

        it "lets an explicit kind win over agent.kind" do
          pc.create_worktree("myapp", "PROJ-123", "/tmp/wt", "PROJ-123", agent_kind: "claude")

          expect(pane).to eq(claude_line)
        end
      end

      context "with a command that is not a plain YAML scalar" do
        ["claude-dev --note 'a # b'", "claude-dev --msg \"x: y\"", "FOO='a: b' claude-dev # trailing", "claude-dev --a '{x}'"].each do |value|
          it "keeps the config valid for #{value.inspect}" do
            settings.replace("agent" => {"commands" => {"claude" => value}})

            pc.create_worktree("myapp", "PROJ-123", "/tmp/wt", "PROJ-123")

            expect(pane).to eq(claude_line.gsub("claude ", "#{value} "))
          end
        end

        it "keeps the config valid for a codex command" do
          settings.replace("agent" => {"kind" => "codex", "commands" => {"codex" => "codex -c 'a: b' # x"}})

          pc.create_worktree("myapp", "PROJ-123", "/tmp/wt", "PROJ-123")

          expect(pane).to eq("codex -c 'a: b' # x")
        end
      end

      describe "#agent_pane_command" do
        let(:settings) { {"agent" => {"commands" => {"claude" => "claude-dev", "codex" => "codex-x"}}} }

        it "uses the configured command for the workspace, the executable without one" do
          expect(pc.agent_pane_command("claude", "myapp")).to eq(claude_line.gsub("claude ", "claude-dev "))
          expect(pc.agent_pane_command("codex", "myapp")).to eq("codex-x")
          expect(pc.agent_pane_command("codex")).to eq("codex")
        end
      end

      describe "#rewrite_agent_pane" do
        let(:settings) { {"agent" => {"commands" => {"claude" => "claude-old", "codex" => "codex-dev"}}} }

        before { allow(project_settings).to receive(:load).with("myapp").and_return({"agent" => {"commands" => {"claude" => "claude-new"}}}) }

        it "rewrites a line already running a configured command, keeping the flags" do
          content = "panes:\n  - echo hi\n  - claude-old --dangerously-skip-permissions --continue || claude-old --dangerously-skip-permissions\n"

          expect(pc.rewrite_agent_pane(content, "claude", "myapp")).to eq(
            "panes:\n  - echo hi\n  - claude-new --dangerously-skip-permissions --continue || claude-new --dangerously-skip-permissions\n"
          )
        end

        it "finds a line another kind's configured command runs and replaces it" do
          allow(project_settings).to receive(:load).with("myapp").and_return({"agent" => {"commands" => {"codex" => "codex-dev --x"}}})

          expect(pc.rewrite_agent_pane("panes:\n  - codex-dev --x\n", "codex", "myapp")).to eq("panes:\n  - codex-dev --x\n")
          expect(pc.rewrite_agent_pane("panes:\n  - codex-dev --x\n", "pi", "myapp")).to eq("panes:\n  - pi\n")
        end

        it "reads a quoted pane line back before matching it" do
          content = "panes:\n  - \"claude-new --a: b --dangerously-skip-permissions\"\n"

          expect(pc.rewrite_agent_pane(content, "codex", "myapp")).to eq("panes:\n  - codex-dev\n")
        end

        it "is nil when no line runs an agent" do
          expect(pc.rewrite_agent_pane("panes:\n  - echo hi\n", "claude", "myapp")).to be_nil
        end
      end

      describe "#create" do
        let(:project_template) { File.join(tmpdir, "project-template.yml") }

        before do
          File.write(project_template, "panes:\n  - #{claude_line}\n")
          allow(config).to receive(:project_template_path).and_return(project_template)
        end

        it "writes the template's line when nothing is configured" do
          pc.create("myapp", "/tmp/myapp")

          expect(File.read(File.join(tmpdir, "workspace.myapp.yml"))).to eq("panes:\n  - #{claude_line}\n")
        end

        it "writes a configured claude command into both halves, quoted when it needs it" do
          allow(project_settings).to receive(:load).with("myapp").and_return({"agent" => {"commands" => {"claude" => "claude-dev --note 'a # b'"}}})

          pc.create("myapp", "/tmp/myapp")

          expect(YAML.safe_load_file(File.join(tmpdir, "workspace.myapp.yml"))).to eq(
            "panes" => ["claude-dev --note 'a # b' --dangerously-skip-permissions --continue || claude-dev --note 'a # b' --dangerously-skip-permissions"]
          )
        end

        it "warns and leaves the file as is when agent.kind is not claude and the template has no agent pane" do
          File.write(project_template, "panes:\n  - echo hi\n")
          allow(project_settings).to receive(:load).with("myapp").and_return({"agent" => {"kind" => "codex"}})

          pc.create("myapp", "/tmp/myapp")

          expect(File.read(File.join(tmpdir, "workspace.myapp.yml"))).to eq("panes:\n  - echo hi\n")
          expect(output.string).to include("Warning: agent.kind is set, but the template has no agent pane line to rewrite; the pane was left as is.")
        end

        it "warns naming agent.commands.claude when a configured claude command has no pane to rewrite" do
          File.write(project_template, "panes:\n  - echo hi\n")
          allow(project_settings).to receive(:load).with("myapp").and_return({"agent" => {"commands" => {"claude" => "claude-dev"}}})

          pc.create("myapp", "/tmp/myapp")

          expect(output.string).to include("Warning: agent.commands.claude is set")
        end

        it "says nothing for the default when the template has no agent pane" do
          File.write(project_template, "panes:\n  - echo hi\n")

          pc.create("myapp", "/tmp/myapp")

          expect(output.string).not_to include("Warning")
        end

        it "writes the configured command" do
          allow(project_settings).to receive(:load).with("myapp").and_return({"agent" => {"kind" => "codex", "commands" => {"codex" => "codex 'a: b'"}}})

          pc.create("myapp", "/tmp/myapp")

          expect(YAML.safe_load_file(File.join(tmpdir, "workspace.myapp.yml"))).to eq("panes" => ["codex 'a: b'"])
        end
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
