require "spec_helper"
require "tmpdir"
require "fileutils"
require "open3"
require "json"

RSpec.describe "workspace step check-ids" do
  around do |example|
    Dir.mktmpdir("step-check-ids") do |dir|
      @home = File.realpath(dir)
      @checkout = File.join(@home, "app")
      @artifacts = File.join(@home, "artifacts")
      @notes = File.join(@checkout, "tmp", "workspace-notes")
      FileUtils.mkdir_p([@checkout, @artifacts, @notes, File.join(@home, ".config", "tmuxinator")])
      File.write(File.join(@home, ".config", "tmuxinator", "workspace.app.yml"), "name: app\nroot: #{@checkout}\nwindows: []\n")
      File.write(File.join(@checkout, "req.md"), "R1 Export\nR2 Name it\n")
      File.write(File.join(@checkout, "plan.md"), "Covers R1 and R2.\n")
      example.run
    end
  end

  def run_verb(*args, env: {}, chdir: @checkout)
    base = {"HOME" => @home, "TMPDIR" => @home, "TMUX" => nil, "TMUX_PANE" => nil, "XDG_CONFIG_HOME" => nil, "XDG_STATE_HOME" => nil, "WORKSPACE_RUN_ARTIFACTS" => nil}
    Open3.capture3(base.merge(env), File.join(PROJECT_ROOT, "bin", "workspace"), "step", "check-ids", *args, chdir: chdir)
  end

  it "exits 0 with one line on stdout when every ID is covered" do
    out, err, status = run_verb("--prefix", "R", "--defined", "req.md", "--covered", "plan.md")

    expect([status.exitstatus, out, err]).to eq([0, "check-ids: all 2 IDs covered\n", ""])
  end

  it "exits 1 with the missing IDs on stderr" do
    File.write(File.join(@checkout, "plan.md"), "Covers R1 and R20.\n")

    out, err, status = run_verb("--prefix", "R", "--defined", "req.md", "--covered", "plan.md")

    expect([status.exitstatus, out]).to eq([1, ""])
    expect(err).to eq("check-ids: not in #{File.join(@checkout, "plan.md")}: R2\n")
  end

  it "prints one document with --json, on a pass and on a failure" do
    out, _err, status = run_verb("--prefix", "R", "--defined", "req.md", "--covered", "plan.md", "--json")
    expect(status.exitstatus).to eq(0)
    expect(JSON.parse(out)).to include("schema_version" => 1, "ok" => true, "prefixes" => ["R"], "defined" => %w[R1 R2], "covered" => %w[R1 R2], "missing" => [], "reason" => nil,
      "defined_path" => File.join(@checkout, "req.md"), "covered_path" => File.join(@checkout, "plan.md"))

    File.write(File.join(@checkout, "plan.md"), "R1\n")
    out, _err, status = run_verb("--prefix", "R", "--defined", "req.md", "--covered", "plan.md", "--json")
    expect(status.exitstatus).to eq(1)
    expect(JSON.parse(out)).to include("ok" => false, "missing" => ["R2"], "reason" => "uncovered")
  end

  it "reports a missing --defined file, passing only with --allow-missing" do
    _out, err, status = run_verb("--prefix", "R", "--defined", "none.md", "--covered", "plan.md")
    expect([status.exitstatus, err]).to eq([1, "check-ids: #{File.join(@checkout, "none.md")} does not exist\n"])

    out, _err, status = run_verb("--prefix", "R", "--defined", "none.md", "--covered", "plan.md", "--allow-missing", "--json")
    expect(status.exitstatus).to eq(0)
    expect(JSON.parse(out)).to include("ok" => true, "reason" => "defined_absent")
  end

  it "counts an ID only on a line that matches --each-line-matches" do
    File.write(File.join(@checkout, "plan.md"), "R1 PASS\nR2 mentioned in prose\n")

    _out, err, status = run_verb("--prefix", "R", "--defined", "req.md", "--covered", "plan.md", "--each-line-matches", "PASS")

    expect(status.exitstatus).to eq(1)
    expect(err).to eq("check-ids: no line of #{File.join(@checkout, "plan.md")} names these and matches /PASS/: R2\n")
  end

  it "resolves relative paths against WORKSPACE_RUN_ARTIFACTS when it is set" do
    File.write(File.join(@artifacts, "req.md"), "R7 Only here\n")
    File.write(File.join(@artifacts, "plan.md"), "R7\n")

    out, err, status = run_verb("--prefix", "R", "--defined", "req.md", "--covered", "plan.md", env: {"WORKSPACE_RUN_ARTIFACTS" => @artifacts})

    expect([status.exitstatus, out, err]).to eq([0, "check-ids: all 1 IDs covered\n", ""])
  end

  context "with --plan-details" do
    before do
      File.write(File.join(@notes, "IMPLEMENTATION_PLAN.md"), "# Plan\n\n## Tasks\n\n- [ ] T1 First\n\n## Task details\n\n### T1 First\n\nCovers R1.\n\n## Notes\n\nR2\n")
    end

    it "reads the plan of the --name workspace and names what no task covers" do
      _out, err, status = run_verb("--prefix", "R", "--defined", "req.md", "--plan-details", "--name", "app")

      expect([status.exitstatus, err]).to eq([1, "In no task of ## Task details: R2\n"])
    end

    it "fails when the plan has no tasks" do
      File.write(File.join(@notes, "IMPLEMENTATION_PLAN.md"), "# Plan\n\n## Tasks\n\n## Task details\n\nR1 R2\n")

      out, _err, status = run_verb("--prefix", "R", "--defined", "req.md", "--plan-details", "--name", "app", "--json")

      expect(status.exitstatus).to eq(1)
      expect(JSON.parse(out)).to include("ok" => false, "reason" => "no_plan")
    end

    it "finds the workspace with no --name the way plan status does, here a checkout with no marker" do
      _out, err, status = run_verb("--prefix", "R", "--defined", "req.md", "--plan-details")

      expect([status.exitstatus, err]).to eq([1, "In no task of ## Task details: R2\n"])
    end

    it "is refused outside any workspace when no --name is given" do
      out, err, status = run_verb("--prefix", "R", "--defined", File.join(@checkout, "req.md"), "--plan-details", "--json", chdir: @artifacts)

      expect(status.exitstatus).to eq(1)
      expect(JSON.parse(out)).to include("ok" => false, "code" => "not_in_workspace")
      expect(err).to eq("")
    end
  end

  it "refuses bad usage with exit 1 and a usage message" do
    [[%w[--defined req.md --covered plan.md], /needs --prefix/],
      [%w[--prefix R --defined req.md], /one of --covered FILE and --plan-details/],
      [%w[--prefix R --defined req.md --covered plan.md --each-line-matches (], /not a valid regular expression/],
      [%w[--prefix R --defined req.md --covered plan.md --summary x], /--summary is not for `step check-ids`/]].each do |args, message|
      out, err, status = run_verb(*args)

      expect(status.exitstatus).to eq(1), err
      expect(out + err).to match(message)
    end
  end
end
