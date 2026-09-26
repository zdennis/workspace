require "spec_helper"
require "stringio"

# Adversarial CLI coverage for PR3 (idle lock release, waiter takeover,
# locks.idle_grace config, `workspace lock instructions`). Each `it` pins one
# confirmed defect and is expected to FAIL until the defect is fixed.
RSpec.describe "PR3 adversarial findings" do
  def build_cli(output:, error_output:, lock_command: nil)
    placeholder = Object.new

    Workspace::CLI.new(
      config: placeholder, state: placeholder, project_config: placeholder, git: placeholder,
      window_manager: placeholder, doctor: placeholder, project_settings: placeholder,
      hook_runner: placeholder, project_detector: placeholder, launch_command: placeholder,
      kill_command: placeholder, start_command: placeholder, stop_command: placeholder,
      focus_command: placeholder, tile_command: placeholder, layout_command: placeholder,
      resize_command: placeholder, init_command: placeholder, repair_command: placeholder,
      cleanup_command: placeholder, prune_command: placeholder, claude_command: placeholder,
      lookup_command: placeholder, update_pane_command: placeholder, run_command: placeholder,
      run_result_store: placeholder, run_and_report_command: placeholder, capture_command: placeholder,
      lock_command: lock_command || placeholder, dev_command: placeholder, parent_command: placeholder,
      agent_command: placeholder, sessions_command: placeholder, session_event_command: placeholder,
      config_command: placeholder, exit_handler: FakeExitHandler, output: output, error_output: error_output,
      working_dir: Dir.pwd
    )
  end

  # --- IU1: `--max-wait`/`--poll` only accept plain numbers, not durations -
  describe "`workspace lock acquire --max-wait` with a duration string (IU1)" do
    it "accepts `--max-wait 9m` as 540 seconds instead of rejecting it outright" do
      output = StringIO.new
      error_output = StringIO.new
      lock_command = CLITestHelpers::FakeLockCommand.new
      cli = build_cli(output: output, error_output: error_output, lock_command: lock_command)

      # The plan's own deferred section documents `--max-wait 9m` as the
      # default retry-loop pattern for an agent following `lock
      # instructions`. `--max-wait DURATION, Float` in
      # lib/workspace/cli.rb#cmd_lock_acquire only accepts a plain number,
      # so OptionParser rejects "9m" outright (rescued at cli.rb:190 into a
      # bare "invalid argument: --max-wait 9m", exit 1, no usage text)
      # instead of parsing it as a duration the way `dev.stop_timeout` and
      # `locks.idle_grace` do.
      cli.run(["lock", "acquire", "edit", "--wait", "--max-wait", "9m"])
      expect(lock_command.calls.last).to include(max_wait: 540.0)
    end

    it "accepts `--poll 5s` as 5 seconds instead of rejecting it outright" do
      output = StringIO.new
      error_output = StringIO.new
      lock_command = CLITestHelpers::FakeLockCommand.new
      cli = build_cli(output: output, error_output: error_output, lock_command: lock_command)

      cli.run(["lock", "acquire", "edit", "--wait", "--poll", "5s"])
      expect(lock_command.calls.last).to include(poll: 5.0)
    end
  end

  # --- IU2: `lock instructions` interpolates the name unsanitized ---------
  describe "`workspace lock instructions <name>` with shell metacharacters (IU2)" do
    it "does not embed unquoted shell metacharacters into the printed command block" do
      output = StringIO.new
      error_output = StringIO.new
      lock_command = Workspace::Commands::Lock.new(
        config: Workspace::Config.new, lock_namespace: nil, lock_holder: nil,
        output: output, error_output: error_output
      )
      cli = build_cli(output: output, error_output: error_output, lock_command: lock_command)

      malicious_name = 'edit"; touch /tmp/pwned; echo "'
      expect { cli.run(["lock", "instructions", malicious_name]) }.to raise_error(FakeSystemExit) { |e| expect(e.status).to eq(1) }
      expect(error_output.string).to include("invalid lock name")

      # `instructions` (lib/workspace/commands/lock.rb#instructions) prints
      # the agent prompt block via unvalidated string interpolation. A lock
      # name containing shell metacharacters is echoed verbatim into a
      # backticked command an agent is told to literally run with Bash, so
      # it changes what actually executes. A safe implementation would
      # reject a name that isn't a plain identifier (or shell-quote it)
      # rather than reproducing it byte-for-byte.
      expect(output.string).not_to include(malicious_name),
        "expected `lock instructions` to reject or quote a name with shell metacharacters, " \
        "but it echoed it verbatim: #{output.string.inspect}"
    end
  end
end
