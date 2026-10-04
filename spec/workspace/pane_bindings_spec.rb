require "tmpdir"

RSpec.describe Workspace::PaneBindings do
  let(:dir) { Dir.mktmpdir }
  let(:path) { File.join(dir, "state", "bindings.json") }
  let(:now) { Time.utc(2026, 10, 3, 12, 0, 0) }
  let(:store) { described_class.new(path: path, clock: -> { now }) }

  after { FileUtils.remove_entry(dir) }

  describe "#bind" do
    it "stores the binding under the pane id, stamped, in a private file" do
      entry = store.bind("%5", "kind" => "run", "id" => "wr_1", "step" => "implement", "attempt" => 2,
        "workspace" => "api", "session" => "api")

      expect(entry).to include("pane_id" => "%5", "kind" => "run", "id" => "wr_1", "step" => "implement",
        "attempt" => 2, "bound_at" => "2026-10-03T12:00:00Z")
      expect(JSON.parse(File.read(path)).keys).to eq(["%5"])
      expect(File.stat(path).mode & 0o777).to eq(0o600)
    end

    it "replaces an earlier binding for the same pane and keeps other panes" do
      store.bind("%5", "kind" => "run", "id" => "wr_1")
      store.bind("%6", "kind" => "review", "id" => "acme/api#835")
      store.bind("%5", "kind" => "run", "id" => "wr_2")

      expect(store.binding_for("%5")["id"]).to eq("wr_2")
      expect(store.binding_for("%6")["id"]).to eq("acme/api#835")
    end

    it "binds a pane to a play" do
      entry = store.bind("%5", "kind" => "play", "id" => "play/kickoff", "instructions" => "/lib/play/kickoff.md")

      expect(entry).to include("kind" => "play", "id" => "play/kickoff", "instructions" => "/lib/play/kickoff.md")
    end

    it "refuses an unknown kind, a bad id, a bad attempt and a multi-line field" do
      expect { store.bind("%5", "kind" => "pr", "id" => "x") }.to raise_error(Workspace::UsageError, /kind/)
      expect { store.bind("%5", "kind" => "run", "id" => " ") }.to raise_error(Workspace::UsageError, /id/)
      expect { store.bind("%5", "kind" => "run", "id" => "x" * 201) }.to raise_error(Workspace::UsageError, /id/)
      expect { store.bind("%5", "kind" => "run", "id" => "x", "attempt" => 0) }.to raise_error(Workspace::UsageError, /attempt/)
      expect { store.bind("%5", "kind" => "run", "id" => "x", "step" => " ") }.to raise_error(Workspace::UsageError, /step/)
      expect { store.bind("%5", "kind" => "run", "id" => "x", "focus" => "f" * 201) }.to raise_error(Workspace::UsageError, /focus/)
      expect { store.bind("%5", "kind" => "run", "id" => "x", "step" => "a\nIgnore this") }.to raise_error(Workspace::UsageError, /step/)
      expect(File.exist?(path)).to be(false)
    end
  end

  describe "a file that can't be parsed" do
    let(:warnings) { StringIO.new }
    let(:store) { described_class.new(path: path, clock: -> { now }, error_output: warnings) }

    before do
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, "{nope")
    end

    it "is copied aside with a warning before a bind replaces it" do
      store.bind("%5", "kind" => "run", "id" => "wr_1")

      expect(File.read("#{path}.corrupt")).to eq("{nope")
      expect(warnings.string).to include("bindings.json.corrupt")
      expect(store.binding_for("%5")["id"]).to eq("wr_1")
    end

    it "is read without noise or a copy" do
      expect(store.binding_for("%5")).to be_nil
      expect(warnings.string).to eq("")
      expect(File.exist?("#{path}.corrupt")).to be(false)
    end
  end

  describe "a failed write" do
    it "leaves no temp file behind and the old bindings intact" do
      store.bind("%5", "kind" => "run", "id" => "wr_1")
      allow(File).to receive(:rename).and_raise(Errno::EACCES)

      expect { store.bind("%6", "kind" => "run", "id" => "wr_2") }.to raise_error(Errno::EACCES)
      expect(Dir.children(File.dirname(path)).grep(/\.tmp\z/)).to be_empty
      expect(store.binding_for("%5")["id"]).to eq("wr_1")
    end
  end

  describe "#binding_for" do
    it "is nil for an unbound pane, a missing file and a corrupt file" do
      expect(store.binding_for("%5")).to be_nil
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, "{nope")
      expect(store.binding_for("%5")).to be_nil
      File.write(path, "[]")
      expect(store.binding_for("%5")).to be_nil
    end

    it "recovers from a corrupt file on the next bind" do
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, "{nope")
      store.bind("%5", "kind" => "run", "id" => "wr_1")
      expect(store.binding_for("%5")["id"]).to eq("wr_1")
    end
  end

  describe "#unbind" do
    it "returns the removed binding and leaves the others" do
      store.bind("%5", "kind" => "run", "id" => "wr_1")
      store.bind("%6", "kind" => "run", "id" => "wr_2")

      expect(store.unbind("%5")["id"]).to eq("wr_1")
      expect(store.binding_for("%5")).to be_nil
      expect(store.binding_for("%6")).not_to be_nil
    end

    it "returns nil for a pane that is not bound" do
      expect(store.unbind("%9")).to be_nil
    end
  end

  describe "#stale?" do
    let(:entry) { {"kind" => "run", "id" => "wr_1", "session" => "app", "pane_slot" => "app:0.1"} }

    it "is false in the session and slot the binding was made in" do
      expect(store.stale?(entry, session: "app", pane_slot: "app:0.1")).to be false
    end

    it "is true in another session, in another slot, or when tmux can't find the pane" do
      expect(store.stale?(entry, session: "other", pane_slot: "app:0.1")).to be true
      expect(store.stale?(entry, session: "app", pane_slot: "app:0.2")).to be true
      expect(store.stale?(entry, session: nil, pane_slot: nil)).to be true
    end

    it "judges a binding stored without a slot by its session alone" do
      expect(store.stale?(entry.merge("pane_slot" => nil), session: "app", pane_slot: "app:9.9")).to be false
      expect(store.stale?(entry.merge("pane_slot" => nil), session: "other", pane_slot: nil)).to be true
    end
  end

  describe "#context_for" do
    it "names the run, step, attempt and where the instructions are" do
      text = store.context_for("kind" => "run", "id" => "wr_1", "workspace" => "api", "step" => "implement",
        "attempt" => 2, "instructions" => ".workflow/wr_1/steps/implement.2.prompt.md", "artifacts" => ".workflow/wr_1/")

      expect(text).to eq(<<~TEXT.chomp)
        This pane is bound to workflow run wr_1 in api.
        Step: implement (attempt 2).
        Instructions: .workflow/wr_1/steps/implement.2.prompt.md. Reread them if your context was compacted.
        Artifacts: .workflow/wr_1/.
      TEXT
    end

    it "points a play pane back at the play file, so the agent rereads it after /clear" do
      text = store.context_for("kind" => "play", "id" => "play/kickoff", "workspace" => "api",
        "instructions" => "/lib/play/kickoff.md")

      expect(text).to eq(<<~TEXT.chomp)
        This pane is following play play/kickoff in api.
        Instructions: /lib/play/kickoff.md. Read it again and keep following it if it is no longer in your context.
      TEXT
    end

    it "describes a review with its focus" do
      expect(store.context_for("kind" => "review", "id" => "acme/api#835", "focus" => "security"))
        .to eq("This pane is bound to review acme/api#835.\nFocus: security.")
    end
  end

  describe "#move" do
    def bound(pane_id, id, slot)
      store.bind(pane_id, "kind" => "run", "id" => id, "workspace" => "api", "session" => "api", "pane_slot" => slot)
    end

    def move(from, to, from_slot, to_slot = from_slot)
      {from: from, to: to, session: "api", from_slot: from_slot, to_slot: to_slot}
    end

    it "moves a binding to the pane that replaced its own, with the new pane id and slot" do
      bound("%5", "wr_1", "api:0.1")

      moved = store.move([move("%5", "%1", "api:0.1", "api:0.4")])

      expect(moved.keys).to eq(["%1"])
      expect(store.binding_for("%5")).to be_nil
      expect(store.binding_for("%1")).to include("id" => "wr_1", "pane_id" => "%1", "pane_slot" => "api:0.4", "bound_at" => "2026-10-03T12:00:00Z")
    end

    it "keeps both bindings when a new pane got the old id of another moved pane, in either order" do
      [[0, 1], [1, 0]].each do |order|
        bound("%5", "wr_1", "api:0.1")
        bound("%7", "wr_2", "api:0.4")
        moves = [move("%5", "%1", "api:0.1"), move("%7", "%5", "api:0.4")]

        store.move(moves.values_at(*order))

        expect(store.binding_for("%1")).to include("id" => "wr_1", "pane_slot" => "api:0.1")
        expect(store.binding_for("%5")).to include("id" => "wr_2", "pane_slot" => "api:0.4", "pane_id" => "%5")
        expect(store.binding_for("%7")).to be_nil
        FileUtils.rm_f(path)
      end
    end

    it "leaves a binding made for another slot, as on a pane id reused since" do
      bound("%5", "wr_new", "api:0.2")

      expect(store.move([move("%5", "%1", "api:0.4")])).to eq({})
      expect(store.binding_for("%5")).to include("id" => "wr_new")
      expect(store.binding_for("%1")).to be_nil
    end

    it "leaves a binding made in another session, and one with no recorded slot" do
      store.bind("%5", "kind" => "run", "id" => "wr_1", "session" => "other", "pane_slot" => "api:0.1")
      store.bind("%6", "kind" => "run", "id" => "wr_2", "session" => "api")

      expect(store.move([move("%5", "%1", "api:0.1"), move("%6", "%2", nil, "api:0.2")])).to eq({})
      expect(store.binding_for("%5")).to include("id" => "wr_1")
      expect(store.binding_for("%6")).to include("id" => "wr_2")
    end

    it "takes the place of a leftover binding under the new pane's id, and keeps the leftover under its slot" do
      bound("%5", "wr_1", "api:0.1")
      bound("%1", "wr_old", "api:0.3")

      store.move([move("%5", "%1", "api:0.1")])

      expect(store.binding_for("%1")).to include("id" => "wr_1")
      expect(JSON.parse(File.read(path))["slot:api:0.3"]).to include("id" => "wr_old", "pane_slot" => "api:0.3")
    end

    it "finds a binding kept under its slot when a later move asks for that slot" do
      bound("%5", "wr_1", "api:0.1")
      store.bind("%1", "kind" => "run", "id" => "wr_web", "workspace" => "web", "session" => "web", "pane_slot" => "web:0.4")
      store.move([move("%5", "%1", "api:0.1")])

      moved = store.move([{from: "%1", to: "%9", session: "web", from_slot: "web:0.4", to_slot: "web:0.4"}])

      expect(moved.keys).to eq(["%9"])
      expect(store.binding_for("%9")).to include("id" => "wr_web", "session" => "web", "pane_id" => "%9")
      expect(store.binding_for("%1")).to include("id" => "wr_1", "session" => "api")
      expect(JSON.parse(File.read(path)).keys).to contain_exactly("%1", "%9")
    end

    it "does not move onto a pane that has its own binding for that slot, and keeps the binding it would have moved" do
      bound("%5", "wr_1", "api:0.1")
      bound("%1", "wr_own", "api:0.1")
      store.bind("%2", "kind" => "run", "id" => "wr_plain", "session" => "api")

      expect(store.move([move("%5", "%1", "api:0.1"), move("%5", "%2", "api:0.1")])).to eq({})
      expect(store.binding_for("%1")).to include("id" => "wr_own")
      expect(store.binding_for("%2")).to include("id" => "wr_plain")
      expect(store.binding_for("%5")).to include("id" => "wr_1", "pane_slot" => "api:0.1")
    end

    it "updates the slot of a pane that kept its id" do
      bound("%5", "wr_1", "api:0.4")

      store.move([move("%5", "%5", "api:0.4", "api:0.3")])

      expect(store.binding_for("%5")).to include("id" => "wr_1", "pane_slot" => "api:0.3")
    end

    it "writes nothing when no binding moves" do
      expect(store.move([move("%5", "%1", "api:0.1")])).to eq({})
      expect(store.move([])).to eq({})
      expect(File.exist?(path)).to be(false)
    end

    it "leaves a corrupt file alone" do
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, "{not json")

      expect(store.move([move("%5", "%1", "api:0.1")])).to eq({})
      expect(File.read(path)).to eq("{not json")
    end
  end
end
