require "spec_helper"
require "tmpdir"

RSpec.describe Workspace::Commands::Ask do
  let(:output) { StringIO.new }
  let(:error_output) { StringIO.new }
  let(:tmpdir) { Dir.mktmpdir("ws-ask-command") }
  let(:config) { instance_double(Workspace::Config, ask_state_path: File.join(tmpdir, "asks.json")) }
  let(:project_detector) { instance_double(Workspace::ProjectDetector, detect: "myapp") }
  let(:alert_config) { nil }
  let(:notifier) { instance_double(Workspace::Notifier, notify: nil, wait: nil) }
  let(:notifier_factory) { ->(_command) { notifier } }

  after { FileUtils.remove_entry(tmpdir) if File.directory?(tmpdir) }

  subject(:command) do
    described_class.new(config: config, project_detector: project_detector, alert_config: alert_config,
      notifier_factory: notifier_factory, env: {}, output: output, error_output: error_output)
  end

  describe "#call" do
    it "records the question and prints the default taken" do
      result = command.call(question: "pg or sqlite?", default: "sqlite", working_dir: "/app")

      expect(result).to eq(exit_code: 0)
      expect(output.string).to include("Recorded question")
      expect(output.string).to include("took default: sqlite")
    end

    it "emits the documented JSON schema" do
      result = command.call(question: "pg or sqlite?", default: "sqlite", context: "lib/x.rb:1", working_dir: "/app", json: true)

      payload = JSON.parse(output.string)
      expect(result).to eq(exit_code: 0)
      expect(payload["schema_version"]).to eq(1)
      expect(payload["question"]).to include("question" => "pg or sqlite?", "default" => "sqlite", "context" => "lib/x.rb:1")
    end

    it "raises when the workspace can't be detected" do
      allow(project_detector).to receive(:detect).and_return(nil)

      expect { command.call(question: "q", default: "d", working_dir: "/app") }.to raise_error(Workspace::Error)
    end

    it "emits a JSON error instead of raising when --json is given and the workspace can't be detected" do
      allow(project_detector).to receive(:detect).and_return(nil)

      result = command.call(question: "q", default: "d", working_dir: "/app", json: true)

      expect(result).to eq(exit_code: 1)
      expect(JSON.parse(output.string)).to include("schema_version" => 1, "error" => a_string_matching(/could not detect/i))
    end

    context "when the project has alerts.notify configured" do
      let(:alert_config) { instance_double(Workspace::AlertConfig) }

      it "runs the notify command with the question kind and details" do
        allow(alert_config).to receive(:for_workspace).with("myapp").and_return(notify: "notify-cmd", idle_after: 600)

        command.call(question: "pg or sqlite?", default: "sqlite", context: "lib/x.rb:1", working_dir: "/app")

        expect(notifier).to have_received(:notify).with(hash_including(
          "WORKSPACE_ALERT" => "question",
          "WORKSPACE_ALERT_WORKSPACE" => "myapp",
          "WORKSPACE_ALERT_QUESTION" => "pg or sqlite?",
          "WORKSPACE_ALERT_DEFAULT" => "sqlite",
          "WORKSPACE_ALERT_CONTEXT" => "lib/x.rb:1"
        ))
      end

      it "waits for the notify command, so the process doesn't exit before spawning it" do
        allow(alert_config).to receive(:for_workspace).with("myapp").and_return(notify: "notify-cmd", idle_after: 600)

        command.call(question: "q", default: "d", working_dir: "/app")

        expect(notifier).to have_received(:notify).ordered
        expect(notifier).to have_received(:wait).ordered
      end

      it "labels notify failures as coming from workspace ask" do
        allow(alert_config).to receive(:for_workspace).with("myapp").and_return(notify: "exit 3", idle_after: 600)
        real = described_class.new(config: config, project_detector: project_detector, alert_config: alert_config,
          env: {}, output: output, error_output: error_output)

        real.call(question: "q", default: "d", working_dir: tmpdir)

        expect(error_output.string).to start_with("workspace ask: notify command failed")
      end
    end

    context "when the project has no alerts.notify configured" do
      let(:alert_config) { instance_double(Workspace::AlertConfig) }

      it "records the question without notifying" do
        allow(alert_config).to receive(:for_workspace).with("myapp").and_return(notify: nil, idle_after: 600)

        result = command.call(question: "q", default: "d", working_dir: "/app")

        expect(result).to eq(exit_code: 0)
      end
    end
  end

  describe "#list" do
    it "shows no open questions initially" do
      result = command.list(working_dir: "/app")

      expect(result).to eq(exit_code: 0)
      expect(output.string).to include("No open questions")
    end

    it "lists open questions, oldest first" do
      command.call(question: "q1", default: "d1", working_dir: "/app")
      command.call(question: "q2", default: "d2", working_dir: "/app")
      output.truncate(0)
      output.rewind

      command.list(working_dir: "/app")

      lines = output.string.lines
      expect(lines[1]).to include("q1")
      expect(lines[2]).to include("q2")
    end

    it "emits the documented JSON schema" do
      command.call(question: "q1", default: "d1", working_dir: "/app")

      command.list(working_dir: "/app", json: true)

      payload = JSON.parse(output.string.lines.last)
      expect(payload).to include("schema_version" => 1, "workspace" => "myapp")
      expect(payload["questions"].size).to eq(1)
    end
  end

  describe "#answer" do
    it "resolves an open question" do
      command.call(question: "q1", default: "d1", working_dir: "/app", json: true)
      id = JSON.parse(output.string)["question"]["id"]
      output.truncate(0)
      output.rewind

      result = command.answer(id, "use postgres", working_dir: "/app")

      expect(result).to eq(exit_code: 0)
      expect(output.string).to include("Answered #{id}")
    end

    it "raises for an unknown id" do
      expect { command.answer("nope", "answer", working_dir: "/app") }.to raise_error(Workspace::Error, /No open question/)
    end

    it "emits a JSON error instead of raising when --json is given and the id is unknown" do
      result = command.answer("nope", "answer", working_dir: "/app", json: true)

      expect(result).to eq(exit_code: 1)
      expect(JSON.parse(output.string)).to include("schema_version" => 1)
    end
  end
end
