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

  describe "#send_keys" do
    let(:tmux) { described_class.new(config: config) }

    it "pastes the full text via buffer and presses Enter by default" do
      allow(tmux).to receive(:system).and_return(true)
      allow(tmux).to receive(:tmux_load_buffer).and_return(true)

      result = tmux.send_keys("my-session", "0.1", "hello world")

      expect(result).to be true
      expect(tmux).to have_received(:tmux_load_buffer).with(anything, "hello world")
      expect(tmux).to have_received(:system).with("tmux", "paste-buffer", "-b", anything, "-t", "my-session:0.1")
      expect(tmux).to have_received(:system).with("tmux", "send-keys", "-t", "my-session:0.1", "Enter")
    end

    it "skips Enter when enter: false" do
      allow(tmux).to receive(:system).and_return(true)
      allow(tmux).to receive(:tmux_load_buffer).and_return(true)

      tmux.send_keys("my-session", "0.1", "hello", enter: false)

      expect(tmux).not_to have_received(:system).with("tmux", "send-keys", "-t", "my-session:0.1", "Enter")
    end

    it "returns false when load-buffer fails" do
      allow(tmux).to receive(:tmux_load_buffer).and_return(false)

      result = tmux.send_keys("bad-session", "0.1", "text")

      expect(result).to be false
    end

    it "returns false when paste-buffer fails" do
      allow(tmux).to receive(:system).and_return(false)
      allow(tmux).to receive(:tmux_load_buffer).and_return(true)

      result = tmux.send_keys("bad-session", "0.1", "text")

      expect(result).to be false
    end

    it "sends multiline text as one paste so newlines are line-breaks not separate submissions" do
      allow(tmux).to receive(:system).and_return(true)
      allow(tmux).to receive(:tmux_load_buffer).and_return(true)
      text = "count to 10\n\nStatus reporting:\nsome command"

      tmux.send_keys("my-session", "0.1", text)

      expect(tmux).to have_received(:tmux_load_buffer).with(anything, text)
      expect(tmux).to have_received(:system).with("tmux", "paste-buffer", "-b", anything, "-t", "my-session:0.1").once
      expect(tmux).to have_received(:system).with("tmux", "send-keys", "-t", "my-session:0.1", "Enter").once
    end

    it "handles text starting with '-' without flag parsing errors" do
      allow(tmux).to receive(:system).and_return(true)
      allow(tmux).to receive(:tmux_load_buffer).and_return(true)

      result = tmux.send_keys("my-session", "0.1", "--ref WC-1")

      expect(result).to be true
      expect(tmux).to have_received(:tmux_load_buffer).with(anything, "--ref WC-1")
    end
  end

  describe "#send_key" do
    let(:tmux) { described_class.new(config: config) }

    it "sends a key name in non-literal mode" do
      allow(tmux).to receive(:system).and_return(true)

      result = tmux.send_key("my-session", "0.1", "C-c")

      expect(result).to be true
      expect(tmux).to have_received(:system).with("tmux", "send-keys", "-t", "my-session:0.1", "C-c")
    end

    it "returns false when send fails" do
      allow(tmux).to receive(:system).and_return(false)

      result = tmux.send_key("bad-session", "0.1", "C-c")

      expect(result).to be false
    end
  end

  describe "#capture_layout" do
    let(:tmux) { described_class.new(config: config) }

    it "returns the layout string on success" do
      allow(Open3).to receive(:capture3)
        .with("tmux", "list-windows", "-t", "my-session:0", "-F", "\#{window_layout}")
        .and_return(["abc1,119x51,0,0[119x5,0,0]\n", "", double(success?: true)])

      expect(tmux.capture_layout("my-session")).to eq("abc1,119x51,0,0[119x5,0,0]")
    end

    it "returns nil on failure" do
      allow(Open3).to receive(:capture3).and_return(["", "error", double(success?: false)])

      expect(tmux.capture_layout("bad-session")).to be_nil
    end
  end

  describe "#capture_pane" do
    let(:tmux) { described_class.new(config: config) }

    it "returns stdout on success using default 100 lines" do
      allow(Open3).to receive(:capture3)
        .with("tmux", "capture-pane", "-t", "my-session:0.2", "-p", "-S", "-100")
        .and_return(["log output\n", "", double(success?: true)])

      expect(tmux.capture_pane("my-session", 2)).to eq("log output\n")
    end

    it "uses -S - when all: true" do
      allow(Open3).to receive(:capture3)
        .with("tmux", "capture-pane", "-t", "my-session:0.0", "-p", "-S", "-")
        .and_return(["full history\n", "", double(success?: true)])

      expect(tmux.capture_pane("my-session", 0, all: true)).to eq("full history\n")
    end

    it "uses -S -N for a custom lines count" do
      allow(Open3).to receive(:capture3)
        .with("tmux", "capture-pane", "-t", "my-session:0.1", "-p", "-S", "-200")
        .and_return(["200 lines\n", "", double(success?: true)])

      expect(tmux.capture_pane("my-session", 1, lines: 200)).to eq("200 lines\n")
    end

    it "returns nil on failure" do
      allow(Open3).to receive(:capture3).and_return(["", "error", double(success?: false)])

      expect(tmux.capture_pane("bad-session", 0)).to be_nil
    end

    it "returns empty string when buffer is empty (valid)" do
      allow(Open3).to receive(:capture3)
        .with("tmux", "capture-pane", "-t", "my-session:0.0", "-p", "-S", "-100")
        .and_return(["", "", double(success?: true)])

      expect(tmux.capture_pane("my-session", 0)).to eq("")
    end
  end

  describe "#apply_layout" do
    let(:tmux) { described_class.new(config: config) }

    it "calls select-layout with the layout string" do
      allow(tmux).to receive(:system).and_return(true)

      result = tmux.apply_layout("my-session", "abc1,119x51,0,0[119x5,0,0]")

      expect(result).to be true
      expect(tmux).to have_received(:system).with("tmux", "select-layout", "-t", "my-session:0", "abc1,119x51,0,0[119x5,0,0]")
    end

    it "returns false on failure" do
      allow(tmux).to receive(:system).and_return(false)

      expect(tmux.apply_layout("bad", "layout")).to be false
    end
  end

  describe "#resize_pane" do
    let(:tmux) { described_class.new(config: config) }

    it "calls tmux resize-pane with the target and size" do
      allow(tmux).to receive(:system).and_return(true)

      result = tmux.resize_pane("my-session", "0.1", "50%")

      expect(result).to be true
      expect(tmux).to have_received(:system).with("tmux", "resize-pane", "-t", "my-session:0.1", "-y", "50%")
    end

    it "returns false when resize fails" do
      allow(tmux).to receive(:system).and_return(false)

      result = tmux.resize_pane("bad-session", "0.0", "10")

      expect(result).to be false
    end
  end

  describe "#panes" do
    let(:tmux) { described_class.new(config: config) }

    it "returns sorted pane indices on success" do
      allow(Open3).to receive(:capture3)
        .with("tmux", "list-panes", "-t", "my-session:0", "-F", "\#{pane_index}")
        .and_return(["2\n0\n1\n", "", double(success?: true)])

      expect(tmux.panes("my-session")).to eq([0, 1, 2])
    end

    it "returns empty array on failure" do
      allow(Open3).to receive(:capture3).and_return(["", "error", double(success?: false)])

      expect(tmux.panes("bad-session")).to eq([])
    end

    it "accepts a window keyword argument" do
      allow(Open3).to receive(:capture3)
        .with("tmux", "list-panes", "-t", "my-session:1", "-F", "\#{pane_index}")
        .and_return(["0\n1\n", "", double(success?: true)])

      expect(tmux.panes("my-session", window: "1")).to eq([0, 1])
    end
  end

  describe "#split_window" do
    let(:tmux) { described_class.new(config: config) }

    def stub_split(target, stdout: "3\n", success: true)
      allow(Open3).to receive(:capture3)
        .with("tmux", "split-window", anything, "-t", target, "-P", "-F", "\#{pane_index}")
        .and_return([stdout, "", double(success?: success)])
    end

    it "splits vertically (top/bottom) by default and returns the new pane index" do
      stub_split("my-session:0")

      expect(tmux.split_window("my-session")).to eq(3)
      expect(Open3).to have_received(:capture3)
        .with("tmux", "split-window", "-v", "-t", "my-session:0", "-P", "-F", "\#{pane_index}")
    end

    it "splits horizontally (side-by-side) when vertical: true" do
      stub_split("my-session:0")

      expect(tmux.split_window("my-session", vertical: true)).to eq(3)
      expect(Open3).to have_received(:capture3)
        .with("tmux", "split-window", "-h", "-t", "my-session:0", "-P", "-F", "\#{pane_index}")
    end

    it "targets a specific pane when pane: is given" do
      stub_split("my-session:0.2")

      tmux.split_window("my-session", pane: 2)

      expect(Open3).to have_received(:capture3)
        .with("tmux", "split-window", "-v", "-t", "my-session:0.2", "-P", "-F", "\#{pane_index}")
    end

    it "returns nil when split fails" do
      stub_split("my-session:0", stdout: "", success: false)

      expect(tmux.split_window("my-session")).to be_nil
    end

    it "returns nil when tmux reports no pane index" do
      stub_split("my-session:0", stdout: "\n")

      expect(tmux.split_window("my-session")).to be_nil
    end
  end

  describe "#find_pane_by_title" do
    let(:tmux) { described_class.new(config: config) }

    def stub_list_panes(target, stdout:, success: true)
      status = instance_double(Process::Status, success?: success)
      allow(Open3).to receive(:capture3)
        .with("tmux", "list-panes", "-t", target, "-F", "\#{pane_index} \#{pane_title}")
        .and_return([stdout, "", status])
    end

    it "returns the index of the first pane whose title contains the pattern (case-insensitive)" do
      stub_list_panes("my-session:0", stdout: "0 banner\n1 ✳ Claude Code 2.1.0\n2 zsh\n")

      expect(tmux.find_pane_by_title("my-session", "claude code")).to eq(1)
    end

    it "matches case-insensitively" do
      stub_list_panes("my-session:0", stdout: "0 banner\n1 CLAUDE CODE 2.1.0\n")

      expect(tmux.find_pane_by_title("my-session", "Claude Code")).to eq(1)
    end

    it "returns nil when no pane title matches" do
      stub_list_panes("my-session:0", stdout: "0 banner\n1 zsh\n")

      expect(tmux.find_pane_by_title("my-session", "Claude Code")).to be_nil
    end

    it "returns nil when list-panes fails" do
      stub_list_panes("my-session:0", stdout: "", success: false)

      expect(tmux.find_pane_by_title("my-session", "Claude Code")).to be_nil
    end
  end

  describe "#find_claude_pane" do
    let(:tmux) { described_class.new(config: config) }

    it "delegates to find_pane_by_title with 'Claude Code'" do
      allow(tmux).to receive(:find_pane_by_title).with("my-session", "Claude Code", window: "0").and_return(2)

      expect(tmux.find_claude_pane("my-session")).to eq(2)
    end
  end
end
