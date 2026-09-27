require "spec_helper"
require "tmpdir"

# Adversarial CLI/UX probes against a3d00ff (concurrent `lock clear` marker)
# and ba4aef7 (WorkspaceLineage.name_from_path extraction). Each `it` is
# tagged CU<N> and documents one confirmed defect found while probing the
# in-progress `clear` case for --json support, human `status` visibility,
# and help-text accuracy.
RSpec.describe "lock clear adversarial CLI probes" do
  let(:output) { StringIO.new }
  let(:error_output) { StringIO.new }
  let(:tmpdir) { Dir.mktmpdir("ws-lock-cli-adversarial") }
  let(:config) { Workspace::Config.new }
  let(:lock_namespace) { instance_double(Workspace::LockNamespace) }
  let(:liveness) { Workspace::LockHolder.new }
  let(:terminator) { instance_double(Workspace::ProcessGroupTerminator) }
  let(:mono) { [0] }
  let(:mono_clock) { double("clock").tap { |c| allow(c).to receive(:now) { mono[0] } } }

  after { FileUtils.remove_entry(tmpdir) if File.directory?(tmpdir) }

  before do
    allow(lock_namespace).to receive(:resolve).and_return(key: "ns", display: "app", dir: tmpdir)
  end

  def hold_devenv
    store = Workspace::LockStore.new(dir: tmpdir, liveness: FakeLockLiveness.new)
    store.acquire("devenv", identity: {kind: "process", pid: 4242, started: "start-4242", pgid: 4242, worktree: "/w/login", branch: "login"},
      waiter_pid: 4242, waiter_started: "start-4242")
  end

  def clear_command(pid: 999, out: output, err: error_output)
    Workspace::Commands::Lock.new(config: config, lock_namespace: lock_namespace, lock_holder: FakeLockIdentity.new(pid: pid),
      output: out, error_output: err, terminator: terminator, clock: mono_clock, trap: ->(*) {}, pid_provider: -> { pid },
      sleeper: ->(seconds) { mono[0] += seconds })
  end

  # CU1: the in-progress `clear` case never gets a chance to honor the
  # documented --json error contract, because `lock clear` accepts no
  # --json flag at all. A caller scripting against locks (per the README's
  # "a caller that always passes --json" guidance for status/dev status)
  # gets plain stderr text and no machine-readable signal for this outcome.
  it "CU1: lock clear has no --json flag, so the in-progress outcome can't be reported as JSON" do
    cli_source = File.read(File.join(__dir__, "..", "..", "lib", "workspace", "cli.rb"))
    clear_method = cli_source[/def cmd_lock_clear.*?\n    end\n/m]

    expect(clear_method).to include("--json"),
      "expected `workspace lock clear` to accept --json like `lock status`/`dev status` do, " \
      "so the already-being-cleared case (and every other clear outcome) can be consumed by scripts " \
      "without scraping stderr text"
  end

  # CU2: the human-readable `workspace lock status` output never shows the
  # `clearing` marker, even though the in-progress message tells the user to
  # "check the result with: workspace lock status devenv". Only --json
  # exposes it (buried in the holder hash), so a human following that exact
  # advice sees no difference from an ordinary kept/held lock.
  it "CU2: human `lock status` output does not surface the clearing marker it tells users to check" do
    hold_devenv
    clearer = clear_command(pid: 998)
    status_out = nil
    allow(terminator).to receive(:stop_holder) do
      # While the first clear is still "stopping" the group (mid-clear),
      # take a human `lock status` reading — the moment the in-progress
      # message tells a second caller to check.
      status_out = StringIO.new
      status_command = Workspace::Commands::Lock.new(config: config, lock_namespace: lock_namespace,
        lock_holder: FakeLockIdentity.new(pid: 1), output: status_out, error_output: StringIO.new,
        terminator: terminator, trap: ->(*) {})
      status_command.status("devenv")
      :terminated
    end

    clearer.clear("devenv")

    expect(status_out.string).to include("CLEARING"),
      "human `lock status` printed #{status_out.string.inspect} while a clear was in progress; " \
      "the in-progress stderr message directs users to `workspace lock status <name>` but the human " \
      "view gives no indication a clear is under way"
  end

  # CU3: the CLI help text's exit-code note (cli.rb `lock_help`, ~line 810)
  # was not updated for the new "already being cleared" exit-1 case that
  # a3d00ff introduced; it still only mentions the process-group-could-not-
  # be-stopped case.
  it "CU3: lock help's exit-code note omits the already-being-cleared case" do
    cli_source = File.read(File.join(__dir__, "..", "..", "lib", "workspace", "cli.rb"))
    help_text = cli_source[/def lock_help.*?HELP\n    end\n/m] || cli_source

    note = help_text[/Note: `lock release`.*?exit codes above\./m]

    expect(note).to include("already being cleared"),
      "the exit-code note documents only the process-group-not-stopped reason for `clear`'s exit 1; " \
      "it should also mention the already-being-cleared-by-another-clear case added in a3d00ff"
  end
end
