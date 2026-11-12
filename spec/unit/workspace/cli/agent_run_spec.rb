require "spec_helper"
require "stringio"
require "json"

RSpec.describe Workspace::CLI::AgentRun do
  let(:out) { StringIO.new }
  let(:err) { StringIO.new }
  let(:restart_agent_command) { double("restart", call: {exit_code: 0}) }
  let(:handoff_command) { double("handoff", check: {exit_code: 0}, new: {exit_code: 0}) }
  let(:agent_client) { double("agent client", call: {"ok" => true}) }
  let(:project_detector) { RecordingProjectDetector.new("/src/app" => "app") }

  def family
    names = Workspace::CLI::Names.new(project_config: CLITestHelpers::FakeProjectConfig.new, project_detector: project_detector,
      lineage: CLITestHelpers::FakeLineage.new, working_dir: "/src/app")
    described_class.new(config: Workspace::Config.new, agent_client: agent_client, restart_agent_command: restart_agent_command,
      send_command: nil, prompt_queue_command: nil, handoff_command: handoff_command, project_detector: project_detector,
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
      run("agent-run", "restart", "--pane", "%3", "--prompt", "go")
      run("handoff", "check")

      expect(restart_agent_command).to have_received(:call).with(name: "app", pane: "%3", prompt: "go", force: false, wait: false,
        timeout: nil, json: false)
      expect(handoff_command).to have_received(:check).with(name: "app", pane: nil, threshold: nil, context_pct: nil,
        handoff_doc: nil, handoff_prompt: nil, json: false)
    end

    it "sends the command message it builds through the agent client and prints the reply" do
      run("agent-run", "command", "--work-item", "WC-1", "--body", "go")

      expect(agent_client).to have_received(:call).with("app", hash_including("type" => "command", "workspace" => "app",
        "work_item_ref" => "WC-1", "body" => "go"))
      expect(out.string).to include("Reply:\n  {\n    \"ok\": true\n  }\n")
    end

    it "writes and exits through the invocation it is given" do
      allow(handoff_command).to receive(:new).and_return({exit_code: 2})

      expect(run("handoff", "new", "app")).to eq(2)
      expect(run("agent-run", "help")).to be_nil
      expect(out.string).to start_with("Usage: workspace agent-run <subcommand> [options]")
    end

    it "raises a usage error for the CLI's rescue funnel to report" do
      expect { run("agent-run", "inject", "--body", "x") }.to raise_error(Workspace::UsageError, /Missing --work-item/)
      expect { run("handoff", "bogus") }.to raise_error(Workspace::UsageError, /Usage: workspace handoff/)
    end
  end

  describe "#prompt" do
    it "sends `agent run`'s words as one command message, through the invocation it is given" do
      family.prompt(["fix", "it"], invocation)

      expect(agent_client).to have_received(:call).with("app", hash_including("type" => "command", "body" => "fix it"))
      expect(out.string).to start_with("Sending JSONL to ")
    end
  end

  # The argv CLI#run hands this family, with the first word as the verb, over the same fake
  # commands as the CLI-level examples in spec/integration/workspace/cli/agent_run_spec.rb.
  describe "argv as CLI#run routes it" do
    def build_test_cli(output: StringIO.new, error_output: StringIO.new, **overrides)
      project_detector = overrides[:project_detector] || RecordingProjectDetector.new
      working_dir = overrides[:working_dir] || "/some/dir"
      names = Workspace::CLI::Names.new(project_config: CLITestHelpers::FakeProjectConfig.new, project_detector: project_detector,
        lineage: CLITestHelpers::FakeLineage.new, working_dir: working_dir)
      family = described_class.new(config: Workspace::Config.new, agent_client: double("agent client"),
        restart_agent_command: overrides[:restart_agent_command], send_command: overrides[:send_command],
        prompt_queue_command: overrides[:prompt_queue_command], handoff_command: overrides[:handoff_command],
        project_detector: project_detector, common: Workspace::CLI::Common.new, names: names, working_dir: working_dir)
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

    describe "#run agent-run command" do
      it "defaults --work-item to a random UUID, shown in the printed message" do
        cli, output = build_test_cli

        cli.run(["agent-run", "command", "--name", "myapp", "--body", "Add OAuth support", "--dry-run"])

        expect(output.string).to match(/"work_item_ref": "[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}"/)
      end

      it "uses an explicit --work-item instead of generating one" do
        cli, output = build_test_cli

        cli.run(["agent-run", "command", "--name", "myapp", "--work-item", "WC-42", "--body", "Add OAuth support", "--dry-run"])

        expect(output.string).to include('"work_item_ref": "WC-42"')
      end
    end

    describe "#run agent-run restart" do
      let(:restart_command) { double("restart", call: {exit_code: 0}) }

      it "passes the explicit pane, prompt and flags to the restart command" do
        cli, = build_test_cli(restart_agent_command: restart_command)

        cli.run(["agent-run", "restart", "--name", "myapp", "--pane", "%18", "--prompt", "Read HANDOFF.md",
          "--force", "--wait", "--timeout", "45s", "--json"])

        expect(restart_command).to have_received(:call).with(name: "myapp", pane: "%18", prompt: "Read HANDOFF.md",
          force: true, wait: true, timeout: 45, json: true)
      end

      it "exits with the command's exit code" do
        allow(restart_command).to receive(:call).and_return({exit_code: 1})
        cli, = build_test_cli(restart_agent_command: restart_command)

        expect { cli.run(["agent-run", "restart", "--name", "myapp", "--pane", "0.1", "--prompt", "go"]) }
          .to raise_error(FakeSystemExit) { |e| expect(e.status).to eq(1) }
      end
    end

    describe "#run agent-run queue" do
      let(:queue_command) { double("prompt queue", list: [], cancel: {}) }

      it "passes list's workspace, pane and json" do
        cli, = build_test_cli(prompt_queue_command: queue_command)

        cli.run(["agent-run", "queue", "list", "--name=api", "--pane=%19", "--json"])

        expect(queue_command).to have_received(:list).with(name: "api", pane: "%19", json: true)
      end

      it "passes cancel's id, leaving the workspace unset to search them all" do
        cli, = build_test_cli(prompt_queue_command: queue_command)

        cli.run(["agent-run", "queue", "cancel", "--id", " abc123 "])

        expect(queue_command).to have_received(:cancel).with(id: "abc123", name: nil, json: false)
      end
    end

    describe "#run handoff" do
      let(:handoff_command) { double("handoff", check: {exit_code: 0}, new: {exit_code: 0}) }

      it "passes name, pane, threshold, and doc/prompt flags to handoff check" do
        cli, = build_test_cli(handoff_command: handoff_command)

        cli.run(["handoff", "check", "myapp", "--pane", "2", "--threshold", "20", "--handoff-doc", "HANDOFF.md", "--json"])

        expect(handoff_command).to have_received(:check).with(name: "myapp", pane: "2", threshold: 20,
          context_pct: nil, handoff_doc: "HANDOFF.md", handoff_prompt: nil, json: true)
      end

      it "passes --context-pct through, skipping detection" do
        cli, = build_test_cli(handoff_command: handoff_command)

        cli.run(["handoff", "check", "myapp", "--context-pct", "42", "--handoff-prompt", "Wrap up"])

        expect(handoff_command).to have_received(:check).with(name: "myapp", pane: nil, threshold: nil,
          context_pct: 42, handoff_doc: nil, handoff_prompt: "Wrap up", json: false)
      end

      it "exits with handoff check's exit code, including 2 for undetermined usage" do
        allow(handoff_command).to receive(:check).and_return({exit_code: 2})
        cli, = build_test_cli(handoff_command: handoff_command)

        expect { cli.run(["handoff", "check", "myapp"]) }.to raise_error(FakeSystemExit) { |e| expect(e.status).to eq(2) }
      end

      it "reports a Workspace::Error from handoff check as a JSON error with --json" do
        allow(handoff_command).to receive(:check).and_raise(Workspace::Error, "no agent daemon for 'myapp'")
        cli, output = build_test_cli(handoff_command: handoff_command)

        expect { cli.run(["handoff", "check", "myapp", "--json"]) }
          .to raise_error(FakeSystemExit) { |e| expect(e.status).to eq(1) }
        expect(JSON.parse(output.string)).to eq("schema_version" => 1, "ok" => false, "code" => "error", "error" => "no agent daemon for 'myapp'")
      end

      it "passes name, pane, and doc/prompt flags to handoff new" do
        cli, = build_test_cli(handoff_command: handoff_command)

        cli.run(["handoff", "new", "myapp", "--pane", "2", "--handoff-doc", "HANDOFF.md", "--json"])

        expect(handoff_command).to have_received(:new).with(name: "myapp", pane: "2", handoff_doc: "HANDOFF.md",
          handoff_prompt: nil, wait: false, json: true)
      end

      it "passes --wait to handoff new" do
        cli, = build_test_cli(handoff_command: handoff_command)

        cli.run(["handoff", "new", "myapp", "--pane", "2", "--handoff-prompt", "Go", "--wait"])

        expect(handoff_command).to have_received(:new).with(name: "myapp", pane: "2", handoff_doc: nil,
          handoff_prompt: "Go", wait: true, json: false)
      end

      it "reports a Workspace::Error from handoff new as a JSON error with --json" do
        allow(handoff_command).to receive(:new).and_raise(Workspace::Error, "no agent daemon for 'myapp'")
        cli, output = build_test_cli(handoff_command: handoff_command)

        expect { cli.run(["handoff", "new", "myapp", "--handoff-doc", "a", "--json"]) }
          .to raise_error(FakeSystemExit) { |e| expect(e.status).to eq(1) }
        expect(JSON.parse(output.string)).to eq("schema_version" => 1, "ok" => false, "code" => "error", "error" => "no agent daemon for 'myapp'")
      end

      it "lets handoff new run with neither --handoff-doc nor --handoff-prompt, which the command defaults" do
        cli, = build_test_cli(handoff_command: handoff_command)

        cli.run(["handoff", "new", "myapp", "--pane", "%2"])

        expect(handoff_command).to have_received(:new).with(name: "myapp", pane: "%2", handoff_doc: nil, handoff_prompt: nil, wait: false, json: false)
      end
    end
  end
end
