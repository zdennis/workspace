require "tmpdir"

RSpec.describe Workspace::Tmux do
  let(:tmpdir) { Dir.mktmpdir }
  let(:config) { Workspace::Config.new(workspace_dir: tmpdir) }

  after { FileUtils.remove_entry(tmpdir) }

  describe "#command_for" do
    it "returns tmuxinator command using the namespaced config name" do
      tmux = described_class.new(config: config)
      expect(tmux.command_for("myproject")).to eq("tmuxinator start workspace.myproject --attach")
    end

    it "returns tmuxinator command when reattaching but session does not exist" do
      tmux = described_class.new(config: config)
      allow(tmux).to receive(:sessions).and_return([])
      expect(tmux.command_for("myproject", reattach: true)).to eq("tmuxinator start workspace.myproject --attach")
    end

    it "returns tmux attach command when reattaching and session exists" do
      config_path = config.config_path_for("myproject")
      FileUtils.mkdir_p(File.dirname(config_path))
      File.write(config_path, "name: myproject\nroot: /tmp\n")

      tmux = described_class.new(config: config)
      allow(tmux).to receive(:sessions).and_return(["myproject"])
      expect(tmux.command_for("myproject", reattach: true)).to eq("tmux -CC attach -t myproject")
    end
  end

  describe "#session_name_for" do
    it "returns the name field from the config file" do
      config = Workspace::Config.new
      config_path = File.join(tmpdir, "test-project.yml")
      File.write(config_path, "name: custom-session-name\nroot: /tmp\n")
      allow(config).to receive(:config_path_for).with("test-project").and_return(config_path)

      tmux = described_class.new(config: config)
      expect(tmux.session_name_for("test-project")).to eq("custom-session-name")
    end

    it "falls back to config_name when file has no name field" do
      config = Workspace::Config.new
      config_path = File.join(tmpdir, "test-project.yml")
      File.write(config_path, "root: /tmp\nwindows:\n  - main:\n")
      allow(config).to receive(:config_path_for).with("test-project").and_return(config_path)

      tmux = described_class.new(config: config)
      expect(tmux.session_name_for("test-project")).to eq("test-project")
    end

    it "falls back to config_name when file does not exist" do
      config = Workspace::Config.new
      allow(config).to receive(:config_path_for).with("missing").and_return(File.join(tmpdir, "missing.yml"))

      tmux = described_class.new(config: config)
      expect(tmux.session_name_for("missing")).to eq("missing")
    end
  end
end
