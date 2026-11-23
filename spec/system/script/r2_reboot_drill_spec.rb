require "spec_helper"
require "etc"
require "fileutils"
require "json"
require "open3"
require "shellwords"
require "tmpdir"

RSpec.describe "script/r2-reboot-drill" do
  let(:script) { File.join(PROJECT_ROOT, "script", "r2-reboot-drill") }
  let(:bin) { File.join(PROJECT_ROOT, "bin", "workspace") }

  # The parent HOME and state directory stand in for the person's real ones; the lab lives under /tmp, where the script insists on it.
  around do |example|
    Dir.mktmpdir("r2-parent") do |parent|
      @parent = parent
      @lab = File.realpath(Dir.mktmpdir("r2-", "/tmp"))
      example.run
    ensure
      FileUtils.remove_entry(@lab) if File.directory?(@lab)
    end
  end

  def parent_env
    state = File.join(@parent, ".local", "state")
    path = [File.join(@parent, "bin"), "~/bin", File.join(Etc.getpwuid.dir, "bin"), ENV.fetch("PATH")].join(":")
    {"HOME" => @parent, "XDG_STATE_HOME" => state, "TMUX" => "/nonexistent/tmux,1,0", "TMUX_PANE" => "%999", "PATH" => path, "R2_LAB" => nil}
  end

  def drill(*args)
    Open3.capture3(parent_env, RbConfig.ruby, script, "--lab", @lab, *args)
  end

  def lab_env
    out, err, status = drill("env")
    raise err unless status.success?
    out.lines.to_h do |line|
      line.start_with?("unset ") ? [line.split.last, nil] : line.delete_prefix("export ").chomp.split("=", 2).then { |k, v| [k, Shellwords.split(v).first] }
    end
  end

  def tree = Dir.glob("**/*", File::FNM_DOTMATCH, base: @parent).sort

  def git(*args) = Open3.capture2("git", "-C", PROJECT_ROOT, *args).first

  describe "setup --dry-run" do
    it "plans the lab checkout and its git common dir under the lab, and leaves the real repository and the parent HOME alone" do
      sentinel = File.join(@parent, ".local", "state", "workspace", "sentinel")
      FileUtils.mkdir_p(File.dirname(sentinel))
      File.write(sentinel, "untouched\n")
      before = tree
      worktrees = git("worktree", "list", "--porcelain")
      refs = git("for-each-ref", "--format=%(refname) %(objectname)")

      out, err, status = drill("setup", "--dry-run")

      expect(status.exitstatus).to eq(0), err
      plan = JSON.parse(out)
      expect(plan["checkout"]).to eq(File.join(@lab, "repo", ".worktrees", "r2lab"))
      expect(plan["git_common_dir"]).to start_with("#{@lab}/")
      expect(Dir.exist?(File.join(@lab, "repo"))).to be(false)
      expect(git("worktree", "list", "--porcelain")).to eq(worktrees)
      expect(git("for-each-ref", "--format=%(refname) %(objectname)")).to eq(refs)
      expect(File.read(sentinel)).to eq("untouched\n")
      expect(tree).to eq(before)
    end

    it "puts the shims first on a lab PATH with no ~/bin, and writes launch.headless true under the lab HOME" do
      _out, err, status = drill("setup", "--dry-run")
      expect(status.exitstatus).to eq(0), err
      env = lab_env

      expect(env).to include("HOME" => File.join(@lab, "home"), "TMUX_TMPDIR" => File.join(@lab, "tmux"), "TMUX" => nil, "TMUX_PANE" => nil)
      entries = env["PATH"].split(":")
      bins = [@parent, Etc.getpwuid.dir].map { |home| File.join(home, "bin") }
      expect(entries).not_to include("~/bin", "~/bin/", *bins, *bins.map { |b| "#{b}/" })
      %w[workspace osascript window-tool].each do |name|
        found, = Open3.capture2(env, "sh", "-c", "command -v #{name}")
        expect(found.strip).to eq(File.join(@lab, "shims", name))
      end
      expect(File.read(File.join(@lab, "shims", "workspace"))).to include("exec #{Shellwords.escape(RbConfig.ruby)} ")
      login_ruby, = Open3.capture2(env, "zsh", "-l", "-i", "-c", "command -v ruby; command -v workspace", chdir: @lab)
      expect(login_ruby.lines.map(&:strip)).to eq([File.join(RbConfig::CONFIG["bindir"], "ruby"), File.join(@lab, "shims", "workspace")])
      headless, = Open3.capture2(env, bin, "config", "get", "launch.headless", chdir: @lab)
      expect(headless.strip).to eq("true")
      _o, _e, tripped = Open3.capture3(env, "osascript", "-e", "beep", chdir: @lab)
      expect(tripped.exitstatus).to eq(1)
      expect(File.read(File.join(@lab, "osascript.log"))).to eq("osascript -e beep\n")
    end

    it "drops the caller's API keys and Claude Code session variables from the lab environment" do
      leaked = {"ANTHROPIC_API_KEY" => "sk-test", "CLAUDECODE" => "1", "CLAUDE_CODE_SESSION_ID" => "abc", "CLAUDE_PID" => "1", "AI_AGENT" => "x"}
      out, err, status = Open3.capture3(parent_env.merge(leaked), RbConfig.ruby, script, "--lab", @lab, "env")
      expect(status.exitstatus).to eq(0), err

      leaked.each_key { |key| expect(out).to include("unset #{key}\n") }
      expect(out).not_to include("sk-test")
    end

    it "refuses with a non-zero exit when the lab's state path resolves outside the lab" do
      Dir.mktmpdir("r2-elsewhere", "/tmp") do |elsewhere|
        FileUtils.mkdir_p(File.join(@lab, "home", ".local"))
        File.symlink(elsewhere, File.join(@lab, "home", ".local", "state"))

        out, err, status = drill("setup", "--dry-run")

        expect(status.exitstatus).to eq(1)
        expect(out).to be_empty
        expect(err).to include("refusing to run").and include("resolves outside #{@lab}")
        expect(Dir.children(elsewhere)).to be_empty
      end
    end
  end

  it "refuses a --lab that is not a /tmp/r2-* directory, and creates nothing" do
    Dir.mktmpdir("foo-", "/tmp") do |other|
      missing = File.join("/tmp", "foo-r2spec-#{Process.pid}")
      [[missing, "setup"], [other, "setup"], [other, "table"]].each do |dir, verb|
        out, err, status = Open3.capture3(parent_env, RbConfig.ruby, script, "--lab", dir, verb, "--dry-run")

        expect(status.exitstatus).to eq(1), "#{dir} #{verb}"
        expect(out).to be_empty
        expect(err).to include("is not a /tmp/r2-* directory")
      end
      expect(File.exist?(missing)).to be(false)
      expect(Dir.children(other)).to be_empty
    end
  end

  it "teardown stops the lab's demo, waits for it to exit and then removes the lab" do
    ws = "repo.worktree-r2lab"
    pid = Process.spawn("sh", "-c", "trap 'exit 0' TERM; while :; do sleep 0.1; done", "script/demo-calculator2 run --id smoke --name #{ws}", pgroup: true)
    File.write(File.join(@lab, "drill.json"), JSON.generate("workspace" => ws, "demo" => {"pid" => pid, "id" => "smoke"}))

    out, err, status = drill("teardown")

    expect(status.exitstatus).to eq(0), err
    expect(JSON.parse(out)).to include("demo" => pid, "removed" => true)
    expect(Process.waitpid(pid, Process::WNOHANG)).to eq(pid)
    expect(File.exist?(@lab)).to be(false)
  ensure
    begin
      Process.kill("KILL", pid)
      Process.wait(pid)
    rescue Errno::ESRCH, Errno::ECHILD
      nil
    end
  end

  it "teardown refuses to remove a lab with no drill.json" do
    FileUtils.touch(File.join(@lab, "keep-me"))

    _out, err, status = drill("teardown")

    expect(status.exitstatus).to eq(1)
    expect(err).to include("has no drill.json")
    expect(File.exist?(File.join(@lab, "keep-me"))).to be(true)
  end

  it "seeds Claude Code with the feedback survey marked shown and turned off, so no dialog covers the input prompt" do
    load script
    now = Time.at(1_800_000_000)
    doc = R2RebootDrill.claude_json(["/tmp/r2-x/repo"], now)

    expect(doc).to include("hasCompletedOnboarding" => true, "feedbackSurveyState" => {"lastShownTime" => 1_800_000_000_000})
    expect(doc["projects"]).to eq("/tmp/r2-x/repo" => {"hasTrustDialogAccepted" => true})
    expect(R2RebootDrill.claude_settings["env"]).to eq("CLAUDE_CODE_DISABLE_FEEDBACK_SURVEY" => "1")
  end

  it "hits a point only once the agent has its prompt, counts a step held for a person as missed, and still hits a running step whose run reads waiting on an open ask" do
    load script
    run = ->(state, flags, run_state = "running") { {"state" => run_state, "current" => {"step" => "research", "state" => state, "flags" => flags}} }
    expect(R2RebootDrill.point_state(run.call("running", ["delivering"]), "research")).to eq(:wait)
    expect(R2RebootDrill.point_state(run.call("running", []), "research")).to eq(:hit)
    expect(R2RebootDrill.point_state(run.call("waiting", [], "waiting"), "research")).to eq(:missed)
    expect(R2RebootDrill.point_state(run.call("running", [], "waiting"), "research")).to eq(:hit)
  end

  it "counts a doctor warn as bad only for workflow runs, review window orphans and agentd orphans" do
    load script
    checks = [{"id" => "templates", "status" => "warn"}, {"id" => "skills-claude", "status" => "warn"}, {"id" => "tmux", "status" => "ok"}]
    expect(R2RebootDrill.doctor_summary({"checks" => checks})).to eq("ok")
    checks += [{"id" => "agentd-orphans", "status" => "warn"}, {"id" => "workflow-review-window-orphaned", "status" => "warn"}, {"id" => "git", "status" => "fail"}]
    expect(R2RebootDrill.doctor_summary({"checks" => checks})).to eq("agentd-orphans (warn), workflow-review-window-orphaned (warn), git (fail)")
  end

  it "run ID --dry-run prints the demo command for the lab worktree, against main, with this checkout's bin/workspace" do
    out, err, status = drill("run", "base1", "--dry-run")

    expect(status.exitstatus).to eq(0), err
    plan = JSON.parse(out)
    argv = plan["argv"]
    expect(argv.first(2)).to eq(["script/demo-calculator2", "run"])
    expect(argv.each_cons(2).to_a).to include(["--base", "main"], ["--id", "base1"], ["--goals", "01,02"], ["--workflow", "deliver-goal-fast"])
    expect(argv).to include("--wait")
    expect(plan["chdir"]).to start_with("#{@lab}/")
    expect(plan["env"]).to eq("WORKSPACE_BIN" => bin)
  end

  describe "check-target" do
    around do |example|
      @sleeper = Process.spawn("sleep", "60")
      example.run
    ensure
      Process.kill("KILL", @sleeper)
      Process.wait(@sleeper)
    end

    it "refuses a session that is not the lab workspace's" do
      _out, err, status = drill("check-target", "--session", "someone-else", "--pid", @sleeper.to_s)

      expect(status.exitstatus).to eq(1)
      expect(err).to include("refusing to kill").and include("someone-else").and include("repo-wt-r2lab")
    end

    it "refuses the workspace name, which is not the tmux session's name" do
      _out, err, status = drill("check-target", "--session", "repo.worktree-r2lab", "--pid", @sleeper.to_s)

      expect(status.exitstatus).to eq(1)
      expect(err).to include("is not the lab workspace's session (repo-wt-r2lab)")
    end

    it "refuses a pid that is not the lab workspace's agentd" do
      _out, err, status = drill("check-target", "--session", "repo-wt-r2lab", "--pid", @sleeper.to_s)

      expect(status.exitstatus).to eq(1)
      expect(err).to include("pid #{@sleeper} is not the lab workspace's agentd")
    end

    it "accepts the lab session on the lab socket and a process whose command line is this checkout's agentd for the lab workspace" do
      _out, err, status = drill("setup", "--dry-run")
      expect(status.exitstatus).to eq(0), err
      socket = File.join(@lab, "tmux", "tmux-#{Process.uid}", "default")
      FileUtils.mkdir_p(File.dirname(socket), mode: 0o700)
      env = {"TMUX" => nil, "TMUX_PANE" => nil, "TMUX_TMPDIR" => File.join(@lab, "tmux")}
      agentd = Process.spawn(["sleep", "#{bin} agentd --name repo.worktree-r2lab"], "60")
      begin
        expect(system(env, "tmux", "-S", socket, "new-session", "-d", "-s", "repo-wt-r2lab", "sleep 60")).to be(true)

        out, err, status = drill("check-target", "--session", "repo-wt-r2lab", "--pid", agentd.to_s)

        expect(status.exitstatus).to eq(0), err
        expect(JSON.parse(out)).to include("ok" => true, "pid" => agentd, "session" => "repo-wt-r2lab")
      ensure
        system(env, "tmux", "-S", socket, "kill-session", "-t", "=repo-wt-r2lab", err: File::NULL)
        Process.kill("KILL", agentd)
        Process.wait(agentd)
      end
    end
  end

  it "table prints the kill rows against the median baseline, keeps missed attempts apart and shows limit_reached as its own value" do
    runs = File.join(@lab, "runs")
    FileUtils.mkdir_p(runs)
    doctor = {"summary" => "ok"}
    records = [
      {"id" => "smoke", "kind" => "baseline", "wall_seconds" => 60, "exit" => 0},
      {"id" => "base1", "kind" => "baseline", "wall_seconds" => 600, "exit" => 0, "runs" => [{"id" => "wr_b1"}], "attempts" => 10, "repeated_attempts" => 0, "osascript_calls" => 0},
      {"id" => "base2", "kind" => "baseline", "wall_seconds" => 900, "exit" => 0, "runs" => [{"id" => "wr_b2"}], "attempts" => 11, "repeated_attempts" => 1, "osascript_calls" => 0},
      {"id" => "res1", "kind" => "kill", "point" => "research", "rep" => "1", "run_id" => "wr_r1", "exit" => 0, "wall_seconds" => 800,
       "repeated_attempts" => 1, "doctor" => doctor, "recover_outcome" => "restarted", "osascript_calls" => 0},
      {"id" => "res2", "kind" => "kill", "point" => "research", "rep" => "2", "missed" => true, "missed_reason" => "the run was at plan/running (running)"},
      {"id" => "plan1", "kind" => "kill", "point" => "plan", "rep" => "1", "run_id" => "wr_p1", "exit" => 3, "wall_seconds" => 700,
       "repeated_attempts" => 0, "doctor" => doctor, "recover_outcome" => "skipped/pane_alive", "osascript_calls" => 0},
      {"id" => "ver1", "kind" => "kill", "point" => "verify", "rep" => "1", "run_id" => "wr_v1", "exit" => 0, "wall_seconds" => 750,
       "repeated_attempts" => 2, "doctor" => {"summary" => "workflow-runs (warn)"}, "recover_outcome" => "limit_reached", "osascript_calls" => 0}
    ]
    records.each { |record| File.write(File.join(runs, "#{record["id"]}.json"), JSON.generate(record)) }

    out, err, status = drill("table")

    expect(status.exitstatus).to eq(0), err
    lines = out.lines.map(&:chomp)
    expect(lines.first).to eq("Median baseline wall: 12m30s (2 baseline(s))")
    expect(lines).to include("| research | 1 | wr_r1 | yes | 1 | 13m20s | +0m50s | ok | restarted | 0 |")
    expect(lines).to include("| plan | 1 | wr_p1 | no | 0 | 11m40s | -0m50s | ok | skipped/pane_alive | 0 |")
    expect(lines).to include("| verify | 1 | wr_v1 | yes | 2 | 12m30s | +0m00s | workflow-runs (warn) | limit_reached | 0 |")
    expect(lines).to include("| base1 | wr_b1 | yes | 10 | 0 | 10m00s | 0 |", "| base2 | wr_b2 | yes | 11 | 1 | 15m00s | 0 |")
    expect(lines).to include("- res2 (research): the run was at plan/running (running)")
    expect(lines.grep(/\A\| (research|plan|verify) /).size).to eq(3)
    expect(out).not_to include("| smoke |")
  end
end
