require "tmpdir"

RSpec.describe Workspace::Commands::Binding do
  let(:dir) { Dir.mktmpdir }
  let(:bindings) { Workspace::PaneBindings.new(path: File.join(dir, "bindings.json")) }
  let(:locator) { instance_double(Workspace::PaneLocator) }
  let(:tmux) { instance_double(Workspace::Tmux, pane_slot: "app:0.1", session_name_for_pane: "app", server_pid_for_pane: 42) }
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

  describe "reflection bindings" do
    it "records the tmux server's pid, as a reviewer binding does" do
      entry = command.bind(workspace: "app", pane: "%5", kind: "reflection", id: "wr_1")

      expect(entry["server_pid"]).to eq(42)
      expect(command.bind(workspace: "app", pane: "%5", kind: "run", id: "wr_1")).not_to have_key("server_pid")
    end

    describe "#reflecting" do
      it "returns the pane's live reflection binding" do
        command.bind(workspace: "app", pane: "%5", kind: "reflection", id: "wr_1")

        expect(command.reflecting(pane: "%5")).to include("kind" => "reflection", "id" => "wr_1")
      end

      it "is nil for a stale binding, another kind, an unbound pane" do
        command.bind(workspace: "app", pane: "%5", kind: "reflection", id: "wr_1")
        allow(tmux).to receive(:server_pid_for_pane).with("%5").and_return(43)
        expect(command.reflecting(pane: "%5")).to be_nil

        command.bind(workspace: "app", pane: "%5", kind: "run", id: "wr_1")
        expect(command.reflecting(pane: "%5")).to be_nil
        expect(command.reflecting(pane: "%8")).to be_nil
      end

      it "refuses a value that is not a pane id" do
        expect { command.reflecting(pane: "0.1") }.to raise_error(Workspace::UsageError)
      end
    end
  end

  describe "packs" do
    it "stores the packs given to set and reports them" do
      entry = command.set(workspace: "app", pane: "%5", kind: "play", id: "play/notes", packs: %w[notes handoff])

      expect(entry["packs"]).to eq(%w[notes handoff])
      expect(bindings.binding_for("%5")["packs"]).to eq(%w[notes handoff])
    end

    it "always reports packs from show and clear, [] for a binding with none or one stored before packs" do
      command.set(workspace: "app", pane: "%5", kind: "run", id: "wr_1")
      File.write(File.join(dir, "bindings.json"), JSON.generate("%5" => {"kind" => "run", "id" => "wr_1", "session" => "app"}))

      expect(command.show(pane: "%5")["packs"]).to eq([])
      expect(command.clear(pane: "%5")["packs"]).to eq([])
    end

    it "always reports plays from show and clear: the stored list, or the single play of a hand-set binding" do
      listed = [{"id" => "play/a", "instructions" => "/a.md"}, {"id" => "play/b", "instructions" => "/b.md"}]
      command.set(workspace: "app", pane: "%5", kind: "play", id: "play/a", instructions: "/a.md", plays: listed)
      expect(command.show(pane: "%5")["plays"]).to eq(listed)

      File.write(File.join(dir, "bindings.json"), JSON.generate(
        "%5" => {"kind" => "play", "id" => "play/a", "instructions" => "/a.md", "session" => "app"},
        "%6" => {"kind" => "run", "id" => "wr_1", "session" => "app"}
      ))
      expect(command.show(pane: "%5")["plays"]).to eq([{"id" => "play/a", "instructions" => "/a.md"}])
      expect(command.show(pane: "%6")["plays"]).to eq([])
      expect(command.clear(pane: "%5")["plays"]).to eq([{"id" => "play/a", "instructions" => "/a.md"}])
    end

    it "prints no Packs line for a binding with none" do
      command.set(workspace: "app", pane: "%5", kind: "run", id: "wr_1")
      output.reopen(+"")

      command.show(pane: "%5")

      expect(output.string).not_to include("Packs:")
    end

    it "prints the packs after what the agent is told, and returns them" do
      command.set(workspace: "app", pane: "%5", kind: "play", id: "play/notes", packs: %w[notes handoff])
      output.reopen(+"")

      entry = command.show(pane: "%5")

      expect(entry["packs"]).to eq(%w[notes handoff])
      expect(output.string).to end_with("Packs: notes, handoff.\n")
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

  describe "run ownership" do
    let(:going) { {"wr_1" => true} }
    let(:paused) { {} }
    let(:runs) do
      double("runs").tap do |store|
        allow(store).to receive(:run) do |id|
          raise Workspace::Error.new("no run", code: "run_not_found") unless going.key?(id)
          double("run", state: going[id] ? "running" : "completed", paused: paused[id])
        end
      end
    end
    let(:owner) { described_class.new(bindings: bindings, locator: locator, tmux: tmux, output: output, runs: runs) }

    it "names the going run for a run binding, whatever its role" do
      owner.bind(workspace: "app", pane: "%5", kind: "run", id: "wr_1", role: "author")
      expect(owner.owning_run(pane: "%5")).to eq("wr_1")

      owner.bind(workspace: "app", pane: "%5", kind: "run", id: "wr_1", role: "reviewer")
      expect(owner.owning_run(pane: "%5")).to eq("wr_1")
    end

    it "is nil for review, play, unbound and stale panes" do
      owner.bind(workspace: "app", pane: "%5", kind: "review", id: "wr_1")
      expect(owner.owning_run(pane: "%5")).to be_nil
      owner.bind(workspace: "app", pane: "%5", kind: "play", id: "play/notes")
      expect(owner.owning_run(pane: "%5")).to be_nil
      expect(owner.owning_run(pane: "%8")).to be_nil

      owner.bind(workspace: "app", pane: "%5", kind: "run", id: "wr_1")
      allow(tmux).to receive(:session_name_for_pane).with("%5").and_return("other")
      expect(owner.owning_run(pane: "%5")).to be_nil
    end

    it "is nil for a run that has ended or an unknown run, and when no store was given" do
      owner.bind(workspace: "app", pane: "%5", kind: "run", id: "wr_2")
      expect(owner.owning_run(pane: "%5")).to be_nil

      owner.bind(workspace: "app", pane: "%5", kind: "run", id: "wr_1")
      going["wr_1"] = false
      expect(owner.owning_run(pane: "%5")).to be_nil

      going["wr_1"] = true
      expect(command.owning_run(pane: "%5")).to be_nil
    end

    it "treats a run file that can't be read as not owned, from one read of the run" do
      owner.bind(workspace: "app", pane: "%5", kind: "run", id: "wr_1")
      allow(runs).to receive(:run).and_raise(Workspace::Error.new("unreadable", code: "run_unreadable"))
      expect(owner.owned(pane: "%5")).to be_nil
      expect(owner.owning_run(pane: "%5")).to be_nil
    end

    it "refuses a pane that is not a pane id instead of saying no run owns it" do
      expect { owner.owned(pane: "0.1") }.to raise_error(Workspace::UsageError, /pane id/)
      expect { owner.refuse_owned!(pane: "0.1", workspace: "app", action: :type) }.to raise_error(Workspace::UsageError)
    end

    it "gives a frozen owned hash with the run's paused state" do
      owner.bind(workspace: "app", pane: "%5", kind: "run", id: "wr_1")
      expect(owner.owned(pane: "%5")).to eq("run" => "wr_1", "pane" => "%5", "paused" => false)
      expect(owner.owned(pane: "%5")).to be_frozen

      paused["wr_1"] = {"since" => "t", "by" => "x"}
      expect(owner.owned(pane: "%5")["paused"]).to be true
      expect(owner.owned(pane: "%9")).to be_nil
    end

    describe "#refusal" do
      let(:live) { {"run" => "wr_1", "pane" => "%5", "paused" => false}.freeze }
      let(:stopped) { {"run" => "wr_1", "pane" => "%5", "paused" => true}.freeze }

      def refuse(owned, action, **opts) = owner.refusal(owned, workspace: "app", action: action, **opts)

      it "words the type refusal, with the unpause form when the run is paused" do
        r = refuse(live, :type)
        expect(r).to be_frozen
        expect(r[:code]).to eq("pane_bound_to_run")
        expect(r[:message]).to eq("Pane %5 is bound to workflow run wr_1, which owns what is typed into it; nothing was typed. Use `workspace workflow status wr_1`.")
        expect(r[:details]).to eq("workspace" => "app", "pane" => "%5", "run" => "wr_1", "paused" => false, "use" => "workspace workflow status wr_1", "plan_resumed" => false)
        expect(refuse(stopped, :type)[:details]["use"]).to eq("workspace workflow unpause wr_1")
      end

      it "words the resumed type refusal" do
        r = refuse(live, :type, resumed: true)
        expect(r[:message]).to eq("Pane %5 is bound to workflow run wr_1, which owns what is typed into it; nothing was typed. The plan was paused and is set back to active, so the run's agent takes it on its next attempt. Use `workspace workflow status wr_1`.")
        expect(r[:details]["plan_resumed"]).to be true
      end

      it "words handoff new for another pane and for the run's own pane" do
        expect(refuse(stopped, :handoff_new)[:message]).to eq("Pane %5 is bound to workflow run wr_1; handoff would /clear the run's turn, so nothing was restarted. Use `workspace workflow unpause wr_1`.")
        own = refuse(live, :handoff_new, own_pane: true)
        expect(own[:message]).to eq("This pane is bound to workflow run wr_1; the run owns its context, so it was not restarted. Finish or record where the step stands, then end your turn; the run checks the step and a retry starts fresh.")
        expect(own[:details]["use"]).to be_nil
      end

      it "words handoff check for another pane and for the run's own pane" do
        expect(refuse(live, :handoff_check)[:message]).to eq("Pane %5 is bound to workflow run wr_1; no save-state prompt was sent. Use `workspace workflow status wr_1`.")
        own = refuse(live, :handoff_check, own_pane: true)
        expect(own[:message]).to eq("This pane is bound to workflow run wr_1, which owns its context; no save-state prompt was sent. Keep working on the step; do not hand off.")
        expect(own[:details]["use"]).to be_nil
      end

      it "words pause, naming workflow status when the run is already paused" do
        r = refuse(live, :pause)
        expect(r[:message]).to eq("Pane %5 is bound to workflow run wr_1; a plan pause would not stop it, so the plan was left as it is. Use `workspace workflow pause wr_1 [--interrupt]`.")
        expect(r[:details]["use"]).to eq("workspace workflow pause wr_1 [--interrupt]")
        s = refuse(stopped, :pause)
        expect(s[:message]).to eq("Pane %5 is bound to workflow run wr_1; a plan pause would not stop it, so the plan was left as it is. Run wr_1 is already paused: `workspace workflow status wr_1`.")
        expect(s[:details]["use"]).to eq("workspace workflow status wr_1")
      end
    end

    describe "#refuse_owned!" do
      it "raises pane_bound_to_run for an owned pane" do
        owner.bind(workspace: "app", pane: "%5", kind: "run", id: "wr_1")
        expect { owner.refuse_owned!(pane: "%5", workspace: "app", action: :type) }.to raise_error(Workspace::Error) { |e|
          expect(e.code).to eq("pane_bound_to_run")
          expect(e.details).to include("run" => "wr_1", "pane" => "%5")
        }
      end

      it "returns nil for a pane no run owns" do
        expect(owner.refuse_owned!(pane: "%5", workspace: "app", action: :type)).to be_nil
      end
    end
  end
end
