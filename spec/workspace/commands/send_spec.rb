RSpec.describe Workspace::Commands::Send do
  let(:tmux) do
    CLITestHelpers::FakeTmuxServer.new(
      "api" => [{id: "%3", window: 0, index: 0}, {id: "%19", window: 1, index: 2}],
      "web" => [{id: "%7", window: 0, index: 0}]
    )
  end
  let(:output) { StringIO.new }
  let(:command) { described_class.new(locator: Workspace::PaneLocator.new(tmux: tmux), tmux: tmux, output: output) }

  describe ".parse_keys" do
    it "splits on whitespace" do
      expect(described_class.parse_keys("Up  Up\tEnter")).to eq(%w[Up Up Enter])
    end

    %w[Enter Escape Tab BTab Space BSpace Up Down Left Right Home End PageUp PageDown PgUp PgDn Delete C-c M-x C-M-a S-Tab F1 F12 y Y 1 / ? \\ C-Up M-Enter].each do |key|
      it "accepts #{key}" do
        expect(described_class.parse_keys(key)).to eq([key])
      end
    end

    ["hello", "-l", "-", ";", "C-;", "F13", "F0", "enter", "Enter;", "C-C-C-C-c", "%1", "$(x)", "Ctrl-c", "ab"].each do |key|
      it "refuses #{key.inspect} as bad_keys" do
        expect { described_class.parse_keys(key) }.to raise_error(Workspace::Error) { |e| expect(e.code).to eq("bad_keys") }
      end
    end

    it "names every refused key" do
      expect { described_class.parse_keys("Escape hello world") }.to raise_error(Workspace::Error, /hello world/) { |e|
        expect(e.details).to eq("keys" => %w[hello world])
      }
    end

    it "refuses an empty value" do
      expect { described_class.parse_keys("  ") }.to raise_error(Workspace::Error) { |e| expect(e.code).to eq("bad_keys") }
    end

    it "refuses more than 64 keys" do
      expect { described_class.parse_keys((["y"] * 65).join(" ")) }.to raise_error(Workspace::Error, /at most 64/)
    end
  end

  describe "#call with text" do
    it "pastes the text then Enter into the resolved pane, targeted by pane id" do
      command.call(name: "api", pane: "%19", body: "yes")

      expect(tmux.deliveries).to eq([{session: "api", pane: "%19", text: "yes", enter: true}])
      expect(output.string).to eq("Sent text to pane %19 and pressed Enter.\n")
    end

    it "leaves Enter off with enter: false" do
      result = command.call(name: "api", pane: "0.0", body: "draft", enter: false)

      expect(tmux.deliveries.first).to include(pane: "%3", enter: false)
      expect(result).to eq("pane" => "%3", "mode" => "text", "submitted" => false)
      expect(output.string).to eq("Typed text into pane %3 without pressing Enter.\n")
    end

    it "prints the result as one JSON document" do
      command.call(name: "api", pane: "%19", body: "yes", json: true)

      expect(JSON.parse(output.string)).to eq(
        "schema_version" => 1, "ok" => true, "workspace" => "api", "pane" => "%19", "mode" => "text", "submitted" => true
      )
    end

    it "raises not_submitted (exit 2) when the text landed but wasn't confirmed" do
      tmux.delivery_status = :unsubmitted

      expect { command.call(name: "api", pane: "%3", body: "x") }.to raise_error(Workspace::Commands::Run::NotSubmittedError) { |e|
        expect(e.code).to eq("not_submitted")
        expect(e.message).to include("already in the pane")
        expect(e.details).to eq("pane" => "%3", "workspace" => "api")
      }
    end

    it "warns the text may be there when delivery was unverified" do
      tmux.delivery_status = :unverified

      expect { command.call(name: "api", pane: "%3", body: "x") }.to raise_error(Workspace::Commands::Run::NotSubmittedError, /check before resending/)
    end

    it "raises not_delivered, safe to resend, when the text never reached the pane" do
      tmux.delivery_status = :not_landed

      expect { command.call(name: "api", pane: "%3", body: "x") }.to raise_error(Workspace::Error, /safe to send again/) { |e|
        expect(e).not_to be_a(Workspace::Commands::Run::NotSubmittedError)
        expect(e.code).to eq("not_delivered")
      }
    end

    it "raises not_delivered when tmux failed" do
      tmux.delivery_status = :failed

      expect { command.call(name: "api", pane: "%3", body: "x") }.to raise_error(Workspace::Error) { |e| expect(e.code).to eq("not_delivered") }
    end
  end

  describe "#call with keys" do
    it "sends each key in order, with no implicit Enter" do
      result = command.call(name: "api", pane: "%19", keys: %w[Escape Up])

      expect(tmux.keys_sent.map { |k| k.values_at(:session, :pane, :key) }).to eq([["api", "%19", "Escape"], ["api", "%19", "Up"]])
      expect(tmux.deliveries).to be_empty
      expect(result).to eq("pane" => "%19", "mode" => "keys", "submitted" => true, "keys" => %w[Escape Up])
      expect(output.string).to eq("Sent Escape Up to pane %19.\n")
    end

    it "prints the contract's JSON shape" do
      command.call(name: "api", pane: "%19", keys: %w[Escape], json: true)

      expect(JSON.parse(output.string)).to include("ok" => true, "pane" => "%19", "submitted" => true, "keys" => ["Escape"])
    end

    it "reports how many keys went through when tmux fails partway" do
      allow(tmux).to receive(:send_key).and_return(true, false)

      expect { command.call(name: "api", pane: "%3", keys: %w[a b c]) }.to raise_error(Workspace::Error, /after 1 of 3 keys/) { |e|
        expect(e.code).to eq("not_delivered")
        expect(e.details).to include("keys_sent" => 1, "pane" => "%3")
      }
    end
  end

  describe "pane safety" do
    it "types nothing into a pane of another session" do
      expect { command.call(name: "api", pane: "%7", body: "rm -rf") }.to raise_error(Workspace::Error) { |e| expect(e.code).to eq("wrong_session") }
      expect { command.call(name: "api", pane: "%7", keys: %w[Enter]) }.to raise_error(Workspace::Error) { |e| expect(e.code).to eq("wrong_session") }

      expect(tmux.deliveries).to be_empty
      expect(tmux.keys_sent).to be_empty
    end

    it "types nothing into a missing pane" do
      expect { command.call(name: "api", pane: "%99", body: "x") }.to raise_error(Workspace::Error) { |e| expect(e.code).to eq("no_such_pane") }

      expect(tmux.deliveries).to be_empty
    end

    it "types nothing for a pane that is not a pane id or window.pane" do
      expect { command.call(name: "api", pane: "bottom", body: "x") }.to raise_error(Workspace::Error) { |e| expect(e.code).to eq("bad_pane") }

      expect(tmux.deliveries).to be_empty
    end

    it "types nothing when the workspace has no session" do
      expect { command.call(name: "nope", pane: "%3", body: "x") }.to raise_error(Workspace::Error) { |e| expect(e.code).to eq("no_session") }
    end
  end

  it "needs exactly one of body and keys" do
    expect { command.deliver(name: "api", pane: "%3") }.to raise_error(ArgumentError)
    expect { command.deliver(name: "api", pane: "%3", body: "x", keys: ["y"]) }.to raise_error(ArgumentError)
  end

  it "names the tmux server a pane lives in" do
    expect(command.server_pid("%3")).to eq("4242")
    expect(command.server_pid("%99")).to be_nil
  end

  describe "#through_daemon" do
    let(:client) { double("client") }
    let(:command) { described_class.new(locator: Workspace::PaneLocator.new(tmux: tmux), tmux: tmux, client: client, output: output) }

    def reply_with(reply)
      allow(client).to receive(:exchange_message).and_return(reply)
    end

    def error_from
      yield
      nil
    rescue Workspace::Error => e
      e
    end

    it "prints a queued answer as a sentence" do
      reply_with("ok" => true, "queued" => true, "id" => "q1", "position" => 1, "pane_id" => "%3")

      result = command.through_daemon(name: "api", pane: "%3", body: "go")

      expect(result).to include("queued" => true, "pane" => "%3")
      expect(output.string).to eq("Queued for pane %3 at position 1 (q1); the agent daemon types it when the agent's turn ends (prompt_dequeued in workspace events says how it went).\n")
    end

    it "says a queued --clear-first prompt clears the conversation first" do
      reply_with("ok" => true, "queued" => true, "id" => "q1", "position" => 2, "pane_id" => "%3")

      command.through_daemon(name: "api", pane: "%3", body: "go", clear_first: true)

      expect(output.string).to eq("Queued for pane %3 at position 2 (q1); the agent daemon clears the conversation and " \
        "types it when the agent's turn ends (prompt_dequeued in workspace events says how it went).\n")
    end

    it "raises clear_unconfirmed as the exit-75 error, with its details" do
      reply_with("ok" => false, "error" => "clear_unconfirmed", "message" => "not confirmed", "id" => "q1", "clear_typed" => true)

      error = error_from { command.through_daemon(name: "api", pane: "%3", body: "go", when_idle: false, clear_first: true) }

      expect(error).to be_a(described_class::ClearUnconfirmedError)
      expect(described_class::ClearUnconfirmedError::EXIT_CODE).to eq(75)
      expect(error.code).to eq("clear_unconfirmed")
      expect(error.details).to eq("id" => "q1", "clear_typed" => true)
    end

    it "names --clear-first in the size refusal when it is used without --when-idle" do
      error = error_from { command.through_daemon(name: "api", pane: "%3", body: "x" * (Workspace::PromptQueueStore::MAX_BYTES + 1), when_idle: false, clear_first: true) }

      expect(error.message).to include("--clear-first takes at most")
    end

    describe "#interrupt_through_daemon" do
      it "sends one prompt_interrupt_send message for the pane id and prints one sentence" do
        reply_with("ok" => true, "interrupted" => true, "keys" => ["Escape"], "delivered" => true, "submitted" => true, "pane" => "0.0")

        result = command.interrupt_through_daemon(name: "api", pane: "%3", body: "go")

        expect(client).to have_received(:exchange_message)
          .with("api", {"type" => "prompt_interrupt_send", "pane_id" => "%3", "text" => "go"}, timeout: described_class::WHEN_IDLE_TIMEOUT)
        expect(result).to include("pane" => "%3", "interrupted" => true)
        expect(output.string).to eq("Interrupted pane %3 (Escape), waited for its prompt, typed the text and pressed Enter.\n")
      end

      it "prints the JSON envelope with --json" do
        reply_with("ok" => true, "interrupted" => true, "keys" => ["Escape"], "delivered" => true, "submitted" => true)

        command.interrupt_through_daemon(name: "api", pane: "%3", body: "go", json: true)

        expect(JSON.parse(output.string)).to eq("schema_version" => 1, "ok" => true, "workspace" => "api", "interrupted" => true,
          "keys" => ["Escape"], "delivered" => true, "submitted" => true, "pane" => "%3")
      end

      it "raises not_ready with the daemon's details" do
        reply_with("ok" => false, "error" => "not_ready", "message" => "prompt did not come back", "interrupted" => true, "reason" => "busy")

        error = error_from { command.interrupt_through_daemon(name: "api", pane: "%3", body: "go") }

        expect(error.code).to eq("not_ready")
        expect(error.details).to eq("interrupted" => true, "reason" => "busy")
      end

      it "tells the caller an older daemon needs a restart, naming --interrupt" do
        reply_with("ok" => false, "error" => "unknown_type")

        error = error_from { command.interrupt_through_daemon(name: "api", pane: "%3", body: "go") }

        expect(error.message).to include("predates --interrupt")
      end

      it "refuses a body over the limit as usage" do
        error = error_from { command.interrupt_through_daemon(name: "api", pane: "%3", body: "x" * (Workspace::PromptQueueStore::MAX_BYTES + 1)) }

        expect(error).to be_a(Workspace::UsageError)
        expect(error.message).to include("--interrupt takes at most")
      end
    end

    it "refuses a body over the limit as usage, before asking the daemon" do
      error = error_from { command.through_daemon(name: "api", pane: "%3", body: "x" * (Workspace::PromptQueueStore::MAX_BYTES + 1)) }

      expect(error).to be_a(Workspace::UsageError)
      expect(error.details).to eq("limit" => Workspace::PromptQueueStore::MAX_BYTES)
    end

    it "gives the pane id as details.pane, as on success, and a usage refusal as a UsageError" do
      reply_with("ok" => false, "error" => "usage", "message" => "too long", "pane" => "0.0", "pane_id" => "%3")

      error = error_from { command.through_daemon(name: "api", pane: "%3", body: "go") }

      expect(error).to be_a(Workspace::UsageError)
      expect(error.details).to eq("pane" => "%3", "pane_id" => "%3")
    end

    it "names a daemon too old for prompt_send" do
      reply_with("ok" => false, "error" => "unknown_type")

      error = error_from { command.through_daemon(name: "api", pane: "%3", body: "go") }

      expect(error.code).to eq("error")
      expect(error.message).to include("workspace agentd restart api")
    end

    it "turns a code the registry doesn't know into error" do
      reply_with("ok" => false, "error" => "mystery_code", "message" => "boom")

      expect(error_from { command.through_daemon(name: "api", pane: "%3", body: "go") }.code).to eq("error")
    end

    it "says a timed-out call may have queued or typed the text" do
      allow(client).to receive(:exchange_message).and_raise(Workspace::AgentSnapshotClient::Unavailable.new("timed out", reason: :timeout))

      error = error_from { command.through_daemon(name: "api", pane: "%3", body: "go") }

      expect(error.code).to eq("connection_failed")
      expect(error.details).to eq("maybe_delivered" => true)
      expect(error.message).to include("check the pane")
    end

    it "answers unreadable_reply for a reply that isn't a JSON object" do
      reply_with(nil)

      error = error_from { command.through_daemon(name: "api", pane: "%3", body: "go") }

      expect(error.code).to eq("unreadable_reply")
      expect(error.details).to eq("maybe_delivered" => true)
    end

    it "refuses with no client wired" do
      bare = described_class.new(locator: Workspace::PaneLocator.new(tmux: tmux), tmux: tmux, output: output)

      expect(error_from { bare.through_daemon(name: "api", pane: "%3", body: "go") }.message).to include("not available")
    end
  end

  it "exposes the locator as #locate" do
    expect(command.locate("api", "%3")).to include(id: "%3")
  end
end
