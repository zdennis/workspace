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
    allow(config).to receive(:render_state_dir).and_return(File.join(tmpdir, ".render"))
  end

  after do
    FileUtils.remove_entry(tmpdir)
    FileUtils.remove_entry(@builtin_dir) if @builtin_dir
  end

  # Points the built-in `default` tmuxinator template set at +path+ for +kind+, through a link, so a
  # spec that writes the file afterwards renders what it wrote.
  def stub_template(kind, path)
    @builtin_dir ||= Dir.mktmpdir("builtin-library")
    allow(config).to receive(:builtin_library_dir).and_return(@builtin_dir)
    dir = File.join(@builtin_dir, "template", "default")
    FileUtils.mkdir_p(dir)
    FileUtils.ln_sf(path, File.join(dir, "#{kind}.yml"))
    (@stubbed_templates ||= {})[kind] = path
  end

  def stubbed_template(kind)
    @stubbed_templates.fetch(kind)
  end

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
      stub_template(:project, File.join(tmpdir, "nonexistent.yml"))
      expect { pc.create("test", "/tmp/test") }.to raise_error(Workspace::Error) { |e| expect(e.code).to eq("library_source_missing") }
    end

    it "creates a config file from the template" do
      template_path = File.join(tmpdir, "project-template.yml")
      File.write(template_path, "name: {{PROJECT_NAME}}\nroot: {{PROJECT_ROOT}}\nconfig: {{CONFIG_PATH}}\n")
      stub_template(:project, template_path)

      result = pc.create("myapp", "/home/user/myapp")
      expect(result).to eq("myapp")

      content = File.read(File.join(tmpdir, "workspace.myapp.yml"))
      expect(content).to include("name: myapp")
      expect(content).to include("root: /home/user/myapp")
      expect(content).to include("config: #{File.join(tmpdir, "workspace.myapp.yml")}")
    end

    it "spaces the banner text of the shipped project template and keeps the real name everywhere else" do
      template = File.join(PROJECT_ROOT, "lib", "library", "template", "default", "project.yml")
      stub_template(:project, template)

      pc.create("my-app.v2", "/tmp/my-app.v2")

      content = File.read(File.join(tmpdir, "workspace.my-app.v2.yml"))
      expect(content).to include('ascii-banner "my app v2"')
      expect(content).to include("name: my-app.v2")
      expect(content).to include("root: /tmp/my-app.v2")
      expect(content).to include("@workspace my-app.v2 || true")
      expect(content).to include("echo 'Ready to work on my-app.v2'")
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
      stub_template(:worktree, template_path)

      result = pc.create_worktree("myapp", "PROJ-123", "/tmp/worktrees/PROJ-123", "PROJ-123")

      expect(result).to eq("myapp.worktree-proj-123")
      content = File.read(File.join(tmpdir, "workspace.myapp.worktree-proj-123.yml"))
      expect(content).to include("name: myapp-wt-proj-123")
      expect(content).to include("root: /tmp/worktrees/PROJ-123")
      expect(content).to include("project: myapp")
      expect(content).to include("branch: PROJ-123")
      expect(content).to include("display: myapp PROJ 123")
    end

    it "records the workspace name on the session in the shipped worktree template" do
      template = File.join(PROJECT_ROOT, "lib", "library", "template", "default", "worktree.yml")
      stub_template(:worktree, template)

      pc.create_worktree("myapp", "feat", "/tmp/wt/feat", "feat", quiet: true)

      content = File.read(File.join(tmpdir, "workspace.myapp.worktree-feat.yml"))
      expect(content).to include("tmux set-option -t '=myapp-wt-feat:' @workspace myapp.worktree-feat || true")
    end

    context "with the shipped worktree template" do
      before do
        template = File.join(PROJECT_ROOT, "lib", "library", "template", "default", "worktree.yml")
        stub_template(:worktree, template)
      end

      it "spaces the banner text and keeps the real names everywhere else" do
        pc.create_worktree("myapp", "feat.x-y_z", "/tmp/wt/feat.x-y_z", "feat.x-y_z", quiet: true)

        content = File.read(File.join(tmpdir, "workspace.myapp.worktree-feat.x-y_z.yml"))
        expect(content).to include('ascii-banner "myapp feat x y_z"')
        expect(content).to include("root: /tmp/wt/feat.x-y_z")
        expect(content).to include("@workspace myapp.worktree-feat.x-y_z || true")
        expect(content).to include("echo 'Worktree — feat.x-y_z (myapp)'")
      end

      it "keeps non-ASCII letters in the banner text" do
        pc.create_worktree("myapp", "café-x", "/tmp/wt/café-x", "café-x", quiet: true)

        content = File.read(File.join(tmpdir, "workspace.myapp.worktree-café-x.yml"))
        expect(content).to include('ascii-banner "myapp café x"')
      end
    end

    it "records it in the shipped project template too, ahead of the && chain and unable to break it" do
      template = File.join(PROJECT_ROOT, "lib", "library", "template", "default", "project.yml")
      stub_template(:project, template)

      pc.create("myapp", "/tmp/myapp")

      lines = File.read(File.join(tmpdir, "workspace.myapp.yml")).lines.map(&:strip)
      expect(lines).to include("tmux set-option -t '=myapp:' @workspace myapp || true")
    end

    context "with a {{PRE_WINDOW}} line in the template" do
      before do
        template_path = File.join(tmpdir, "project-worktree-template.yml")
        File.write(template_path, "name: {{TMUX_SESSION_NAME}}\n{{PRE_WINDOW}}\nwindows: []\n")
        stub_template(:worktree, template_path)
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
        stub_template(:worktree, path)

        expect(pc.agent_pane_command("claude")).to eq("claude --dangerously-skip-permissions --continue || claude --dangerously-skip-permissions")
        expect(pc.agent_pane_command("codex")).to eq("codex")
        expect(pc.agent_pane_command("vim")).to be_nil
      end

      it "is nil for claude when the template is missing or has no Claude Code pane" do
        path = File.join(tmpdir, "t.yml")
        stub_template(:worktree, path)
        expect(pc.agent_pane_command("claude")).to be_nil

        File.write(path, "panes:\n  - echo hi\n")
        expect(pc.agent_pane_command("claude")).to be_nil
      end
    end

    describe "#with_configured_program" do
      let(:settings) { {"agent" => {"commands" => {"claude" => "claude-dev"}}} }
      let(:project_settings) { instance_double(Workspace::ProjectSettings, load_global: settings, load: {}) }
      let(:agent_commands) { Workspace::AgentCommands.new(config_resolver: Workspace::ConfigResolver.new(project_settings: project_settings)) }
      subject(:pc) { described_class.new(config: config, output: output, git: git, agent_commands: agent_commands) }

      it "swaps the program in each half of the chain, keeping flags and other halves" do
        expect(pc.with_configured_program("claude --a --continue || claude --a", "claude", "app")).to eq("claude-dev --a --continue || claude-dev --a")
        expect(pc.with_configured_program("claude-dev --continue || claude", "claude", "app")).to eq("claude-dev --continue || claude-dev")
        expect(pc.with_configured_program("claude || echo failed", "claude", "app")).to eq("claude-dev || echo failed")
      end

      it "applies a command with extra words once, however often a line is passed through" do
        settings.replace("agent" => {"commands" => {"claude" => "mycl --flag"}})

        once = pc.with_configured_program("claude --x", "claude", "app")
        expect(once).to eq("mycl --flag --x")
        expect(pc.with_configured_program(once, "claude", "app")).to eq(once)
        expect(pc.with_configured_program("mycl --flag --x", "claude", "app")).to eq("mycl --flag --x")
      end

      it "returns the text for another kind and the executable when nothing is configured" do
        expect(pc.with_configured_program("codex --yolo", "codex", "app")).to eq("codex --yolo")
        settings.clear
        expect(pc.with_configured_program("claude --a", "claude", "app")).to eq("claude --a")
      end
    end

    describe "#check_agent_kind!" do
      it "raises template_outdated for a template with no Claude Code pane" do
        path = File.join(tmpdir, "t.yml")
        File.write(path, "panes:\n  - echo hi\n")
        stub_template(:worktree, path)

        expect { pc.check_agent_kind!("codex") }.to raise_error(Workspace::Error) { |e| expect(e.code).to eq("template_outdated") }
        expect { pc.check_agent_kind!("claude") }.not_to raise_error
      end
    end

    context "with an agent kind" do
      let(:template_path) { File.join(tmpdir, "project-worktree-template.yml") }

      def written = File.read(File.join(tmpdir, "workspace.myapp.worktree-proj-123.yml"))

      before { stub_template(:worktree, template_path) }

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
        stub_template(:worktree, template_path)
        File.write(template_path, "panes:\n  - echo hi\n  - #{claude_line}\n")
      end

      it "writes exactly the template's line when the command is the default" do
        pc.create_worktree("myapp", "PROJ-123", "/tmp/wt", "PROJ-123")

        expect(written).to eq("panes:\n  - echo hi\n  - #{claude_line}\n")
      end

      context "with a configured claude command" do
        let(:settings) { {"agent" => {"commands" => {"claude" => "claude-dev"}}} }

        before { allow(project_settings).to receive(:load).with("myapp").and_return({}) }

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

      context "with a template line that has no skip-permissions flag and a configured claude-dev" do
        let(:settings) { {"agent" => {"commands" => {"claude" => "claude-dev"}}} }
        let(:project_template_file) { File.join(tmpdir, "project-template.yml") }

        def project_pane = YAML.safe_load_file(File.join(tmpdir, "workspace.myapp.yml")).fetch("panes").last

        def write_templates(line)
          [template_path, project_template_file].each { |p| File.write(p, "panes:\n  - echo hi\n  - #{line}\n") }
        end

        before do
          stub_template(:project, project_template_file)
          write_templates("claude-dev --continue || claude")
        end

        it "runs claude-dev on both sides of || in a worktree config (start)" do
          pc.create_worktree("myapp", "PROJ-123", "/tmp/wt", "PROJ-123", agent_kind: "claude")

          expect(pane).to eq("claude-dev --continue || claude-dev")
        end

        it "runs claude-dev on both sides of || in a project config (add)" do
          pc.create("myapp", "/tmp/myapp")

          expect(project_pane).to eq("claude-dev --continue || claude-dev")
        end

        it "does the same for a bare claude line with no kind given" do
          write_templates("claude --continue || claude")

          pc.create_worktree("myapp", "PROJ-123", "/tmp/wt", "PROJ-123")
          pc.create("myapp", "/tmp/myapp")

          expect(pane).to eq("claude-dev --continue || claude-dev")
          expect(project_pane).to eq("claude-dev --continue || claude-dev")
        end
      end

      describe "#agent_pane_command" do
        let(:settings) { {"agent" => {"commands" => {"claude" => "claude-dev", "codex" => "codex-x"}}} }

        it "uses the configured command for the workspace, the executable without one" do
          expect(pc.agent_pane_command("claude", "myapp")).to eq(claude_line.gsub("claude ", "claude-dev "))
          expect(pc.agent_pane_command("codex", "myapp")).to eq("codex-x")
          expect(pc.agent_pane_command("codex")).to eq("codex")
        end

        context "with a template line without the skip-permissions flag" do
          def template(line) = File.write(template_path, "panes:\n  - echo hi\n  - #{line}\n")

          it "finds it and swaps the program in each half that runs Claude Code" do
            template("claude-dev --continue || claude")

            expect(pc.agent_pane_command("claude", "myapp")).to eq("claude-dev --continue || claude-dev")
            expect { pc.check_agent_kind!("codex") }.not_to raise_error
          end

          it "finds it for a nil workspace through the bare executable in its second half, leaving the first half" do
            template("claude-dev --continue || claude")

            expect(pc.agent_pane_command("claude")).to eq("claude-dev --continue || claude")
          end

          it "finds it for a nil workspace through its first program" do
            template("claude --continue || echo failed")

            expect(pc.agent_pane_command("claude")).to eq("claude --continue || echo failed")
          end

          it "finds a line whose first half runs another program" do
            template("echo x || claude")

            expect(pc.agent_pane_command("claude", "myapp")).to eq("echo x || claude-dev")
          end

          it "prefers the flagged pane over an earlier plain Claude Code line" do
            File.write(template_path, "panes:\n  - claude --version\n  - #{claude_line}\n")

            expect(pc.agent_pane_command("claude", "myapp")).to eq(claude_line.gsub("claude ", "claude-dev "))
          end

          it "does not take a Claude Code entry of a hook list before panes:" do
            File.write(template_path, "pre_window:\n  - claude --version\npanes:\n  - echo hi\n  - #{claude_line}\n")

            expect(pc.agent_pane_command("claude", "myapp")).to eq(claude_line.gsub("claude ", "claude-dev "))
          end

          it "finds no pane when only a hook list runs Claude Code" do
            File.write(template_path, "pre_window:\n  - claude --version\npanes:\n  - echo hi\n")

            expect(pc.agent_pane_command("claude", "myapp")).to be_nil
          end

          it "lets check_agent_kind! pass for an all-custom line when given the configured workspace" do
            settings.replace("agent" => {"commands" => {"claude" => "mycl"}})
            template("mycl --continue || mycl")

            expect { pc.check_agent_kind!("codex", "myapp") }.not_to raise_error
          end

          it "rewrites a codex pane through the template fallback" do
            template("claude --continue || claude")

            expect(pc.rewrite_agent_pane("panes:\n  - codex\n", "claude", "myapp")).to eq("panes:\n  - claude-dev --continue || claude-dev\n")
          end

          it "does not take a line of another program for the template's pane" do
            template("echo x || echo y")

            expect(pc.agent_pane_command("claude", "myapp")).to be_nil
            expect { pc.check_agent_kind!("codex") }.to raise_error(Workspace::Error) { |e| expect(e.code).to eq("template_outdated") }
          end
        end
      end

      describe "#stale_agent_pane" do
        let(:settings) { {"agent" => {"commands" => {"claude" => "claude-new"}}} }
        let(:path) { File.join(tmpdir, "workspace.myapp.yml") }

        it "describes the pane line that runs another program" do
          File.write(path, "panes:\n  - claude --dangerously-skip-permissions\n")

          stale = pc.stale_agent_pane("myapp", "claude")

          expect(stale).to include(path: path, running: "claude", wanted: "claude-new",
            content: "panes:\n  - claude-new --dangerously-skip-permissions\n")
        end

        it "is stale when a fallback half runs another program, naming the fallback's program" do
          File.write(path, "panes:\n  - claude-new --continue || claude --continue\n")

          expect(pc.stale_agent_pane("myapp", "claude")).to include(running: "claude", wanted: "claude-new",
            content: "panes:\n  - claude-new --continue || claude-new --continue\n")
        end

        it "is not stale for flag differences or a non-agent fallback" do
          File.write(path, "panes:\n  - claude-new --continue || claude-new --other\n")
          expect(pc.stale_agent_pane("myapp", "claude")).to be_nil
          File.write(path, "panes:\n  - claude-new --continue || echo failed\n")
          expect(pc.stale_agent_pane("myapp", "claude")).to be_nil
        end

        it "names the first half's program when several halves are stale" do
          File.write(path, "panes:\n  - claude --continue || claude\n")

          expect(pc.stale_agent_pane("myapp", "claude")).to include(running: "claude", wanted: "claude-new")
        end

        it "is not stale for an ordinary claude || claude line with no key set" do
          settings.clear
          File.write(path, "panes:\n  - claude --continue || claude\n")

          expect(pc.stale_agent_pane("myapp", "claude")).to be_nil
        end

        it "is nil for a current pane, kind none, a missing pane and an unreadable config" do
          File.write(path, "panes:\n  - claude-new --dangerously-skip-permissions\n")
          expect(pc.stale_agent_pane("myapp", "claude")).to be_nil
          expect(pc.stale_agent_pane("myapp", "none")).to be_nil
          File.write(path, "panes:\n  - echo hi\n")
          expect(pc.stale_agent_pane("myapp", "claude")).to be_nil
          expect(pc.stale_agent_pane("nope", "claude")).to be_nil
        end
      end

      describe "#rewrite_agent_pane" do
        let(:settings) { {"agent" => {"commands" => {"claude" => "claude-old", "codex" => "codex-dev"}}} }

        before { allow(project_settings).to receive(:load).with("myapp").and_return({"agent" => {"commands" => {"claude" => "claude-new"}}}) }

        context "with a line that has no --dangerously-skip-permissions" do
          let(:settings) { {"agent" => {"commands" => {"claude" => "claude-dev"}}} }

          before { allow(project_settings).to receive(:load).with("myapp").and_return({}) }

          def rewrite(line) = pc.rewrite_agent_pane("panes:\n  - #{line}\n", "claude", "myapp")

          it "swaps the fallback half too and adds no flag" do
            expect(rewrite("claude-dev --continue || claude")).to eq("panes:\n  - claude-dev --continue || claude-dev\n")
          end

          it "swaps a plain claude line" do
            expect(rewrite("claude --continue || claude")).to eq("panes:\n  - claude-dev --continue || claude-dev\n")
          end

          it "keeps different flags in each half" do
            expect(rewrite("claude --resume || claude --model opus")).to eq("panes:\n  - claude-dev --resume || claude-dev --model opus\n")
          end

          it "keeps a half that runs another program" do
            expect(rewrite("claude-dev --continue || echo failed")).to eq("panes:\n  - claude-dev --continue || echo failed\n")
          end

          it "returns the same content when the line is already right" do
            content = "panes:\n  - claude-dev --continue || claude-dev\n"

            expect(pc.rewrite_agent_pane(content, "claude", "myapp")).to eq(content)
          end

          it "keeps a quoted path and VAR=value words" do
            expect(rewrite("\x27FOO=1 \"/my bin/claude\" --continue || claude\x27")).to eq("panes:\n  - FOO=1 claude-dev --continue || claude-dev\n")
          end

          it "takes the template line for a line of another agent" do
            expect(pc.rewrite_agent_pane("panes:\n  - codex --x || claude --y\n", "claude", "myapp")).to eq(
              "panes:\n  - claude-dev --dangerously-skip-permissions --continue || claude-dev --dangerously-skip-permissions\n"
            )
            expect(pc.rewrite_agent_pane("panes:\n  - codex --x\n", "claude", "myapp")).to eq(
              "panes:\n  - claude-dev --dangerously-skip-permissions --continue || claude-dev --dangerously-skip-permissions\n"
            )
          end

          it "prints no warning when generation meets the reported line" do
            project_template = File.join(tmpdir, "project-template.yml")
            File.write(project_template, "panes:\n  - claude-dev --continue || claude\n")
            stub_template(:project, project_template)

            pc.create("myapp", "/tmp/myapp")

            expect(output.string).not_to include("Warning")
            expect(File.read(File.join(tmpdir, "workspace.myapp.yml"))).to eq("panes:\n  - claude-dev --continue || claude-dev\n")
          end
        end

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

        it "replaces a quoted program with a space whole, keeping the flags" do
          content = "panes:\n  - '\"/my bin/claude-old\" --continue || claude-old --dangerously-skip-permissions'\n"

          expect(pc.rewrite_agent_pane(content, "claude", "myapp")).to eq(
            "panes:\n  - claude-new --continue || claude-new --dangerously-skip-permissions\n"
          )
        end

        it "replaces a program past VAR=value words and a trailing backslash" do
          content = "panes:\n  - 'FOO=1 claude-old --dangerously-skip-permissions \\'\n"

          expect(pc.rewrite_agent_pane(content, "claude", "myapp")).to eq("panes:\n  - FOO=1 claude-new --dangerously-skip-permissions \\\n")
        end

        it "is nil when no line runs an agent" do
          expect(pc.rewrite_agent_pane("panes:\n  - echo hi\n", "claude", "myapp")).to be_nil
        end
      end

      describe "#create" do
        let(:project_template) { File.join(tmpdir, "project-template.yml") }

        before do
          File.write(project_template, "panes:\n  - #{claude_line}\n")
          stub_template(:project, project_template)
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

    it "names a worktree config from the project and the sanitized directory name, in lowercase" do
      allow(pc).to receive(:settle_new_name) { |name, _path| name }

      expect(pc.settle_worktree_name("MyApp", "PROJ/123", "/tmp/wt")).to eq("myapp.worktree-proj-123")
    end

    it "raises error when worktree template is missing" do
      stub_template(:worktree, File.join(tmpdir, "nonexistent.yml"))
      expect {
        pc.create_worktree("myapp", "branch", "/tmp/wt", "branch")
      }.to raise_error(Workspace::Error) { |e| expect(e.code).to eq("library_source_missing") }
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

    it "deletes the config's render record with it" do
      writer = Workspace::TmuxinatorConfigWriter.new(config: config)
      writer.write("myapp", "x", kind: :project, template: "default", template_sha: "abc", inputs: {workspace_name: "myapp"})

      pc.remove("myapp", quiet: true)

      expect(File.exist?(File.join(tmpdir, "workspace.myapp.yml"))).to be(false)
      expect(File.exist?(writer.record_path("myapp"))).to be(false)
    end

    it "deletes a render record left behind with no config" do
      writer = Workspace::TmuxinatorConfigWriter.new(config: config)
      writer.write("myapp", "x", kind: :project, template: "default", template_sha: "abc", inputs: {workspace_name: "myapp"})
      File.delete(File.join(tmpdir, "workspace.myapp.yml"))

      pc.remove("myapp", quiet: true)

      expect(File.exist?(writer.record_path("myapp"))).to be(false)
    end

    it "leaves another workspace's render record alone" do
      writer = Workspace::TmuxinatorConfigWriter.new(config: config)
      writer.write("myapp", "x", kind: :project, template: "default", template_sha: "abc", inputs: {workspace_name: "myapp"})
      writer.write("other", "y", kind: :project, template: "default", template_sha: "abc", inputs: {workspace_name: "other"})

      pc.remove("myapp", quiet: true)

      expect(writer.record("other")).not_to be_nil
    end

    it "still removes the config when the render record can't be deleted" do
      writer = instance_double(Workspace::TmuxinatorConfigWriter)
      allow(writer).to receive(:remove_record).and_raise(Errno::EACCES)
      path = File.join(tmpdir, "workspace.myapp.yml")
      File.write(path, "x")

      expect { described_class.new(config: config, output: output, git: git, writer: writer).remove("myapp") }.not_to raise_error

      expect(File.exist?(path)).to be(false)
      expect(output.string).to include("Removed config: #{path}")
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

    it "returns nil when config holds a disallowed YAML class" do
      File.write(File.join(tmpdir, "workspace.odd.yml"), "root: !ruby/object:Object {}\n")
      expect(pc.project_root_for("odd")).to be_nil
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
    let(:worktree_template_file) { File.join(tmpdir, "project-worktree-template.yml") }
    let(:root) { Dir.mktmpdir("notes-root") }
    let(:other_root) { Dir.mktmpdir("other-root") }

    before do
      File.write(template_path, "name: {{PROJECT_NAME}}\nroot: {{PROJECT_ROOT}}\n")
      File.write(worktree_template_file, "name: {{TMUX_SESSION_NAME}}\nroot: {{WORKTREE_PATH}}\n")
      stub_template(:project, template_path)
      stub_template(:worktree, worktree_template_file)
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
        expect(e.message).to include("'Notes'").and include("'notes'").and include(other_root).and include("share config and state files").and include("a directory with a different name")
        expect(e.message).not_to match(/renamed/)
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

  describe "rendered output of the shipped tmuxinator templates" do
    let(:fixtures) { File.join(PROJECT_ROOT, "spec", "fixtures", "tmuxinator_render") }
    let(:settings) { {} }
    let(:project_settings) { instance_double(Workspace::ProjectSettings, load_global: settings, load: {}) }
    let(:agent_commands) { Workspace::AgentCommands.new(config_resolver: Workspace::ConfigResolver.new(project_settings: project_settings)) }
    subject(:pc) { described_class.new(config: config, output: output, git: git, agent_commands: agent_commands) }

    before do
      stub_template(:project, File.join(PROJECT_ROOT, "lib", "library", "template", "default", "project.yml"))
      stub_template(:worktree, File.join(PROJECT_ROOT, "lib", "library", "template", "default", "worktree.yml"))
    end

    def fixture(name) = File.read(File.join(fixtures, name)).gsub("$TMPDIR", tmpdir)

    def written(name) = File.read(File.join(tmpdir, "workspace.#{name}.yml"))

    it "renders a project config" do
      pc.create("myapp", "/src/my app")

      expect(written("myapp")).to eq(fixture("project.yml"))
    end

    it "renders a worktree config with no task id and claude" do
      pc.create_worktree("myapp", "PROJ-123", "/src/myapp/.worktrees/PROJ-123", "PROJ-123")

      expect(written("myapp.worktree-proj-123")).to eq(fixture("worktree.yml"))
    end

    it "renders a worktree config with a task id" do
      pc.create_worktree("myapp", "PROJ-123", "/src/myapp/.worktrees/PROJ-123", "PROJ-123", task_id: "t_abc123")

      expect(written("myapp.worktree-proj-123")).to eq(fixture("worktree-with-task.yml"))
    end

    it "renders a worktree config for a configured claude program" do
      settings.replace("agent" => {"commands" => {"claude" => "claude-dev"}})

      pc.create_worktree("myapp", "PROJ-123", "/src/myapp/.worktrees/PROJ-123", "PROJ-123")

      expect(written("myapp.worktree-proj-123")).to eq(fixture("worktree-claude-dev.yml"))
    end

    it "renders a worktree config for codex" do
      pc.create_worktree("myapp", "PROJ-123", "/src/myapp/.worktrees/PROJ-123", "PROJ-123", agent_kind: "codex")

      expect(written("myapp.worktree-proj-123")).to eq(fixture("worktree-codex.yml"))
    end

    it "writes files with the mode File.write gives under the current umask" do
      control = File.join(tmpdir, "control")
      File.write(control, "x")
      pc.create("myapp", "/src/myapp")
      pc.create_worktree("myapp", "PROJ-123", "/src/myapp/.worktrees/PROJ-123", "PROJ-123")

      expected = File.stat(control).mode
      expect(File.stat(File.join(tmpdir, "workspace.myapp.yml")).mode).to eq(expected)
      expect(File.stat(File.join(tmpdir, "workspace.myapp.worktree-proj-123.yml")).mode).to eq(expected)
    end

    it "leaves a render record beside each new config, and the record renders the same text again" do
      writer = Workspace::TmuxinatorConfigWriter.new(config: config)
      settings.replace("agent" => {"commands" => {"claude" => "claude-dev"}})
      pc.create("myapp", "/src/my app")
      pc.create_worktree("myapp", "PROJ-123", "/src/myapp/.worktrees/PROJ-123", "PROJ-123", task_id: "t_abc123")

      project = writer.record("myapp")
      worktree = writer.record("myapp.worktree-proj-123")
      expect(project.kind).to eq(:project)
      expect(project.template).to eq("default")
      expect(project.template_sha).to eq(Digest::SHA256.hexdigest(File.read(stubbed_template(:project))))
      expect(worktree.template_sha).to eq(Digest::SHA256.hexdigest(File.read(stubbed_template(:worktree))))
      expect(worktree.inputs).to include(workspace_name: "myapp.worktree-proj-123", worktree_branch: "PROJ-123",
        task_id: "t_abc123", agent_kind: "claude",
        agent_command: "claude-dev --dangerously-skip-permissions --continue || claude-dev --dangerously-skip-permissions")
      expect(writer.current?("myapp")).to be(true)
      expect(writer.current?("myapp.worktree-proj-123")).to be(true)
      expect(pc.render(project.kind, project.inputs, File.read(stubbed_template(:project)))).to eq(written("myapp"))
      expect(pc.render(worktree.kind, worktree.inputs, File.read(stubbed_template(:worktree)))).to eq(written("myapp.worktree-proj-123"))
    end

    it "records a nil task id and the codex pane" do
      writer = Workspace::TmuxinatorConfigWriter.new(config: config)
      pc.create_worktree("myapp", "PROJ-123", "/src/myapp/.worktrees/PROJ-123", "PROJ-123", agent_kind: "codex")

      inputs = writer.record("myapp.worktree-proj-123").inputs
      expect(inputs).to include(task_id: nil, agent_kind: "codex", agent_command: "codex")
      expect(pc.render(:worktree, inputs, File.read(stubbed_template(:worktree)))).to eq(fixture("worktree-codex.yml"))
    end

    it "writes nothing when the config already exists" do
      path = File.join(tmpdir, "workspace.myapp.yml")
      worktree_path = File.join(tmpdir, "workspace.myapp.worktree-proj-123.yml")
      File.write(path, "keep\n")
      File.write(worktree_path, "keep\n")

      pc.create("myapp", "/src/myapp")
      pc.create_worktree("myapp", "PROJ-123", "/src/myapp/.worktrees/PROJ-123", "PROJ-123")

      expect(File.read(path)).to eq("keep\n")
      expect(File.read(worktree_path)).to eq("keep\n")
      expect(File.exist?(File.join(tmpdir, ".render"))).to be(false)
    end

    describe "the {{AGENT_COMMAND}} placeholder" do
      let(:legacy) { File.join(PROJECT_ROOT, "spec", "fixtures", "legacy_templates") }
      let(:placeholder_templates) { File.join(PROJECT_ROOT, "lib", "library", "template", "default") }
      let(:flagged) { "claude --dangerously-skip-permissions --continue || claude --dangerously-skip-permissions" }

      def template_file(dir, kind)
        File.join(dir, "#{kind}.yml")
      end

      def use_templates(dir)
        stub_template(:project, template_file(dir, "project"))
        stub_template(:worktree, template_file(dir, "worktree"))
      end

      def create_all
        pc.create("myapp", "/src/my app")
        pc.create_worktree("myapp", "PROJ-123", "/src/myapp/.worktrees/PROJ-123", "PROJ-123")
      end

      it "ships in both templates as the agent pane line" do
        %w[project.yml worktree.yml].each do |name|
          lines = File.readlines(File.join(placeholder_templates, name))
          expect(lines.grep(/AGENT_COMMAND/).map(&:strip)).to eq(["- {{AGENT_COMMAND}}"])
          expect(lines.grep(/claude/)).to be_empty
        end
      end

      it "has a DEFAULT_CLAUDE_PANE equal to the legacy worktree template's pane, frozen" do
        pane = File.readlines(File.join(legacy, "worktree.yml")).filter_map { |l| l[/^\s*- (claude .*?)\s*$/, 1] }
        expect(pane).to eq([described_class::DEFAULT_CLAUDE_PANE])
        expect(described_class::DEFAULT_CLAUDE_PANE).to be_frozen
      end

      [
        ["the placeholder templates", :placeholder_templates],
        ["the legacy templates, through the literal-line path", :legacy]
      ].each do |label, dir|
        context "with #{label}" do
          before { use_templates(send(dir)) }

          it "renders the four pinned files" do
            pc.create("myapp", "/src/my app")
            expect(written("myapp")).to eq(fixture("project.yml"))
            pc.create_worktree("myapp", "PROJ-123", "/src/myapp/.worktrees/PROJ-123", "PROJ-123")
            expect(written("myapp.worktree-proj-123")).to eq(fixture("worktree.yml"))
            File.delete(File.join(tmpdir, "workspace.myapp.worktree-proj-123.yml"))
            pc.create_worktree("myapp", "PROJ-123", "/src/myapp/.worktrees/PROJ-123", "PROJ-123", agent_kind: "codex")
            expect(written("myapp.worktree-proj-123")).to eq(fixture("worktree-codex.yml"))
            File.delete(File.join(tmpdir, "workspace.myapp.worktree-proj-123.yml"))
            settings.replace("agent" => {"commands" => {"claude" => "claude-dev"}})
            pc.create_worktree("myapp", "PROJ-123", "/src/myapp/.worktrees/PROJ-123", "PROJ-123")
            expect(written("myapp.worktree-proj-123")).to eq(fixture("worktree-claude-dev.yml"))
          end

          it "quotes a shell-unsafe configured command as rewrite_agent_pane does" do
            settings.replace("agent" => {"commands" => {"claude" => "my cl: #x"}})
            pc.create_worktree("myapp", "PROJ-123", "/src/myapp/.worktrees/PROJ-123", "PROJ-123")

            text = written("myapp.worktree-proj-123")
            expect(text).to include(%(- "my cl: #x --dangerously-skip-permissions --continue || my cl: #x --dangerously-skip-permissions"))
            expect(text).to eq(pc.rewrite_agent_pane(fixture("worktree.yml"), "claude", "myapp.worktree-proj-123"))
          end

          it "pins spawn_command" do
            main_agent = Workspace::MainAgent.new(project_config: pc, agent_commands: agent_commands)

            expect(pc.agent_pane_command("claude")).to eq(flagged)
            expect(pc.agent_pane_command("codex")).to eq("codex")
            expect(main_agent.spawn_command("myapp", "claude")).to eq("claude --dangerously-skip-permissions")
            expect(main_agent.spawn_command("myapp", "codex")).to eq("codex")
          end

          it "swaps a codex pane back to claude with the flags" do
            codex = fixture("worktree-codex.yml")
            expect(pc.rewrite_agent_pane(codex, "claude", "myapp.worktree-proj-123")).to eq(fixture("worktree.yml"))
          end

          it "raises the same error for a kind with no AgentProvider entry" do
            expect { pc.check_agent_kind!("vim") }.not_to raise_error
            expect { pc.create_worktree("myapp", "PROJ-123", "/tmp/wt", "PROJ-123", agent_kind: "vim") }
              .to raise_error(ArgumentError, /unknown agent kind "vim"/)
          end
        end
      end

      it "gives agent_pane_command the flagged default line for a placeholder template and the literal line's flags for a literal one" do
        use_templates(placeholder_templates)
        expect(pc.agent_pane_command("claude")).to eq(flagged)
        use_templates(legacy)
        expect(pc.agent_pane_command("claude")).to eq(flagged)
        File.write(File.join(tmpdir, "literal.yml"), "panes:\n  - claude --model opus\n")
        stub_template(:worktree, File.join(tmpdir, "literal.yml"))
        expect(pc.agent_pane_command("claude")).to eq("claude --model opus")
      end

      it "raises the swap error for an unknown kind when no AgentCommands is wired, under either template style" do
        bare = described_class.new(config: config, output: output, git: git)
        [placeholder_templates, legacy].each do |dir|
          use_templates(dir)
          expect { bare.create_worktree("myapp", "PROJ-123", "/tmp/wt", "PROJ-123", agent_kind: "vim") }
            .to raise_error(Workspace::Error, /no Claude Code pane to swap for vim/)
        end
      end

      it "passes check_agent_kind! for a placeholder template" do
        use_templates(placeholder_templates)
        expect { pc.check_agent_kind!("codex") }.not_to raise_error
      end

      it "records the agent pane text the placeholder was filled with" do
        use_templates(placeholder_templates)
        create_all
        writer = Workspace::TmuxinatorConfigWriter.new(config: config)
        expect(writer.record("myapp.worktree-proj-123").inputs[:agent_command]).to eq(flagged)
      end
    end

    describe "#render" do
      let(:project_text) { File.read(stubbed_template(:project)) }
      let(:worktree_text) { File.read(stubbed_template(:worktree)) }
      let(:worktree_inputs) do
        {
          tmux_session_name: "myapp-wt-proj-123", workspace_name: "myapp.worktree-proj-123",
          worktree_path: "/src/myapp/.worktrees/PROJ-123", project_name: "myapp", worktree_branch: "PROJ-123",
          display_name: "myapp PROJ 123", config_path: File.join(tmpdir, "workspace.myapp.worktree-proj-123.yml"),
          task_id: nil, agent_kind: "claude"
        }
      end

      it "gives the project fixture bytes and writes nothing" do
        text = pc.render(:project, {
          project_name: "myapp", workspace_name: "myapp", project_root: "/src/my app",
          display_name: "myapp", config_path: File.join(tmpdir, "workspace.myapp.yml"), agent_kind: "claude"
        }, project_text)

        expect(text).to eq(fixture("project.yml"))
        expect(Dir.children(tmpdir)).to be_empty
      end

      it "gives the worktree fixture bytes with and without a task id, and for codex" do
        expect(pc.render(:worktree, worktree_inputs, worktree_text)).to eq(fixture("worktree.yml"))
        expect(pc.render(:worktree, worktree_inputs.merge(task_id: "t_abc123"), worktree_text)).to eq(fixture("worktree-with-task.yml"))
        expect(pc.render(:worktree, worktree_inputs.merge(agent_kind: "codex"), worktree_text)).to eq(fixture("worktree-codex.yml"))
        expect(Dir.children(tmpdir)).to be_empty
      end

      it "raises when a required input is nil and the template holds its placeholder" do
        expect { pc.render(:worktree, worktree_inputs.merge(worktree_path: nil), worktree_text) }
          .to raise_error(Workspace::Error, /no value for WORKTREE_PATH/)
      end

      it "raises for a project template with no project_root" do
        inputs = {project_name: "myapp", workspace_name: "myapp", project_root: nil, display_name: "myapp", config_path: "/x.yml", agent_kind: "claude"}
        expect { pc.render(:project, inputs, project_text) }.to raise_error(Workspace::Error, /no value for PROJECT_ROOT/)
      end

      it "leaves an optional nil input alone" do
        expect(pc.render(:worktree, worktree_inputs.merge(task_id: nil), worktree_text)).to eq(fixture("worktree.yml"))
      end

      it "raises for a worktree whose template has no pane to swap for the agent kind" do
        text = worktree_text.lines.grep_v(/claude|codex|AGENT_COMMAND/).join

        expect { pc.render(:worktree, worktree_inputs.merge(agent_kind: "codex"), text) }
          .to raise_error(Workspace::Error, /no Claude Code pane to swap for codex/)
      end

      it "puts a project_root with a backslash in literally" do
        text = pc.render(:project, {
          project_name: "myapp", workspace_name: "myapp", project_root: '/src/a\\1b',
          display_name: "myapp", config_path: "/c.yml", agent_kind: "claude"
        }, project_text)

        expect(text).to include('/src/a\\1b')
      end

      it "ignores task_id for a project" do
        inputs = {
          project_name: "myapp", workspace_name: "myapp", project_root: "/src/my app",
          display_name: "myapp", config_path: File.join(tmpdir, "workspace.myapp.yml"), agent_kind: "claude"
        }

        expect(pc.render(:project, inputs.merge(task_id: "t_abc123"), project_text)).to eq(pc.render(:project, inputs, project_text))
      end
    end
  end

  describe "templates resolved through Library#tmuxinator_template" do
    let(:settings) { {} }
    let(:project_settings) { instance_double(Workspace::ProjectSettings, load_global: settings, load: {}) }
    let(:resolver) { Workspace::ConfigResolver.new(project_settings: project_settings) }
    let(:library) do
      Workspace::Library.new(config: config, lineage: nil, project_config: pc,
        template_config: Workspace::TmuxinatorTemplateConfig.new(config_resolver: resolver))
    end
    let(:writer) { Workspace::TmuxinatorConfigWriter.new(config: config) }
    subject(:pc) { described_class.new(config: config, output: output, git: git, library: -> { library }) }

    before do
      allow(config).to receive(:library_dir).and_return(File.join(tmpdir, "library"))
      allow(config).to receive(:builtin_library_dir).and_return(File.join(PROJECT_ROOT, "lib", "library"))
    end

    def global_set(name, project:, worktree:)
      dir = File.join(tmpdir, "library", "global", "template", name)
      FileUtils.mkdir_p(dir)
      File.write(File.join(dir, "project.yml"), project)
      File.write(File.join(dir, "worktree.yml"), worktree)
    end

    it "renders from the global set tmuxinator.template selects, and the record names it" do
      settings.replace("tmuxinator" => {"template" => "team"})
      global_set("team", project: "name: {{PROJECT_NAME}}\n", worktree: "name: {{TMUX_SESSION_NAME}}\npanes:\n  - {{AGENT_COMMAND}}\n")

      pc.create("myapp", "/src/myapp")
      pc.create_worktree("myapp", "feat", "/src/myapp/.worktrees/feat", "feat", agent_kind: "codex")

      expect(File.read(File.join(tmpdir, "workspace.myapp.yml"))).to eq("name: myapp\n")
      expect(File.read(File.join(tmpdir, "workspace.myapp.worktree-feat.yml"))).to eq("name: myapp-wt-feat\npanes:\n  - codex\n")
      expect(writer.record("myapp").template).to eq("team")
      expect(writer.record("myapp.worktree-feat").template).to eq("team")
      expect(pc.agent_pane_command("claude", "myapp")).to eq(described_class::DEFAULT_CLAUDE_PANE)
    end

    it "reads the agent pane of the selected worktree template" do
      settings.replace("tmuxinator" => {"worktree_template" => "team"})
      global_set("team", project: "x\n", worktree: "panes:\n  - claude --model opus\n")

      expect(pc.agent_pane_command("claude", "myapp")).to eq("claude --model opus")
      expect { pc.check_agent_kind!("codex", "myapp") }.not_to raise_error
    end

    it "refuses an agent kind for a set no store has, before anything is written" do
      settings.replace("tmuxinator" => {"template" => "gone"})

      expect { pc.check_agent_kind!("codex", "myapp") }.to raise_error(Workspace::Error) { |e| expect(e.details).to include("kind" => "tmuxinator") }
      expect { pc.create("myapp", "/src/myapp") }.to raise_error(Workspace::Error) { |e| expect(e.code).to eq("unknown_template") }
      expect(File.exist?(File.join(tmpdir, "workspace.myapp.yml"))).to be(false)
      expect(pc.agent_pane_command("claude", "myapp")).to be_nil
    end

    it "renders from an edited installed copy while no key is set, and records it as legacy" do
      File.write(Workspace::LegacyTmuxinatorTemplates.path(:project, tmpdir), "name: {{PROJECT_NAME}} # mine\n")

      pc.create("myapp", "/src/myapp")

      expect(File.read(File.join(tmpdir, "workspace.myapp.yml"))).to eq("name: myapp # mine\n")
      expect(writer.record("myapp").template).to eq("legacy")
    end
  end
end
