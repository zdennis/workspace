require "spec_helper"
require "tmpdir"
require "socket"

# Adversarial CLI-facing coverage for `workspace agent-run restart` /
# restart_agent, on top of spec/workspace/commands/restart_agent_spec.rb and
# spec/workspace/commands/agent_restart_message_spec.rb. Each `it` documents
# one confirmed defect, tagged with an ID (see H2 review notes).
RSpec.describe "agent-run restart adversarial CLI behavior" do
  # Unix socket paths cap at 104 bytes on macOS, so stay under /tmp directly.
  let(:tmpdir) { Dir.mktmpdir("ws-restart-adv", "/tmp") }
  let(:socket_path) { File.join(tmpdir, "workspace-myapp.sock") }
  let(:config) { instance_double(Workspace::Config, agent_socket_path: socket_path) }
  let(:output) { StringIO.new }

  subject(:command) { Workspace::Commands::RestartAgent.new(config: config, output: output) }

  after { FileUtils.remove_entry(tmpdir) if File.directory?(tmpdir) }

  def call(**opts)
    command.call(name: "myapp", pane: "%18", prompt: "Read HANDOFF.md", json: true, **opts)
  end

  # U1: docs/README.agent-run.md:78 promises the --json error contract is
  # always `{"schema_version":1,"error":"<message>","code":"<daemon error
  # code>",...}`. That "code" key is only set when a daemon actually replied
  # with ok:false (RestartAgent#failure). Every connection-level failure
  # (no daemon, daemon closes without replying, unreadable reply) is raised
  # as a bare Workspace::Error and caught by the generic rescue in
  # RestartAgent#call (lib/workspace/commands/restart_agent.rb:48-52), which
  # never emits "code". A script parsing `code` per the documented contract
  # gets a silent nil instead of a usage error, for the very failures a
  # --wait caller is most likely to hit (daemon crashed mid-restart).
  it "U1: omits the documented 'code' key when no daemon is listening" do
    result = call

    expect(result).to eq(exit_code: 1)
    payload = JSON.parse(output.string)
    expect(payload["error"]).to include("No agent daemon for 'myapp'")
    expect(payload).to have_key("code"), "expected the documented {\"code\": ...} field; got #{payload.inspect}"
  end

  it "U1: omits the documented 'code' key when the daemon closes without replying" do
    server = UNIXServer.new(socket_path)
    thread = Thread.new do
      client = server.accept
      client.gets
      client.close # hang up without a reply, as a crashing worker thread would
    end

    result = call
    thread.join(2)
    server.close

    expect(result).to eq(exit_code: 1)
    payload = JSON.parse(output.string)
    expect(payload["error"]).to include("closed the connection without replying")
    expect(payload).to have_key("code"), "expected the documented {\"code\": ...} field; got #{payload.inspect}"
  end

  it "U1: omits the documented 'code' key when the daemon's reply isn't JSON" do
    server = UNIXServer.new(socket_path)
    thread = Thread.new do
      client = server.accept
      client.gets
      client.puts("not json")
      client.close
    end

    result = call
    thread.join(2)
    server.close

    expect(result).to eq(exit_code: 1)
    payload = JSON.parse(output.string)
    expect(payload["error"]).to include("Unreadable reply")
    expect(payload).to have_key("code"), "expected the documented {\"code\": ...} field; got #{payload.inspect}"
  end

  # U2: the daemon waits up to AgentRestart::QUIET_TIMEOUT (120s, fixed) for
  # the pane to go quiet before it ever types /clear. --timeout only bounds
  # the later "confirm the drop" wait (AgentRestart#call passes it through as
  # confirm_timeout). Neither `workspace agent-run restart --help` nor
  # docs/README.agent-run.md says a word about that first 120s wait, so a
  # caller who passes --timeout 5 expecting a 5s cap can still block for two
  # full minutes with no way to shorten it, and no documentation warns them.
  it "U2: neither the CLI's --help text nor the docs mention the fixed pane-quiet wait before --timeout applies" do
    cli_source = File.read(File.join(__dir__, "..", "..", "lib", "workspace", "cli.rb"))
    restart_help_source = cli_source[/def cmd_agent_run_restart.*?\n    end\n/m]
    docs = File.read(File.join(__dir__, "..", "..", "docs", "README.agent-run.md"))

    quiet_number = Regexp.new(Workspace::AgentRestart::QUIET_TIMEOUT.to_s)
    mentions_quiet_bound = ->(text) { quiet_number.match?(text) }

    expect(mentions_quiet_bound.call(restart_help_source) || mentions_quiet_bound.call(docs)).to be(true),
      "expected the restart subcommand's --help text (its opts.separator/opts.on strings in cli.rb) or " \
      "docs/README.agent-run.md to state that the initial \"go quiet\" wait is fixed at " \
      "#{Workspace::AgentRestart::QUIET_TIMEOUT}s and is NOT bounded by --timeout (which only covers the " \
      "confirm-the-drop step); both currently say only that the daemon \"waits for the pane to go quiet\" " \
      "with no duration or caveat"
  end

  # U3: /clear (AgentRestart::CLEAR_COMMAND, lib/workspace/agent_restart.rb:18)
  # is Claude Code's own slash command. The daemon's only pane-type guard
  # (lib/workspace/commands/agent.rb:410) rejects a "shell" pane but accepts
  # anything else, including a non-Claude provider like codex
  # (lib/workspace/agent_provider.rb:69-71). A restart_agent message aimed at
  # a codex pane is accepted and will type a Claude-only slash command into
  # an agent that doesn't understand it.
  it "U3: accepts a restart_agent for a pane running a non-Claude provider (codex), though /clear is Claude-only" do
    tmux = AgentRestartAdversarialFakeTmux.new
    monitor = AgentRestartAdversarialFakeMonitor.new("%18" => "codex")
    restart = AgentRestartAdversarialGatedRestart.new({"ok" => true, "status" => "restarted", "pane_id" => "%18"})
    config = instance_double(Workspace::Config).tap do |c|
      allow(c).to receive(:agent_socket_path).with("myapp").and_return(socket_path)
      allow(c).to receive(:project_config_path).with("myapp").and_return(File.join(tmpdir, "myapp.yml"))
      allow(c).to receive(:pipeline_state_path).and_return(File.join(tmpdir, "pipeline.json"))
    end
    coordinator_client = instance_double(Workspace::WorkCoordinatorClient, register: {"ok" => true, "epoch" => "e"},
      deregister: nil, status_socket_path: nil)
    pipeline_config = Workspace::PipelineConfig.new(config: config)
    context_reader = instance_double(Workspace::ContextReader).tap do |reader|
      allow(reader).to receive(:read).and_return({pct: 42, error: nil, updated_at: "2026-09-27T12:00:00Z"})
    end
    signal_trapper = Class.new {
      attr_reader :handlers

      def initialize = @handlers = {}

      def trap(signal, &block) = @handlers[signal] = block
    }.new
    output = StringIO.new
    error_output = StringIO.new

    agent = Workspace::Commands::Agent.new(config: config, tmux: tmux, work_coordinator_client: coordinator_client,
      pipeline_config: pipeline_config, signal_trapper: signal_trapper,
      session_monitor_factory: ->(_name) { monitor }, context_reader: context_reader,
      agent_restart_factory: restart.method(:build), output: output, error_output: error_output)

    thread = Thread.new { agent.call(name: "myapp") }
    deadline = Time.now + 2
    sleep(0.01) until output.string.include?("ready") || Time.now > deadline

    reply = UNIXSocket.open(socket_path) do |socket|
      socket.puts({"type" => "restart_agent", "workspace" => "myapp", "pane" => "%18",
                   "prompt" => "Read HANDOFF.md"}.to_json)
      JSON.parse(socket.gets)
    end

    expect(reply["ok"]).to be(false),
      "expected a codex pane to be refused before typing a Claude-only /clear, but the daemon accepted it: #{reply.inspect}"
  ensure
    restart&.finish
    signal_trapper&.handlers&.[]("TERM")&.call
    thread&.join(2)
    thread&.kill
  end
end

class AgentRestartAdversarialFakeTmux < CLITestHelpers::FakeTmux
  def initialize
    super
    @details = [{id: "%18", window: 0, index: 1, pid: 2, command: "codex", cwd: "/", title: ""}]
  end

  def session_name_for(_config) = "workspace-wt-myapp"

  def pane_details(_session, window: "0")
    window.nil? ? @details : @details.select { |d| d[:window] == window.to_i }
  end
end

class AgentRestartAdversarialFakeMonitor
  def initialize(kinds) = @kinds = kinds
  def start = nil
  def stop = nil
  def snapshot = {"panes" => []}
  def pane_kind(id) = @kinds[id]
  def agent_pid(_id) = nil
  def pane_state(_id) = "idle"
end

# Records what it was asked to do and finishes when the spec says so, so the
# worker thread doesn't race the assertions.
class AgentRestartAdversarialGatedRestart
  attr_reader :calls, :built_with

  def initialize(result)
    @result = result
    @calls = Queue.new
    @gate = Queue.new
  end

  def build(**kwargs)
    @built_with = kwargs
    self
  end

  def call(**kwargs)
    @calls << kwargs
    @gate.pop
    @result
  end

  def finish = @gate << :go
end
