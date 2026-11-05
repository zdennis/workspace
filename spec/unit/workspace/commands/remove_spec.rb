require "tmpdir"

RSpec.describe Workspace::Commands::Remove do
  let(:tmpdir) { Dir.mktmpdir }
  let(:config_path) { File.join(tmpdir, "workspace.app.yml") }
  let(:settings_path) { File.join(tmpdir, "app.yml") }
  let(:output) { StringIO.new }
  let(:input) { StringIO.new("y\n") }
  let(:project_config) { instance_double(Workspace::ProjectConfig, config_path_for: config_path, project_root_for: "/src/app") }
  let(:project_settings) { instance_double(Workspace::ProjectSettings, project_config_path: settings_path) }
  let(:state) { instance_double(Workspace::State, load: nil, save: nil, delete: nil) }
  let(:tmux) { instance_double(Workspace::Tmux, session_name_for: "app", session_exists?: false) }
  let(:git) { instance_double(Workspace::Git, linked_worktree?: false) }
  let(:file_backup) { Workspace::FileBackup.new(output: StringIO.new) }

  def build(input)
    described_class.new(project_config: project_config, project_settings: project_settings, state: state,
      tmux: tmux, git: git, file_backup: file_backup, output: output, input: input)
  end

  subject(:command) { build(input) }

  before do
    File.write(config_path, "name: app\n")
    File.write(settings_path, "hooks: {}\n")
    allow(project_config).to receive(:remove) { |_name, **| FileUtils.rm_f(config_path) }
    allow(project_settings).to receive(:remove) { |_name| FileUtils.rm_f(settings_path) }
    allow(state).to receive(:[]).with("app").and_return({"unique_id" => "x"})
  end

  after { FileUtils.remove_entry(tmpdir) }

  it "removes the config, settings and state entry after backing the files up" do
    row = command.call("app", yes: true)

    expect(row).to include("outcome" => "removed", "state_entry" => true, "files" => [config_path, settings_path])
    expect(row["backups"].size).to eq(2)
    expect(row["backups"]).to all(satisfy { |path| File.exist?(path) })
    expect(File.exist?(config_path)).to be false
    expect(File.exist?(settings_path)).to be false
    expect(state).to have_received(:delete).with("app")
    expect(state).to have_received(:save)
  end

  it "removes a state entry that has no files" do
    File.delete(config_path)
    File.delete(settings_path)

    expect(command.call("app", yes: true)).to include("outcome" => "removed", "files" => [], "state_entry" => true)
    expect(state).to have_received(:delete).with("app")
  end

  it "changes nothing on --dry-run and does not prompt" do
    row = command.call("app", dry_run: true)

    expect(row).to include("outcome" => "would_remove", "backups" => [])
    expect(File.exist?(config_path)).to be true
    expect(Dir.children(tmpdir).grep(/backup/)).to be_empty
    expect(state).not_to have_received(:delete)
    expect(output.string).to include("Would remove: #{config_path}")
    expect(input.string).to eq("y\n")
  end

  it "asks first and returns nil when declined" do
    expect(build(StringIO.new("n\n")).call("app")).to be_nil
    expect(File.exist?(config_path)).to be true
    expect(output.string).to include("Cancelled.")
    expect(state).not_to have_received(:delete)
  end

  it "removes after a yes answer to the prompt" do
    expect(command.call("app")).to include("outcome" => "removed")
    expect(output.string).to include("Remove workspace 'app'? [y/N]")
  end

  it "asks through Prompt, which refuses under --no-input" do
    no_input = Workspace::PromptInput.new(StringIO.new)
    no_input.no_input!

    expect { build(no_input).call("app") }.to raise_error(Workspace::Error) { |e| expect(e.code).to eq("confirmation_required") }
    expect(File.exist?(config_path)).to be true
  end

  it "refuses with session_running when the tmux session is up" do
    allow(tmux).to receive(:session_exists?).with("app", project: "app").and_return(true)

    expect { command.call("app", yes: true) }.to raise_error(Workspace::Error) { |e|
      expect(e.code).to eq("session_running")
      expect(e.details).to include("session" => "app")
    }
    expect(File.exist?(config_path)).to be true
  end

  it "refuses a worktree project with not_removable" do
    allow(git).to receive(:linked_worktree?).with("/src/app").and_return(true)

    expect { command.call("app", yes: true) }.to raise_error(Workspace::Error) { |e| expect(e.code).to eq("not_removable") }
    expect(File.exist?(config_path)).to be true
  end

  it "refuses not_removable for a worktree config name when there is no config root" do
    allow(project_config).to receive(:project_root_for).and_return(nil)
    allow(state).to receive(:[]).with("app.worktree-PROJ-1").and_return({"unique_id" => "x"})

    expect { command.call("app.worktree-PROJ-1", yes: true) }.to raise_error(Workspace::Error) { |e| expect(e.code).to eq("not_removable") }
    expect(state).not_to have_received(:delete)
  end

  it "refuses not_removable when the root's marker names a worktree" do
    File.write(File.join(tmpdir, ".workspace-project"), "app.worktree-PROJ-1\n")
    allow(project_config).to receive(:project_root_for).and_return(tmpdir)

    expect { command.call("app", yes: true) }.to raise_error(Workspace::Error) { |e| expect(e.code).to eq("not_removable") }
    expect(File.exist?(config_path)).to be true
  end

  it "counts a session under the lowercase name as running for a mixed-case name" do
    allow(state).to receive(:[]).with("App").and_return({"unique_id" => "x"})
    allow(tmux).to receive(:session_name_for).with("App").and_return("App")
    allow(tmux).to receive(:session_name_for).with("app").and_return("app")
    allow(tmux).to receive(:session_exists?).with("app", project: "App").and_return(true)

    expect { command.call("App", yes: true) }.to raise_error(Workspace::Error) { |e| expect(e.code).to eq("session_running") }
    expect(File.exist?(config_path)).to be true
  end

  it "deletes nothing when a backup comes back nil" do
    allow(file_backup).to receive(:backup).and_return(nil)

    expect { command.call("app", yes: true) }.to raise_error(Workspace::Error, /Could not back up/)
    expect(File.exist?(config_path)).to be true
    expect(File.exist?(settings_path)).to be true
    expect(state).not_to have_received(:delete)
  end

  it "raises unknown_workspace when nothing exists for the name" do
    File.delete(config_path)
    File.delete(settings_path)
    allow(state).to receive(:[]).with("app").and_return(nil)

    expect { command.call("app", yes: true) }.to raise_error(Workspace::Error) { |e| expect(e.code).to eq("unknown_workspace") }
  end
end
