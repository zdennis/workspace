require "spec_helper"
require "stringio"
require "json"

RSpec.describe Workspace::CLI::Agent do
  let(:out) { StringIO.new }
  let(:err) { StringIO.new }
  let(:agent_command) { CLITestHelpers::FakeAgentCommand.new }
  let(:daemon_command) { CLITestHelpers::FakeDaemonCommand.new }
  let(:review_command) { CLITestHelpers::FakeReviewCommand.new }
  let(:sessions_command) { instance_double(Workspace::Commands::Sessions, call: {exit_code: 0}) }
  let(:project_detector) { RecordingProjectDetector.new("/src/app" => "app") }
  let(:agent_runs) { [] }

  def family
    names = Workspace::CLI::Names.new(project_config: CLITestHelpers::FakeProjectConfig.new, project_detector: project_detector,
      lineage: CLITestHelpers::FakeLineage.new, working_dir: "/src/app")
    described_class.new(agent_command: agent_command, ensure_agent_command: nil, daemon_command: daemon_command, sessions_command: sessions_command,
      review_command: review_command, agent_status_command: nil, agent_executables_command: nil,
      agent_run: ->(args, invocation) { agent_runs << [args, invocation] }, project_detector: project_detector,
      common: Workspace::CLI::Common.new, names: names, working_dir: "/src/app")
  end

  def invocation
    @invocation ||= Workspace::CLI::Invocation.new(output: out, error_output: err, exit_handler: FakeExitHandler, help_asked: false, quiet: false, env: {})
  end

  def run(verb, *args)
    family.call(verb, args, invocation)
    nil
  rescue FakeSystemExit => e
    e.status
  end

  describe "#call" do
    it "hands each verb its parsed values, the workspace detected from the working directory" do
      run("agentd")
      run("daemon", "list", "--json")
      run("sessions", "--worktrees")
      run("review", "list")

      expect(agent_command.calls).to eq([{name: "app", wc_socket: nil}])
      expect(daemon_command.calls).to eq([{list: true, json: true}])
      expect(sessions_command).to have_received(:call).with(name: "app", json: false, watch: false, interval: 2, worktrees: true)
      expect(review_command.calls).to eq([{list: nil, json: false}])
    end

    it "hands `agent run` its arguments and the invocation, and sends nothing itself" do
      run("agent", "--name", "app", "run", "fix", "it")

      expect(agent_runs).to eq([[["--name", "app", "fix", "it"], invocation]])
      expect(agent_command.calls).to be_empty
    end

    it "writes and exits through the invocation it is given" do
      daemon_command.restart_result = Workspace::Commands::Daemon::Result.new("failed", 11, nil, "not_stopped", "still running")

      expect(run("daemon", "restart", "app")).to eq(1)
      expect(err.string).to eq("Error: still running\n")
      expect(run("agent", "help")).to be_nil
      expect(out.string).to start_with("Usage: workspace agent <subcommand> [options]")
    end

    it "raises a usage error for the CLI's rescue funnel to report" do
      expect { run("agentd", "app", "extra") }.to raise_error(Workspace::UsageError, /Unexpected argument: extra/)
      expect { run("review", "list", "--name", "app") }.to raise_error(Workspace::UsageError, /'review list' takes a PROJECT argument/)
    end
  end

  # The argv CLI#run hands this family, with the first word as the verb, over the same fake
  # commands as the CLI-level examples in spec/integration/workspace/cli/agent_spec.rb.
  describe "argv as CLI#run routes it" do
    def build_test_cli(output: StringIO.new, error_output: StringIO.new, **overrides)
      project_detector = overrides[:project_detector] || RecordingProjectDetector.new
      working_dir = overrides[:working_dir] || "/some/dir"
      names = Workspace::CLI::Names.new(project_config: CLITestHelpers::FakeProjectConfig.new, project_detector: project_detector,
        lineage: CLITestHelpers::FakeLineage.new, working_dir: working_dir)
      family = described_class.new(agent_command: overrides[:agent_command] || CLITestHelpers::FakeAgentCommand.new,
        ensure_agent_command: overrides[:ensure_agent_command], daemon_command: overrides[:daemon_command], sessions_command: overrides[:sessions_command],
        review_command: overrides[:review_command], agent_status_command: overrides[:agent_status_command],
        agent_executables_command: overrides[:agent_executables_command], agent_run: nil, project_detector: project_detector,
        common: Workspace::CLI::Common.new, names: names, working_dir: working_dir)
      runner = Struct.new(:family, :output, :error_output) do
        def run(argv)
          before = argv.take_while { |arg| arg != "--" }
          invocation = Workspace::CLI::Invocation.new(output: output, error_output: error_output, exit_handler: FakeExitHandler,
            help_asked: before.any? { |arg| %w[--help -h].include?(arg) }, quiet: before.include?("--json"), env: {})
          family.call(argv.first, argv.drop(1), invocation)
        end
      end
      [runner.new(family, output, error_output), output, error_output]
    end

    describe "agent and agentd" do
      it "dispatches to agent_command with --name and --wc-socket" do
        agent_command = CLITestHelpers::FakeAgentCommand.new
        cli, _, _ = build_test_cli(agent_command: agent_command)
        cli.run(["agentd", "--name", "myapp", "--wc-socket", "/tmp/wc.sock"])

        expect(agent_command.calls).to eq([{name: "myapp", wc_socket: "/tmp/wc.sock"}])
      end

      it "accepts a positional project name for agentd" do
        agent_command = CLITestHelpers::FakeAgentCommand.new
        cli, _, _ = build_test_cli(agent_command: agent_command)
        cli.run(["agentd", "myapp", "--force"])

        expect(agent_command.calls).to eq([{name: "myapp", wc_socket: nil}])
      end

      it "exits 1 when the agent refuses to start" do
        agent_command = CLITestHelpers::FakeAgentCommand.new
        agent_command.result = false
        cli, _, _ = build_test_cli(agent_command: agent_command)

        expect { cli.run(["agentd", "--name", "myapp"]) }.to raise_error(FakeSystemExit) { |e|
          expect(e.status).to eq(1)
        }
      end

      it "starts the daemon for legacy agent --name, with a deprecation warning" do
        agent_command = CLITestHelpers::FakeAgentCommand.new
        cli, _, error_output = build_test_cli(agent_command: agent_command)

        cli.run(["agent", "--name", "myapp"])

        expect(agent_command.calls).to eq([{name: "myapp", wc_socket: nil}])
        expect(error_output.string).to include("deprecated; use `workspace agentd`")
      end

      it "starts the daemon for bare agent with empty args (installed templates)" do
        agent_command = CLITestHelpers::FakeAgentCommand.new
        project_detector = instance_double(Workspace::ProjectDetector, detect: "proj")
        cli, _, error_output = build_test_cli(agent_command: agent_command, project_detector: project_detector)

        cli.run(["agent"])

        expect(agent_command.calls).to eq([{name: "proj", wc_socket: nil}])
        expect(error_output.string).to include("deprecated; use `workspace agentd`")
      end

      it "shows the umbrella help for agent help" do
        cli, output, _ = build_test_cli

        cli.run(["agent", "help"])

        expect(output.string).to include("Usage: workspace agent <subcommand>")
        expect(output.string).to include("workspace agentd")
      end
    end

    describe "#run agentd --ensure" do
      let(:ensure_command) do
        Class.new do
          attr_reader :calls
          attr_accessor :result

          def initialize
            @calls = []
            @result = Workspace::Commands::EnsureAgent::Result.new(:started)
          end

          def call(name:, wc_socket: nil)
            @calls << {name: name, wc_socket: wc_socket}
            @result
          end
        end.new
      end

      it "ensures instead of running the daemon, passing --wc-socket through" do
        agent_command = CLITestHelpers::FakeAgentCommand.new
        cli, output, _ = build_test_cli(agent_command: agent_command, ensure_agent_command: ensure_command)

        cli.run(["agentd", "--ensure", "myapp", "--wc-socket", "/tmp/wc.sock"])

        expect(ensure_command.calls).to eq([{name: "myapp", wc_socket: "/tmp/wc.sock"}])
        expect(agent_command.calls).to be_empty
        expect(output.string).to eq("Started agentd for myapp\n")
      end

      it "says so and exits 0 when one is already running" do
        ensure_command.result = Workspace::Commands::EnsureAgent::Result.new(:running)
        cli, output, _ = build_test_cli(ensure_agent_command: ensure_command)

        cli.run(["agentd", "--ensure", "--name", "myapp"])

        expect(output.string).to eq("agentd for myapp is already running\n")
      end

      it "exits 1 with the reason when the daemon can't be started" do
        ensure_command.result = Workspace::Commands::EnsureAgent::Result.new(:failed, "it did not answer within 5s")
        cli, _, error_output = build_test_cli(ensure_agent_command: ensure_command)

        expect { cli.run(["agentd", "--ensure", "myapp"]) }.to raise_error(FakeSystemExit) { |e| expect(e.status).to eq(1) }
        expect(error_output.string).to include("Could not start the agent daemon for myapp: it did not answer within 5s")
      end

      it "exits 1 quietly when the pipeline config was invalid (the warning is already printed)" do
        ensure_command.result = Workspace::Commands::EnsureAgent::Result.new(:invalid_config)
        cli, output, error_output = build_test_cli(ensure_agent_command: ensure_command)

        expect { cli.run(["agentd", "--ensure", "myapp"]) }.to raise_error(FakeSystemExit) { |e| expect(e.status).to eq(1) }
        expect(output.string).to eq("")
        expect(error_output.string).to eq("")
      end
    end

    describe "#run agentd restart" do
      let(:daemon_command) { CLITestHelpers::FakeDaemonCommand.new }
      let(:agent_command) { CLITestHelpers::FakeAgentCommand.new }
      let(:detector) { instance_double(Workspace::ProjectDetector, detect: "detected-ws") }
      let(:built) { build_test_cli(daemon_command: daemon_command, agent_command: agent_command, project_detector: detector, working_dir: "/some/dir") }
      let(:cli) { built[0] }
      let(:output) { built[1] }
      let(:error_output) { built[2] }

      it "restarts through the daemon command, the way `daemon restart` does, and never runs a daemon in the terminal" do
        cli.run(["agentd", "restart", "app"])
        cli.run(["agentd", "restart", "--name", "other", "--wc-socket", "/tmp/wc.sock"])
        cli.run(["agentd", "--name", "third", "restart"])

        expect(daemon_command.calls).to eq([
          {restart: "app", wc_socket: nil}, {restart: "other", wc_socket: "/tmp/wc.sock"}, {restart: "third", wc_socket: nil}
        ])
        expect(agent_command.calls).to eq([])
        expect(output.string.lines.first).to eq("Restarted agentd for app (pid 11 -> 22)\n")
      end

      it "restarts the detected workspace when none is named" do
        cli.run(["agentd", "restart"])

        expect(detector).to have_received(:detect).with("/some/dir")
        expect(daemon_command.calls).to eq([{restart: "detected-ws", wc_socket: nil}])
      end

      it "keeps a workspace named restart reachable through --name" do
        cli.run(["agentd", "--name", "restart"])
        cli.run(["agentd", "restart", "--name", "restart"])
        cli.run(["agentd", "restart", "restart"])

        expect(agent_command.calls).to eq([{name: "restart", wc_socket: nil}])
        expect(daemon_command.calls).to eq([{restart: "restart", wc_socket: nil}, {restart: "restart", wc_socket: nil}])
      end

      it "says which work-coordinator socket the new daemon kept when the caller named none" do
        daemon_command.restart_result = Workspace::Commands::Daemon::Result.new("restarted", 11, 22, nil, nil, "/tmp/wc-dev.sock")

        cli.run(["agentd", "restart", "app"])

        expect(output.string).to eq("Restarted agentd for app (pid 11 -> 22)\nKept its work-coordinator socket: /tmp/wc-dev.sock\n")
      end

      it "doesn't repeat a socket the caller named" do
        daemon_command.restart_result = Workspace::Commands::Daemon::Result.new("restarted", 11, 22, nil, nil, "/tmp/wc.sock")

        cli.run(["agentd", "restart", "app", "--wc-socket", "/tmp/wc.sock"])

        expect(output.string).to eq("Restarted agentd for app (pid 11 -> 22)\n")
      end

      it "prints one action document under --json, with the old pid, the new pid and the socket" do
        daemon_command.restart_result = Workspace::Commands::Daemon::Result.new("restarted", 11, 22, nil, nil, "/tmp/wc-dev.sock")

        cli.run(["agentd", "restart", "app", "--json"])

        doc = JSON.parse(output.string.lines.last)
        expect(doc).to include("ok" => true, "action" => "restart", "status" => "ok", "summary" => {"restarted" => 1})
        expect(doc["results"]).to eq([{"workspace" => "app", "outcome" => "restarted", "reason" => nil, "message" => nil,
                                       "old_pid" => 11, "pid" => 22, "wc_socket" => "/tmp/wc-dev.sock"}])
      end

      it "reports a start with nothing to stop as started, with a null old pid" do
        daemon_command.restart_result = Workspace::Commands::Daemon::Result.new("started", nil, 22)

        cli.run(["agentd", "--json", "restart", "app"])

        expect(JSON.parse(output.string.lines.last)["results"].first).to include("outcome" => "started", "old_pid" => nil, "pid" => 22, "wc_socket" => nil)
      end

      it "exits 1 with the reason on stderr when the restart fails, and as a failed document under --json" do
        daemon_command.restart_result = Workspace::Commands::Daemon::Result.new("failed", 11, nil, "not_stopped", "still running")

        expect { cli.run(["agentd", "restart", "app"]) }.to raise_error(FakeSystemExit) { |e| expect(e.status).to eq(1) }
        expect(error_output.string).to include("Error: still running")
        expect(output.string).to eq("")

        expect { cli.run(["agentd", "restart", "app", "--json"]) }.to raise_error(FakeSystemExit) { |e| expect(e.status).to eq(1) }
        doc = JSON.parse(output.string)
        expect(doc).to include("ok" => true, "status" => "failed")
        expect(doc["results"].first).to include("outcome" => "failed", "reason" => "not_stopped", "old_pid" => 11)
      end

      it "takes restart for the workspace's name with --force or --ensure, as before the subcommand existed" do
        ensure_command = double("ensure_agent", call: Workspace::Commands::EnsureAgent::Result.new(:started))
        cli, output, _ = build_test_cli(daemon_command: daemon_command, agent_command: agent_command, ensure_agent_command: ensure_command)

        cli.run(["agentd", "--ensure", "restart"])
        cli.run(["agentd", "restart", "--ensure"])
        cli.run(["agentd", "-f", "restart"])
        cli.run(["agentd", "restart", "--force"])

        expect(ensure_command).to have_received(:call).with(name: "restart", wc_socket: nil).twice
        expect(output.string).to eq("Started agentd for restart\n" * 2)
        expect(agent_command.calls).to eq([{name: "restart", wc_socket: nil}] * 2)
        expect(daemon_command.calls).to eq([])
      end

      it "takes a restart that is --wc-socket's value for the socket, not the subcommand" do
        cli.run(["agentd", "--wc-socket", "restart"])

        expect(agent_command.calls).to eq([{name: "detected-ws", wc_socket: "restart"}])
        expect(daemon_command.calls).to eq([])
      end

      it "makes a relative --wc-socket absolute, for agentd restart and daemon restart alike" do
        cli.run(["agentd", "restart", "app", "--wc-socket", "run/wc.sock"])
        cli.run(["daemon", "restart", "app", "--wc-socket", "./wc.sock"])

        expect(daemon_command.calls).to eq([{restart: "app", wc_socket: "/some/dir/run/wc.sock"}, {restart: "app", wc_socket: "/some/dir/wc.sock"}])
      end

      it "puts the socket to name on the retry in the failed row" do
        daemon_command.restart_result = Workspace::Commands::Daemon::Result.new("failed", 11, nil, "not_stopped", "still running", "/tmp/wc-dev.sock")

        expect { cli.run(["agentd", "restart", "app", "--json"]) }.to raise_error(FakeSystemExit)

        expect(JSON.parse(output.string.lines.last)["results"].first).to include("outcome" => "failed", "wc_socket" => "/tmp/wc-dev.sock")
        expect(error_output.string).not_to include("Kept its work-coordinator socket")
      end

      it "reports a usage error as a JSON error document under --json" do
        expect { cli.run(["agentd", "restart", "app", "--bogus", "--json"]) }.to raise_error(FakeSystemExit) { |e| expect(e.status).to eq(1) }

        expect(JSON.parse(output.string)).to include("ok" => false, "code" => "usage", "error" => "invalid option: --bogus")
        expect(daemon_command.calls).to eq([])
      end
    end

    describe "#run agent executables" do
      let(:executables_command) { double("agent executables", call: nil) }
      let(:detector) { instance_double(Workspace::ProjectDetector, detect: "api") }

      it "passes the kind, name and json, in either flag form, without detecting when named" do
        cli, = build_test_cli(agent_executables_command: executables_command, project_detector: detector)

        cli.run(["agent", "executables", "--kind=codex", "--name", "web", "--json"])

        expect(executables_command).to have_received(:call).with(name: "web", detected: nil, kind: "codex", json: true)
        expect(detector).not_to have_received(:detect)
      end

      it "detects the workspace from the working directory when no name is given" do
        cli, = build_test_cli(agent_executables_command: executables_command, project_detector: detector)

        cli.run(["agent", "executables"])

        expect(executables_command).to have_received(:call).with(name: nil, detected: "api", kind: nil, json: false)
      end

      it "finds the subcommand when --kind comes first" do
        cli, = build_test_cli(agent_executables_command: executables_command, project_detector: detector)

        cli.run(["agent", "--kind", "pi", "executables"])

        expect(executables_command).to have_received(:call).with(hash_including(kind: "pi"))
      end

      it "prints its help and lists it in the agent help" do
        cli, output = build_test_cli(agent_executables_command: executables_command)

        cli.run(["agent", "executables", "--help"])
        expect(output.string).to include("Usage: workspace agent executables [--kind KIND] [--name WORKSPACE] [--json]")
          .and include("claude, codex, opencode, pi").and include("unknown_agent_kind")

        output.truncate(0)
        cli.run(["agent", "help"])
        expect(output.string).to include("executables   List the agent programs on PATH")
      end
    end

    describe "#run agent status" do
      let(:status_command) { double("agent status", request: {}, post: {}) }

      it "passes request's pane and name, in either flag form" do
        cli, = build_test_cli(agent_status_command: status_command)

        cli.run(["agent", "status", "request", "--name=myapp", "--pane=%18", "--json"])

        expect(status_command).to have_received(:request).with(name: "myapp", pane: "%18", json: true)
      end

      it "passes post's fields, with progress parsed" do
        cli, = build_test_cli(agent_status_command: status_command)

        cli.run(["agent", "status", "post", "--summary=Writing specs", "--task", "T3", "--progress=3/7", "--reply-to", " sr-abc ", "--json"])

        expect(status_command).to have_received(:post).with(summary: "Writing specs", task: "T3",
          progress: {"done" => 3, "total" => 7}, reply_to: "sr-abc", json: true)
      end

      it "prints the status help, and lists status in the agent help" do
        cli, output = build_test_cli

        cli.run(["agent", "status", "--help"])
        cli.run(["agent", "help"])

        expect(output.string).to include("workspace agent status post --summary TEXT").and include("status        Ask an agent pane")
      end
    end
  end
end
