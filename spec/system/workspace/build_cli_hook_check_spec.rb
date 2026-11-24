require "spec_helper"
require "stringio"
require "tmpdir"
require "fileutils"
require "json"

RSpec.describe "Workspace.build_cli wiring" do
  around do |example|
    Dir.mktmpdir("hook-check-cli") do |dir|
      saved = ENV.to_h
      begin
        @home = File.realpath(dir)
        bin = File.join(@home, "bin")
        FileUtils.mkdir_p(bin)
        File.write(File.join(bin, "claude"), "#!/bin/sh\n")
        FileUtils.chmod(0o755, File.join(bin, "claude"))
        ENV.replace("HOME" => @home, "PATH" => [bin, File.dirname(RbConfig.ruby), "/usr/bin", "/bin"].join(":"),
          "XDG_STATE_HOME" => File.join(@home, "state"), "XDG_CONFIG_HOME" => File.join(@home, "config"), "CODEX_HOME" => File.join(@home, "codex"), "CLAUDE_CONFIG_DIR" => File.join(@home, "claude-config"))
        example.run
      ensure
        ENV.replace(saved)
      end
    end
  end

  let(:out) { StringIO.new }
  let(:err) { StringIO.new }

  def build(**options)
    CLITestHelpers.build_cli(output: out, error_output: err, input: StringIO.new, env: {}, exit_handler: FakeExitHandler, **options)
  end

  it "builds a LaunchHookCheck into the launcher" do
    launcher = instance_double(Workspace::CLI::Launcher)
    allow(Workspace::CLI::Launcher).to receive(:new).and_return(launcher)

    build

    expect(Workspace::CLI::Launcher).to have_received(:new).with(hash_including(hook_check: an_instance_of(Workspace::LaunchHookCheck)))
  end

  it "gives the CLI and Launch the same ClaudeTrust" do
    trust = instance_double(Workspace::ClaudeTrust)
    allow(Workspace::ClaudeTrust).to receive(:new).and_return(trust)
    allow(Workspace::Commands::Launch).to receive(:new).and_return(instance_double(Workspace::Commands::Launch))
    allow(Workspace::CLI).to receive(:new).and_return(instance_double(Workspace::CLI))

    build

    expect(Workspace::Commands::Launch).to have_received(:new).with(hash_including(claude_trust: trust))
    expect(Workspace::CLI).to have_received(:new).with(hash_including(claude_trust: trust))
  end

  it "gives the launcher and start the one AgentHookSetup" do
    launcher_args = nil
    start_args = nil
    allow(Workspace::CLI::Launcher).to receive(:new) { |**kw| (launcher_args = kw) && instance_double(Workspace::CLI::Launcher) }
    allow(Workspace::Commands::Start).to receive(:new) { |**kw| (start_args = kw) && instance_double(Workspace::Commands::Start) }

    build

    expect(launcher_args[:hook_setup]).to be_a(Workspace::AgentHookSetup)
    expect(launcher_args[:hook_setup]).to equal(start_args[:agent_hook_setup])
  end

  it "installs the checkout's hooks on a real `launch --json --headless` and keeps stdout one JSON document" do
    checkout = File.join(@home, "src", "proj")
    FileUtils.mkdir_p(checkout)
    tmux = Class.new(FakeTmux) do
      def start_headless(name)
        @started = session_name_for(name)
        nil
      end

      def sessions(**) = [@started].compact
    end.new
    ensurer = Class.new do
      def call(name:, wc_socket: nil) = Struct.new(:status, :detail) { def ok? = true }.new(:ok, nil)
    end.new
    allow(Workspace::Commands::EnsureAgent).to receive(:new).and_return(ensurer)
    build(tmux: tmux).run(["launch", "--json", "--headless", checkout])

    expect(File).to exist(File.join(checkout, ".claude", "settings.local.json"))
    expect(JSON.parse(out.string)).to include("action" => "launch")
  end
end
