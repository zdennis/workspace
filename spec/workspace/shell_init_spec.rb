require "open3"
require "tmpdir"
require "fileutils"

RSpec.describe Workspace::ShellInit do
  def find_shell(name)
    ENV["PATH"].split(File::PATH_SEPARATOR).map { |d| File.join(d, name) }.find { |p| File.executable?(p) }
  end

  shell_commands = {
    "zsh -f" => ->(finder) { (z = finder.call("zsh")) && [z, "-f"] },
    "bash --norc --noprofile" => ->(finder) { (b = finder.call("bash")) && [b, "--norc", "--noprofile"] },
    "/bin/bash" => ->(_) { File.executable?("/bin/bash") ? ["/bin/bash"] : nil }
  }

  let(:sandbox) { Dir.mktmpdir("shell-init") }
  let(:bin_dir) { File.join(sandbox, "bin") }
  let(:work_dir) { File.join(sandbox, "work") }
  let(:argv_file) { File.join(sandbox, "argv") }

  before do
    FileUtils.mkdir_p([bin_dir, work_dir])
    fake = File.join(bin_dir, "workspace")
    File.write(fake, <<~'SH')
      #!/bin/sh
      : >> "$WF_OUT"
      for a in "$@"; do printf '%s\0' "$a" >> "$WF_OUT"; done
      exit "${FAKE_STATUS:-0}"
    SH
    File.chmod(0o755, fake)
  end

  after { FileUtils.remove_entry(sandbox) }

  def argv
    return nil unless File.exist?(argv_file)
    File.binread(argv_file).split("\0", -1)[0...-1]
  end

  # Loads the printed text with eval, then runs +line+ with +args+ as "$@".
  def run_shell(command, shell_name, line, args = [], prefix: "", env: {}, interactive: false)
    text = Workspace::ShellInit.text(shell_name)
    script = "#{prefix}\neval \"$WF_TEXT\"\n#{line}"
    cmd = command + (interactive ? ["-i"] : []) + ["-c", script, "sh", *args]
    environment = {"PATH" => "#{bin_dir}:#{ENV["PATH"]}", "WF_TEXT" => text, "WF_OUT" => argv_file, "HOME" => sandbox}.merge(env)
    Open3.capture3(environment, *cmd, chdir: work_dir, unsetenv_others: false)
  end

  shell_commands.each do |label, resolver|
    context "under #{label}" do
      let(:command) { resolver.call(method(:find_shell)) }
      let(:shell_name) { label.start_with?("zsh") ? "zsh" : "bash" }

      before { skip "#{label} is not installed" unless command }

      def wf(*args, **opts)
        run_shell(command, shell_name, 'wf "$@"', args, **opts)
      end

      it "loads silently, with an alias on wf set first" do
        prefix = (shell_name == "bash") ? "shopt -s expand_aliases\nalias wf=x" : "alias wf=x"
        out, err, status = run_shell(command, shell_name, ":", prefix: prefix)
        expect([out, err, status.exitstatus]).to eq(["", "", 0])
      end

      it "starts the default workflow on one word as a ref" do
        _, _, status = wf("feature-x")
        expect(status.exitstatus).to eq(0)
        expect(argv).to eq(%w[workflow start -- rpiv feature-x])
      end

      it "takes the id from -w" do
        wf("-w", "explore", "feature-x")
        expect(argv).to eq(%w[workflow start -- explore feature-x])
      end

      it "takes the default id from WORKSPACE_WF_DEFAULT" do
        wf("feature-x", env: {"WORKSPACE_WF_DEFAULT" => "investigate"})
        expect(argv).to eq(%w[workflow start -- investigate feature-x])
      end

      it "sends several words as one prompt joined by spaces" do
        wf("fix", "the", "thing")
        expect(argv).to eq(["workflow", "start", "--prompt", "fix the thing", "--", "rpiv"])
      end

      it "sends one quoted string with whitespace as a prompt, newline intact" do
        wf("fix the\nthing")
        expect(argv).to eq(["workflow", "start", "--prompt", "fix the\nthing", "--", "rpiv"])
      end

      it "puts --dry-run before the other arguments" do
        wf("--dry-run", "fix the thing")
        expect(argv).to eq(["workflow", "start", "--dry-run", "--prompt", "fix the thing", "--", "rpiv"])
        File.delete(argv_file)
        wf("--dry-run", "feature-x")
        expect(argv).to eq(%w[workflow start --dry-run -- rpiv feature-x])
      end

      it "takes text that starts with a dash after --" do
        wf("--", "-x")
        expect(argv).to eq(%w[workflow start -- rpiv -x])
      end

      it "treats a --dry-run after -- as text, not a dry run" do
        wf("--", "--dry-run", "fix")
        expect(argv).to eq(["workflow", "start", "--prompt", "--dry-run fix", "--", "rpiv"])
      end

      it "passes a quoted #123 as a ref" do
        wf("#123")
        expect(argv).to eq(%w[workflow start -- rpiv #123])
      end

      it "stops reading options at the first word that is not one" do
        wf("fix", "-w", "foo")
        expect(argv).to eq(["workflow", "start", "--prompt", "fix -w foo", "--", "rpiv"])
      end

      it "refuses no words, an empty word, a -w without a value and an unknown option" do
        [[], [""], ["-w"], ["-w", ""], ["-w", "x"], ["--bogus", "x"], ["-x"]].each do |args|
          File.delete(argv_file) if File.exist?(argv_file)
          _, err, status = wf(*args)
          expect(status.exitstatus).to eq(1), "args #{args.inspect}"
          expect(err).not_to be_empty
          expect(argv).to be_nil, "args #{args.inspect}"
        end
      end

      it "points an unknown option at --" do
        _, err, _ = wf("--bogus", "x")
        expect(err).to include("--")
      end

      it "prints help on stdout and exits 0" do
        out, _, status = wf("--help")
        expect(status.exitstatus).to eq(0)
        expect(out).to start_with("Usage: wf")
        expect(argv).to be_nil
      end

      it "passes the exit status of workspace through" do
        _, _, status = wf("feature-x", env: {"FAKE_STATUS" => "7"})
        expect(status.exitstatus).to eq(7)
        _, _, status = wf("fix the thing", env: {"FAKE_STATUS" => "3"})
        expect(status.exitstatus).to eq(3)
      end

      it "hands hostile words to argv byte for byte and runs nothing" do
        hostile = ["$(touch canary)", "`touch canary`", "x; touch canary", "a'b\"c", "*", "$HOME \\n"]
        hostile.each do |word|
          wf(word)
          expected = word.match?(/\s/) ? ["workflow", "start", "--prompt", word, "--", "rpiv"] : ["workflow", "start", "--", "rpiv", word]
          expect(argv).to eq(expected), word
          File.delete(argv_file)
          wf("say", word)
          expect(argv).to eq(["workflow", "start", "--prompt", "say #{word}", "--", "rpiv"]), word
          File.delete(argv_file)
        end
        expect(File.exist?(File.join(work_dir, "canary"))).to be(false)
      end
    end
  end

  context "under an interactive zsh" do
    before { skip "zsh is not installed" unless find_shell("zsh") }

    it "loads silently" do
      out, _err, status = run_shell([find_shell("zsh"), "-f"], "zsh", ":", interactive: true)
      expect([out, status.exitstatus]).to eq(["", 0])
    end
  end

  context "under zsh with sh_word_split, ksh_arrays and no_unset" do
    before { skip "zsh is not installed" unless find_shell("zsh") }

    it "gives the same argv" do
      prefix = "setopt sh_word_split ksh_arrays no_unset"
      run_shell([find_shell("zsh"), "-f"], "zsh", 'wf --dry-run -w explore "$@"', ["fix", "the thing"], prefix: prefix)
      expect(argv).to eq(["workflow", "start", "--dry-run", "--prompt", "fix the thing", "--", "explore"])
      File.delete(argv_file)
      run_shell([find_shell("zsh"), "-f"], "zsh", 'wf "$@"', ["feature-x"], prefix: prefix)
      expect(argv).to eq(%w[workflow start -- rpiv feature-x])
    end
  end

  describe ".text" do
    %w[zsh bash].each do |shell|
      it "holds no eval, no compgen -W and no name() { for #{shell}" do
        text = described_class.text(shell)
        expect(text).not_to match(/eval/)
        expect(text).not_to include("compgen -W")
        expect(text).not_to include("() {")
      end
    end

    it "refuses another shell" do
      expect { described_class.text("fish") }.to raise_error(ArgumentError)
    end
  end

  describe "workspace shell-init" do
    %w[zsh bash].each do |shell|
      it "prints the #{shell} text" do
        out, err, status = Open3.capture3(File.expand_path("../../bin/workspace", __dir__), "shell-init", shell)
        expect(status.exitstatus).to eq(0), err
        expect(out).to eq(described_class.text(shell))
      end
    end

    it "refuses no argument, an unknown shell and two arguments" do
      [[], ["fish"], %w[zsh bash]].each do |args|
        _, err, status = Open3.capture3(File.expand_path("../../bin/workspace", __dir__), "shell-init", *args)
        expect(status.exitstatus).to eq(1)
        expect(err).to include("Usage: workspace shell-init zsh|bash")
      end
    end
  end
end
