require "tmpdir"
require "socket"

# Adversarial probe for commit 15c1d9e ("show every lock a pane holds or
# waits on"). See sessions_adversarial_cli_spec.rb for the SX1-SX3 siblings.
RSpec.describe Workspace::Commands::Sessions do
  let(:output) { StringIO.new }
  let(:error_output) { StringIO.new }

  # SX4: the `workspace sessions` help text (cli.rb) still documents only the
  # single-lock "edit" format, even though the LOCK column and --json now
  # describe every lock in the namespace. A user reading --help has no way
  # to learn about the "locks" JSON array or the space-joined multi-lock
  # label.
  #
  # `sessions` has no subcommands, so its --help is handled the same way as
  # every other flat OptionParser-based command (focus, doctor, status, ...):
  # OptionParser's built-in --help switch prints straight to the real
  # $stdout and exits, rather than going through the injected `output`.
  it "SX4: --help documents multi-lock behavior, not just the edit lock" do
    cli = Workspace.build_cli(output: output, error_output: error_output)

    real_stdout = StringIO.new
    $stdout = real_stdout
    begin
      expect { cli.run(["sessions", "--help"]) }.to raise_error(SystemExit)
    ensure
      $stdout = STDOUT
    end

    expect(real_stdout.string).to include("locks")
    expect(real_stdout.string).not_to match(/LOCK column:\s*"edit/)
  end
end
