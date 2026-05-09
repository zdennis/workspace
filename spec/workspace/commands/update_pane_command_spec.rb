require "tmpdir"
require "fileutils"

RSpec.describe Workspace::Commands::UpdatePaneCommand do
  let(:tmpdir) { Dir.mktmpdir }
  let(:tmuxinator_dir) { File.join(tmpdir, "tmuxinator") }
  let(:config) do
    c = Workspace::Config.new(workspace_dir: tmpdir)
    allow(c).to receive(:tmuxinator_dir).and_return(tmuxinator_dir)
    allow(c).to receive(:config_path_for) { |name| File.join(tmuxinator_dir, "workspace.#{name}.yml") }
    c
  end
  let(:project_config) do
    pc = instance_double(Workspace::ProjectConfig)
    allow(pc).to receive(:exists?).with("myproject").and_return(true)
    allow(pc).to receive(:exists?).with("missing").and_return(false)
    pc
  end
  let(:output) { StringIO.new }
  let(:input) { StringIO.new }

  subject(:command) do
    described_class.new(
      config: config,
      project_config: project_config,
      output: output,
      input: input
    )
  end

  before { FileUtils.mkdir_p(tmuxinator_dir) }
  after { FileUtils.remove_entry(tmpdir) }

  let(:config_path) { File.join(tmuxinator_dir, "workspace.myproject.yml") }

  let(:base_config) do
    <<~YAML
      # /path/to/config

      name: myproject
      root: /some/path
      tmux_options: -CC
      attach: false

      startup_pane: 2

      windows:
        - workspace-myproject:
            layout: even-vertical
            panes:
              - ascii-banner "myproject"
              - claude --continue || claude
              - echo 'Ready'
    YAML
  end

  before { File.write(config_path, base_config) }

  describe "#call" do
    context "when project does not exist" do
      it "raises UsageError" do
        expect {
          command.call(project: "missing", command: "vim", pane_index: 1)
        }.to raise_error(Workspace::UsageError, /not found/)
      end
    end

    context "when tmuxinator config file is missing" do
      before { File.delete(config_path) }

      it "raises Error" do
        expect {
          command.call(project: "myproject", command: "vim", pane_index: 1)
        }.to raise_error(Workspace::Error, /not found/)
      end
    end

    context "when pane_index is negative" do
      it "raises UsageError" do
        expect {
          command.call(project: "myproject", command: "vim", pane_index: -1)
        }.to raise_error(Workspace::UsageError, /1 or greater/)
      end
    end

    context "when pane_index is zero" do
      it "raises UsageError" do
        expect {
          command.call(project: "myproject", command: "vim", pane_index: 0)
        }.to raise_error(Workspace::UsageError, /1 or greater/)
      end
    end

    context "when replacing an existing pane" do
      it "updates pane 2 command" do
        command.call(project: "myproject", command: "vim .", pane_index: 2)

        updated = YAML.safe_load_file(config_path)
        panes = updated.dig("windows", 0, "workspace-myproject", "panes")
        expect(panes[1]).to eq("vim .")
      end

      it "preserves other panes" do
        command.call(project: "myproject", command: "vim .", pane_index: 2)

        updated = YAML.safe_load_file(config_path)
        panes = updated.dig("windows", 0, "workspace-myproject", "panes")
        expect(panes[0]).to include("ascii-banner")
        expect(panes[2]).to include("Ready")
      end

      it "prints project name and pane summary" do
        command.call(project: "myproject", command: "vim .", pane_index: 2)

        expect(output.string).to include("Project: myproject")
        expect(output.string).to include("[1]")
        expect(output.string).to include("[2]")
        expect(output.string).to include("[3]")
      end
    end

    context "when pane_index is beyond the last pane" do
      context "and user confirms" do
        before do
          input.string = "y\n"
          input.rewind
        end

        it "appends a new pane at the next available index" do
          command.call(project: "myproject", command: "htop", pane_index: 10)

          updated = YAML.safe_load_file(config_path)
          panes = updated.dig("windows", 0, "workspace-myproject", "panes")
          expect(panes.size).to eq(4)
          expect(panes.last).to eq("htop")
        end

        it "prints the updated pane summary with the new pane" do
          command.call(project: "myproject", command: "htop", pane_index: 10)

          expect(output.string).to include("[4]")
          expect(output.string).to include("htop")
        end
      end

      context "and user declines" do
        before do
          input.string = "n\n"
          input.rewind
        end

        it "does not modify the config" do
          original = File.read(config_path)
          command.call(project: "myproject", command: "htop", pane_index: 10)
          expect(File.read(config_path)).to eq(original)
        end

        it "prints Cancelled" do
          command.call(project: "myproject", command: "htop", pane_index: 10)
          expect(output.string).to include("Cancelled")
        end
      end
    end

    context "when replacing a multi-line pane block" do
      let(:base_config) do
        <<~YAML
          name: myproject
          root: /some/path
          tmux_options: -CC
          attach: false
          startup_pane: 2
          windows:
            - workspace-myproject:
                layout: even-vertical
                panes:
                  - |
                    printf 'hello' &&
                    ascii-banner "myproject"
                  - claude --continue || claude
                  - echo 'Ready'
        YAML
      end

      it "replaces the multi-line pane with a single-line command" do
        command.call(project: "myproject", command: "vim .", pane_index: 1)

        updated = YAML.safe_load_file(config_path)
        panes = updated.dig("windows", 0, "workspace-myproject", "panes")
        expect(panes[0]).to eq("vim .")
        expect(panes[1]).to include("claude")
        expect(panes[2]).to include("Ready")
      end
    end
  end
end
