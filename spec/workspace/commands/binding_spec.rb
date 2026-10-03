require "tmpdir"

RSpec.describe Workspace::Commands::Binding do
  let(:dir) { Dir.mktmpdir }
  let(:bindings) { Workspace::PaneBindings.new(path: File.join(dir, "bindings.json")) }
  let(:locator) { instance_double(Workspace::PaneLocator) }
  let(:tmux) { instance_double(Workspace::Tmux, pane_slot: "app:0.1") }
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

  describe "#show and #clear" do
    before { command.set(workspace: "app", pane: "%5", kind: "review", id: "acme/api#835", focus: "security") }

    it "shows what the agent will be told" do
      output.reopen(+"")
      entry = command.show(pane: "%5")

      expect(entry["id"]).to eq("acme/api#835")
      expect(output.string).to eq("This pane is bound to review acme/api#835 in app.\nFocus: security.\n")
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
end
