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

  it "exposes the locator as #locate" do
    expect(command.locate("api", "%3")).to include(id: "%3")
  end
end
