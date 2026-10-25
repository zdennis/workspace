require "tmpdir"
require "open3"
require "yaml"

# Runs real tmux on a private socket. tmux rejects `-t =NAME` for commands that
# take a session-only target (`no such session: =NAME`), and reads a dot in a
# bare `=proj.wt-x` as a pane separator; only `=NAME:` works. Mocked specs
# cannot see that, so this one asks tmux itself.
RSpec.describe "tmux session targets (contract against real tmux)" do
  tmux_missing = !system("command -v tmux >/dev/null 2>&1")

  let(:tmpdir) { Dir.mktmpdir("ws-contract", "/tmp") }
  let(:socket) { "wsctr#{Process.pid}#{rand(100000)}" }
  let(:session) { "proj.wt-x" }
  let(:config) { Workspace::Config.new(workspace_dir: tmpdir) }
  let(:tmux) { Workspace::Tmux.new(config: config) }

  around do |example|
    skip "tmux is not installed" if tmux_missing
    bin = File.join(tmpdir, "bin")
    FileUtils.mkdir_p(bin)
    real = `command -v tmux`.strip
    shim = File.join(bin, "tmux")
    File.write(shim, "#!/bin/sh\nexec #{real} -L #{socket} -f /dev/null \"$@\"\n")
    File.chmod(0o755, shim)
    saved = ENV.to_h.slice("PATH", "TMUX", "TMUX_PANE", "TMUX_TMPDIR")
    ENV["PATH"] = "#{bin}:#{saved["PATH"]}"
    ENV.delete("TMUX")
    ENV.delete("TMUX_PANE")
    system(shim, "new-session", "-d", "-s", session)
    begin
      example.run
    ensure
      system(shim, "kill-server", err: File::NULL, out: File::NULL)
      saved.each { |k, v| ENV[k] = v }
      FileUtils.remove_entry(tmpdir)
    end
  end

  it "round-trips a session option on a dotted session name" do
    expect(tmux.set_session_option(session, "@workspace", "proj.worktree-x")).to be true
    expect(tmux.session_option(session, "@workspace")).to eq("proj.worktree-x")
  end

  it "round-trips a session option on an undotted name, which bare =NAME rejects" do
    system("tmux", "new-session", "-d", "-s", "plain")
    expect(tmux.set_session_option("plain", "@workspace", "plain")).to be true
    expect(tmux.session_option("plain", "@workspace")).to eq("plain")
  end

  it "finds, renames and kills a dotted session" do
    expect(tmux.session_exists?(session)).to be true
    expect(tmux.rename_session(session, "other.name")).to be true
    expect(tmux.session_exists?("other.name")).to be true
    tmux.kill_session("other.name")
    expect(tmux.session_exists?("other.name")).to be false
  end

  [["workspace.project-template.yml", {"PROJECT_NAME" => "proj.wt-x"}],
    ["workspace.project-worktree-template.yml", {"TMUX_SESSION_NAME" => "proj.wt-x"}]].each do |file, vars|
    it "sets @workspace from the line in #{file}" do
      text = File.read(File.expand_path("../../lib/templates/#{file}", __dir__))
      vars.each { |k, v| text = text.gsub("{{#{k}}}", v) }
      text = text.gsub("{{WORKSPACE_NAME}}", "proj.worktree-x")
      line = text.lines.find { |l| l.include?("set-option") }
      expect(line).not_to be_nil

      _, err, status = Open3.capture3({"TMUX" => nil}, "sh", "-c", line.strip.sub(/ \|\| true\z/, ""))
      expect([status.success?, err]).to eq([true, ""])
      expect(tmux.session_option(session, "@workspace")).to eq("proj.worktree-x")
    end
  end
end
