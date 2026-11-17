require "spec_helper"
require "tmpdir"
require "fileutils"
require "open3"

RSpec.describe "workspace step expect-fail" do
  around do |example|
    Dir.mktmpdir("step-expect-fail") do |dir|
      @home = File.realpath(dir)
      @checkout = File.join(@home, "app")
      FileUtils.mkdir_p([@checkout, File.join(@home, ".config", "workspace", "projects")])
      File.write(File.join(@home, ".config", "workspace", "projects", "app.yml"), "commands:\n  test: sh run-tests.sh\n")
      File.write(File.join(@checkout, "run-tests.sh"), "for f in \"$@\"; do echo \"running $f\"; sh \"$f\" || exit 1; done\n")
      File.write(File.join(@checkout, "failing test.sh"), "echo 'expected 3, got 2' >&2\nexit 1\n")
      File.write(File.join(@checkout, "passing.sh"), "exit 0\n")
      File.write(File.join(@checkout, "failure.txt"), "expected 3, got 2\n")
      example.run
    end
  end

  def run_verb(*args)
    env = {"HOME" => @home, "TMPDIR" => @home, "TMUX" => nil, "TMUX_PANE" => nil, "XDG_CONFIG_HOME" => nil, "XDG_STATE_HOME" => nil}
    Open3.capture3(env, File.join(PROJECT_ROOT, "bin", "workspace"), "step", "expect-fail", *args, chdir: @checkout)
  end

  it "exits 0 from no pane when the test fails with the expected text, found on stderr" do
    out, err, status = run_verb("--match-file", "failure.txt", "--", "failing test.sh")

    expect([status.exitstatus, err]).to eq([0, ""])
    expect(out).to include("running failing test.sh", "expected 3, got 2")
    expect(out.lines.last).to eq("expect-fail: the tests failed as expected (exit 1) with the text of failure.txt\n")
  end

  it "exits 1 with one expect-fail line when the test passes" do
    out, err, status = run_verb("passing.sh")

    expect(status.exitstatus).to eq(1)
    expect(out).to include("running passing.sh")
    expect(err).to eq("expect-fail: the tests passed (exit 0); a fail-first test must fail before the fix\n")
  end

  it "exits 1 when the expected text is missing from the failure" do
    File.write(File.join(@checkout, "failure.txt"), "expected 4\n")

    _out, err, status = run_verb("--match-file", "failure.txt", "failing test.sh")

    expect(status.exitstatus).to eq(1)
    expect(err).to eq("expect-fail: the tests failed (exit 1) but their output does not hold the text of failure.txt (trimmed, as one exact substring)\n")
  end

  it "stops tests that run past --timeout" do
    File.write(File.join(@checkout, "slow.sh"), "sleep 30\n")

    _out, err, status = run_verb("--timeout", "1", "slow.sh")

    expect(status.exitstatus).to eq(1)
    expect(err).to eq("expect-fail: tests ran past 1s and were stopped\n")
  end

  it "refuses a bad --timeout, a flag of another step verb, and its own flags on done" do
    [["--timeout", "0", "passing.sh"], ["--json", "passing.sh"], ["--summary", "x", "passing.sh"]].each do |args|
      out, err, status = run_verb(*args)
      expect(status.exitstatus).to eq(1), err
      expect(out + err).to match(/--timeout takes a whole number|--json is not for `step expect-fail`|--summary is not for `step expect-fail`/)
    end
    _out, err, status = Open3.capture3({"HOME" => @home, "TMUX_PANE" => nil}, File.join(PROJECT_ROOT, "bin", "workspace"), "step", "done", "--timeout", "5", chdir: @checkout)
    expect(status.exitstatus).to eq(1)
    expect(err).to include("--timeout is only for `step expect-fail`.")
  end

  it "exits 1 when no file is given" do
    _out, err, status = run_verb

    expect(status.exitstatus).to eq(1)
    expect(err).to start_with("expect-fail: no test files given")
  end
end
