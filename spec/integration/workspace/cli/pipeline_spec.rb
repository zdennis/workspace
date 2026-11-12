require "spec_helper"
require "stringio"
require "tmpdir"
require "json"
require "socket"
require "shellwords"

# The pipeline family through CLI#run: its rescue funnel, its help, a real PipelineState file
# under a temporary directory and a real AgentMessageClient over a Unix socket the example
# answers itself.
RSpec.describe Workspace::CLI do
  include CLITestHelpers::AgentFamilyCli

  describe "pipeline" do
    # Routes the pipeline paths into a tmpdir so specs never touch the real ones.
    let(:tmpdir) { Dir.mktmpdir("ws-pipeline", "/tmp") }
    let(:config) do
      dir = tmpdir
      Class.new(Workspace::Config) do
        define_method(:pipeline_state_path) { |name| File.join(dir, "#{name}-pipeline.json") }
        define_method(:agent_socket_path) { |name| File.join(dir, "#{name}.sock") }
      end.new
    end

    after { FileUtils.remove_entry(tmpdir) if File.directory?(tmpdir) }

    def write_state(project, entries)
      File.write(config.pipeline_state_path(project), JSON.generate(entries))
    end

    # Answers one connection the way a live agent would, and records what it got.
    def with_fake_agent(project, reply)
      server = UNIXServer.new(config.agent_socket_path(project))
      received = []
      accepter = Thread.new do
        client = server.accept
        received << JSON.parse(client.gets)
        client.puts(reply.to_json)
        client.close
      rescue IOError, Errno::EBADF
        nil
      end
      yield received
      accepter.join(2)
      received
    ensure
      server.close
      accepter&.kill
    end

    describe "status" do
      it "says so when the project has no state file at all" do
        cli, output, = build_test_cli(config: config)
        cli.run(["pipeline", "status", "myapp"])
        expect(output.string).to include("No pipeline work in flight for myapp")
      end

      it "says so when the project has a state file with nothing in it" do
        cli, output, = build_test_cli(config: config)
        write_state("myapp", {})
        cli.run(["pipeline", "status", "myapp"])
        expect(output.string).to include("No pipeline work in flight for myapp")
      end

      it "lists each in-flight work item with its pane and phase" do
        cli, output, = build_test_cli(config: config)
        write_state("myapp",
          "WC-42" => {"work_item_ref" => "WC-42", "pane_index" => 1, "phase" => "implementer"},
          "WC-43" => {"work_item_ref" => "WC-43", "pane_index" => 0, "phase" => "researcher"})

        cli.run(["pipeline", "status", "myapp"])

        expect(output.string).to include("WORK ITEM  PANE  STAGE")
        expect(output.string).to include("WC-42  pane 1  implementer")
        expect(output.string).to include("WC-43  pane 0  researcher")
      end

      it "exits 1 without a project" do
        cli, _, error_output = build_test_cli(config: config)
        expect { cli.run(["pipeline", "status"]) }.to raise_error(FakeSystemExit)
        expect(error_output.string).to include("Usage: workspace pipeline status")
      end

      it "prints the reset page when reset has no project" do
        cli, _, error_output = build_test_cli(config: config)
        expect { cli.run(["pipeline", "reset"]) }.to raise_error(FakeSystemExit)
        expect(error_output.string).to include("Usage: workspace pipeline reset PROJECT")
        expect(error_output.string).to include("Examples:")
      end

      it "prints the reset page when reset has extra arguments" do
        cli, _, error_output = build_test_cli(config: config)
        expect { cli.run(["pipeline", "reset", "myapp", "extra"]) }.to raise_error(FakeSystemExit)
        expect(error_output.string).to include("Usage: workspace pipeline reset PROJECT")
        expect(error_output.string).to include("Examples:")
      end

      it "prints the advance page when advance has no --work-item" do
        cli, _, error_output = build_test_cli(config: config)
        expect { cli.run(["pipeline", "advance", "myapp"]) }.to raise_error(FakeSystemExit)
        expect(error_output.string).to include("Usage: workspace pipeline advance PROJECT")
        expect(error_output.string).to include("Examples:")
      end

      it "shows a stage's deadline in local time plus how long remains" do
        now = Time.utc(2026, 9, 27, 12, 0, 0)
        deadline = Time.utc(2026, 9, 27, 12, 12, 0)
        cli, output, = build_test_cli(config: config, clock: -> { now })
        write_state("myapp",
          "WC-42" => {"work_item_ref" => "WC-42", "pane_index" => 1, "phase" => "implementer",
                      "deadline_at" => deadline.iso8601(3)})

        cli.run(["pipeline", "status", "myapp"])

        expect(output.string).to include("(in 12m)")
        expect(output.string).to include(deadline.localtime.strftime("%H:%M"))
      end

      it "shows an overdue stage's deadline as overdue" do
        now = Time.utc(2026, 9, 27, 12, 15, 0)
        deadline = Time.utc(2026, 9, 27, 12, 12, 0)
        cli, output, = build_test_cli(config: config, clock: -> { now })
        write_state("myapp",
          "WC-42" => {"work_item_ref" => "WC-42", "pane_index" => 1, "phase" => "implementer",
                      "deadline_at" => deadline.iso8601(3)})

        cli.run(["pipeline", "status", "myapp"])

        expect(output.string).to include("(overdue 3m)")
      end

      it "shows '-' when the stage has no deadline" do
        cli, output, = build_test_cli(config: config)
        write_state("myapp",
          "WC-42" => {"work_item_ref" => "WC-42", "pane_index" => 1, "phase" => "implementer"})

        cli.run(["pipeline", "status", "myapp"])

        expect(output.string).to include("WC-42  pane 1  implementer  -")
      end

      it "leaves --json's deadline_at as raw ISO 8601 UTC" do
        deadline = Time.utc(2026, 9, 27, 12, 12, 0)
        cli, output, = build_test_cli(config: config)
        write_state("myapp",
          "WC-42" => {"work_item_ref" => "WC-42", "pane_index" => 1, "phase" => "implementer",
                      "deadline_at" => deadline.iso8601(3)})

        cli.run(["pipeline", "status", "myapp", "--json"])

        expect(JSON.parse(output.string)["entries"].first["deadline_at"]).to eq(deadline.iso8601(3))
      end

      it "treats an unreadable state file as empty rather than dying on it" do
        cli, output, error_output = build_test_cli(config: config)
        File.write(config.pipeline_state_path("myapp"), "{ truncated")

        cli.run(["pipeline", "status", "myapp"])

        expect(error_output.string).to include("Could not read myapp's pipeline state")
        expect(output.string).to include("No pipeline work in flight for myapp")
      end

      it "prints the entries as a JSON envelope for scripts" do
        cli, output, = build_test_cli(config: config)
        write_state("myapp",
          "WC-42" => {"work_item_ref" => "WC-42", "dispatch_id" => "d-7a1",
                      "pane_index" => 1, "phase" => "implementer"})

        cli.run(["pipeline", "status", "myapp", "--json"])

        expect(JSON.parse(output.string)).to eq({
          "schema_version" => 1, "ok" => true,
          "entries" => [
            {"work_item_ref" => "WC-42", "dispatch_id" => "d-7a1",
             "pane_index" => 1, "phase" => "implementer"}
          ]
        })
      end

      it "prints an empty entries array when nothing is in flight" do
        cli, output, = build_test_cli(config: config)
        cli.run(["pipeline", "status", "myapp", "--json"])
        expect(JSON.parse(output.string)).to eq({"schema_version" => 1, "ok" => true, "entries" => []})
      end

      it "emits a JSON usage error when --json is passed without a project" do
        cli, output, = build_test_cli(config: config)
        expect { cli.run(["pipeline", "status", "--json"]) }.to raise_error(FakeSystemExit) { |e|
          expect(e.status).to eq(1)
        }
        parsed = JSON.parse(output.string)
        expect(parsed["schema_version"]).to eq(1)
        expect(parsed["error"]).to be_a(String)
      end
    end

    describe "start" do
      it "hands the work item to the running agent" do
        cli, output, = build_test_cli(config: config)

        received = with_fake_agent("myapp", {"ok" => true}) do
          cli.run(["pipeline", "start", "myapp", "--work-item", "WC-42"])
        end

        expect(received.first).to include(
          "type" => "command", "workspace" => "myapp", "work_item_ref" => "WC-42"
        )
        expect(received.first["dispatch_id"]).to start_with("manual-")
        expect(output.string).to include("Sent WC-42 into myapp's pipeline")
      end

      it "exits 1 when no agent is listening" do
        cli, _, error_output = build_test_cli(config: config)
        expect { cli.run(["pipeline", "start", "myapp", "--work-item", "WC-42"]) }
          .to raise_error(FakeSystemExit)
        expect(error_output.string).to include("No agent is running for myapp")
        expect(error_output.string).to include("workspace agentd --name myapp")
      end

      it "exits 1 when the work item is missing" do
        cli, _, error_output = build_test_cli(config: config)
        expect { cli.run(["pipeline", "start", "myapp"]) }.to raise_error(FakeSystemExit)
        expect(error_output.string).to include("Missing project or --work-item")
      end

      it "exits 1 when the agent refuses the work item" do
        cli, _, error_output = build_test_cli(config: config)

        with_fake_agent("myapp", {"ok" => false, "error" => "wrong_workspace"}) do
          expect { cli.run(["pipeline", "start", "myapp", "--work-item", "WC-42"]) }
            .to raise_error(FakeSystemExit)
        end

        expect(error_output.string).to include("refused the work item: wrong_workspace")
      end

      it "exits 1 on a stray extra argument rather than silently ignoring it" do
        cli, _, error_output = build_test_cli(config: config)
        expect { cli.run(["pipeline", "start", "myapp", "extra", "--work-item", "WC-42"]) }
          .to raise_error(FakeSystemExit)
        expect(error_output.string).to include("Unexpected arguments: extra")
      end

      it "exits 1 when the agent hangs up without replying" do
        cli, _, error_output = build_test_cli(config: config)
        server = UNIXServer.new(config.agent_socket_path("myapp"))
        accepter = Thread.new { server.accept.close }

        expect { cli.run(["pipeline", "start", "myapp", "--work-item", "WC-42"]) }
          .to raise_error(FakeSystemExit)
        accepter.join(2)

        expect(error_output.string).to include("closed the connection without replying")
        server.close
      end

      it "exits 1 with the same message when the write races the daemon's close (EPIPE after connect)" do
        cli, _, error_output = build_test_cli(config: config)
        socket = instance_double(UNIXSocket, close: nil)
        allow(socket).to receive(:puts).and_raise(Errno::EPIPE)
        allow(UNIXSocket).to receive(:open).and_return(socket)

        expect { cli.run(["pipeline", "start", "myapp", "--work-item", "WC-42"]) }
          .to raise_error(FakeSystemExit)

        expect(error_output.string).to include("closed the connection without replying")
        expect(error_output.string).not_to include("No agent is running")
      end

      it "exits 1 when the agent's reply is not readable" do
        cli, _, error_output = build_test_cli(config: config)
        server = UNIXServer.new(config.agent_socket_path("myapp"))
        accepter = Thread.new do
          client = server.accept
          client.gets
          client.puts("garbage")
          client.close
        end

        expect { cli.run(["pipeline", "start", "myapp", "--work-item", "WC-42"]) }
          .to raise_error(FakeSystemExit)
        accepter.join(2)

        expect(error_output.string).to include("Unreadable reply from the agent for myapp")
        server.close
      end
    end

    describe "advance" do
      it "asks the agent to interrupt the stage with the completion sentinel" do
        cli, output, = build_test_cli(config: config)

        received = with_fake_agent("myapp", {"ok" => true, "queued_for_pane" => 1}) do
          cli.run(["pipeline", "advance", "myapp", "--work-item", "WC-42"])
        end

        expect(received.first).to include(
          "type" => "inject", "work_item_ref" => "WC-42", "interrupt" => true
        )
        expect(received.first["body"]).to include(Workspace::SentinelPoller::SENTINEL)
        expect(output.string).to include("Nudged myapp/WC-42 to advance")
      end

      it "carries the running stage's token so the agent's watch accepts it" do
        cli, = build_test_cli(config: config)
        write_state("myapp", "WC-42" => {"work_item_ref" => "WC-42", "sentinel_token" => "a1b2c3d4"})

        received = with_fake_agent("myapp", {"ok" => true, "queued_for_pane" => 1}) do
          cli.run(["pipeline", "advance", "myapp", "--work-item", "WC-42"])
        end

        expect(Shellwords.split(received.first["body"])).to eq(["echo", "WORKSPACE_DONE:a1b2c3d4 manual advance"])
      end

      it "sends a tokenless sentinel for a stage recorded before stages had tokens" do
        cli, = build_test_cli(config: config)
        write_state("myapp", "WC-42" => {"work_item_ref" => "WC-42", "pane_index" => 1})

        received = with_fake_agent("myapp", {"ok" => true, "queued_for_pane" => 1}) do
          cli.run(["pipeline", "advance", "myapp", "--work-item", "WC-42"])
        end

        expect(Shellwords.split(received.first["body"])).to eq(["echo", "WORKSPACE_DONE: manual advance"])
      end

      it "escapes the body so it cannot break out of the echo it is typed into" do
        cli, _, = build_test_cli(config: config)

        received = with_fake_agent("myapp", {"ok" => true, "queued_for_pane" => 1}) do
          cli.run(["pipeline", "advance", "myapp", "--work-item", "WC-42",
            "--body", "it's done'; rm -rf /tmp/nope; echo '"])
        end

        # One shell word: the quotes and semicolons reach the pane as text.
        expect(Shellwords.split(received.first["body"])).to eq([
          "echo", "#{Workspace::SentinelPoller::SENTINEL} it's done'; rm -rf /tmp/nope; echo '"
        ])
      end

      it "exits 1 when the agent refuses" do
        cli, _, error_output = build_test_cli(config: config)

        with_fake_agent("myapp", {"ok" => false, "error" => "no_active_pipeline"}) do
          expect { cli.run(["pipeline", "advance", "myapp", "--work-item", "WC-42"]) }
            .to raise_error(FakeSystemExit)
        end

        expect(error_output.string).to include("no_active_pipeline")
      end

      it "sends the running stage's token as expected_token" do
        cli, = build_test_cli(config: config)
        write_state("myapp", "WC-42" => {"work_item_ref" => "WC-42", "sentinel_token" => "a1b2c3d4"})

        received = with_fake_agent("myapp", {"ok" => true, "queued_for_pane" => 1}) do
          cli.run(["pipeline", "advance", "myapp", "--work-item", "WC-42"])
        end

        expect(received.first["expected_token"]).to eq("a1b2c3d4")
      end

      it "exits 1 with a clear message when the stage moved on before the advance landed" do
        cli, _, error_output = build_test_cli(config: config)

        with_fake_agent("myapp", {"ok" => false, "error" => "stale_token"}) do
          expect { cli.run(["pipeline", "advance", "myapp", "--work-item", "WC-42"]) }
            .to raise_error(FakeSystemExit)
        end

        expect(error_output.string).to include("The stage moved on before the advance landed; run 'workspace pipeline advance' again")
      end
    end

    describe "reset" do
      it "clears the state file when no agent is running" do
        cli, output, = build_test_cli(config: config)
        write_state("myapp", "WC-42" => {"work_item_ref" => "WC-42"})

        cli.run(["pipeline", "reset", "myapp"])

        expect(File.exist?(config.pipeline_state_path("myapp"))).to be false
        expect(output.string).to include("Cleared pipeline state for myapp")
      end

      it "refuses while the agent is still running so the two cannot disagree" do
        cli, _, error_output = build_test_cli(config: config)
        write_state("myapp", "WC-42" => {"work_item_ref" => "WC-42"})
        server = UNIXServer.new(config.agent_socket_path("myapp"))
        accepter = Thread.new do
          loop { server.accept.close }
        rescue IOError, Errno::EBADF
          nil
        end

        expect { cli.run(["pipeline", "reset", "myapp"]) }.to raise_error(FakeSystemExit)

        expect(error_output.string).to include("before resetting its pipeline state")
        expect(File.exist?(config.pipeline_state_path("myapp"))).to be true
        server.close
        accepter.kill
      end
    end

    it "warns on stderr that pipeline is deprecated, for every subcommand that acts, and says so in its help" do
      cli, output, error_output = build_test_cli(config: config)
      write_state("myapp", {})

      cli.run(["pipeline", "status", "myapp"])
      expect(error_output.string).to eq("Warning: `workspace pipeline` is deprecated and will be removed in a later release. " \
        "Use `workspace workflow` (see `workspace workflow --help`).\n")

      cli.run(["pipeline", "help"])
      expect(output.string).to include("Deprecated: use `workspace workflow`")
      expect(error_output.string.scan("deprecated").size).to eq(1)
    end

    it "keeps stderr and the status document free of the notice under --json" do
      cli, output, error_output = build_test_cli(config: config)
      write_state("myapp", {})

      cli.run(["pipeline", "status", "myapp", "--json"])

      expect(error_output.string).to eq("")
      expect(JSON.parse(output.string)).to include("ok" => true, "entries" => [])
    end

    describe "--json" do
      def json_cli
        raw = StringIO.new
        err = StringIO.new
        cli, = build_test_cli(config: config, output: Workspace::OutputGate.new(raw), error_output: err)
        [cli, raw, err]
      end

      it "start prints one action document" do
        cli, raw, err = json_cli

        received = with_fake_agent("myapp", {"ok" => true}) do
          cli.run(["pipeline", "start", "myapp", "--work-item", "WC-42", "--json"])
        end

        expect(received.first).to include("type" => "command", "work_item_ref" => "WC-42")
        expect(JSON.parse(raw.string)).to include("action" => "pipeline start", "status" => "ok")
        expect(JSON.parse(raw.string)["results"].first).to include("workspace" => "myapp", "outcome" => "started", "work_item_ref" => "WC-42")
        expect(err.string).to include("Sent WC-42 into myapp's pipeline")
      end

      it "says pipeline is deprecated in the document's warnings, not on stderr" do
        cli, raw, err = json_cli

        with_fake_agent("myapp", {"ok" => true}) do
          cli.run(["pipeline", "start", "myapp", "--work-item", "WC-42", "--json"])
        end

        expect(JSON.parse(raw.string)["warnings"]).to eq(["`workspace pipeline` is deprecated and will be removed in a later release. " \
          "Use `workspace workflow` (see `workspace workflow --help`)."])
        expect(err.string).not_to include("deprecated")
      end

      it "advance prints one action document" do
        cli, raw, = json_cli

        with_fake_agent("myapp", {"ok" => true}) do
          cli.run(["pipeline", "advance", "myapp", "--work-item", "WC-42", "--json"])
        end

        expect(JSON.parse(raw.string)["results"].first).to include("outcome" => "advanced", "work_item_ref" => "WC-42")
      end

      it "advance answers a stale token with the stale_token code" do
        cli, raw, err = json_cli

        with_fake_agent("myapp", {"ok" => false, "error" => "stale_token"}) do
          expect { cli.run(["pipeline", "advance", "myapp", "--work-item", "WC-42", "--json"]) }.to raise_error(FakeSystemExit)
        end

        expect(JSON.parse(raw.string)).to include("ok" => false, "code" => "stale_token")
        expect(err.string).to eq("")
      end

      it "start answers an agent that hangs up with the connection_failed code" do
        cli, raw, = json_cli
        server = UNIXServer.new(config.agent_socket_path("myapp"))
        accepter = Thread.new { server.accept.close }

        expect { cli.run(["pipeline", "start", "myapp", "--work-item", "WC-42", "--json"]) }.to raise_error(FakeSystemExit)
        accepter.join(2)

        expect(JSON.parse(raw.string)).to include("ok" => false, "code" => "connection_failed")
        server.close
      end

      it "reset prints one action document" do
        cli, raw, = json_cli
        write_state("myapp", "WC-42" => {"work_item_ref" => "WC-42"})

        cli.run(["pipeline", "reset", "myapp", "--json"])

        expect(File.exist?(config.pipeline_state_path("myapp"))).to be false
        expect(JSON.parse(raw.string)["results"]).to eq([{"workspace" => "myapp", "outcome" => "reset", "reason" => nil, "message" => nil}])
      end
    end

    it "prints help for an unknown subcommand" do
      cli, _, error_output = build_test_cli(config: config)
      expect { cli.run(["pipeline", "nonsense"]) }.to raise_error(FakeSystemExit)
      expect(error_output.string).to include("Usage: workspace pipeline start PROJECT")
    end

    it "prints help with no subcommand" do
      cli, output, = build_test_cli(config: config)
      cli.run(["pipeline"])
      expect(output.string).to include("Usage: workspace pipeline start PROJECT")
    end
  end
end
