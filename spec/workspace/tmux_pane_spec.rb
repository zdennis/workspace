require "spec_helper"

RSpec.describe Workspace::TmuxPane do
  let(:tmux) { instance_double(Workspace::Tmux) }
  let(:session_name) { "my-session" }

  describe "#resolve" do
    it "resolves nil to the last pane in the window" do
      allow(tmux).to receive(:panes).with(session_name, window: "0").and_return([0, 1, 2])
      expect(described_class.new(nil, tmux: tmux).resolve(session_name)).to eq(2)
    end

    it "resolves an integer index" do
      allow(tmux).to receive(:panes).with(session_name, window: "0").and_return([0, 1, 2])
      expect(described_class.new(1, tmux: tmux).resolve(session_name)).to eq(1)
    end

    it "resolves a bare digit string" do
      allow(tmux).to receive(:panes).with(session_name, window: "0").and_return([0, 1, 2])
      expect(described_class.new("1", tmux: tmux).resolve(session_name)).to eq(1)
    end

    it "resolves a window.pane string against the named window" do
      allow(tmux).to receive(:panes).with(session_name, window: "1").and_return([0, 1, 2])
      expect(described_class.new("1.2", tmux: tmux).resolve(session_name)).to eq(2)
    end

    it "raises when the window.pane pane index is out of range" do
      allow(tmux).to receive(:panes).with(session_name, window: "1").and_return([0, 1])
      expect { described_class.new("1.5", tmux: tmux).resolve(session_name) }
        .to raise_error(Workspace::Error, /Pane 5 does not exist/)
    end

    it "raises when the window.pane window has no panes" do
      allow(tmux).to receive(:panes).with(session_name, window: "3").and_return([])
      expect { described_class.new("3.0", tmux: tmux).resolve(session_name) }
        .to raise_error(Workspace::Error, /No panes found/)
    end

    it "treats a malformed dotted spec as a title substring, not window.pane" do
      allow(tmux).to receive(:panes).with(session_name, window: "0").and_return([0, 1])
      allow(tmux).to receive(:find_pane_by_title).with(session_name, "0.1.2", window: "0").and_return(nil)
      allow(tmux).to receive(:pane_details).with(session_name, window: "0").and_return([])
      expect { described_class.new("0.1.2", tmux: tmux).resolve(session_name) }
        .to raise_error(Workspace::Error, /No pane matching/)
    end

    it "resolves a title substring" do
      allow(tmux).to receive(:panes).with(session_name, window: "0").and_return([0, 1])
      allow(tmux).to receive(:find_pane_by_title).with(session_name, "Claude Code", window: "0").and_return(1)
      expect(described_class.new("Claude Code", tmux: tmux).resolve(session_name)).to eq(1)
    end

    context "when no raw pane title matches" do
      let(:process_tree) { instance_double(Workspace::ProcessTree, snapshot: :snapshot) }
      let(:providers) { Workspace::AgentProvider.all }
      let(:labels) { Workspace::AgentLabels.new(process_tree: process_tree, providers: providers) }
      let(:claude) { Workspace::AgentProvider.find("claude") }
      let(:codex) { Workspace::AgentProvider.find("codex") }
      let(:details) do
        [
          {id: "%9", window: 0, index: 0, pid: 100, command: "ruby", title: "banner"},
          {id: "%10", window: 0, index: 1, pid: 200, command: "2.1.302", title: "✳ Current work status"}
        ]
      end

      before do
        allow(tmux).to receive(:panes).with(session_name, window: "0").and_return([0, 1])
        allow(tmux).to receive(:find_pane_by_title).and_return(nil)
        allow(tmux).to receive(:pane_details).with(session_name, window: "0").and_return(details)
        allow(Workspace::AgentProvider).to receive(:detect) do |command:, providers:, **|
          provider = providers.find { |p| (command == "2.1.302") ? p.key == "claude" : p.executable == command }
          provider && {provider: provider, pid: 200}
        end
      end

      def pane(spec)
        described_class.new(spec, tmux: tmux, agent_labels: labels)
      end

      it "matches the agent label that `workspace sessions` shows in TITLE" do
        expect(pane("Claude Code").resolve(session_name)).to eq(1)
        expect(pane("Claude Code").target(session_name)).to eq("0.1")
      end

      it "names both searches in the error and points at `workspace sessions`" do
        expect { pane("Nope").resolve(session_name) }.to raise_error(
          Workspace::Error,
          "No pane matching \"Nope\" found in session 'my-session' (searched pane titles and agent labels; see `workspace sessions`)"
        )
      end

      it "reads a process table that cannot be read as no label match" do
        allow(process_tree).to receive(:snapshot).and_raise(Workspace::Error, "ps failed")
        expect { pane("Claude Code").resolve(session_name) }.to raise_error(Workspace::Error, /No pane matching/)
      end

      it "picks the lower index when two panes run Claude" do
        two = details + [{id: "%11", window: 0, index: 2, pid: 300, command: "2.1.302", title: "other"}]
        allow(tmux).to receive(:panes).with(session_name, window: "0").and_return([0, 1, 2])
        allow(tmux).to receive(:pane_details).with(session_name, window: "0").and_return(two.reverse)
        expect(pane("Claude Code").resolve(session_name)).to eq(1)
      end

      it "matches a Codex pane by its label" do
        allow(tmux).to receive(:pane_details).with(session_name, window: "0").and_return([
          {id: "%9", window: 0, index: 0, pid: 100, command: "zsh", title: "x"},
          {id: "%10", window: 0, index: 1, pid: 200, command: "codex", title: "y"}
        ])
        expect(pane("Codex").resolve(session_name)).to eq(1)
      end

      it "respects the configured providers" do
        only_codex = Workspace::AgentLabels.new(process_tree: process_tree, providers: [codex])
        resolver = described_class.new("Claude Code", tmux: tmux, agent_labels: only_codex)
        expect { resolver.resolve(session_name) }.to raise_error(Workspace::Error, /No pane matching/)
      end

      it "returns the same window.pane target form as a raw title match" do
        allow(tmux).to receive(:panes).with(session_name, window: "2").and_return([0, 1])
        allow(tmux).to receive(:pane_details).with(session_name, window: "2").and_return(details)
        expect(described_class.new("Claude Code", tmux: tmux, agent_labels: labels).target(session_name, window: "2")).to eq("2.1")
        allow(tmux).to receive(:find_pane_by_title).with(session_name, "banner", window: "2").and_return(0)
        expect(described_class.new("banner", tmux: tmux, agent_labels: labels).target(session_name, window: "2")).to eq("2.0")
      end

      it "does not search labels across windows when there is no window" do
        allow(tmux).to receive(:panes).with(session_name, window: nil).and_return([0, 1])
        allow(tmux).to receive(:find_pane_by_title).with(session_name, "Claude Code", window: nil).and_return(nil)
        expect(tmux).not_to receive(:pane_details)
        expect { pane("Claude Code").resolve(session_name, window: nil) }.to raise_error(Workspace::Error, /No pane matching/)
      end
    end

    context "with an AgentLabels double" do
      let(:agent_labels) { instance_double(Workspace::AgentLabels) }

      before { allow(tmux).to receive(:panes).with(session_name, window: "0").and_return([0, 1]) }

      it "lets a raw title match win and reads no agent labels" do
        allow(tmux).to receive(:find_pane_by_title).with(session_name, "Claude Code", window: "0").and_return(0)
        expect(agent_labels).not_to receive(:by_index)
        expect(tmux).not_to receive(:pane_details)
        expect(described_class.new("Claude Code", tmux: tmux, agent_labels: agent_labels).resolve(session_name)).to eq(0)
      end

      it "does not take a process snapshot when the window has no pane details" do
        process_tree = instance_double(Workspace::ProcessTree)
        expect(process_tree).not_to receive(:snapshot)
        labels = Workspace::AgentLabels.new(process_tree: process_tree)
        allow(tmux).to receive(:find_pane_by_title).and_return(nil)
        allow(tmux).to receive(:pane_details).with(session_name, window: "0").and_return([])
        expect { described_class.new("Claude Code", tmux: tmux, agent_labels: labels).resolve(session_name) }
          .to raise_error(Workspace::Error, /No pane matching/)
      end
    end

    it "resolves a tmux pane id searching the whole session" do
      allow(tmux).to receive(:pane_details).with(session_name, window: nil).and_return([
        {id: "%1", window: 0, index: 0},
        {id: "%19", window: 0, index: 1}
      ])
      expect(described_class.new("%19", tmux: tmux).resolve(session_name)).to eq(1)
    end

    it "resolves a tmux pane id in a non-default window" do
      allow(tmux).to receive(:pane_details).with(session_name, window: nil).and_return([
        {id: "%1", window: 0, index: 0},
        {id: "%19", window: 3, index: 2}
      ])
      expect(described_class.new("%19", tmux: tmux).resolve(session_name)).to eq(2)
    end

    it "raises when no pane with the given id exists in the session" do
      allow(tmux).to receive(:pane_details).with(session_name, window: nil).and_return([
        {id: "%1", window: 0, index: 0}
      ])
      expect { described_class.new("%99", tmux: tmux).resolve(session_name) }
        .to raise_error(Workspace::Error, "No pane with id %99 in session '#{session_name}'")
    end
  end

  describe "#resolve_id" do
    it "resolves an index spec to the pane's tmux pane id" do
      allow(tmux).to receive(:panes).with(session_name, window: "0").and_return([0, 1])
      allow(tmux).to receive(:pane_details).with(session_name, window: "0").and_return([
        {id: "%1", window: 0, index: 0},
        {id: "%19", window: 0, index: 1}
      ])
      expect(described_class.new(1, tmux: tmux).resolve_id(session_name)).to eq("%19")
    end

    it "resolves bottom to the last pane's id" do
      allow(tmux).to receive(:panes).with(session_name, window: "0").and_return([0, 1, 2])
      allow(tmux).to receive(:pane_details).with(session_name, window: "0").and_return([
        {id: "%1", window: 0, index: 1},
        {id: "%19", window: 0, index: 2}
      ])
      expect(described_class.new(nil, tmux: tmux).resolve_id(session_name)).to eq("%19")
    end

    it "resolves a window.pane spec against the named window" do
      allow(tmux).to receive(:panes).with(session_name, window: "3").and_return([0, 1])
      allow(tmux).to receive(:pane_details).with(session_name, window: "3").and_return([
        {id: "%1", window: 3, index: 0},
        {id: "%19", window: 3, index: 1}
      ])
      expect(described_class.new("3.1", tmux: tmux).resolve_id(session_name)).to eq("%19")
    end

    it "returns a pane-id spec unchanged" do
      expect(described_class.new("%19", tmux: tmux).resolve_id(session_name)).to eq("%19")
    end

    it "raises when the resolved pane has no detail entry" do
      allow(tmux).to receive(:panes).with(session_name, window: "0").and_return([0, 1])
      allow(tmux).to receive(:pane_details).with(session_name, window: "0").and_return([])
      expect { described_class.new(1, tmux: tmux).resolve_id(session_name) }
        .to raise_error(Workspace::Error, /No pane with index 1 in window 0/)
    end
  end

  describe "#target" do
    it "returns window.pane using the default window" do
      allow(tmux).to receive(:panes).with(session_name, window: "0").and_return([0, 1])
      expect(described_class.new(1, tmux: tmux).target(session_name)).to eq("0.1")
    end

    it "returns window.pane using the window embedded in the spec" do
      allow(tmux).to receive(:panes).with(session_name, window: "2").and_return([0, 1])
      expect(described_class.new("2.1", tmux: tmux).target(session_name)).to eq("2.1")
    end

    it "returns window.pane for a tmux pane id, using the pane's actual window" do
      allow(tmux).to receive(:pane_details).with(session_name, window: nil).and_return([
        {id: "%1", window: 0, index: 0},
        {id: "%19", window: 3, index: 2}
      ])
      expect(described_class.new("%19", tmux: tmux).target(session_name)).to eq("3.2")
    end

    it "raises when no pane with the given id exists in the session" do
      allow(tmux).to receive(:pane_details).with(session_name, window: nil).and_return([])
      expect { described_class.new("%5", tmux: tmux).target(session_name) }
        .to raise_error(Workspace::Error, "No pane with id %5 in session '#{session_name}'")
    end
  end
end
