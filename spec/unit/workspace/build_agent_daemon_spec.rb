require "spec_helper"

RSpec.describe "Workspace.build_agent_daemon" do
  let(:tmux) { FakeTmux.new }
  let(:config) { Workspace::Config.new }
  let(:pipeline_config) { RecordingPipelineConfig.new }
  let(:parts) do
    Workspace.build_agentd_parts(tmux: tmux, config: config, work_coordinator_client: RecordingCoordinatorClient.new,
      pipeline_config: pipeline_config, pipeline_state: RecordingPipelineState.new, session_monitor_factory: ->(_workspace) {},
      error_output: StringIO.new)
  end
  let(:reply) { StringIO.new }

  def build(**given)
    Workspace.build_agent_daemon(config: config, tmux: tmux, pipeline_config: pipeline_config, parts: parts,
      output: StringIO.new, error_output: StringIO.new, **given)
  end

  def replied = JSON.parse(reply.string.lines.last)

  it "serves the current_name it is given, routing its messages" do
    build(current_name: "myapp").handle(Workspace::AgentProtocol.version(workspace: "myapp"), reply)

    expect(replied).to eq("ok" => true, "version" => Workspace::VERSION)
  end

  it "serves no workspace without a current_name, refusing an addressed message" do
    build.handle(Workspace::AgentProtocol.version(workspace: "myapp"), reply)

    expect(replied).to eq("ok" => false, "error" => "wrong_workspace")
  end

  it "sends a command with no pipeline to the pane titled Claude Code in the workspace's session" do
    allow(tmux).to receive(:find_pane_by_title).with("myapp", "Claude Code", window: "0").and_return(2)

    build(current_name: "myapp").handle({"type" => "command", "workspace" => "myapp", "work_item_ref" => "WC-1",
                                         "dispatch_id" => "d-1", "body" => "do it"}, reply)

    expect(replied).to include("ok" => true)
    expect(tmux.delivered).to eq([{session: "myapp", target: "0.2", text: "do it"}])
  end
end
