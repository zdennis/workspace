require "tmpdir"

RSpec.describe Workspace::Tmux do
  let(:tmpdir) { Dir.mktmpdir }
  let(:config) { Workspace::Config.new(workspace_dir: tmpdir) }

  before { allow(config).to receive(:tmuxinator_dir).and_return(File.join(tmpdir, "tmuxinator")) }

  after { FileUtils.remove_entry(tmpdir) }

  describe "#sessions and #start_server" do
    let(:bin) { File.join(tmpdir, "bin") }
    let(:tmux) { described_class.new(config: config, command_timeout: 0.5) }

    def fake_tmux(body)
      FileUtils.mkdir_p(bin)
      File.write(File.join(bin, "tmux"), "#!/bin/sh\n#{body}\n")
      File.chmod(0o755, File.join(bin, "tmux"))
    end

    around do |example|
      original_path = ENV["PATH"]
      ENV["PATH"] = "#{bin}:#{original_path}"
      example.run
    ensure
      ENV["PATH"] = original_path
    end

    it "lists the session names tmux prints" do
      fake_tmux(%(printf 'alpha\\nbeta\\n'))
      expect(tmux.sessions).to eq(%w[alpha beta])
    end

    it "treats a tmux that exits nonzero (no server) as no sessions" do
      fake_tmux("echo 'no server running' >&2; exit 1")
      expect(tmux.sessions).to eq([])
    end

    it "treats no server as no sessions even when strict" do
      fake_tmux("echo 'no server running' >&2; exit 1")
      expect(tmux.sessions(strict: true)).to eq([])
    end

    it "raises on any other tmux error when strict, but not otherwise" do
      fake_tmux("echo 'protocol version mismatch' >&2; exit 1")
      expect(tmux.sessions).to eq([])
      expect { tmux.sessions(strict: true) }.to raise_error(Workspace::Error, /protocol version mismatch/)
    end

    it "stops a tmux that doesn't answer and raises naming the command" do
      pid_file = File.join(tmpdir, "tmux.pid")
      fake_tmux("echo $$ > '#{pid_file}'\nexec sleep 30")

      expect { tmux.sessions }.to raise_error(Workspace::Error, /tmux list-sessions did not respond within 0.5s/)
      pid = File.read(pid_file).to_i
      expect { Process.kill(0, pid) }.to raise_error(Errno::ESRCH)
    end

    it "raises when start-server doesn't answer" do
      fake_tmux("exec sleep 30")
      expect { tmux.start_server }.to raise_error(Workspace::Error, /tmux start-server did not respond/)
    end

    it "reports whether start-server succeeded" do
      fake_tmux("exit 0")
      expect(tmux.start_server).to be(true)
    end

    it "returns nil from start_server when tmux can't be run" do
      FileUtils.mkdir_p(bin)
      File.write(File.join(bin, "tmux"), "not executable")
      File.chmod(0o644, File.join(bin, "tmux"))
      ENV["PATH"] = bin
      expect(tmux.start_server).to be_nil
    end
  end

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

    it "returns tmux attach command when reattaching and session exists, falling back to start only if the session is really gone" do
      config_path = config.config_path_for("myproject")
      FileUtils.mkdir_p(File.dirname(config_path))
      File.write(config_path, "name: myproject\nroot: /tmp\n")

      tmux = described_class.new(config: config)
      allow(tmux).to receive(:sessions).and_return(["myproject"])
      expect(tmux.command_for("myproject", reattach: true)).to eq(
        "tmux -CC attach -t myproject || tmux has-session -t myproject 2>/dev/null || tmuxinator start workspace.myproject --attach"
      )
    end

    it "shell-quotes a session name and tmuxinator config name containing shell metacharacters" do
      dangerous = %(pro"j$(touch pwned)`x` a\\b)
      config_path = config.config_path_for(dangerous)
      FileUtils.mkdir_p(File.dirname(config_path))
      File.write(config_path, "name: #{dangerous}\nroot: /tmp\n")

      tmux = described_class.new(config: config)
      allow(tmux).to receive(:sessions).and_return([dangerous])
      command = tmux.command_for(dangerous, reattach: true)

      expect(command).to eq(
        "tmux -CC attach -t #{Shellwords.escape(dangerous)} || tmux has-session -t #{Shellwords.escape(dangerous)} 2>/dev/null || " \
        "tmuxinator start #{Shellwords.escape("workspace.#{dangerous}")} --attach"
      )
    end
  end

  describe "#reattach_or_start" do
    it "builds a plain || chain with no braces" do
      tmux = described_class.new(config: config)
      expect(tmux.reattach_or_start("myproject", "tmuxinator start workspace.myproject --attach")).to eq(
        "tmux -CC attach -t myproject || tmux has-session -t myproject 2>/dev/null || tmuxinator start workspace.myproject --attach"
      )
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
    def live_pane(initial: "$ ")
      screen = [initial]
      allow(tmux).to receive(:capture_screen) { screen[0] }
      allow(tmux).to receive(:tmux_load_buffer) { |_buf, text|
        screen[0] = "$ #{text}"
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
      allow(tmux).to receive(:tmux_paste_buffer).and_return([true, nil])
    end

    it "pastes the full text as one bracketed paste and presses Enter once" do
      live_pane

      result = tmux.deliver("my-session", "0.1", "hello world")

      expect(result.status).to eq(:submitted)
      expect(result).to be_ok
      expect(tmux).to have_received(:tmux_load_buffer).with(anything, "hello world")
      expect(tmux).to have_received(:tmux_paste_buffer).with(anything, "my-session:0.1")
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
      expect(tmux).to have_received(:tmux_paste_buffer).with(anything, "my-session:0.1").once
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

    it "reports :not_landed for whitespace-only text instead of a false match" do
      screens("$ ")
      allow(tmux).to receive(:system) do |*args|
        enters << args.last if args[1] == "send-keys"
        true
      end

      result = tmux.deliver("my-session", "0.1", "   \n  ")

      expect(result.status).to eq(:not_landed)
      expect(result).not_to be_landed
      expect(enters).to be_empty
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
      expect(result).not_to be_ok
      expect(result).to be_landed
      expect(tmux).to have_received(:system).with("tmux", "send-keys", "-t", "my-session:0.1", "Enter").once
    end

    it "counts a paste placeholder on screen as the text having arrived" do
      screens("$ ", "> [Pasted text #1 +40 lines]")

      result = tmux.deliver("my-session", "0.1", "line\n" * 40, enter: false)

      expect(result.status).to eq(:pasted)
    end

    it "counts the text as arrived when it wraps across lines" do
      screens("> ", "> please fix the fail\n  ing spec in foo_spec.rb")

      result = tmux.deliver("my-session", "0.1", "please fix the failing spec in foo_spec.rb", enter: false)

      expect(result.status).to eq(:pasted)
    end

    it "does not count text that was already on screen before the paste" do
      screens("> hello", "> hello\nthinking...")

      result = tmux.deliver("my-session", "0.1", "hello", enter: false)

      expect(result.status).to eq(:unverified)
      expect(result.message).to include("never showed the text")
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
      allow(tmux).to receive(:tmux_paste_buffer).and_return([false, nil])

      result = tmux.deliver("bad-session", "0.1", "text")

      expect(result.status).to eq(:failed)
      expect(result.message).to eq("tmux could not paste into bad-session:0.1")
      expect(tmux).to have_received(:system).with("tmux", "delete-buffer", "-b", anything)
    end

    # A config name ("app.worktree-x") passed where the tmux session name
    # ("app-wt-x") belongs failed every paste with only "could not paste",
    # which read as a busy pane. tmux's own reason says what went wrong.
    it "names tmux's reason when paste-buffer fails" do
      screens("$ ")
      allow(tmux).to receive(:tmux_paste_buffer).and_return([false, "can't find session: app.worktree-x"])

      result = tmux.deliver("app.worktree-x", "0.1", "text")

      expect(result.status).to eq(:failed)
      expect(result.message).to eq("tmux could not paste into app.worktree-x:0.1: can't find session: app.worktree-x")
    end

    it "runs paste-buffer as a bracketed paste and returns tmux's stderr" do
      status = instance_double(Process::Status, success?: false)
      allow(Open3).to receive(:capture3)
        .with("tmux", "paste-buffer", "-p", "-b", "buf-1", "-t", "s:0.1")
        .and_return(["", "can't find pane: 0.1\n", status])

      expect(described_class.new(config: config).send(:tmux_paste_buffer, "buf-1", "s:0.1")).to eq([false, "can't find pane: 0.1"])
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

  describe "#shows_text?" do
    let(:tmux) { described_class.new(config: config) }

    it "is true when the screen shows the end of the text" do
      allow(tmux).to receive(:capture_screen).with("proj:0.1").and_return("> ...and then please do the thing\n")

      expect(tmux.shows_text?("proj", "0.1", "read the notes first, and then please do the thing")).to be true
    end

    it "is false when the screen does not show it, or can not be read" do
      allow(tmux).to receive(:capture_screen).and_return("> \n", nil)

      expect(tmux.shows_text?("proj", "0.1", "do the thing")).to be false
      expect(tmux.shows_text?("proj", "0.1", "do the thing")).to be false
    end
  end

  describe "#pane_details" do
    let(:tmux) { described_class.new(config: config) }
    let(:ok) { instance_double(Process::Status, success?: true) }

    it "lists every window in the session when window is nil" do
      allow(Open3).to receive(:capture3).and_return(["%7\t2\t1\t700\tclaude\t/src\tClaude Code\n", "", ok])

      details = tmux.pane_details("proj", window: nil)

      expect(Open3).to have_received(:capture3).with("tmux", "list-panes", "-s", "-t", "proj", "-F", anything)
      expect(details).to eq([{id: "%7", window: 2, index: 1, pid: 700, command: "claude", cwd: "/src", title: "Claude Code"}])
    end

    it "lists one window by default" do
      allow(Open3).to receive(:capture3).and_return(["", "", ok])

      tmux.pane_details("proj")

      expect(Open3).to have_received(:capture3).with("tmux", "list-panes", "-t", "proj:0", "-F", anything)
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

    it "bounds the capture server-side to the requested window via -S -N" do
      allow(Open3).to receive(:capture3)
        .with("tmux", "capture-pane", "-t", "my-session:0.2", "-p", "-S", "-100")
        .and_return(["line1\nline2\nlog output\n", "", double(success?: true)])

      expect(tmux.capture_pane("my-session", 2)).to eq("line1\nline2\nlog output\n")
    end

    it "always captures full history via -S -" do
      allow(Open3).to receive(:capture3)
        .with("tmux", "capture-pane", "-t", "my-session:0.0", "-p", "-S", "-")
        .and_return(["full history\n", "", double(success?: true)])

      expect(tmux.capture_pane("my-session", 0, all: true)).to eq("full history\n")
    end

    it "still trims to a custom lines count from the tail in Ruby" do
      allow(Open3).to receive(:capture3)
        .with("tmux", "capture-pane", "-t", "my-session:0.1", "-p", "-S", "-2")
        .and_return(["old\nrecent1\nrecent2\n", "", double(success?: true)])

      expect(tmux.capture_pane("my-session", 1, lines: 2)).to eq("recent1\nrecent2\n")
    end

    it "keeps the last line when output has no trailing newline" do
      allow(Open3).to receive(:capture3).and_return(["old\nrecent1\nrecent2", "", double(success?: true)])

      expect(tmux.capture_pane("my-session", 1, lines: 2)).to eq("recent1\nrecent2")
    end

    it "returns everything when lines exceeds the history" do
      allow(Open3).to receive(:capture3).and_return(["a\nb\n", "", double(success?: true)])

      expect(tmux.capture_pane("my-session", 1, lines: 100)).to eq("a\nb\n")
    end

    it "returns an empty string for lines: 0" do
      allow(Open3).to receive(:capture3).and_return(["a\nb\n", "", double(success?: true)])

      expect(tmux.capture_pane("my-session", 1, lines: 0)).to eq("")
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

  describe "#capture_pane_by_id" do
    let(:tmux) { described_class.new(config: config) }

    it "captures by pane id, bounding the window via -S -N" do
      allow(Open3).to receive(:capture3)
        .with("tmux", "capture-pane", "-t", "%19", "-p", "-S", "-100")
        .and_return(["line1\nline2\nlog output\n", "", double(success?: true)])

      expect(tmux.capture_pane_by_id("%19")).to eq("line1\nline2\nlog output\n")
    end

    it "captures full history via -S -" do
      allow(Open3).to receive(:capture3)
        .with("tmux", "capture-pane", "-t", "%19", "-p", "-S", "-")
        .and_return(["full history\n", "", double(success?: true)])

      expect(tmux.capture_pane_by_id("%19", all: true)).to eq("full history\n")
    end

    it "trims to a custom lines count from the tail in Ruby" do
      allow(Open3).to receive(:capture3)
        .with("tmux", "capture-pane", "-t", "%19", "-p", "-S", "-2")
        .and_return(["old\nrecent1\nrecent2\n", "", double(success?: true)])

      expect(tmux.capture_pane_by_id("%19", lines: 2)).to eq("recent1\nrecent2\n")
    end

    it "returns nil on failure" do
      allow(Open3).to receive(:capture3).and_return(["", "error", double(success?: false)])

      expect(tmux.capture_pane_by_id("%99")).to be_nil
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

  describe "#start_headless" do
    let(:tmux) { described_class.new(config: config) }
    let(:source) { File.join(tmpdir, "workspace.proj.yml") }

    before do
      allow(config).to receive(:config_path_for).with("proj").and_return(source)
      File.write(source, "name: proj\nroot: /tmp\ntmux_options: -CC -2\nattach: false\nwindows:\n  - main: echo hi\n")
    end

    # Runs +script+ with sh in place of tmuxinator, keeping the spawn options,
    # and records tmuxinator's arguments and the config it was given.
    def fake_tmuxinator(script = "exit 0")
      seen = {}
      allow(Process).to receive(:spawn).and_wrap_original do |original, *args, **opts|
        seen[:args] = args
        seen[:opts] = opts
        seen[:content] = File.read(args[3])
        original.call("sh", "-c", script, **opts)
      end
      seen
    end

    it "runs tmuxinator detached, in its own process group, on a copy of the config without control mode" do
      seen = fake_tmuxinator

      expect(tmux.start_headless("proj")).to be_nil
      expect(seen[:args].values_at(0, 1, 2, 4)).to eq(["tmuxinator", "start", "-p", "--no-attach"])
      expect(seen[:opts]).to include(pgroup: true)
      expect(seen[:content]).to include("tmux_options: -2\n")
      expect(seen[:content]).not_to include("-CC")
      expect(seen[:content]).to include("windows:")
      expect(File.exist?(seen[:args][3])).to be false
      expect(File.read(source)).to include("tmux_options: -CC -2")
    end

    it "drops the tmux_options line when control mode was its only option" do
      File.write(source, "name: proj\ntmux_options: -CC\nwindows: []\n")
      seen = fake_tmuxinator

      tmux.start_headless("proj")

      expect(seen[:content]).not_to include("tmux_options")
    end

    it "strips control mode from a quoted tmux_options value, keeping the quotes" do
      File.write(source, "name: proj\ntmux_options: \"-CC -2\"\nwindows: []\n")
      seen = fake_tmuxinator

      tmux.start_headless("proj")

      expect(seen[:content]).to include("tmux_options: \"-2\"\n")
    end

    it "drops a quoted tmux_options line holding only control mode" do
      File.write(source, "name: proj\ntmux_options: '-CC'\nwindows: []\n")
      seen = fake_tmuxinator

      tmux.start_headless("proj")

      expect(seen[:content]).not_to include("tmux_options")
    end

    it "reports why tmuxinator failed" do
      fake_tmuxinator("printf 'warning\\nsession exists\\n' >&2; exit 1")

      expect(tmux.start_headless("proj")).to eq("tmuxinator exited 1: session exists")
    end

    it "reports a missing tmuxinator instead of raising" do
      allow(Process).to receive(:spawn).and_raise(Errno::ENOENT, "tmuxinator")

      expect(tmux.start_headless("proj")).to match(/could not run tmuxinator/)
    end

    it "stops a tmuxinator that outlives start_timeout and reports the timeout" do
      tmux = described_class.new(config: config, start_timeout: 0.2)
      pid_file = File.join(tmpdir, "tmuxinator.pid")
      fake_tmuxinator("echo $$ > '#{pid_file}'; exec sleep 30")

      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      expect(tmux.start_headless("proj")).to eq("tmuxinator timed out after 0.2s")
      expect(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).to be < 3
      pid = File.read(pid_file).to_i
      expect { Process.kill(0, pid) }.to raise_error(Errno::ESRCH)
    end
  end

  describe "#custom_socket_option" do
    let(:tmux) { described_class.new(config: config) }
    let(:source) { File.join(tmpdir, "workspace.proj.yml") }

    before { allow(config).to receive(:config_path_for).with("proj").and_return(source) }

    it "returns nil when tmux_options has no -L/-S" do
      File.write(source, "name: proj\ntmux_options: -CC -2\nwindows: []\n")

      expect(tmux.custom_socket_option("proj")).to be_nil
    end

    it "detects an unquoted -L socket name" do
      File.write(source, "name: proj\ntmux_options: -CC -L mysocket\nwindows: []\n")

      expect(tmux.custom_socket_option("proj")).to eq("-L")
    end

    it "detects a -S socket path inside a quoted tmux_options value" do
      File.write(source, "name: proj\ntmux_options: \"-CC -S /tmp/my.sock\"\nwindows: []\n")

      expect(tmux.custom_socket_option("proj")).to eq("-S")
    end

    it "returns nil when the config has no tmux_options line" do
      File.write(source, "name: proj\nwindows: []\n")

      expect(tmux.custom_socket_option("proj")).to be_nil
    end

    it "returns nil when the config doesn't exist" do
      allow(config).to receive(:config_path_for).with("missing-project").and_return(File.join(tmpdir, "nope.yml"))

      expect(tmux.custom_socket_option("missing-project")).to be_nil
    end

    it "detects a -L socket name containing a quoted space" do
      File.write(source, %(name: proj\ntmux_options: -CC -L "my socket"\nwindows: []\n))

      expect(tmux.custom_socket_option("proj")).to eq("-L")
    end

    it "treats unbalanced quotes in tmux_options as not detectable, same as no custom socket" do
      File.write(source, %(name: proj\ntmux_options: -CC -L "my socket\nwindows: []\n))

      expect(tmux.custom_socket_option("proj")).to be_nil
    end
  end
end
