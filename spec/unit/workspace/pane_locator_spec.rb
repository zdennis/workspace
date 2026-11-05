RSpec.describe Workspace::PaneLocator do
  let(:tmux) do
    CLITestHelpers::FakeTmuxServer.new(
      "api" => [{id: "%3", window: 0, index: 0}, {id: "%19", window: 1, index: 2}],
      "web" => [{id: "%7", window: 0, index: 0}]
    )
  end
  let(:locator) { described_class.new(tmux: tmux) }

  def error_for(spec, project: "api")
    locator.locate(project, spec)
    nil
  rescue Workspace::Error => e
    e
  end

  it "finds a pane by id anywhere in the session" do
    expect(locator.locate("api", "%19")).to include(id: "%19", window: 1, index: 2, session: "api")
  end

  it "finds a pane by window.pane" do
    expect(locator.locate("api", "1.2")).to include(id: "%19", session: "api")
  end

  it "trims surrounding space" do
    expect(locator.locate("api", " %3 ")).to include(id: "%3")
  end

  it "refuses a pane id that belongs to another session" do
    error = error_for("%7")

    expect(error.code).to eq("wrong_session")
    expect(error.details).to include("pane" => "%7", "session" => "api")
    expect(error.message).to include("'web'")
  end

  it "reports a pane id that exists nowhere as no_such_pane" do
    expect(error_for("%99").code).to eq("no_such_pane")
  end

  it "reports a window.pane with no pane as no_such_pane" do
    expect(error_for("0.5").code).to eq("no_such_pane")
  end

  it "does not look in another window for a bare index" do
    expect(error_for("2").code).to eq("bad_pane")
  end

  %w[bottom Claude 0 %x %19x 0.1.2 -1].each do |spec|
    it "refuses #{spec.inspect} as bad_pane" do
      expect(error_for(spec).code).to eq("bad_pane")
    end
  end

  it "refuses a blank pane" do
    expect(error_for("").code).to eq("bad_pane")
    expect(error_for(nil).code).to eq("bad_pane")
  end

  it "reports a workspace with no tmux session as no_session" do
    error = error_for("%3", project: "gone")

    expect(error.code).to eq("no_session")
    expect(error.message).to include("workspace launch gone")
  end

  it "checks the form before it touches tmux" do
    allow(tmux).to receive(:sessions).and_call_original

    error_for("bottom")

    expect(tmux).not_to have_received(:sessions)
  end
end
