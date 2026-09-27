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

  describe "#send_keys and #deliver" do
    # A pane whose screen is read back from a script: each capture returns the
    # next screen, and the last one repeats. Time moves only when the sender
    # sleeps, so the timeouts run without waiting.
    let(:now) { [0.0] }
    let(:sleeps) { [] }
    let(:tmux) do
      described_class.new(config: config, clock: -> { now[0] },
        sleeper: ->(seconds) {
          sleeps << seconds
          now[0] += seconds
        })
    end
    let(:enters) { [] }

    def screens(*list)
      queue = list.dup
      allow(tmux).to receive(:capture_screen) { (queue.size > 1) ? queue.shift : queue.first }
    end

    # Screens that change whenever Enter is pressed, the way a live prompt does.
    def live_pane(initial: "$ ", after_paste: "$ hello")
      screen = [initial]
      allow(tmux).to receive(:capture_screen) { screen[0] }
      allow(tmux).to receive(:tmux_load_buffer) {
        screen[0] = after_paste
        true
      }
      allow(tmux).to receive(:system) do |*args|
        if args[1] == "send-keys"
          enters << args.last
          screen[0] = "#{screen[0]}\n$ "
        end
        true
      end
    end

    before do
      allow(tmux).to receive(:system).and_return(true)
      allow(tmux).to receive(:tmux_load_buffer).and_return(true)
    end

    it "pastes the full text as one bracketed paste and presses Enter once" do
      live_pane

      result = tmux.deliver("my-session", "0.1", "hello world")

      expect(result.status).to eq(:submitted)
      expect(result).to be_ok
      expect(tmux).to have_received(:tmux_load_buffer).with(anything, "hello world")
      expect(tmux).to have_received(:system).with("tmux", "paste-buffer", "-p", "-b", anything, "-t", "my-session:0.1")
      expect(enters).to eq(["Enter"])
    end

    it "returns true from send_keys when the text was submitted" do
      live_pane

      expect(tmux.send_keys("my-session", "0.1", "hello")).to be true
    end

    it "presses Enter once for a paste over 1,000 bytes, so it is not submitted twice" do
      live_pane

      result = tmux.deliver("my-session", "0.1", "x" * 5_000)

      expect(result.status).to eq(:submitted)
      expect(enters).to eq(["Enter"])
    end

    it "sends multiline text as one paste so newlines are line-breaks not separate submissions" do
      live_pane
      text = "count to 10\n\nStatus reporting:\nsome command"

      tmux.deliver("my-session", "0.1", text)

      expect(tmux).to have_received(:tmux_load_buffer).with(anything, text).once
      expect(tmux).to have_received(:system).with("tmux", "paste-buffer", "-p", "-b", anything, "-t", "my-session:0.1").once
      expect(enters).to eq(["Enter"])
    end

    it "waits for the pane to stop changing before pressing Enter" do
      screens("$ ", "$ he", "$ hell", "$ hello", "$ hello", "$ hello", "$ hello\n$ ")
      allow(tmux).to receive(:system) do |*args|
        enters << now[0] if args[1] == "send-keys"
        true
      end

      tmux.deliver("my-session", "0.1", "hello")

      # Pasted text first shows at the second read; two more changes and a
      # repeat come before Enter.
      expect(enters.size).to eq(1)
      expect(enters.first).to be >= 3 * described_class::DELIVERY_POLL
    end

    it "presses Enter a second time only when the first left the screen unchanged" do
      screen = ["$ "]
      allow(tmux).to receive(:capture_screen) { screen[0] }
      allow(tmux).to receive(:tmux_load_buffer) {
        screen[0] = "$ hello"
        true
      }
      allow(tmux).to receive(:system) do |*args|
        if args[1] == "send-keys"
          enters << args.last
          screen[0] = "$ hello\n$ " if enters.size == 2
        end
        true
      end

      result = tmux.deliver("my-session", "0.1", "hello")

      expect(result.status).to eq(:submitted)
      expect(enters.size).to eq(2)
    end

    it "reports :unsubmitted when neither Enter changes the screen" do
      screens("$ ", "$ hello")
      allow(tmux).to receive(:system) do |*args|
        enters << args.last if args[1] == "send-keys"
        true
      end

      result = tmux.deliver("my-session", "0.1", "hello")

      expect(result.status).to eq(:unsubmitted)
      expect(result).not_to be_ok
      expect(result).to be_landed
      expect(result.message).to include("may not have been submitted")
      expect(enters.size).to eq(2)
    end

    it "reports :not_landed, and presses no Enter, when the paste never shows up" do
      screens("$ ")
      allow(tmux).to receive(:system) do |*args|
        enters << args.last if args[1] == "send-keys"
        true
      end

      result = tmux.deliver("my-session", "0.1", "hello")

      expect(result.status).to eq(:not_landed)
      expect(result).not_to be_landed
      expect(enters).to be_empty
      expect(now[0]).to be >= described_class::LAND_TIMEOUT
      expect(tmux.send_keys("my-session", "0.1", "hello")).to be false
    end

    it "skips Enter when enter: false and reports :pasted" do
      screens("$ ", "$ hello")

      result = tmux.deliver("my-session", "0.1", "hello", enter: false)

      expect(result.status).to eq(:pasted)
      expect(result).to be_ok
      expect(tmux).not_to have_received(:system).with("tmux", "send-keys", "-t", "my-session:0.1", "Enter")
    end

    it "reports :unverified, still pressing Enter, when the pane can't be read back" do
      screens(nil)

      result = tmux.deliver("my-session", "0.1", "hello")

      expect(result.status).to eq(:unverified)
      expect(result).to be_ok
      expect(tmux).to have_received(:system).with("tmux", "send-keys", "-t", "my-session:0.1", "Enter").once
    end

    it "reports :failed when load-buffer fails" do
      screens("$ ")
      allow(tmux).to receive(:tmux_load_buffer).and_return(false)

      result = tmux.deliver("bad-session", "0.1", "text")

      expect(result.status).to eq(:failed)
      expect(tmux.send_keys("bad-session", "0.1", "text")).to be false
    end

    it "reports :failed when paste-buffer fails, and still deletes the buffer" do
      screens("$ ")
      allow(tmux).to receive(:system).and_return(false)

      result = tmux.deliver("bad-session", "0.1", "text")

      expect(result.status).to eq(:failed)
      expect(result.message).to include("could not paste")
      expect(tmux).to have_received(:system).with("tmux", "delete-buffer", "-b", anything)
    end

    it "reports :failed when Enter can't be pressed" do
      screens("$ ", "$ text")
      allow(tmux).to receive(:system) { |*args| args[1] != "send-keys" }

      expect(tmux.deliver("my-session", "0.1", "text").status).to eq(:failed)
    end

    it "handles text starting with '-' without flag parsing errors" do
      live_pane

      result = tmux.send_keys("my-session", "0.1", "--ref WC-1")

      expect(result).to be true
      expect(tmux).to have_received(:tmux_load_buffer).with(anything, "--ref WC-1")
    end

    it "only presses Enter for empty text" do
      live_pane

      result = tmux.deliver("my-session", "0.1", "")

      expect(result.status).to eq(:submitted)
      expect(tmux).not_to have_received(:tmux_load_buffer)
    end

    it "never really sleeps" do
      screens("$ ")
      tmux.deliver("my-session", "0.1", "hello")

      expect(sleeps).to all(eq(described_class::DELIVERY_POLL))
    end
  end

  describe "#capture_screen" do
    let(:tmux) { described_class.new(config: config) }

    it "reads the visible screen of any target" do
      allow(Open3).to receive(:capture3)
        .with("tmux", "capture-pane", "-p", "-t", "%23")
        .and_return(["screen\n", "", double(success?: true)])

      expect(tmux.capture_screen("%23")).to eq("screen\n")
    end

    it "returns nil on failure" do
      allow(Open3).to receive(:capture3).and_return(["", "no pane", double(success?: false)])

      expect(tmux.capture_screen("%99")).to be_nil
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

  describe "#new_window" do
    let(:tmux) { described_class.new(config: config) }

    it "opens a detached window running the argv directly and returns the pane pid" do
      allow(Open3).to receive(:capture3).and_return(["4321 %12\n", "", double(success?: true)])

      pid = tmux.new_window("app", name: "devenv", cwd: "/w/app", command: ["ruby", "ws", "dev", "__run"], env: {"XDG_STATE_HOME" => "/s"})

      expect(pid).to eq(4321)
      expect(Open3).to have_received(:capture3).with("tmux", "new-window", "-d", "-P", "-F", "\#{pane_pid} \#{pane_id}", "-t", "app:",
        "-n", "devenv", "-c", "/w/app", "-e", "XDG_STATE_HOME=/s", "--", "ruby", "ws", "dev", "__run")
      expect(Open3).to have_received(:capture3).once
    end

    it "sets remain-on-exit on the new window only when asked" do
      allow(Open3).to receive(:capture3).and_return(["4321 %12\n", "", double(success?: true)])

      tmux.new_window("app", name: "devenv", cwd: "/w", command: ["true"], remain_on_exit: true)

      expect(Open3).to have_received(:capture3).with("tmux", "set-option", "-w", "-t", "%12", "remain-on-exit", "on")
    end

    it "returns nil when tmux fails" do
      allow(Open3).to receive(:capture3).and_return(["", "no session", double(success?: false)])

      expect(tmux.new_window("gone", name: "devenv", cwd: "/w", command: ["true"])).to be_nil
    end
  end

  describe "#close_dead_pane" do
    let(:tmux) { described_class.new(config: config) }

    def stub_display(stdout, success: true)
      allow(Open3).to receive(:capture3).with("tmux", "display-message", "-p", "-t", "%12", "\#{pane_dead} \#{pane_pid}")
        .and_return([stdout, "", double(success?: success)])
      allow(Open3).to receive(:capture3).with("tmux", "kill-pane", "-t", "%12").and_return(["", "", double(success?: true)])
    end

    it "kills a dead pane whose process was the given pid" do
      stub_display("1 4321\n")

      expect(tmux.close_dead_pane("%12", pid: 4321)).to be(true)
      expect(Open3).to have_received(:capture3).with("tmux", "kill-pane", "-t", "%12")
    end

    it "returns false while the pid is still running in the pane" do
      stub_display("0 4321\n")

      expect(tmux.close_dead_pane("%12", pid: 4321)).to be(false)
      expect(Open3).not_to have_received(:capture3).with("tmux", "kill-pane", "-t", "%12")
    end

    it "leaves alone a pane that ran some other process" do
      stub_display("1 999\n")

      expect(tmux.close_dead_pane("%12", pid: 4321)).to be_nil
      expect(Open3).not_to have_received(:capture3).with("tmux", "kill-pane", "-t", "%12")
    end

    it "returns nil when the pane no longer exists" do
      stub_display("", success: false)

      expect(tmux.close_dead_pane("%12", pid: 4321)).to be_nil
    end
  end

  describe "#server_running?" do
    let(:tmux) { described_class.new(config: config) }

    it "is true when tmux can list sessions" do
      allow(Open3).to receive(:capture3).with("tmux", "list-sessions").and_return(["app: 1 windows\n", "", double(success?: true)])

      expect(tmux.server_running?).to be(true)
    end

    it "is false when no server answers" do
      allow(Open3).to receive(:capture3).with("tmux", "list-sessions").and_return(["", "no server running", double(success?: false)])

      expect(tmux.server_running?).to be(false)
    end
  end
end
