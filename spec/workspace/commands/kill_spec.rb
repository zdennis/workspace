require "tmpdir"
require "yaml"

RSpec.describe Workspace::Commands::Kill do
  let(:tmpdir) { Dir.mktmpdir }
  let(:output) { StringIO.new }
  let(:input) { StringIO.new }
  let(:git) { double("git") }
  let(:project_config) { double("project_config") }
  let(:project_settings) { double("project_settings") }
  let(:stop_command) { double("stop_command") }
  let(:project_detector) { Workspace::ProjectDetector.new(state: CLITestHelpers::FakeState.new, project_config: project_config) }

  subject(:command) do
    described_class.new(
      git: git,
      project_config: project_config,
      project_settings: project_settings,
      stop_command: stop_command,
      project_detector: project_detector,
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

      it "suggests workspace stop for non-worktree projects" do
        allow(git).to receive(:worktree_exists?).with("/path/to/worktree").and_return(false)

        expect { command.call("myproject.worktree-PROJ-123") }.to raise_error(
          Workspace::Error, /workspace stop/
        )
      end

      context "with valid worktree" do
        before do
          allow(git).to receive(:worktree_exists?).with("/path/to/worktree").and_return(true)
          allow(git).to receive(:unsaved_work).with("/path/to/worktree").and_return(nil)
        end

        it "cancels when user declines confirmation" do
          input.puts "n"
          input.rewind

          command.call("myproject.worktree-PROJ-123")

          expect(output.string).to include("Cancelled")
          expect(stop_command).not_to have_received(:call) if stop_command.respond_to?(:have_received)
        end

        context "when input is off" do
          let(:input) { Workspace::PromptInput.new(StringIO.new("y\n"), no_input: true) }

          it "refuses with confirmation_required and offers --force" do
            expect { command.call("myproject.worktree-PROJ-123") }.to raise_error(Workspace::Error) { |e|
              expect(e.code).to eq("confirmation_required")
              expect(e.details).to eq({"prompt" => "Remove worktree and kill session? [y/N]"})
              expect(e.retry).to eq({"flags" => ["--force"], "destructive" => true})
            }
            expect(output.string).not_to include("[y/N]")
          end
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
          allow(stop_command).to receive(:call).and_return(["myproject.worktree-PROJ-123"])
          allow(project_config).to receive(:remove)
          allow(project_settings).to receive(:remove)

          command.call("myproject.worktree-PROJ-123")

          expect(git).to have_received(:remove_worktree).with("/path/to/worktree", force: false)
          expect(stop_command).to have_received(:call).with(["myproject.worktree-PROJ-123"], quiet: false, warn_inactive: true)
          expect(project_config).to have_received(:remove).with("myproject.worktree-PROJ-123", quiet: false)
          expect(project_settings).to have_received(:remove).with("myproject.worktree-PROJ-123")
          expect(output.string).to include("Killing session...")
        end

        it "removes worktree before killing session" do
          input.puts "y"
          input.rewind

          order = []
          allow(git).to receive(:remove_worktree) { order << :remove_worktree }
          allow(stop_command).to receive(:call) {
            order << :kill
            []
          }
          allow(project_config).to receive(:remove) { order << :remove_config }
          allow(project_settings).to receive(:remove) { order << :remove_settings }

          command.call("myproject.worktree-PROJ-123")

          expect(order).to eq([:remove_worktree, :remove_config, :remove_settings, :kill])
        end

        it "skips confirmation with force flag" do
          allow(git).to receive(:remove_worktree)
          allow(stop_command).to receive(:call).and_return([])
          allow(project_config).to receive(:remove)
          allow(project_settings).to receive(:remove)

          command.call("myproject.worktree-PROJ-123", force: true)

          expect(output.string).not_to include("[y/N]")
          expect(git).to have_received(:remove_worktree).with("/path/to/worktree", force: true)
          expect(output.string).to include("Killing session")
        end

        it "with confirm: false, skips the prompt but still has git re-check before removing" do
          allow(git).to receive(:remove_worktree)
          allow(stop_command).to receive(:call).and_return([])
          allow(project_config).to receive(:remove)
          allow(project_settings).to receive(:remove)

          command.call("myproject.worktree-PROJ-123", confirm: false)

          expect(output.string).not_to include("[y/N]")
          expect(git).to have_received(:unsaved_work).with("/path/to/worktree")
          expect(git).to have_received(:remove_worktree).with("/path/to/worktree", force: false)
        end

        it "with quiet: true, prints nothing and asks Stop to be quiet too" do
          allow(git).to receive(:remove_worktree)
          allow(stop_command).to receive(:call).and_return([])
          allow(project_config).to receive(:remove)
          allow(project_settings).to receive(:remove)

          command.call("myproject.worktree-PROJ-123", force: true, quiet: true)

          expect(output.string).to eq("")
          expect(project_config).to have_received(:remove).with("myproject.worktree-PROJ-123", quiet: true)
          expect(stop_command).to have_received(:call).with(["myproject.worktree-PROJ-123"], quiet: true, warn_inactive: true)
        end

        it "yields the project after removing the worktree and before removing config or stopping" do
          order = []
          allow(git).to receive(:remove_worktree) { order << :remove_worktree }
          allow(stop_command).to receive(:call) { order << :stop }
          allow(project_config).to receive(:remove) { order << :remove_config }
          allow(project_settings).to receive(:remove) { order << :remove_settings }

          command.call("myproject.worktree-PROJ-123", force: true) { |p| order << [:yield, p] }

          expect(order).to eq([:remove_worktree, [:yield, "myproject.worktree-PROJ-123"], :remove_config, :remove_settings, :stop])
        end

        it "refuses, touching nothing else, when git's re-check finds unsaved work at removal time" do
          input.puts "y"
          input.rewind
          unsaved = {changed_files: 1, unpushed_commits: 0, branch: "feature/x"}
          allow(git).to receive(:remove_worktree).and_raise(Workspace::UnsavedWorkError.new("x", unsaved: unsaved))
          expect(project_config).not_to receive(:remove)
          expect(stop_command).not_to receive(:call)

          expect { command.call("myproject.worktree-PROJ-123") }.to raise_error(
            Workspace::UnsavedWorkError, /1 changed file\(s\) and 0 unpushed commit\(s\) on feature\/x.*--force/m
          )
        end

        it "passes force to remove_worktree" do
          allow(git).to receive(:remove_worktree)
          allow(stop_command).to receive(:call).and_return([])
          allow(project_config).to receive(:remove)
          allow(project_settings).to receive(:remove)

          command.call("myproject.worktree-PROJ-123", force: true)

          expect(git).to have_received(:remove_worktree).with("/path/to/worktree", force: true)
        end

        it "ignores missing_ok while the checkout exists" do
          allow(File).to receive(:directory?).and_call_original
          allow(File).to receive(:directory?).with("/path/to/worktree").and_return(true)
          allow(git).to receive(:remove_worktree)
          allow(stop_command).to receive(:call).and_return([])
          allow(project_config).to receive(:remove)
          allow(project_settings).to receive(:remove)

          command.call("myproject.worktree-PROJ-123", confirm: false, missing_ok: true)

          expect(git).to have_received(:unsaved_work)
          expect(git).to have_received(:remove_worktree).with("/path/to/worktree", force: false)
        end
      end

      context "when the checkout directory is gone" do
        let(:order) { [] }

        before do
          allow(git).to receive(:worktree_exists?).with("/path/to/worktree").and_return(false)
          allow(stop_command).to receive(:call) { order << :stop }
          allow(project_config).to receive(:remove) { order << :remove_config }
          allow(project_settings).to receive(:remove) { order << :remove_settings }
        end

        it "still raises without missing_ok" do
          expect { command.call("myproject.worktree-PROJ-123", confirm: false) }.to raise_error(Workspace::Error, /does not appear to be a worktree project/)
          expect(order).to be_empty
        end

        it "with missing_ok, skips the worktree removal and unsaved check but removes everything else" do
          expect(git).not_to receive(:remove_worktree)
          expect(git).not_to receive(:unsaved_work)

          result = command.call("myproject.worktree-PROJ-123", confirm: false, missing_ok: true) { |p| order << [:yield, p] }

          expect(result).to eq("myproject.worktree-PROJ-123")
          expect(order).to eq([[:yield, "myproject.worktree-PROJ-123"], :remove_config, :remove_settings, :stop])
          expect(output.string).to include("Checkout already gone; skipping worktree removal.")
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
        allow(git).to receive(:unsaved_work).with("/path/to/worktree").and_return(nil)
        allow(git).to receive(:remove_worktree)
        allow(stop_command).to receive(:call).and_return([])
        allow(project_config).to receive(:remove)
        allow(project_settings).to receive(:remove)

        cmd = described_class.new(
          git: git, project_config: project_config, project_settings: project_settings,
          stop_command: stop_command, project_detector: project_detector, output: output, input: input
        )
        cmd.call(nil, force: true, working_dir: marker_dir)

        expect(stop_command).to have_received(:call).with(["myproject.worktree-PROJ-123"], quiet: false, warn_inactive: true)
        expect(output.string).to include("Killing session...")
      end

      it "walks up directories to find .workspace-project" do
        marker_dir = File.join(tmpdir, "worktree-dir")
        sub_dir = File.join(marker_dir, "src", "lib")
        FileUtils.mkdir_p(sub_dir)
        File.write(File.join(marker_dir, ".workspace-project"), "myproject.worktree-PROJ-123")

        File.write(config_path, YAML.dump("name" => "myproject-wt-PROJ-123", "root" => "/path/to/worktree"))
        allow(git).to receive(:worktree_exists?).with("/path/to/worktree").and_return(true)
        allow(git).to receive(:unsaved_work).with("/path/to/worktree").and_return(nil)
        allow(git).to receive(:remove_worktree)
        allow(stop_command).to receive(:call).and_return([])
        allow(project_config).to receive(:remove)
        allow(project_settings).to receive(:remove)

        cmd = described_class.new(
          git: git, project_config: project_config, project_settings: project_settings,
          stop_command: stop_command, project_detector: project_detector, output: output, input: input
        )
        cmd.call(nil, force: true, working_dir: sub_dir)

        expect(stop_command).to have_received(:call).with(["myproject.worktree-PROJ-123"], quiet: false, warn_inactive: true)
      end

      it "raises error when no marker file found and no project given" do
        cmd = described_class.new(
          git: git, project_config: project_config, project_settings: project_settings,
          stop_command: stop_command, project_detector: project_detector, output: output, input: input
        )

        expect { cmd.call(nil, working_dir: tmpdir) }.to raise_error(
          Workspace::Error, /No project specified/
        )
      end
    end

    context "with unsaved work" do
      before do
        File.write(config_path, YAML.dump("name" => "myproject-wt-PROJ-123", "root" => "/path/to/worktree"))
        allow(git).to receive(:worktree_exists?).with("/path/to/worktree").and_return(true)
      end

      it "refuses to remove a dirty or unpushed worktree before touching anything" do
        allow(git).to receive(:unsaved_work).with("/path/to/worktree")
          .and_return(changed_files: 2, unpushed_commits: 1, branch: "feature/x")
        expect(git).not_to receive(:remove_worktree)
        expect(stop_command).not_to receive(:call)

        expect { command.call("myproject.worktree-PROJ-123") }.to raise_error(
          Workspace::Error, /2 changed file\(s\) and 1 unpushed commit\(s\) on feature\/x/
        )
      end

      it "refuses when git cannot answer" do
        allow(git).to receive(:unsaved_work).with("/path/to/worktree").and_return(:unknown)
        expect(git).not_to receive(:remove_worktree)

        expect { command.call("myproject.worktree-PROJ-123") }.to raise_error(
          Workspace::Error, /git couldn't answer/
        )
      end

      it "mentions --force as the way out" do
        allow(git).to receive(:unsaved_work).with("/path/to/worktree")
          .and_return(changed_files: 2, unpushed_commits: 1, branch: "feature/x")

        expect { command.call("myproject.worktree-PROJ-123") }.to raise_error(
          Workspace::Error, /--force/
        )
      end

      it "proceeds without checking when --force is given" do
        allow(git).to receive(:unsaved_work).with("/path/to/worktree")
          .and_return(changed_files: 2, unpushed_commits: 1, branch: "feature/x")
        allow(git).to receive(:remove_worktree)
        allow(stop_command).to receive(:call).and_return([])
        allow(project_config).to receive(:remove)
        allow(project_settings).to receive(:remove)

        command.call("myproject.worktree-PROJ-123", force: true)

        expect(git).to have_received(:remove_worktree).with("/path/to/worktree", force: true)
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

    context "with a config containing a disallowed YAML class" do
      before do
        File.write(config_path, "root: !ruby/object {}\n")
      end

      it "raises a friendly error instead of Psych::DisallowedClass" do
        expect { command.call("myproject.worktree-PROJ-123") }.to raise_error(
          Workspace::Error, /Corrupt config file/
        )
      end
    end
  end

  describe "recording worktree_finished" do
    let(:event_log) { CLITestHelpers::FakeEventLog.new }
    let(:name) { "myproject.worktree-PROJ-123" }

    subject(:command) do
      described_class.new(git: git, project_config: project_config, project_settings: project_settings,
        stop_command: stop_command, project_detector: project_detector, event_log: event_log, output: output, input: input)
    end

    before do
      File.write(config_path, YAML.dump("name" => "myproject-wt-PROJ-123", "root" => "/path/to/worktree"))
      allow(git).to receive(:worktree_exists?).with("/path/to/worktree").and_return(true)
      allow(git).to receive(:unsaved_work).and_return(nil)
      allow(git).to receive(:remove_worktree)
      allow(stop_command).to receive(:call).and_return([])
      allow(project_config).to receive(:remove)
      allow(project_settings).to receive(:remove)
    end

    it "records the outcome under the workspace once the worktree is removed, with no path" do
      command.call(name, confirm: false)

      expect(event_log.events).to eq([{"type" => "worktree_finished", "project" => name, "data" => {"workspace" => name, "outcome" => "abandoned"}}])
    end

    it "records the event only after the worktree, config and settings are removed, and before the session stops" do
      order = []
      allow(git).to receive(:remove_worktree) { order << :worktree }
      allow(project_config).to receive(:remove) { order << :config }
      allow(project_settings).to receive(:remove) { order << :settings }
      allow(stop_command).to receive(:call) {
        order << :stop
        []
      }
      allow(event_log).to receive(:record).and_wrap_original { |m, **kw|
        order << :event
        m.call(**kw)
      }

      command.call(name, confirm: false)

      expect(order).to eq(%i[worktree config settings event stop])
    end

    it "records discarded for a forced kill and the caller's outcome otherwise" do
      command.call(name, force: true)
      command.call(name, confirm: false, outcome: "merged")

      expect(event_log.events.map { |e| e["data"]["outcome"] }).to eq(%w[discarded merged])
    end

    it "records nothing when the user cancels" do
      input.puts "n"
      input.rewind

      command.call(name)

      expect(event_log.events).to be_empty
    end

    it "records nothing when git refuses to remove the worktree" do
      allow(git).to receive(:remove_worktree).and_raise(Workspace::UnsavedWorkError.new("x", unsaved: {changed_files: 1, unpushed_commits: 0, branch: "b"}))

      expect { command.call(name, confirm: false) }.to raise_error(Workspace::UnsavedWorkError)

      expect(event_log.events).to be_empty
    end

    it "still removes the config and stops the session when the log can't be written" do
      broken = described_class.new(git: git, project_config: project_config, project_settings: project_settings,
        stop_command: stop_command, project_detector: project_detector,
        event_log: CLITestHelpers.unwritable_event_log(tmpdir), output: output, input: input)

      expect(broken.call(name, force: true)).to eq(name)

      expect(project_config).to have_received(:remove)
      expect(stop_command).to have_received(:call)
    end
  end
end

RSpec.describe Workspace::Commands::Kill, "task archiving" do
  let(:tmpdir) { Dir.mktmpdir }
  let(:project_config) { double("project_config", remove: nil) }
  let(:git) { double("git", worktree_exists?: true, unsaved_work: nil, remove_worktree: nil) }
  let(:stop_command) { double("stop_command", call: []) }
  let(:task_store) { double("task_store", archive: nil) }
  let(:name) { "myproject.worktree-PROJ-123" }
  let(:config_path) { File.join(tmpdir, "workspace.#{name}.yml") }

  subject(:command) do
    described_class.new(git: git, project_config: project_config, project_settings: double("settings", remove: nil),
      stop_command: stop_command, project_detector: double("detector"), task_store: task_store,
      output: StringIO.new, input: StringIO.new)
  end

  before do
    File.write(config_path, YAML.dump("root" => "/path/to/worktree"))
    allow(project_config).to receive(:config_path_for).with(name).and_return(config_path)
  end

  after { FileUtils.remove_entry(tmpdir) }

  it "ends the project's workflow runs once the worktree is removed, before the session stops, and says which" do
    order = []
    out = StringIO.new
    runs = double("workflow_runs")
    allow(runs).to receive(:workspace_killed) do |workspace|
      order << [:runs, workspace]
      {"cancelled" => %w[wr_1 wr_2], "failed" => ["wr_3"]}
    end
    allow(git).to receive(:remove_worktree) { order << :remove }
    allow(stop_command).to receive(:call) { order << :stop }
    with_runs = described_class.new(git: git, project_config: project_config, project_settings: double("settings", remove: nil),
      stop_command: stop_command, project_detector: double("detector"), workflow_runs: runs, output: out, input: StringIO.new)

    with_runs.call(name, confirm: false)

    expect(order).to eq([:remove, [:runs, name], :stop])
    expect(out.string).to include("Cancelled workflow run wr_1.\nCancelled workflow run wr_2.\n" \
      "Warning: workflow run wr_3 could not be ended (its run file may be malformed). If it holds a lock, free it with `workspace lock clear NAME`.\n")
  end

  it "ends no run when the kill is refused for unsaved work" do
    runs = double("workflow_runs", workspace_killed: {"cancelled" => [], "failed" => []})
    allow(git).to receive(:unsaved_work).and_return(changed_files: 1, unpushed_commits: 0, branch: "x")
    with_runs = described_class.new(git: git, project_config: project_config, project_settings: double("settings", remove: nil),
      stop_command: stop_command, project_detector: double("detector"), workflow_runs: runs, output: StringIO.new, input: StringIO.new)

    expect { with_runs.call(name, confirm: false) }.to raise_error(Workspace::UnsavedWorkError)
    expect(runs).not_to have_received(:workspace_killed)
  end

  it "archives the task as abandoned after removing the worktree" do
    order = []
    allow(git).to receive(:remove_worktree) { order << :remove }
    allow(task_store).to receive(:archive) { order << :archive }

    command.call(name, confirm: false)

    expect(task_store).to have_received(:archive).with(name, outcome: "abandoned")
    expect(order).to eq([:remove, :archive])
  end

  it "archives the task as discarded under --force" do
    command.call(name, force: true)

    expect(task_store).to have_received(:archive).with(name, outcome: "discarded")
  end

  it "archives with the outcome the caller gives" do
    command.call(name, confirm: false, outcome: "merged")

    expect(task_store).to have_received(:archive).with(name, outcome: "merged")
  end

  it "keeps the task when the worktree can't be removed" do
    allow(git).to receive(:remove_worktree).and_raise(Workspace::UnsavedWorkError.new("x", unsaved: :unknown))

    expect { command.call(name, confirm: false) }.to raise_error(Workspace::UnsavedWorkError)
    expect(task_store).not_to have_received(:archive)
  end

  it "still removes the config, settings and session, with a warning, when the task can't be archived" do
    out = StringIO.new
    command = described_class.new(git: git, project_config: project_config, project_settings: (settings = double("settings", remove: nil)),
      stop_command: stop_command, project_detector: double("detector"), task_store: task_store, output: out, input: StringIO.new)
    allow(task_store).to receive(:archive).and_raise(Workspace::Error, "Could not access task store at /x")

    expect(command.call(name, confirm: false)).to eq(name)

    expect(out.string).to include("Warning: could not archive the task for #{name}: Could not access task store at /x")
    expect(project_config).to have_received(:remove).with(name, quiet: false)
    expect(settings).to have_received(:remove).with(name)
    expect(stop_command).to have_received(:call)
  end

  it "keeps the task when the user cancels" do
    command = described_class.new(git: git, project_config: project_config, project_settings: double("settings"),
      stop_command: stop_command, project_detector: double("detector"), task_store: task_store,
      output: StringIO.new, input: StringIO.new("n\n"))

    command.call(name)

    expect(task_store).not_to have_received(:archive)
  end
end
