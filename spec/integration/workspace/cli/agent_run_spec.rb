require "spec_helper"
require "stringio"
require "tmpdir"
require "json"

# The agent-run and handoff family through CLI#run: its rescue funnel, the main help, and a real
# Commands::Send over a real PaneLocator.
RSpec.describe Workspace::CLI do
  include CLITestHelpers::AgentFamilyCli

  describe "#run agent-run inject" do
    it "still requires --work-item" do
      cli, _, error_output = build_test_cli

      expect { cli.run(["agent-run", "inject", "--name", "myapp", "--body", "Use Postgres"]) }
        .to raise_error(FakeSystemExit)
      expect(error_output.string).to include("Missing --work-item")
    end
  end

  describe "#run agent-run restart" do
    let(:restart_command) { double("restart", call: {exit_code: 0}) }

    [
      [["--name", "myapp", "--prompt", "go"], "Missing --pane."],
      [["--name", "myapp", "--pane", "0.1"], "Missing --prompt."],
      [["--name", "myapp", "--pane", "0.1", "--prompt", "go", "--timeout", "11m"], "--timeout: at most 600s"],
      [["--name", "myapp", "--pane", "0.1", "--prompt", "go", "extra"], "Unexpected argument: extra"]
    ].each do |args, message|
      it "rejects #{args.last(2).join(" ")} with a usage error" do
        cli, _, error_output = build_test_cli(restart_agent_command: restart_command)

        expect { cli.run(["agent-run", "restart", *args]) }.to raise_error(FakeSystemExit)
        expect(error_output.string).to include(message)
        expect(restart_command).not_to have_received(:call)
      end

      it "reports #{args.last(2).join(" ")} as a JSON error with --json" do
        cli, output = build_test_cli(restart_agent_command: restart_command)

        expect { cli.run(["agent-run", "restart", "--json", *args]) }.to raise_error(FakeSystemExit) { |e|
          expect(e.status).to eq(1)
        }
        expect(JSON.parse(output.string)).to eq("schema_version" => 1, "ok" => false, "code" => "usage", "error" => message)
      end
    end

    it "lists restart in the agent-run help" do
      cli, _, error_output = build_test_cli

      expect { cli.run(["agent-run"]) }.to raise_error(FakeSystemExit)
      expect(error_output.string).to include("restart   Clear the coding agent in one pane")
    end
  end

  describe "#run agent-run queue" do
    let(:queue_command) { double("prompt queue", list: [], cancel: {}) }

    [
      [%w[cancel], "Missing --id."],
      [["list", "--name", "api", "--pane", ""], "--pane can't be empty"],
      [%w[cancel --id x extra], "Unexpected argument: extra"],
      [%w[nope], "Unknown queue verb: nope."],
      [[], "Missing queue verb"]
    ].each do |args, message|
      it "refuses #{args.inspect} as a usage error" do
        cli, _, error_output = build_test_cli(prompt_queue_command: queue_command)

        expect { cli.run(["agent-run", "queue", *args]) }.to raise_error(FakeSystemExit) { |e| expect(e.status).to eq(1) }
        expect(error_output.string).to include(message)
        expect(queue_command).not_to have_received(:cancel)
      end
    end
  end

  describe "#run agent-run send" do
    let(:tmux) do
      CLITestHelpers::FakeTmuxServer.new("api" => [{id: "%3", window: 0, index: 0}, {id: "%19", window: 1, index: 2}], "web" => [{id: "%7", window: 0, index: 0}])
    end

    def send_cli(**overrides)
      out = StringIO.new
      send_command = Workspace::Commands::Send.new(locator: Workspace::PaneLocator.new(tmux: tmux), tmux: tmux, output: out)
      build_test_cli(output: out, send_command: send_command, **overrides)
    end

    def status_of
      yield
      0
    rescue FakeSystemExit => e
      e.status
    end

    it "pastes --body and Enter into the named pane" do
      cli, output = send_cli

      cli.run(["agent-run", "send", "--name", "api", "--pane", "%19", "--body", "yes"])

      expect(tmux.deliveries).to eq([{session: "api", pane: "%19", text: "yes", enter: true}])
      expect(output.string).to eq("Sent text to pane %19 and pressed Enter.\n")
    end

    it "keeps text that starts with a dash intact" do
      cli, = send_cli

      cli.run(["agent-run", "send", "--name", "api", "--pane", "%3", "--body", "--force"])

      expect(tmux.deliveries.first).to include(text: "--force")
    end

    it "sends --no-enter text without Enter" do
      cli, = send_cli

      cli.run(["agent-run", "send", "--name", "api", "--pane", "%3", "--body", "draft", "--no-enter", "--json"])

      expect(tmux.deliveries.first).to include(enter: false)
    end

    it "sends --keys as key names and prints the contract's JSON" do
      cli, output = send_cli

      cli.run(["agent-run", "send", "--name", "api", "--pane", "%19", "--keys", "Escape", "--json"])

      expect(tmux.keys_sent.map { |k| k[:key] }).to eq(["Escape"])
      expect(JSON.parse(output.string)).to eq("schema_version" => 1, "ok" => true, "workspace" => "api",
        "pane" => "%19", "mode" => "keys", "submitted" => true, "keys" => ["Escape"])
    end

    it "detects the workspace from the working directory" do
      detector = double("detector", detect: "api")
      cli, = send_cli(project_detector: detector)

      cli.run(["agent-run", "send", "--pane", "%3", "--keys", "y Enter"])

      expect(tmux.keys_sent.map { |k| k[:key] }).to eq(%w[y Enter])
    end

    it "answers a pane of another workspace with wrong_session and types nothing, exit 1" do
      cli, output = send_cli

      expect(status_of { cli.run(["agent-run", "send", "--name", "api", "--pane", "%7", "--body", "x", "--json"]) }).to eq(1)

      expect(JSON.parse(output.string)).to include("ok" => false, "code" => "wrong_session")
      expect(tmux.deliveries).to be_empty
    end

    it "answers a bad key with bad_keys before sending any key" do
      cli, output = send_cli

      expect(status_of { cli.run(["agent-run", "send", "--name", "api", "--pane", "%3", "--keys", "Escape hello", "--json"]) }).to eq(1)

      expect(JSON.parse(output.string)).to include("code" => "bad_keys")
      expect(tmux.keys_sent).to be_empty
    end

    it "exits 2 with not_submitted when the text landed but wasn't confirmed" do
      tmux.delivery_status = :unsubmitted
      cli, output = send_cli

      expect(status_of { cli.run(["agent-run", "send", "--name", "api", "--pane", "%3", "--body", "x", "--json"]) }).to eq(2)

      expect(JSON.parse(output.string)).to include("ok" => false, "code" => "not_submitted")
    end

    it "prints the error on stderr without --json" do
      cli, output, error_output = send_cli

      expect(status_of { cli.run(["agent-run", "send", "--name", "api", "--pane", "%99", "--body", "x"]) }).to eq(1)

      expect(output.string).to eq("")
      expect(error_output.string).to include("No pane %99 in tmux session 'api'")
    end

    [
      [["--name", "api", "--body", "x"], "Missing --pane."],
      [["--name", "api", "--pane", "%3"], "Missing --body or --keys."],
      [["--name", "api", "--pane", "%3", "--body", "x", "--keys", "y"], "Pass --body or --keys, not both."],
      [["--name", "api", "--pane", "%3", "--body", ""], "--body can't be empty."],
      [["--name", "api", "--pane", "%3", "--keys", "y", "--no-enter"], "--no-enter applies to --body; --keys never presses Enter on its own."],
      [["--name", "api", "--pane", "%3", "--body", "x", "extra"], "Unexpected argument: extra"],
      [["--name", "api", "--pane", "%3", "--keys", "y", "--when-idle"], "--when-idle takes --body, not --keys."],
      [["--name", "api", "--pane", "%3", "--body", "x", "--when-idle", "--no-enter"], "--when-idle always presses Enter; drop --no-enter."]
    ].each do |args, message|
      it "rejects #{args.join(" ").inspect} as a usage error naming #{message.inspect}" do
        cli, output = send_cli

        expect(status_of { cli.run(["agent-run", "send", "--json", *args]) }).to eq(1)

        expect(JSON.parse(output.string)).to include("ok" => false, "code" => "usage", "error" => message)
        expect(tmux.deliveries + tmux.keys_sent).to be_empty
      end
    end

    describe "--when-idle" do
      let(:replies) { [] }
      let(:client) do
        double("client").tap do |c|
          allow(c).to receive(:exchange_message) do |name, message, timeout:|
            replies.shift || {"ok" => true, "queued" => true, "id" => "q1", "position" => 2, "pane" => "1.2", "pane_id" => message["pane_id"]}
          end
        end
      end

      def idle_cli(**overrides)
        out = StringIO.new
        send_command = Workspace::Commands::Send.new(locator: Workspace::PaneLocator.new(tmux: tmux), tmux: tmux, client: client, output: out)
        build_test_cli(output: out, send_command: send_command, **overrides)
      end

      it "asks the daemon to queue the text for the pane id and prints its answer, typing nothing itself" do
        cli, output = idle_cli

        cli.run(["agent-run", "send", "--name", "api", "--pane", "1.2", "--body", "--next step", "--when-idle", "--json"])

        expect(client).to have_received(:exchange_message)
          .with("api", {"type" => "prompt_send", "pane_id" => "%19", "text" => "--next step"}, timeout: Workspace::Commands::Send::WHEN_IDLE_TIMEOUT)
        expect(JSON.parse(output.string)).to eq("schema_version" => 1, "ok" => true, "workspace" => "api",
          "queued" => true, "id" => "q1", "position" => 2, "pane" => "%19", "pane_id" => "%19")
        expect(tmux.deliveries).to be_empty
      end

      it "says so when the pane was idle and the text was typed" do
        replies << {"ok" => true, "delivered" => true, "submitted" => true, "id" => "q1", "pane_id" => "%19"}
        cli, output = idle_cli

        cli.run(["agent-run", "send", "--name", "api", "--pane", "%19", "--body", "go", "--when-idle"])

        expect(output.string).to eq("Pane %19 was idle; typed the text and pressed Enter.\n")
      end

      it "prints a refusal as the error envelope, exit 1, with the daemon's details" do
        replies << {"ok" => false, "error" => "queue_full", "message" => "pane 1.2 already has 8 prompts queued", "limit" => 8, "pane_id" => "%19"}
        cli, output = idle_cli

        expect(status_of { cli.run(["agent-run", "send", "--name", "api", "--pane", "%19", "--body", "go", "--when-idle", "--json"]) }).to eq(1)

        expect(JSON.parse(output.string)).to include("ok" => false, "code" => "queue_full", "details" => {"limit" => 8, "pane_id" => "%19"})
      end

      it "exits 2 when the daemon typed the text but couldn't confirm it submitted" do
        replies << {"ok" => false, "error" => "not_submitted", "message" => "pasted but not confirmed", "delivered" => true, "submitted" => false}
        cli, output = idle_cli

        expect(status_of { cli.run(["agent-run", "send", "--name", "api", "--pane", "%19", "--body", "go", "--when-idle", "--json"]) }).to eq(2)

        expect(JSON.parse(output.string)).to include("code" => "not_submitted")
      end

      it "refuses no_daemon when no agent daemon answers, queueing nothing" do
        allow(client).to receive(:exchange_message).and_raise(Workspace::AgentSnapshotClient::Unavailable.new("no agent daemon", reason: :no_daemon))
        cli, output = idle_cli

        expect(status_of { cli.run(["agent-run", "send", "--name", "api", "--pane", "%19", "--body", "go", "--when-idle", "--json"]) }).to eq(1)

        expect(JSON.parse(output.string)).to include("code" => "no_daemon")
      end

      it "checks the pane before asking the daemon" do
        cli, output = idle_cli

        expect(status_of { cli.run(["agent-run", "send", "--name", "api", "--pane", "%7", "--body", "go", "--when-idle", "--json"]) }).to eq(1)

        expect(JSON.parse(output.string)).to include("code" => "wrong_session")
        expect(client).not_to have_received(:exchange_message)
      end

      describe "with --clear-first" do
        it "asks the daemon to clear first and queue when the turn hasn't ended" do
          cli, = idle_cli

          cli.run(["agent-run", "send", "--name", "api", "--pane", "%19", "--body", "go", "--when-idle", "--clear-first", "--json"])

          expect(client).to have_received(:exchange_message).with("api",
            {"type" => "prompt_send", "pane_id" => "%19", "text" => "go", "clear_first" => true, "when_idle" => true},
            timeout: Workspace::Commands::Send::WHEN_IDLE_TIMEOUT)
        end

        it "goes through the daemon without --when-idle too, asking it not to queue" do
          replies << {"ok" => true, "delivered" => true, "submitted" => true, "cleared" => true, "id" => "q1", "pane_id" => "%19"}
          cli, output = idle_cli

          cli.run(["agent-run", "send", "--name", "api", "--pane", "%19", "--body", "go", "--clear-first"])

          expect(client).to have_received(:exchange_message).with("api",
            {"type" => "prompt_send", "pane_id" => "%19", "text" => "go", "clear_first" => true, "when_idle" => false},
            timeout: Workspace::Commands::Send::WHEN_IDLE_TIMEOUT)
          expect(output.string).to eq("Pane %19 was idle; cleared the conversation, typed the text and pressed Enter.\n")
          expect(tmux.deliveries).to be_empty
        end

        it "exits 75 with clear_typed when the clear wasn't confirmed" do
          replies << {"ok" => false, "error" => "clear_unconfirmed", "message" => "the clear was typed but no SessionStart came",
                      "id" => "q1", "clear_typed" => true, "pane" => "1.2", "pane_id" => "%19"}
          cli, output = idle_cli

          expect(status_of { cli.run(["agent-run", "send", "--name", "api", "--pane", "%19", "--body", "go", "--clear-first", "--json"]) }).to eq(75)

          expect(JSON.parse(output.string)).to include("ok" => false, "code" => "clear_unconfirmed",
            "details" => {"id" => "q1", "clear_typed" => true, "pane" => "%19", "pane_id" => "%19"})
        end

        it "exits 1 on clear_unsupported, before anything is typed" do
          replies << {"ok" => false, "error" => "clear_unsupported", "message" => "Codex's clear can't be confirmed", "kind" => "codex", "reason" => "agent"}
          cli, output = idle_cli

          expect(status_of { cli.run(["agent-run", "send", "--name", "api", "--pane", "%19", "--body", "go", "--clear-first", "--json"]) }).to eq(1)

          expect(JSON.parse(output.string)).to include("code" => "clear_unsupported", "details" => {"kind" => "codex", "reason" => "agent"})
        end

        [
          [["--keys", "y"], "--clear-first takes --body, not --keys."],
          [["--body", "x", "--no-enter"], "--clear-first always presses Enter; drop --no-enter."]
        ].each do |extra, message|
          it "refuses #{extra.join(" ")} as usage" do
            cli, output = idle_cli

            expect(status_of { cli.run(["agent-run", "send", "--name", "api", "--pane", "%19", "--clear-first", *extra, "--json"]) }).to eq(1)

            expect(JSON.parse(output.string)).to include("code" => "usage", "error" => message)
            expect(client).not_to have_received(:exchange_message)
          end
        end
      end
    end

    describe "--interrupt" do
      let(:client) do
        double("client").tap do |c|
          allow(c).to receive(:exchange_message) do |_name, message, timeout:|
            {"ok" => true, "interrupted" => true, "keys" => ["Escape"], "delivered" => true, "submitted" => true, "pane_id" => message["pane_id"]}
          end
        end
      end

      def interrupt_cli
        out = StringIO.new
        send_command = Workspace::Commands::Send.new(locator: Workspace::PaneLocator.new(tmux: tmux), tmux: tmux, client: client, output: out)
        build_test_cli(output: out, send_command: send_command)
      end

      it "asks the daemon for one interrupt-and-type and prints its single result" do
        cli, output = interrupt_cli

        cli.run(["agent-run", "send", "--name", "api", "--pane", "1.2", "--body", "new plan", "--interrupt", "--json"])

        expect(client).to have_received(:exchange_message)
          .with("api", {"type" => "prompt_interrupt_send", "pane_id" => "%19", "text" => "new plan"}, timeout: Workspace::Commands::Send::WHEN_IDLE_TIMEOUT)
        expect(JSON.parse(output.string)).to eq("schema_version" => 1, "ok" => true, "workspace" => "api", "interrupted" => true,
          "keys" => ["Escape"], "delivered" => true, "submitted" => true, "pane" => "%19", "pane_id" => "%19")
        expect(tmux.deliveries + tmux.keys_sent).to be_empty
      end

      [
        [["--interrupt"], "Missing --body or --keys."],
        [["--keys", "y", "--interrupt"], "--interrupt takes --body, not --keys."],
        [["--body", "x", "--interrupt", "--no-enter"], "--interrupt always presses Enter; drop --no-enter."],
        [["--body", "x", "--interrupt", "--when-idle"], "--interrupt types now or not at all; it does not combine with --when-idle or --clear-first."],
        [["--body", "x", "--interrupt", "--clear-first"], "--interrupt types now or not at all; it does not combine with --when-idle or --clear-first."]
      ].each do |extra, message|
        it "refuses #{extra.join(" ")} as usage" do
          cli, output = interrupt_cli

          expect(status_of { cli.run(["agent-run", "send", "--name", "api", "--pane", "%19", *extra, "--json"]) }).to eq(1)

          expect(JSON.parse(output.string)).to include("code" => "usage", "error" => message)
          expect(client).not_to have_received(:exchange_message)
        end
      end
    end

    it "reports an unwired build plainly" do
      cli, _, error_output = build_test_cli

      expect(status_of { cli.run(["agent-run", "send", "--name", "api", "--pane", "%3", "--body", "x"]) }).to eq(1)
      expect(error_output.string).to include("not available in this build")
    end

    it "lists send in the agent-run help" do
      cli, _, error_output = build_test_cli

      expect { cli.run(["agent-run"]) }.to raise_error(FakeSystemExit)
      expect(error_output.string).to include("send      Type text or tmux keys into one pane")
    end
  end

  describe "#run handoff" do
    let(:handoff_command) { double("handoff", check: {exit_code: 0}, new: {exit_code: 0}) }

    it "rejects a non-numeric --threshold with the custom range message" do
      cli, _, error_output = build_test_cli(handoff_command: handoff_command)

      expect { cli.run(["handoff", "check", "myapp", "--threshold", "bogus"]) }.to raise_error(FakeSystemExit)
      expect(error_output.string).to include("--threshold must be an integer between 1 and 100")
      expect(handoff_command).not_to have_received(:check)
    end

    it "rejects an out-of-range --threshold with the custom range message" do
      cli, _, error_output = build_test_cli(handoff_command: handoff_command)

      expect { cli.run(["handoff", "check", "myapp", "--threshold", "150"]) }.to raise_error(FakeSystemExit)
      expect(error_output.string).to include("--threshold must be an integer between 1 and 100")
      expect(handoff_command).not_to have_received(:check)
    end

    it "rejects both --handoff-doc and --handoff-prompt together" do
      cli, _, error_output = build_test_cli(handoff_command: handoff_command)

      expect { cli.run(["handoff", "check", "myapp", "--handoff-doc", "a", "--handoff-prompt", "b"]) }
        .to raise_error(FakeSystemExit)
      expect(error_output.string).to include("mutually exclusive")
      expect(handoff_command).not_to have_received(:check)
    end

    it "requires a workspace name when none is given and cwd detection fails" do
      cli, _, error_output = build_test_cli(handoff_command: handoff_command)

      expect { cli.run(["handoff", "check"]) }.to raise_error(FakeSystemExit)
      expect(error_output.string).to include("Missing workspace name")
      expect(handoff_command).not_to have_received(:check)
    end

    it "raises a usage error for an unknown handoff subcommand" do
      cli, _, error_output = build_test_cli(handoff_command: handoff_command)

      expect { cli.run(["handoff", "bogus"]) }.to raise_error(FakeSystemExit)
      expect(error_output.string).to include("Usage: workspace handoff")
    end

    it "lists handoff in the main help" do
      cli, output = build_test_cli
      cli.run(["help"])
      expect(output.string).to include("handoff         Check context usage and hand off to a fresh conversation")
    end
  end
end
