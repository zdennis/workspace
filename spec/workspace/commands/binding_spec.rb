require "tmpdir"

RSpec.describe Workspace::Commands::Binding do
  let(:dir) { Dir.mktmpdir }
  let(:bindings) { Workspace::PaneBindings.new(path: File.join(dir, "bindings.json")) }
  let(:locator) { instance_double(Workspace::PaneLocator) }
  let(:tmux) { instance_double(Workspace::Tmux, pane_slot: "app:0.1", session_name_for_pane: "app") }
  let(:output) { StringIO.new }
  let(:command) { described_class.new(bindings: bindings, locator: locator, tmux: tmux, output: output) }

  after { FileUtils.remove_entry(dir) }

  before do
    allow(locator).to receive(:locate).with("app", "0.1").and_return({id: "%5", window: 0, index: 1, session: "app"})
    allow(locator).to receive(:locate).with("app", "%5").and_return({id: "%5", window: 0, index: 1, session: "app"})
  end

  describe "#set" do
    it "binds the pane by its id, with the session and slot it was made for" do
      entry = command.set(workspace: "app", pane: "0.1", kind: "run", id: "wr_1", step: "implement", attempt: 2)

      expect(entry).to include("pane_id" => "%5", "workspace" => "app", "session" => "app", "pane_slot" => "app:0.1", "step" => "implement")
      expect(bindings.binding_for("%5")["id"]).to eq("wr_1")
      expect(output.string).to eq("Bound pane %5 to run wr_1.\n")
    end

    it "binds nothing when the pane can't be located" do
      allow(locator).to receive(:locate).with("app", "%9").and_raise(Workspace::Error.new("No pane", code: "no_such_pane"))

      expect { command.set(workspace: "app", pane: "%9", kind: "run", id: "x") }.to raise_error(Workspace::Error) { |e| expect(e.code).to eq("no_such_pane") }
      expect(bindings.binding_for("%9")).to be_nil
    end

    it "refuses a bad kind before writing anything" do
      expect { command.set(workspace: "app", pane: "%5", kind: "pr", id: "x") }.to raise_error(Workspace::UsageError)
      expect(bindings.binding_for("%5")).to be_nil
    end
  end

  describe "#bind" do
    it "binds like set without printing anything" do
      entry = command.bind(workspace: "app", pane: "0.1", kind: "play", id: "play/kickoff", instructions: "/lib/play/kickoff.md")

      expect(entry).to include("pane_id" => "%5", "kind" => "play", "session" => "app", "pane_slot" => "app:0.1")
      expect(bindings.binding_for("%5")["instructions"]).to eq("/lib/play/kickoff.md")
      expect(output.string).to be_empty
    end
  end

  describe "#show and #clear" do
    before { command.set(workspace: "app", pane: "%5", kind: "review", id: "acme/api#835", focus: "security") }

    it "shows what the agent will be told" do
      output.reopen(+"")
      entry = command.show(pane: "%5")

      expect(entry).to include("id" => "acme/api#835", "stale" => false)
      expect(output.string).to eq("This pane is bound to review acme/api#835 in app.\nFocus: security.\n")
    end

    it "marks a binding stale when the pane has moved to another slot, and says what to do" do
      allow(tmux).to receive(:pane_slot).with("%5").and_return("app:0.2")
      output.reopen(+"")

      entry = command.show(pane: "%5")

      expect(entry["stale"]).to be true
      expect(output.string).to eq("This pane is bound to review acme/api#835 in app.\nFocus: security.\n" \
        "Stale: pane %5 is no longer at app:0.1, where it was bound, so the agent in it is not reminded. Bind it again, or clear it.\n")
      expect(bindings.binding_for("%5")).not_to have_key("stale")
    end

    it "names the session in the stale line for a binding stored without a slot" do
      bindings.bind("%6", "kind" => "run", "id" => "wr_2", "workspace" => "app", "session" => "old")
      output.reopen(+"")

      expect(command.show(pane: "%6")["stale"]).to be true
      expect(output.string.lines.last).to eq("Stale: pane %6 is no longer at old, where it was bound, so the agent in it is not reminded. Bind it again, or clear it.\n")
    end

    it "clears the binding" do
      expect(command.clear(pane: "%5")["id"]).to eq("acme/api#835")
      expect(bindings.binding_for("%5")).to be_nil
    end

    it "reports an unbound pane with the not_bound code" do
      expect { command.show(pane: "%7") }.to raise_error(Workspace::Error) { |e| expect(e.code).to eq("not_bound") }
      expect { command.clear(pane: "%7") }.to raise_error(Workspace::Error) { |e| expect(e.code).to eq("not_bound") }
    end

    it "refuses a pane that is not a pane id" do
      expect { command.show(pane: "0.1") }.to raise_error(Workspace::UsageError, /pane id/)
    end
  end

  describe "#stale? and #live" do
    before { command.set(workspace: "app", pane: "%5", kind: "run", id: "wr_1") }

    it "is live in the session and slot it was bound in" do
      expect(command.live(pane: "%5")).to include("id" => "wr_1", "pane_slot" => "app:0.1")
      expect(command.stale?(bindings.binding_for("%5"))).to be false
    end

    it "is stale when the pane id now belongs to another session" do
      allow(tmux).to receive(:session_name_for_pane).with("%5").and_return("other")

      expect(command.stale?(bindings.binding_for("%5"))).to be true
      expect(command.live(pane: "%5")).to be_nil
    end

    it "is stale when the pane sits in another slot, or tmux can't find it" do
      allow(tmux).to receive(:pane_slot).with("%5").and_return("app:1.0")
      expect(command.live(pane: "%5")).to be_nil

      allow(tmux).to receive_messages(session_name_for_pane: nil, pane_slot: nil)
      expect(command.stale?(bindings.binding_for("%5"))).to be true
    end

    it "judges a binding stored without a slot by its session alone" do
      entry = bindings.binding_for("%5").merge("pane_slot" => nil)
      allow(tmux).to receive(:pane_slot).and_return("app:9.9")

      expect(command.stale?(entry)).to be false
    end

    it "has no live binding for an unbound pane, and refuses a pane that is not a pane id" do
      expect(command.live(pane: "%7")).to be_nil
      expect { command.live(pane: "0.1") }.to raise_error(Workspace::UsageError, /pane id/)
    end
  end
end
