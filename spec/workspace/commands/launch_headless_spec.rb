require "tmpdir"

RSpec.describe Workspace::Commands::Launch, "headless" do
  let(:tmpdir) { Dir.mktmpdir }
  let(:config) { Workspace::Config.new(workspace_dir: tmpdir) }
  let(:state) do
    allow(config).to receive(:state_file).and_return(File.join(tmpdir, "state.json"))
    allow(config).to receive(:event_log_file).and_return(File.join(tmpdir, "events.jsonl"))
    Workspace::State.new(config: config, event_log: Workspace::EventLog.new(config: config))
  end
  let(:output) { StringIO.new }
  let(:error_output) { StringIO.new }
  # Plain doubles with nothing stubbed: any iTerm2, window or layout call fails the example.
  let(:iterm) { double("iterm") }
  let(:window_manager) { double("window_manager") }
  let(:window_layout) { double("window_layout") }
  let(:tmux) { double("tmux", start_server: nil, rename_window: nil) }
  let(:project_config) { double("project_config", exists?: true) }
  let(:pipeline_config) { double("pipeline_config", stages_for: nil, literal_sentinel_warnings: []) }
  let(:agent_readiness) { instance_double(Workspace::AgentReadiness, deadline_in: 60.0) }

  subject(:command) do
    described_class.new(state: state, iterm: iterm, window_manager: window_manager, tmux: tmux,
      project_config: project_config, window_layout: window_layout, config: config,
      pipeline_config: pipeline_config, agent_readiness: agent_readiness, prompt_timeout: 60,
      sleeper: ->(_seconds) {}, output: output, error_output: error_output)
  end

  before do
    allow(config).to receive(:agent_running?).and_return(true)
    allow(tmux).to receive(:session_name_for) { |project| "tmux-#{project}" }
  end

  after { FileUtils.rm_rf(tmpdir) }

  it "starts each session with tmuxinator in the background and records it as headless" do
    allow(tmux).to receive(:sessions).and_return([], ["tmux-proj1"])
    allow(tmux).to receive(:start_headless).with("proj1").and_return(nil)

    result = command.call(["proj1"], headless: true)

    expect(result).to include(exit_code: 0, headless: true, reused: [], start_failures: {})
    expect(tmux).to have_received(:start_headless).with("proj1")
    state.load
    expect(state["proj1"]).to eq("headless" => true)
    expect(output.string).to include("Attach with: tmux attach -t tmux-proj1")
  end

  it "reuses a session that is already running instead of starting it again" do
    allow(tmux).to receive(:sessions).and_return(["tmux-proj1"])
    allow(tmux).to receive(:start_headless)

    result = command.call(["proj1"], headless: true)

    expect(tmux).not_to have_received(:start_headless)
    expect(result[:reused]).to eq(["proj1"])
    expect(output.string).to include("Session tmux-proj1 is already running for proj1; reusing it.")
  end

  it "keeps the state entry of a running session it reuses, so its iTerm window stays known" do
    state["proj1"] = {"unique_id" => "uid-1", "iterm_window_id" => 7}
    state.save
    allow(tmux).to receive(:sessions).and_return(["tmux-proj1"])

    command.call(["proj1"], headless: true)

    state.load
    expect(state["proj1"]).to eq("unique_id" => "uid-1", "iterm_window_id" => 7)
  end

  it "exits 1 and leaves state alone for a project whose session can't be started" do
    allow(tmux).to receive(:sessions).and_return([])
    allow(tmux).to receive(:start_headless).with("proj1").and_return("tmuxinator exited 1: boom")

    result = command.call(["proj1"], headless: true, prompts: {"proj1" => "go"})

    expect(result).to include(exit_code: 1, start_failures: {"proj1" => "tmuxinator exited 1: boom"}, prompt_failures: {})
    expect(error_output.string).to include("Error: could not start proj1: tmuxinator exited 1: boom")
    state.load
    expect(state["proj1"]).to be_nil
  end

  it "sends --prompt through the same readiness wait and delivery as an iTerm launch" do
    allow(tmux).to receive(:sessions).and_return(["tmux-proj1"])
    allow(agent_readiness).to receive(:wait)
      .and_return(Workspace::AgentReadiness::Result.new(ready: true, pane: "0.1", label: "Claude Code"))
    allow(tmux).to receive(:deliver).and_return(Workspace::Tmux::Delivery.new(status: :submitted, message: "ok"))

    result = command.call(["proj1"], headless: true, prompts: {"proj1" => "do it"})

    expect(result[:exit_code]).to eq(0)
    expect(agent_readiness).to have_received(:wait).with("tmux-proj1", deadline: 60.0)
    expect(tmux).to have_received(:deliver).with("tmux-proj1", "0.1", "do it")
  end

  it "prints nothing on stdout when quiet" do
    allow(tmux).to receive(:sessions).and_return(["tmux-proj1"])

    command.call(["proj1"], headless: true, quiet: true)

    expect(output.string).to eq("")
  end
end
