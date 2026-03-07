require "tmpdir"
require "yaml"

RSpec.describe Workspace::Commands::Stop do
  let(:tmpdir) { Dir.mktmpdir }
  let(:output) { StringIO.new }
  let(:input) { StringIO.new }
  let(:git) { double("git") }
  let(:project_config) { double("project_config") }
  let(:kill_command) { double("kill_command") }

  subject(:command) do
    described_class.new(
      git: git,
      project_config: project_config,
      kill_command: kill_command,
      output: output,
      input: input
    )
  end

  after { FileUtils.remove_entry(tmpdir) }

  let(:config_path) { File.join(tmpdir, "workspace.myproject.worktree-PROJ-123.yml") }

  before do
    allow(project_config).to receive(:config_path_for)
      .with("myproject.worktree-PROJ-123")
      .and_return(config_path)
  end

  describe "#call" do
    it "raises error when config not found" do
      expect { command.call("myproject.worktree-PROJ-123") }.to raise_error(
        Workspace::Error, /No config found/
      )
    end

    context "with existing config" do
      before do
        File.write(config_path, YAML.dump("name" => "myproject-wt-PROJ-123", "root" => "/path/to/worktree"))
      end

      it "raises error when not a worktree project" do
        allow(git).to receive(:worktree_exists?).with("/path/to/worktree").and_return(false)

        expect { command.call("myproject.worktree-PROJ-123") }.to raise_error(
          Workspace::Error, /does not appear to be a worktree project/
        )
      end

      it "suggests workspace kill for non-worktree projects" do
        allow(git).to receive(:worktree_exists?).with("/path/to/worktree").and_return(false)

        expect { command.call("myproject.worktree-PROJ-123") }.to raise_error(
          Workspace::Error, /workspace kill/
        )
      end

      context "with valid worktree" do
        before do
          allow(git).to receive(:worktree_exists?).with("/path/to/worktree").and_return(true)
        end

        it "cancels when user declines confirmation" do
          input.puts "n"
          input.rewind

          command.call("myproject.worktree-PROJ-123")

          expect(output.string).to include("Cancelled")
          expect(kill_command).not_to have_received(:call) if kill_command.respond_to?(:have_received)
        end

        it "cancels on empty input" do
          input.puts ""
          input.rewind

          command.call("myproject.worktree-PROJ-123")

          expect(output.string).to include("Cancelled")
        end

        it "removes worktree, kills session, and cleans up config on confirmation" do
          input.puts "y"
          input.rewind

          allow(git).to receive(:remove_worktree)
          allow(kill_command).to receive(:call).and_return(["myproject.worktree-PROJ-123"])
          allow(project_config).to receive(:remove)

          command.call("myproject.worktree-PROJ-123")

          expect(git).to have_received(:remove_worktree).with("/path/to/worktree", force: false)
          expect(kill_command).to have_received(:call).with(["myproject.worktree-PROJ-123"])
          expect(project_config).to have_received(:remove).with("myproject.worktree-PROJ-123")
          expect(output.string).to include("Stopped myproject.worktree-PROJ-123")
        end

        it "removes marker file before worktree removal" do
          worktree_dir = File.join(tmpdir, "worktree")
          Dir.mkdir(worktree_dir)
          marker = File.join(worktree_dir, ".workspace-project")
          File.write(marker, "myproject.worktree-PROJ-123")

          File.write(config_path, YAML.dump("name" => "myproject-wt-PROJ-123", "root" => worktree_dir))
          allow(git).to receive(:worktree_exists?).with(worktree_dir).and_return(true)
          allow(git).to receive(:remove_worktree)
          allow(kill_command).to receive(:call).and_return([])
          allow(project_config).to receive(:remove)

          command.call("myproject.worktree-PROJ-123", force: true)

          expect(File.exist?(marker)).to be false
        end

        it "removes worktree before killing session" do
          input.puts "y"
          input.rewind

          order = []
          allow(git).to receive(:remove_worktree) { order << :remove_worktree }
          allow(kill_command).to receive(:call) {
            order << :kill
            []
          }
          allow(project_config).to receive(:remove) { order << :remove_config }

          command.call("myproject.worktree-PROJ-123")

          expect(order).to eq([:remove_worktree, :kill, :remove_config])
        end

        it "skips confirmation with force flag" do
          allow(git).to receive(:remove_worktree)
          allow(kill_command).to receive(:call).and_return([])
          allow(project_config).to receive(:remove)

          command.call("myproject.worktree-PROJ-123", force: true)

          expect(output.string).not_to include("[y/N]")
          expect(git).to have_received(:remove_worktree).with("/path/to/worktree", force: true)
          expect(output.string).to include("Stopped")
        end

        it "passes force to remove_worktree" do
          allow(git).to receive(:remove_worktree)
          allow(kill_command).to receive(:call).and_return([])
          allow(project_config).to receive(:remove)

          command.call("myproject.worktree-PROJ-123", force: true)

          expect(git).to have_received(:remove_worktree).with("/path/to/worktree", force: true)
        end
      end
    end

    context "with marker file auto-detection" do
      it "detects project from .workspace-project in current directory" do
        marker_dir = File.join(tmpdir, "worktree-dir")
        Dir.mkdir(marker_dir)
        File.write(File.join(marker_dir, ".workspace-project"), "myproject.worktree-PROJ-123")

        File.write(config_path, YAML.dump("name" => "myproject-wt-PROJ-123", "root" => "/path/to/worktree"))
        allow(git).to receive(:worktree_exists?).with("/path/to/worktree").and_return(true)
        allow(git).to receive(:remove_worktree)
        allow(kill_command).to receive(:call).and_return([])
        allow(project_config).to receive(:remove)

        allow(Dir).to receive(:pwd).and_return(marker_dir)

        command.call(nil, force: true)

        expect(kill_command).to have_received(:call).with(["myproject.worktree-PROJ-123"])
        expect(output.string).to include("Stopped myproject.worktree-PROJ-123")
      end

      it "walks up directories to find .workspace-project" do
        marker_dir = File.join(tmpdir, "worktree-dir")
        sub_dir = File.join(marker_dir, "src", "lib")
        FileUtils.mkdir_p(sub_dir)
        File.write(File.join(marker_dir, ".workspace-project"), "myproject.worktree-PROJ-123")

        File.write(config_path, YAML.dump("name" => "myproject-wt-PROJ-123", "root" => "/path/to/worktree"))
        allow(git).to receive(:worktree_exists?).with("/path/to/worktree").and_return(true)
        allow(git).to receive(:remove_worktree)
        allow(kill_command).to receive(:call).and_return([])
        allow(project_config).to receive(:remove)

        allow(Dir).to receive(:pwd).and_return(sub_dir)

        command.call(nil, force: true)

        expect(kill_command).to have_received(:call).with(["myproject.worktree-PROJ-123"])
      end

      it "raises error when no marker file found and no project given" do
        allow(Dir).to receive(:pwd).and_return(tmpdir)

        expect { command.call(nil) }.to raise_error(
          Workspace::Error, /No project specified/
        )
      end
    end

    context "with corrupt config" do
      before do
        File.write(config_path, "{{invalid yaml")
      end

      it "raises a friendly error" do
        expect { command.call("myproject.worktree-PROJ-123") }.to raise_error(
          Workspace::Error, /Corrupt config file/
        )
      end
    end
  end
end
