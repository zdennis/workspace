require "spec_helper"
require "open3"
require "rbconfig"
require "tmpdir"
require "json"

# The fast session-event entry, run as `bin/workspace` runs it, in a throwaway HOME: what it loads,
# what it prints, and that the command lines it does not take still print what they printed before.
RSpec.describe "workspace session-event fast path" do
  let(:loaded_script) do
    <<~RUBY
      require "workspace/cli/session_event_entry"
      code = Workspace::CLI::SessionEventEntry.run(ARGV, stdin: $stdin, stdout: $stdout, stderr: $stderr, env: ENV)
      report = %w[Doctor ITerm WorkflowEngine ProjectConfig InstructionComposer SessionMonitor].to_h { |name| [name, Workspace.const_defined?(name, false)] }
      report["cli_run"] = !!(defined?(Workspace::CLI) && Workspace::CLI.method_defined?(:run))
      report["code"] = code
      File.write(ENV.fetch("REPORT_PATH"), JSON.generate(report))
    RUBY
  end

  let(:old_path_script) { 'require "workspace"; Workspace.build_cli.run(ARGV)' }

  around do |example|
    Dir.mktmpdir("wsf", "/tmp") do |dir|
      @home = File.realpath(dir)
      @bin = File.join(@home, "bin")
      FileUtils.mkdir_p(@bin)
      tmux = File.join(@bin, "tmux")
      File.write(tmux, "#!/bin/sh\ncase \" $* \" in *\" display-message \"*) echo proj ;; esac\nexit 0\n")
      File.chmod(0o755, tmux)
      example.run
    end
  end

  def env(pane: nil)
    {"PATH" => "#{@bin}:#{ENV.fetch("PATH")}", "HOME" => @home, "TMUX_PANE" => pane, "REPORT_PATH" => File.join(@home, "report.json"),
     "XDG_STATE_HOME" => File.join(@home, "state"), "XDG_CONFIG_HOME" => File.join(@home, ".config"),
     "BUNDLE_GEMFILE" => ENV["BUNDLE_GEMFILE"], "BUNDLE_PATH" => ENV["BUNDLE_PATH"]}.compact
  end

  def payload(hook = "PreToolUse")
    JSON.generate("hook_event_name" => hook, "session_id" => "s1", "tool_name" => "Read", "cwd" => @home, "tool_input" => {"file_path" => File.join(@home, "a.rb")})
  end

  def ruby(script, *args, pane: nil, stdin: payload)
    Open3.capture3(env(pane: pane), RbConfig.ruby, "-I", File.join(PROJECT_ROOT, "lib"), "-e", script, "--", *args, stdin_data: stdin, unsetenv_others: true, chdir: @home)
  end

  def bin_workspace(*args, stdin: payload)
    Open3.capture3(env, RbConfig.ruby, File.join(PROJECT_ROOT, "bin", "workspace"), *args, stdin_data: stdin, unsetenv_others: true, chdir: @home)
  end

  def report = JSON.parse(File.read(File.join(@home, "report.json")))

  unloaded = {"Doctor" => false, "ITerm" => false, "WorkflowEngine" => false, "ProjectConfig" => false,
              "InstructionComposer" => false, "SessionMonitor" => false, "cli_run" => false, "code" => 0}

  [[[], nil], [%w[--agent codex], nil], [%w[--workspace proj], nil], [[], "%1"], [%w[--agent=codex --workspace=proj], "%1"]].each do |args, pane|
    it "loads none of the CLI for a PreToolUse with #{args.inspect}#{" in pane #{pane}" if pane}" do
      out, err, status = ruby(loaded_script, "session-event", *args, pane: pane)

      expect([out, err, status.exitstatus]).to eq(["", "", 0])
      expect(report).to eq(unloaded)
    end
  end

  it "loads none of the CLI for a UserPromptSubmit in a pane with a hang guard count to clear" do
    state = File.join(@home, "state", "workspace")
    FileUtils.mkdir_p(state)
    File.write(File.join(state, "hang-guard.json"), JSON.generate("pane:%1:s1" => {"count" => 1, "updated_at" => Time.now.utc.iso8601}))

    out, err, status = ruby(loaded_script, "session-event", pane: "%1", stdin: payload("UserPromptSubmit"))

    expect([out, err, status.exitstatus]).to eq(["", "", 0])
    expect(report).to eq(unloaded)
    expect(JSON.parse(File.read(File.join(state, "hang-guard.json")))).to eq({})
  end

  it "hands a SessionStart to the whole CLI" do
    out, err, status = ruby(loaded_script, "session-event", stdin: payload("SessionStart"))

    expect([out, err, status.exitstatus]).to eq(["", "", 0])
    expect(report).to include("cli_run" => true, "code" => 0)
  end

  it "runs bin/workspace session-event on a PreToolUse with no output and exit 0" do
    out, err, status = bin_workspace("session-event")

    expect([out, err, status.exitstatus]).to eq(["", "", 0])
  end

  [%w[--version], %w[--help], %w[session-event --help], %w[session-event --bogus]].each do |args|
    it "prints the same bytes and exit code for #{args.join(" ")} as the old path" do
      expect(bin_workspace(*args).map { |part| part.is_a?(String) ? part : part.exitstatus })
        .to eq(ruby(old_path_script, *args).map { |part| part.is_a?(String) ? part : part.exitstatus })
    end
  end
end
