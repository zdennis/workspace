require "spec_helper"

# The same examples run against the real Pane (over a FakeTmux) and the FakePane, so the fake
# cannot drift from what the desks will be given.
RSpec.shared_examples "a pane" do
  it "captures the plain and the styled screen" do
    expect(pane.capture).to eq("plain")
    expect(pane.capture_styled).to eq("styled")
  end

  it "takes a delivery and a key" do
    expect(pane.deliver("hi", enter: false).status).to eq(:submitted)
    expect(pane.deliver("go").ok?).to be(true)
    expect(pane.send_key("C-u")).to be(true)
  end

  it "describes itself" do
    expect(pane.id).to eq("%5")
    expect(pane.details).to include(id: "%5", pid: 77)
    expect(pane.server_pid).to eq("900")
    expect(pane.start_command).to eq("claude --x")
    expect(pane.session_gone?).to be(false)
  end
end

RSpec.shared_examples "a pane factory" do
  it "answers the pane, :gone or :unlisted" do
    expect(listing.call("%5").id).to eq("%5")
    expect(listing.call("five")).to eq(:gone)
    expect(listing.call(nil)).to eq(:gone)
    expect(empty.call("%5")).to eq(:unlisted)
    expect(empty.call("five")).to eq(:unlisted)
  end

  it "builds the pane of a pane id without listing, :gone for anything else" do
    expect(empty.for("%5").id).to eq("%5")
    expect(listing.for("%5").id).to eq("%5")
    expect(listing.for("five")).to eq(:gone)
    expect(listing.for(nil)).to eq(:gone)
  end
end

RSpec.describe "Pane contract" do
  let(:row) { {id: "%5", window: 0, index: 1, pid: 77} }
  let(:options) do
    {screens: ["plain"], styled_screens: ["styled"], server_pid: "900", details: [row],
     start_commands: [{window: 0, index: 1, id: "%5", start_command: "claude --x"}]}
  end

  describe Workspace::Pane do
    it_behaves_like "a pane" do
      let(:pane) { Workspace::PaneFactory.new(tmux: FakeTmux.new(**options), session_name: "app").call("%5") }
    end
  end

  describe FakePane do
    it_behaves_like "a pane" do
      let(:pane) { FakePane.new(id: "%5", row: row, start_command: "claude --x", **options.except(:details, :start_commands)) }
    end

    it "records what the desks typed and pressed" do
      pane = FakePane.new(id: "%5")
      pane.deliver("hi", enter: false)
      pane.send_key("C-u")
      expect(pane.deliveries).to eq([{text: "hi", enter: false}])
      expect(pane.keys).to eq(["C-u"])
    end
  end

  describe Workspace::PaneFactory do
    it_behaves_like "a pane factory" do
      let(:listing) { described_class.new(tmux: FakeTmux.new(details: [row]), session_name: "app") }
      let(:empty) { described_class.new(tmux: FakeTmux.new(details: []), session_name: "app") }
    end
  end

  describe FakePaneFactory do
    it_behaves_like "a pane factory" do
      let(:listing) { described_class.new(panes: [FakePane.new(id: "%5")]) }
      let(:empty) { described_class.new(unlisted: true) }
    end
  end
end
