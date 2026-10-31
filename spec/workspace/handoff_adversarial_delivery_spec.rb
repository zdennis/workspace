require "spec_helper"
require "tmpdir"
require "socket"

# Adversarial coverage for `workspace handoff check|new`'s delivery and
# daemon-reply handling. See AGENT-CONTEXT-RESEARCH.md for the behavior
# spec this probes against. Each `it` here is a confirmed defect, not a
# speculative risk -- every one fails against current lib/workspace code
# for the reason stated in its description.
RSpec.describe Workspace::Commands::Handoff do
  # Unix socket paths cap at 104 bytes on macOS, so stay under /tmp directly.
  let(:tmpdir) { Dir.mktmpdir("ws-handoff-adv", "/tmp") }
  let(:socket_path) { File.join(tmpdir, "workspace-myapp.sock") }
  let(:config) { instance_double(Workspace::Config, agent_socket_path: socket_path) }
  let(:tmux) { instance_double(Workspace::Tmux) }
  # Stands in for the workspace's own tmux session "myapp": a pane id is
  # found as given, and "window.pane" is the pane whose id ends in that index.
  let(:locator) { instance_double(Workspace::PaneLocator) }
  let(:handoff_config) { instance_double(Workspace::HandoffConfig) }
  let(:restart_agent_command) { instance_double(Workspace::Commands::RestartAgent) }
  let(:notes) { instance_double(Workspace::Commands::Notes) }
  let(:binder) { instance_double(Workspace::Commands::Binding, live: nil, bind: {}) }
  let(:library) { instance_double(Workspace::Library) }
  let(:notes_dir) { "/notes/myapp" }
  let(:output) { StringIO.new }
  let(:error_output) { StringIO.new }

  subject(:command) do
    described_class.new(config: config, tmux: tmux, locator: locator, handoff_config: handoff_config,
      restart_agent_command: restart_agent_command, notes: notes, binder: binder, library: library, output: output, error_output: error_output)
  end

  let(:defaults) { {threshold: 11, check_prompt: nil, resume_prompt: nil} }

  before do
    allow(notes).to receive(:info).and_return({"dir" => notes_dir})
    allow(handoff_config).to receive(:for_workspace).and_return(defaults)
    allow(tmux).to receive(:session_name_for).with("myapp").and_return("myapp")
    allow(locator).to receive(:locate) do |_name, spec|
      {id: spec.start_with?("%") ? spec : "%#{spec.split(".").last}", session: "myapp"}
    end
  end

  after { FileUtils.remove_entry(tmpdir) }

  # Answers one "sessions" request with a raw string body (bypassing the
  # {panes:} shape the daemon is documented to send) and closes.
  def with_raw_reply(body)
    File.delete(socket_path) if File.exist?(socket_path)
    server = UNIXServer.new(socket_path)
    thread = Thread.new do
      client = server.accept
      client.gets
      client.puts(body)
      client.close
    end
    yield
  ensure
    thread&.join(2)
    thread&.kill
    server&.close
  end

  let(:claude_pane) { {"index" => 1, "pane_id" => "%1", "kind" => "claude", "context_pct" => 42, "context_error" => nil} }

  it "HD1: reports the existing malformed-reply outcome, not a bare NoMethodError, when the daemon's reply parses as JSON but isn't the documented {panes:} object" do
    result = nil
    expect {
      with_raw_reply("null") { result = command.check(name: "myapp") }
    }.not_to raise_error

    expect(result).to eq(exit_code: 2)
    expect(error_output.string).to match(/malformed reply/)
  end

  it "HD2: guards handoff.resume_prompt the same way check guards handoff.check_prompt, instead of crashing `new` on a stray %" do
    allow(handoff_config).to receive(:for_workspace).with("myapp")
      .and_return(defaults.merge(resume_prompt: "50% done, resume %{doc}"))
    allow(restart_agent_command).to receive(:call).and_return({exit_code: 0})

    expect {
      command.new(name: "myapp", pane: "1", handoff_doc: "HANDOFF.md")
    }.not_to raise_error

    expect(error_output.string).to match(/invalid prompt template/i)
    expect(restart_agent_command).to have_received(:call)
      .with(hash_including(prompt: a_string_matching(/HANDOFF\.md/)))
  end

  it "HD3: reports a tmux delivery failure (Tmux#deliver raising) as a handled error, not a propagated exception with a backtrace" do
    allow(tmux).to receive(:deliver).and_raise(Errno::ENOENT, "tmux")

    result = nil
    expect {
      with_raw_reply({"panes" => [claude_pane]}.to_json) { result = command.check(name: "myapp") }
    }.not_to raise_error

    expect(result).to eq(exit_code: 1)
    expect(output.string).to match(/handoff_send_failed|failed to deliver/)
  end

  it "HD4: rejects an out-of-range --threshold instead of silently treating a negative threshold as always-over" do
    allow(tmux).to receive(:deliver).and_return(Workspace::Tmux::Delivery.new(status: :submitted))

    # The threshold is refused before the daemon is asked, so no socket server is
    # started: with_raw_reply would wait out its 2s join for a connection that never comes.
    expect {
      command.check(name: "myapp", threshold: -10)
    }.to raise_error(Workspace::UsageError, /threshold/)
    expect(tmux).not_to have_received(:deliver)
  end

  it "HD5: guards handoff.followup_prompt like check_prompt, so a stray % in it neither crashes check nor changes its exit code" do
    stub_const("Workspace::Commands::Handoff::FOLLOWUP_REPLY_WAIT", 0.1)
    allow(tmux).to receive(:deliver).and_return(Workspace::Tmux::Delivery.new(status: :submitted))
    allow(handoff_config).to receive(:for_workspace).and_return(
      defaults.merge(followup_interval: 30, followup_max: 10, followup_prompt: "100% sure, run %{oops}")
    )

    result = nil
    expect {
      with_raw_reply({"panes" => [claude_pane]}.to_json) { result = command.check(name: "myapp", handoff_doc: "HANDOFF.md") }
    }.not_to raise_error

    expect(result).to eq(exit_code: 1)
    expect(error_output.string).to match(/invalid prompt template/i)
  end
end
