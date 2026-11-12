require "spec_helper"
require "stringio"
require "tmpdir"
require "json"
require "socket"
require "fileutils"

# The agent family through CLI#run: its rescue funnel, `agent run` (which the CLI still sends),
# the main help, names settled by a real WorkspaceName, and a real Commands::Daemon or Commands::Sessions.
RSpec.describe Workspace::CLI do
  include CLITestHelpers::AgentFamilyCli

  describe "#run with agent" do
    describe "#run agent run" do
      describe "--json" do
        let(:tmpdir) { Dir.mktmpdir("ws-agent-run", "/tmp") }
        let(:config) do
          dir = tmpdir
          Class.new(Workspace::Config) do
            define_method(:agent_socket_path) { |name| File.join(dir, "#{name}.sock") }
          end.new
        end

        after { FileUtils.remove_entry(tmpdir) if File.directory?(tmpdir) }

        def json_cli
          raw = StringIO.new
          err = StringIO.new
          cli, = build_test_cli(config: config, output: Workspace::OutputGate.new(raw), error_output: err)
          [cli, raw, err]
        end

        def with_fake_agent(project, reply)
          server = UNIXServer.new(config.agent_socket_path(project))
          accepter = Thread.new do
            client = server.accept
            client.gets
            client.puts(reply.to_json)
            client.close
          rescue IOError, Errno::EBADF
            nil
          end
          yield
          accepter.join(2)
        ensure
          server.close
          accepter&.kill
        end

        it "prints one document with the agent's reply and no Reply: scrape" do
          cli, raw, err = json_cli

          with_fake_agent("myapp", {"ok" => true, "work_item_ref" => "wi_12"}) do
            cli.run(["agent", "run", "--name", "myapp", "--work-item", "wi_12", "fix it", "--json"])
          end

          doc = JSON.parse(raw.string)
          expect(doc).to include("schema_version" => 1, "ok" => true, "workspace" => "myapp", "work_item_ref" => "wi_12", "dry_run" => false)
          expect(doc["dispatch_id"]).to start_with("agent-run-")
          expect(doc["reply"]).to eq({"ok" => true, "work_item_ref" => "wi_12"})
          expect(raw.string).not_to include("Reply:")
          expect(err.string).to include("Reply:")
        end

        it "passes a refusing reply through under reply, exit 0" do
          cli, raw, = json_cli

          with_fake_agent("myapp", {"ok" => false, "error" => "no_active_pipeline"}) do
            cli.run(["agent", "run", "--name", "myapp", "fix it", "--json"])
          end

          expect(JSON.parse(raw.string)).to include("ok" => true, "reply" => {"ok" => false, "error" => "no_active_pipeline"})
        end

        it "shows the message instead of a reply for --dry-run" do
          cli, raw, = json_cli

          cli.run(["agent", "run", "--name", "myapp", "fix it", "--dry-run", "--json"])

          doc = JSON.parse(raw.string)
          expect(doc).to include("dry_run" => true)
          expect(doc).not_to have_key("reply")
          expect(doc["message"]).to include("type" => "command", "workspace" => "myapp")
        end

        it "answers a missing daemon with the error envelope" do
          cli, raw, err = json_cli

          expect { cli.run(["agent", "run", "--name", "myapp", "fix it", "--json"]) }.to raise_error(FakeSystemExit)

          expect(JSON.parse(raw.string)).to include("ok" => false, "code" => "no_daemon")
          expect(JSON.parse(raw.string)["error"]).to include("No agent is running for myapp")
          expect(err.string).not_to include("No agent")
        end
      end

      it "sends the joined positional args as the prompt" do
        cli, output = build_test_cli

        cli.run(["agent", "run", "--name", "myapp", "--work-item", "WC-42", "Add", "OAuth", "support", "--dry-run"])

        expect(output.string).to include('"work_item_ref": "WC-42"')
        expect(output.string).to include("Add OAuth support")
        expect(output.string).to include('"type": "command"')
      end

      it "defaults --work-item to a random UUID" do
        cli, output = build_test_cli

        cli.run(["agent", "run", "--name", "myapp", "Do the thing", "--dry-run"])

        expect(output.string).to match(/"work_item_ref": "[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}"/)
      end

      it "supports -- for a prompt starting with a dash" do
        cli, output = build_test_cli

        cli.run(["agent", "run", "--name", "myapp", "--dry-run", "--", "--verbose prompt"])

        expect(output.string).to include("--verbose prompt")
      end

      it "errors when the prompt is missing" do
        cli, _, error_output = build_test_cli

        expect { cli.run(["agent", "run", "--name", "myapp"]) }.to raise_error(FakeSystemExit)
        expect(error_output.string).to include("Missing prompt")
      end

      it "sends a prompt containing the word help" do
        cli, output = build_test_cli

        cli.run(["agent", "run", "--name", "myapp", "--dry-run", "help", "me", "refactor", "login"])

        expect(output.string).to include("help me refactor login")
      end

      it "dispatches to run when a value-taking flag leads" do
        cli, output = build_test_cli

        cli.run(["agent", "--name", "myapp", "run", "Add OAuth support", "--dry-run"])

        expect(output.string).to include("Add OAuth support")
      end

      it "dry-runs when a -- terminator leads the subcommand" do
        cli, output = build_test_cli

        cli.run(["agent", "--", "run", "--name", "myapp", "x", "--dry-run"])

        expect(output.string).to include('"type": "command"')
        expect(output.string).to include('"body"')
        expect(output.string).to include("(dry-run: not sent)")
        expect(output.string).not_to include("--dry-run")
      end

      it "uses an agent-run dispatch_id prefix" do
        cli, output = build_test_cli

        cli.run(["agent", "run", "--name", "myapp", "Do the thing", "--dry-run"])

        expect(output.string).to match(/"dispatch_id": "agent-run-[0-9a-f]{8}"/)
      end

      it "errors with a hint when a flag-looking word is parsed as an option" do
        cli, _, error_output = build_test_cli

        expect { cli.run(["agent", "run", "--name", "myapp", "fix", "the", "--force", "flag", "handling"]) }
          .to raise_error(FakeSystemExit)
        expect(error_output.string).to include("pass it after --")
      end
    end

    describe "#run agent unknown word" do
      it "errors instead of starting a daemon named after the word" do
        agent_command = CLITestHelpers::FakeAgentCommand.new
        cli, _, error_output = build_test_cli(agent_command: agent_command)

        expect { cli.run(["agent", "frobnicate"]) }.to raise_error(FakeSystemExit)
        expect(error_output.string).to include("Unknown agent subcommand: frobnicate")
        expect(error_output.string).to include("workspace agentd")
        expect(agent_command.calls).to be_empty
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

      it "refuses to combine --ensure with --force" do
        cli, _, error_output = build_test_cli(ensure_agent_command: ensure_command)

        expect { cli.run(["agentd", "--ensure", "--force", "myapp"]) }.to raise_error(FakeSystemExit)
        expect(error_output.string).to include("--ensure and --force can't be combined")
        expect(ensure_command.calls).to be_empty
      end
    end

    describe "#run agentd" do
      it "errors on an unexpected argument" do
        cli, _, error_output = build_test_cli

        expect { cli.run(["agentd", "myapp", "extra"]) }.to raise_error(FakeSystemExit)
        expect(error_output.string).to include("Unexpected argument: extra")
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

      context "when a config exists under a different case" do
        let(:project_config) do
          instance_double(Workspace::ProjectConfig, available_projects: ["Notes"]).tap do |pc|
            allow(pc).to receive(:existing_name) { |name| %w[Notes].find { |known| known.casecmp?(name) } }
          end
        end
        let(:built) do
          build_test_cli(daemon_command: daemon_command, agent_command: agent_command, project_detector: detector, working_dir: "/some/dir", project_config: project_config,
            workspace_name: Workspace::WorkspaceName.new(project_config: project_config))
        end

        it "takes notes and Notes for one workspace, by position and by --name" do
          cli.run(["agentd", "restart", "notes"])
          cli.run(["agentd", "restart", "--name", "NOTES"])
          cli.run(["agentd", "restart", "--name=notes"])
          cli.run(["agentd", "--name", "notes"])
          cli.run(["agentd", "Notes"])

          expect(daemon_command.calls.map { |call| call[:restart] }).to eq(["Notes", "Notes", "Notes"])
          expect(agent_command.calls.map { |call| call[:name] }).to eq(["Notes", "Notes"])
        end

        it "refuses a name no config matches, in every agentd form" do
          [["agentd", "restart", "Fresh"], ["agentd", "restart", "--name", "Fresh"], ["agentd", "Fresh"],
            ["agentd", "--ensure", "Fresh"], ["agentd", "--force", "--name", "Fresh"]].each do |args|
            expect { cli.run(args) }.to raise_error(FakeSystemExit) { |e| expect(e.status).to eq(1) }
          end

          expect(error_output.string.scan("Unknown workspace 'Fresh'").size).to eq(5)

          expect(daemon_command.calls).to eq([])
          expect(agent_command.calls).to eq([])
        end

        it "leaves a --name after -- alone and a trailing --name without a value" do
          expect { cli.run(["agentd", "restart", "--", "--name", "notes"]) }.to raise_error(FakeSystemExit)
          expect(error_output.string).to include("Unexpected argument: notes")
          expect(error_output.string).not_to include("Notes")

          expect { cli.run(["agentd", "--name"]) }.to raise_error(FakeSystemExit)
          expect(error_output.string).to include("missing argument: --name")
          expect(daemon_command.calls).to eq([])
          expect(agent_command.calls).to eq([])
        end
      end

      it "refuses an extra argument, also beside --force or --ensure" do
        {
          ["agentd", "restart", "app", "extra"] => "Unexpected argument: extra",
          ["agentd", "restart", "app", "--name", "other"] => "Unexpected argument: app",
          ["agentd", "restart", "app", "--force"] => "Unexpected argument: app",
          ["agentd", "restart", "app", "--ensure"] => "Unexpected argument: app"
        }.each do |argv, message|
          expect { cli.run(argv) }.to raise_error(FakeSystemExit) { |e| expect(e.status).to eq(1) }, argv.inspect
          expect(error_output.string).to include(message), argv.inspect
        end
        expect(daemon_command.calls).to eq([])
        expect(agent_command.calls).to eq([])
      end

      it "reports an unknown workspace as a JSON error document under --json" do
        daemon_command.error = Workspace::Error.new("Unknown workspace 'nope'", code: "unknown_workspace", details: {"name" => "nope"})

        expect { cli.run(["agentd", "restart", "nope", "--json"]) }.to raise_error(FakeSystemExit) { |e| expect(e.status).to eq(1) }

        expect(JSON.parse(output.string)).to include("ok" => false, "code" => "unknown_workspace", "details" => {"name" => "nope"})
      end

      it "asks for a workspace when none is named or detected" do
        allow(detector).to receive(:detect).and_return(nil)

        expect { cli.run(["agentd", "restart"]) }.to raise_error(FakeSystemExit)
        expect(error_output.string).to include("Missing workspace name", "workspace agentd restart [PROJECT]")
      end

      it "keeps --json for restart: plain agentd refuses it" do
        expect { cli.run(["agentd", "app", "--json"]) }.to raise_error(FakeSystemExit) { |e| expect(e.status).to eq(1) }
        expect(JSON.parse(output.string)).to include("ok" => false, "code" => "usage", "error" => "invalid option: --json")
        expect(agent_command.calls).to eq([])
      end

      it "shows its own help, and agentd's help and the main help name it" do
        cli.run(["agentd", "restart", "--help"])
        expect(output.string).to include("Usage: workspace agentd restart [PROJECT]", "--wc-socket PATH", "--json")
        expect(daemon_command.calls).to eq([])

        output.truncate(0)
        output.rewind
        cli.run(["help"])
        expect(output.string).to match(/^\s+agentd\s.*agentd restart/)

        # agentd's own help, as its usage error prints it: OptionParser's built-in --help exits the process.
        allow(detector).to receive(:detect).and_return(nil)
        expect { cli.run(["agentd"]) }.to raise_error(FakeSystemExit)
        expect(error_output.string).to include("workspace agentd restart [PROJECT] [--wc-socket PATH] [--json]", "workspace agentd restart --help")
      end

      it "says so when no daemon command is wired" do
        cli, _, error_output = build_test_cli

        expect { cli.run(["agentd", "restart", "app"]) }.to raise_error(FakeSystemExit)
        expect(error_output.string).to include("agentd restart is not available")
      end
    end
  end

  describe "#run agent executables" do
    let(:executables_command) { double("agent executables", call: nil) }
    let(:detector) { instance_double(Workspace::ProjectDetector, detect: "api") }

    it "reports an extra argument as a usage error, as JSON with --json" do
      cli, output = build_test_cli(agent_executables_command: executables_command)

      expect { cli.run(["agent", "executables", "extra", "--json"]) }.to raise_error(FakeSystemExit)
      expect(JSON.parse(output.string)).to include("ok" => false, "code" => "usage")
    end
  end

  describe "#run agent status" do
    let(:status_command) { double("agent status", request: {}, post: {}) }

    [
      [%w[request --name myapp], "Missing --pane."],
      [%w[post], "Missing --summary."],
      [["post", "--summary", "ok", "--progress", "8/7"], "--progress must be N/M"],
      [%w[post --summary ok extra], "Unexpected argument: extra"],
      [%w[nope], "Unknown agent status verb: nope."],
      [%w[], "Missing agent status verb"]
    ].each do |args, message|
      it "reports #{args.join(" ")} as a usage error, as JSON with --json" do
        cli, output = build_test_cli(agent_status_command: status_command)

        expect { cli.run(["agent", "status", *args, "--json"]) }.to raise_error(FakeSystemExit) { |e| expect(e.status).to eq(1) }
        expect(JSON.parse(output.string)).to include("ok" => false, "code" => "usage")
        expect(JSON.parse(output.string)["error"]).to include(message)
      end
    end

    it "exits 2 when the request landed but wasn't confirmed submitted" do
      allow(status_command).to receive(:request)
        .and_raise(Workspace::Commands::Run::NotSubmittedError.new("check the pane", code: "not_submitted", details: {"request_id" => "sr-abc"}))
      cli, output = build_test_cli(agent_status_command: status_command)

      expect { cli.run(["agent", "status", "request", "--name", "myapp", "--pane", "%18", "--json"]) }
        .to raise_error(FakeSystemExit) { |e| expect(e.status).to eq(2) }
      expect(JSON.parse(output.string)).to include("code" => "not_submitted", "details" => {"request_id" => "sr-abc"})
    end
  end

  describe "#run with daemon" do
    let(:daemon_command) { CLITestHelpers::FakeDaemonCommand.new }
    let(:detector) { instance_double(Workspace::ProjectDetector, detect: "detected-ws") }
    let(:built) { build_test_cli(daemon_command: daemon_command, project_detector: detector, working_dir: "/some/dir") }
    let(:cli) { built[0] }
    let(:output) { built[1] }
    let(:error_output) { built[2] }

    describe "list and restart --all" do
      let(:result_class) { Workspace::Commands::Daemon::Result }

      it "sends restart-all progress to stderr and keeps stdout to one JSON document" do
        dir = Dir.mktmpdir
        raw = StringIO.new
        error_output = StringIO.new
        output_gate = Workspace::OutputGate.new(raw)
        socket = File.join(dir, "workspace-api.sock")
        File.write(socket, "")
        config = instance_double(Workspace::Config)
        allow(config).to receive(:agent_socket_path).with("api").and_return(socket)
        allow(config).to receive(:agent_log_path).with("api").and_return(File.join(dir, "workspace-api.log"))
        allow(config).to receive(:agent_running?).with("api").and_return(true)
        project_config = instance_double(Workspace::ProjectConfig, available_projects: ["api"], exists?: true)
        process_tree = double(snapshot: double(find: nil))
        command = Workspace::Commands::Daemon.new(config: config, project_config: project_config, ensure_agent: double("ensure_agent"),
          version_client: double("version_client", version: nil), process_tree: process_tree, pid_finder: ->(_path) { [] }, output: output_gate)
        cli, = build_test_cli(config: config, project_config: project_config, daemon_command: command, output: output_gate, error_output: error_output)

        expect { cli.run(["daemon", "restart", "--all", "--json"]) }.to raise_error(FakeSystemExit) { |e| expect(e.status).to eq(1) }

        expect(raw.string.lines.size).to eq(1)
        expect(JSON.parse(raw.string)).to include("action" => "restart", "status" => "failed")
        expect(error_output.string).to include("Looking for running agentd processes...", "Found agentd for api.", "Restarting agentd for api...")
      ensure
        FileUtils.remove_entry(dir) if dir && File.directory?(dir)
      end

      it "refuses a workspace with --all or list, and --all or --wc-socket where they don't belong, as usage errors" do
        [%w[daemon restart --all app], %w[daemon restart --all --name app], %w[daemon list app], %w[daemon list --wc-socket /x],
          %w[daemon restart --all --wc-socket /x], %w[daemon status --all], %w[daemon list --lines 3]].each do |argv|
          expect { cli.run(argv) }.to raise_error(FakeSystemExit), argv.join(" ")
        end
        expect(daemon_command.calls).to eq([])
      end
    end

    it "rejects a missing subcommand, extra arguments and misplaced options as usage errors" do
      [
        ["daemon"],
        ["daemon", "bogus"],
        ["daemon", "status", "a", "b"],
        ["daemon", "status", "a", "--lines", "3"],
        ["daemon", "log", "a", "--wc-socket", "/x"],
        ["daemon", "log", "a", "--lines", "many"]
      ].each do |argv|
        expect { cli.run(argv) }.to raise_error(FakeSystemExit), argv.inspect
      end
      expect(daemon_command.calls).to eq([])
    end

    it "rejects a non-numeric --lines, in text and as a usage JSON error" do
      expect { cli.run(["daemon", "log", "app", "--lines", "abc"]) }.to raise_error(FakeSystemExit)
      expect(error_output.string).to include("invalid argument: --lines abc")
      output.truncate(0)
      output.rewind
      expect { cli.run(["daemon", "log", "app", "--lines", "abc", "--json"]) }.to raise_error(FakeSystemExit) { |e| expect(e.status).to eq(1) }

      expect(JSON.parse(output.string)).to include("ok" => false, "code" => "usage")
      expect(daemon_command.calls).to eq([])
    end

    it "rejects --lines out of range in text and as a usage JSON error" do
      daemon_command.error = Workspace::UsageError.new("--lines must be a whole number from 1 to 10000")
      expect { cli.run(["daemon", "log", "app", "--lines", "0"]) }.to raise_error(FakeSystemExit)
      expect(error_output.string).to include("--lines must be a whole number from 1 to 10000")
      output.truncate(0)
      output.rewind
      expect { cli.run(["daemon", "log", "app", "--lines", "10001", "--json"]) }.to raise_error(FakeSystemExit) { |e| expect(e.status).to eq(1) }

      expect(JSON.parse(output.string)).to include("ok" => false, "code" => "usage")
    end

    it "prints the unknown_workspace envelope on stdout and exits 1 for status and log under --json" do
      daemon_command.error = Workspace::Error.new("Unknown workspace 'nope'", code: "unknown_workspace", details: {"name" => "nope"})

      %w[status log].each do |sub|
        output.truncate(0)
        output.rewind
        output.rewind
        expect { cli.run(["daemon", sub, "nope", "--json"]) }.to raise_error(FakeSystemExit) { |e| expect(e.status).to eq(1) }

        expect(JSON.parse(output.string)).to include("ok" => false, "code" => "unknown_workspace", "details" => {"name" => "nope"})
      end
    end

    it "says so when no daemon command was wired" do
      bare, _output, bare_errors = build_test_cli(project_detector: detector)

      expect { bare.run(["daemon", "status", "app"]) }.to raise_error(FakeSystemExit)
      expect(bare_errors.string).to include("no daemon command was wired")
    end

    it "lists daemon in the main help" do
      cli.run(["help"])

      expect(output.string).to match(/^\s+daemon\s+List, show, restart/)
    end
  end

  describe "#run with review" do
    let(:review_command) { CLITestHelpers::FakeReviewCommand.new }
    let(:detector) { instance_double(Workspace::ProjectDetector, detect: "detected-ws") }
    let(:built) { build_test_cli(review_command: review_command, project_detector: detector, working_dir: "/some/dir") }
    let(:cli) { built[0] }
    let(:output) { built[1] }
    let(:error_output) { built[2] }

    it "passes the patch cap to show, defaulting it, and refuses misuse as usage errors" do
      cli.run(["review", "app", "--patch"])
      cli.run(["review", "app", "--patch", "--max-bytes", "500", "--json"])

      expect(review_command.calls).to eq([{show: "app", json: false, patch: 200_000}, {show: "app", json: true, patch: 500}])
      [%w[app --max-bytes 5], %w[app --patch --max-bytes x], %w[list --patch]].each do |extra|
        expect { cli.run(["review", *extra]) }.to raise_error(FakeSystemExit)
      end
      expect(review_command.calls.size).to eq(2)
      expect(error_output.string).to include("--max-bytes needs --patch", "--patch and --max-bytes are for 'review show'")
    end

    it "rejects extra arguments, as a usage JSON error under --json" do
      expect { cli.run(["review", "a", "b"]) }.to raise_error(FakeSystemExit)
      expect(error_output.string).to include("Unexpected argument: b")
      output.truncate(0)
      output.rewind
      expect { cli.run(["review", "a", "b", "--json"]) }.to raise_error(FakeSystemExit) { |e| expect(e.status).to eq(1) }

      expect(JSON.parse(output.string)).to include("ok" => false, "code" => "usage")
      expect(review_command.calls).to eq([])
    end

    it "reports a missing workspace when none can be detected" do
      allow(detector).to receive(:detect).and_return(nil)

      expect { cli.run(["review"]) }.to raise_error(FakeSystemExit)
      expect(error_output.string).to include("Missing workspace name")
    end

    it "names review in the main help" do
      cli.run(["help"])

      expect(output.string).to include("review          Show a workspace's finished work for review")
    end
  end

  describe "sessions" do
    it "explains the LOCK column legend in its help" do
      cli, _, error_output = build_test_cli

      expect { cli.run(["sessions"]) }.to raise_error(FakeSystemExit) { |e| expect(e.status).to eq(1) }

      expect(error_output.string).to include("every lock", "locks array")
    end

    it "exits 1 without raising when --json and no agent daemon is listening" do
      config = instance_double(Workspace::Config, agent_socket_path: "/nonexistent/socket")
      cli, output, = build_test_cli(config: config, project_detector: instance_double(Workspace::ProjectDetector, detect: "proj"))

      expect { cli.run(["sessions", "--json"]) }.to raise_error(FakeSystemExit) { |e| expect(e.status).to eq(1) }

      expect(JSON.parse(output.string)).to eq("schema_version" => 1, "ok" => false, "code" => "no_daemon", "error" => "No agent daemon for 'proj'.\nStart one with:  workspace agentd proj")
    end
  end
end
