require "spec_helper"
require "json"
require "open3"
require "tmpdir"

RSpec.describe "script/r4-damaged-run" do
  let(:script) { File.join(PROJECT_ROOT, "script", "r4-damaged-run") }
  let(:faults) { %w[half_json empty garbage_bytes wrong_shape_json dead_pid_holder going_no_agent half_events_line] }
  let(:commands) { ["workflow status", "workflow sweep --json", "workflow advance A", "workflow recover --dry-run", "doctor", "lock status"] }

  # The HOME and state directory the script is started with stand in for the person's real ones: it must leave them alone.
  around do |example|
    Dir.mktmpdir("r4-parent") do |dir|
      @parent = dir
      example.run
    end
  end

  def tree = Dir.glob("**/*", File::FNM_DOTMATCH, base: @parent).sort

  it "runs every fault through every command in its own HOME and prints one JSON document" do
    state = File.join(@parent, ".local", "state")
    FileUtils.mkdir_p(File.join(state, "workspace"))
    sentinel = File.join(state, "workspace", "sentinel")
    File.write(sentinel, "untouched\n")
    before = tree
    env = {"HOME" => @parent, "XDG_STATE_HOME" => state, "TMUX" => "/nonexistent/tmux,1,0", "TMUX_PANE" => "%999"}

    out, err, status = Open3.capture3(env, RbConfig.ruby, script, "--json", "--alert-wait", "0.2")

    expect(status.exitstatus).to eq(0), err
    result = JSON.parse(out)
    expect(result["faults"].map { |row| row["fault"] }).to eq(faults)
    result["faults"].each do |row|
      expect(row["commands"].map { |cmd| cmd["command"] }).to eq(commands)
      row["commands"].each { |cmd| expect(cmd).to include("exit", "noticed", "reason", "next_action", "lock_freed", "alert_grew") }
    end
    expect(result["run_b"]).to include("state" => "waiting", "reason" => "waiting_lock")
    expect(result["run_b"]["holder"]).to include("run_id" => "A")
    expect(result["sweep_twice"].map { |pass| pass["pass"] }).to eq([1, 2])
    expect(result["tmux_server_started"]).to be(false)
    expect(File.read(sentinel)).to eq("untouched\n")
    expect(tree).to eq(before)
  end

  it "exits 2 with a one-line message on an unknown option" do
    out, err, status = Open3.capture3(RbConfig.ruby, script, "--bogus")

    expect(status.exitstatus).to eq(2)
    expect(out).to be_empty
    expect(err).to eq("r4-damaged-run: invalid option: --bogus\n")
  end
end
