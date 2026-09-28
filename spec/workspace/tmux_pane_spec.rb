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
      expect { described_class.new("0.1.2", tmux: tmux).resolve(session_name) }
        .to raise_error(Workspace::Error, /No pane matching/)
    end

    it "resolves a title substring" do
      allow(tmux).to receive(:panes).with(session_name, window: "0").and_return([0, 1])
      allow(tmux).to receive(:find_pane_by_title).with(session_name, "Claude Code", window: "0").and_return(1)
      expect(described_class.new("Claude Code", tmux: tmux).resolve(session_name)).to eq(1)
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
