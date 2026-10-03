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

    it "emits a JSON error for a blank default and records nothing" do
      result = command.call(question: "q", default: " ", working_dir: "/app", json: true)

      expect(result).to eq(exit_code: 1)
      expect(JSON.parse(output.string)).to include("error" => "The default can't be blank.")
      expect(File.exist?(File.join(tmpdir, "asks.json"))).to be(false)
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
      expect { command.answer("nope", "answer", working_dir: "/app") }.to raise_error(Workspace::Error, /No question 'nope'/)
    end

    it "raises a distinct message for an already-answered id" do
      command.call(question: "q1", default: "d1", working_dir: "/app", json: true)
      id = JSON.parse(output.string)["question"]["id"]
      output.truncate(0)
      output.rewind
      command.answer(id, "first answer", working_dir: "/app")

      expect { command.answer(id, "second answer", working_dir: "/app") }
        .to raise_error(Workspace::Error, /was already answered/)
    end

    it "emits a JSON error instead of raising when --json is given and the id is unknown" do
      result = command.answer("nope", "answer", working_dir: "/app", json: true)

      expect(result).to eq(exit_code: 1)
      expect(JSON.parse(output.string)).to include("schema_version" => 1)
    end

    it "emits a JSON error instead of raising when --json is given and the id was already answered" do
      command.call(question: "q1", default: "d1", working_dir: "/app", json: true)
      id = JSON.parse(output.string)["question"]["id"]
      command.answer(id, "first answer", working_dir: "/app")
      output.truncate(0)
      output.rewind

      result = command.answer(id, "second answer", working_dir: "/app", json: true)

      expect(result).to eq(exit_code: 1)
      payload = JSON.parse(output.string)
      expect(payload).to include("schema_version" => 1)
      expect(payload["error"]).to match(/was already answered/)
    end
  end

  describe "#answer with deliver" do
    let(:tmux) do
      CLITestHelpers::FakeTmuxServer.new("myapp" => [{id: "%19", window: 1, index: 2}], "other" => [{id: "%7", window: 0, index: 0}])
    end
    let(:pane_sender) { Workspace::Commands::Send.new(locator: Workspace::PaneLocator.new(tmux: tmux), tmux: tmux, output: StringIO.new) }
    let(:env) { {"TMUX_PANE" => "%19", "TMUX" => "/private/tmp/tmux-501/default,4242,0"} }

    subject(:command) do
      described_class.new(config: config, project_detector: project_detector, alert_config: alert_config,
        notifier_factory: notifier_factory, pane_sender: pane_sender, env: env, output: output, error_output: error_output)
    end

    def ask(pane_env = env)
      out = StringIO.new
      described_class.new(config: config, project_detector: project_detector, notifier_factory: notifier_factory,
        env: pane_env, output: out, error_output: error_output).call(question: "pg?", default: "sqlite", working_dir: "/app", json: true)
      JSON.parse(out.string)["question"]["id"]
    end

    def error_from(**opts)
      command.answer(*opts.delete(:args), working_dir: "/app", **opts)
      nil
    rescue Workspace::Error => e
      e
    end

    it "answers, then types the answer and Enter into the asking pane" do
      id = ask

      result = command.answer(id, "postgres", working_dir: "/app", deliver: true)

      expect(result).to eq(exit_code: 0)
      expect(tmux.deliveries).to eq([{session: "myapp", pane: "%19", text: "postgres", enter: true}])
      expect(output.string).to eq("Answered #{id}\nTyped the answer into pane %19 and pressed Enter.\n")
    end

    it "adds the delivery to the JSON document" do
      id = ask

      command.answer(id, "postgres", working_dir: "/app", deliver: true, json: true)

      payload = JSON.parse(output.string)
      expect(payload["question"]).to include("id" => id, "status" => "answered", "answer" => "postgres")
      expect(payload["delivered"]).to eq("pane" => "%19", "submitted" => true)
    end

    it "leaves delivered out without deliver" do
      id = ask

      command.answer(id, "postgres", working_dir: "/app", json: true)

      expect(JSON.parse(output.string)).not_to have_key("delivered")
      expect(tmux.deliveries).to be_empty
    end

    it "leaves the question open when its pane is in another session" do
      id = ask(env.merge("TMUX_PANE" => "%7"))

      expect(error_from(args: [id, "x"], deliver: true).code).to eq("wrong_session")

      expect(tmux.deliveries).to be_empty
      command.answer(id, "x", working_dir: "/app")
    end

    it "leaves the question open when its pane has gone" do
      id = ask(env.merge("TMUX_PANE" => "%99"))

      expect(error_from(args: [id, "x"], deliver: true).code).to eq("no_such_pane")

      command.answer(id, "x", working_dir: "/app")
    end

    it "leaves the question open when it wasn't asked from tmux" do
      id = ask({})

      error = error_from(args: [id, "x"], deliver: true)

      expect(error.code).to eq("no_pane")
      expect(error.details).to eq("question" => id)
      command.answer(id, "x", working_dir: "/app")
    end

    it "records the tmux server the question was asked under" do
      id = ask

      record = command.answer(id, "x", working_dir: "/app", json: true) && JSON.parse(output.string)["question"]

      expect(record).to include("id" => id, "pane" => "%19", "tmux_server" => "4242")
    end

    it "leaves tmux_server out of a question asked outside tmux" do
      id = ask({})
      command.answer(id, "x", working_dir: "/app", json: true)

      expect(JSON.parse(output.string)["question"]).not_to have_key("tmux_server")
    end

    it "refuses a pane id that may have been reused after tmux restarted, leaving the question open" do
      id = ask
      tmux.server_pid = "9999"

      error = error_from(args: [id, "x"], deliver: true)

      expect(error.code).to eq("stale_pane")
      expect(error.message).to include("tmux has restarted since it was asked")
      expect(error.details).to eq("question" => id, "pane" => "%19")
      expect(tmux.deliveries).to be_empty
      command.answer(id, "x", working_dir: "/app")
    end

    it "refuses a question that doesn't record its tmux server" do
      id = ask(env.except("TMUX"))

      error = error_from(args: [id, "x"], deliver: true)

      expect(error.code).to eq("stale_pane")
      expect(error.message).to include("doesn't record which tmux server")
      expect(tmux.deliveries).to be_empty
    end

    it "keeps the answer and says so when typing fails" do
      id = ask
      tmux.delivery_status = :not_landed

      error = error_from(args: [id, "x"], deliver: true)

      expect(error.code).to eq("not_delivered")
      expect(error.message).to include("is marked answered, but typing the answer into pane %19 failed")
      expect(error.details).to include("question" => id, "answered" => true, "pane" => "%19")
      expect { command.answer(id, "again", working_dir: "/app") }.to raise_error(Workspace::Error, /already answered/)
    end

    it "exits 2 in JSON when the answer may already be in the pane" do
      id = ask
      tmux.delivery_status = :unverified

      result = command.answer(id, "x", working_dir: "/app", deliver: true, json: true)

      expect(result).to eq(exit_code: 2)
      expect(JSON.parse(output.string)).to include("ok" => false, "code" => "not_submitted")
    end

    it "keeps the not-found error for an unknown id" do
      expect(error_from(args: ["nope", "x"], deliver: true).message).to eq("No question 'nope' for myapp.")
    end

    it "refuses deliver when no sender is wired" do
      plain = described_class.new(config: config, project_detector: project_detector, env: {}, output: output, error_output: error_output)

      expect { plain.answer("x", "y", working_dir: "/app", deliver: true) }.to raise_error(Workspace::Error, /not available in this build/)
    end
  end

  describe "recording events" do
    let(:event_log) { CLITestHelpers::FakeEventLog.new }
    let(:env) { {"TMUX_PANE" => "%7"} }

    subject(:command) do
      described_class.new(config: config, project_detector: project_detector, notifier_factory: notifier_factory,
        event_log: event_log, env: env, output: output, error_output: error_output)
    end

    def asked_id
      JSON.parse(output.string)["question"]["id"]
    end

    it "records ask_created with the id and pane, and none of the question text" do
      command.call(question: "pg or sqlite?", default: "sqlite", context: "lib/x.rb:1", working_dir: "/app", json: true)

      expect(event_log.events).to eq([{"type" => "ask_created", "project" => "myapp", "data" => {"id" => asked_id, "workspace" => "myapp", "pane_id" => "%7"}}])
    end

    it "records ask_answered with the id and pane, and not the answer" do
      command.call(question: "q1", default: "d1", working_dir: "/app", json: true)
      id = asked_id

      command.answer(id, "use postgres", working_dir: "/app")

      expect(event_log.events.last).to eq({"type" => "ask_answered", "project" => "myapp", "data" => {"id" => id, "workspace" => "myapp", "pane_id" => "%7"}})
      expect(event_log.events.to_s).not_to include("use postgres")
    end

    it "records ask_answered before typing the answer, so a failed delivery still shows as answered" do
      sender = instance_double(Workspace::Commands::Send)
      allow(sender).to receive_messages(locate: nil, server_pid: "4242")
      allow(sender).to receive(:deliver).and_raise(Workspace::Error, "tmux said no")
      tmux_env = env.merge("TMUX" => "/tmp/sock,4242,0")
      delivering = described_class.new(config: config, project_detector: project_detector, notifier_factory: notifier_factory,
        pane_sender: sender, event_log: event_log, env: tmux_env, output: output, error_output: error_output)
      delivering.call(question: "q1", default: "d1", working_dir: "/app", json: true)
      id = asked_id

      expect { delivering.answer(id, "yes", working_dir: "/app", deliver: true) }.to raise_error(Workspace::Error)

      expect(event_log.events.map { |e| e["type"] }).to eq(%w[ask_created ask_answered])
    end

    it "records nothing for an answer that finds no question" do
      expect { command.answer("nope", "a", working_dir: "/app") }.to raise_error(Workspace::Error)

      expect(event_log.events).to be_empty
    end

    it "keeps its exit code and output when the log can't be written" do
      warnings = StringIO.new
      broken = described_class.new(config: config, project_detector: project_detector, notifier_factory: notifier_factory,
        event_log: CLITestHelpers.unwritable_event_log(tmpdir, error_output: warnings), env: env, output: output,
        error_output: error_output)

      result = broken.call(question: "q", default: "d", working_dir: "/app", json: true)

      expect(result).to eq(exit_code: 0)
      expect(JSON.parse(output.string)["ok"]).to be(true)
      expect(warnings.string.lines.size).to eq(1)
    end
  end
end
