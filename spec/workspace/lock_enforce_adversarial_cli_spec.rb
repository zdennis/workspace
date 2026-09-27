require "spec_helper"
require "tmpdir"

# Adversarial CLI/UX coverage for PR4 enforcement (`workspace session-event`
# denying an edit lock, and its outside-tmux/session behavior). Each `it`
# below proves one confirmed defect against the current implementation.
RSpec.describe "PR4 enforcement adversarial CLI cases" do
  let(:state_dir) { Dir.mktmpdir("ws-lock-enforce-adversarial") }
  let(:lock_dir) { File.join(state_dir, "locks") }
  let(:store_dir) { File.join(lock_dir, "app-ns") }
  let(:config) { instance_double(Workspace::Config, lock_dir: lock_dir) }
  let(:lock_namespace) { instance_double(Workspace::LockNamespace) }
  let(:tmux) { instance_double(Workspace::Tmux) }

  let(:holder_agent) { FakeLockIdentity.new(pid: 100, pane: "%1", worktree: "app") }
  let(:other_agent) { FakeLockIdentity.new(pid: 200, pane: "%2", worktree: "app.worktree-b") }

  after { FileUtils.remove_entry(state_dir) }

  before do
    allow(lock_namespace).to receive(:resolve).and_return(key: "ns", display: "app", dir: store_dir)
  end

  def hold(identity, task: nil)
    id = identity.current
    Workspace::LockStore.new(dir: store_dir, liveness: identity)
      .acquire("edit", identity: id, waiter_pid: id[:pid], waiter_started: id[:started], task: task)
  end

  def enforcer(lock_holder:)
    Workspace::LockEnforcer.new(config: config, lock_namespace: lock_namespace, lock_holder: lock_holder)
  end

  # EU1: regression guard — enforcement deliberately applies outside tmux
  # (holder identity resolves by pid even outside a tmux pane)
  it "EU1: denies an edit outside tmux when another agent holds the edit lock" do
    hold(holder_agent, task: "PROJ-12")

    env = {} # no TMUX_PANE
    error_output = StringIO.new
    command = Workspace::Commands::SessionEvent.new(
      config: config, tmux: tmux, env: env,
      input: StringIO.new(JSON.generate("hook_event_name" => "PreToolUse", "tool_name" => "Edit", "cwd" => "/project")),
      error_output: error_output,
      lock_enforcer: enforcer(lock_holder: other_agent)
    )

    result = command.call

    expect(result[:exit_code]).to eq(2)
    expect(error_output.string).to include("Workspace edit lock held by")
  end
end
