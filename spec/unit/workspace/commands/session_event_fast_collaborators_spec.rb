require "spec_helper"
require "json"
require "stringio"
require "tmpdir"

# The fast entry builds the command with no instruction composer and no permission policy, so
# every event {Commands::SessionEvent.full_wiring?} leaves on the fast path must never reach the
# collaborators only the whole CLI gives it. A hook newly gated on one of them that full_wiring?
# does not name fails here.
RSpec.describe Workspace::Commands::SessionEvent, "events the fast entry serves" do
  let(:tmpdir) { Dir.mktmpdir }
  let(:calls) { [] }
  let(:tripwire) do
    Class.new(BasicObject) do
      def initialize(calls, name)
        @calls = calls
        @name = name
      end

      def method_missing(method, *_args, **_kwargs)
        @calls << [@name, method]
        ::Kernel.raise "#{@name}.#{method} called on the fast path"
      end

      def respond_to_missing?(*) = true
    end
  end
  let(:config) { instance_double(Workspace::Config, agent_socket_path: File.join(tmpdir, "none.sock")) }
  let(:tmux) do
    instance_double(Workspace::Tmux, session_name_for_pane: "proj", pane_slot: "proj:0.0", server_pid_for_pane: "1", pane_layout: nil)
  end
  let(:pane_bindings) do
    entry = {"kind" => "run", "id" => "wr_1", "session" => "proj", "packs" => ["p"]}
    instance_double(Workspace::PaneBindings, binding_for: entry, stale?: false, packs_for: ["p"], context_for: "bound")
  end

  after { FileUtils.remove_entry(tmpdir) }

  def run(hook, agent)
    payload = {"hook_event_name" => hook, "session_id" => "s1", "source" => "clear", "reason" => "exit", "cwd" => tmpdir,
               "tool_name" => "Bash", "tool_input" => {"command" => "ls"}, "message" => "m"}
    described_class.new(config: config, tmux: tmux, input: StringIO.new(JSON.generate(payload)), env: {"TMUX_PANE" => "%1"},
      output: StringIO.new, error_output: StringIO.new, pane_bindings: pane_bindings,
      workspace_for_session: ->(_session) { "proj" }, session_ambiguous: ->(_session) { false },
      instruction_composer: tripwire.new(calls, "instruction_composer"),
      permission_policy_config: tripwire.new(calls, "permission_policy_config"), hang_guard_counter: Class.new(tripwire) { def clear_pane(_pane_id) = nil }.new(calls, "hang_guard_counter"),
      dev_session_release: tripwire.new(calls, "dev_session_release")).call(agent: agent)
  end

  {"claude" => described_class::CLAUDE_EVENTS, "codex" => described_class::CODEX_EVENTS}.each do |agent, table|
    table.each_key do |hook|
      next if described_class.full_wiring?(JSON.generate("hook_event_name" => hook), agent)

      it "never calls the whole CLI's collaborators for #{agent}'s #{hook}" do
        run(hook, agent)

        expect(calls).to eq([])
      end
    end
  end

  it "catches a call to the permission policy, as a PermissionRequest shows" do
    run("PermissionRequest", "claude")

    expect(calls).to include(["permission_policy_config", :policy])
  end

  it "catches a call to the instruction composer, as a SessionStart in a bound pane shows" do
    run("SessionStart", "claude")

    expect(calls).to include(["instruction_composer", :compose])
  end

  it "catches a call to the dev release, as a SessionEnd shows" do
    expect { run("SessionEnd", "claude") }.to raise_error(RuntimeError, /dev_session_release.call/)

    expect(calls).to include(["dev_session_release", :call])
  end
end
