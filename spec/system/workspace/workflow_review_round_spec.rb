require "tmpdir"
require "fileutils"

# A review round's window through real tmux on a private socket: opened marked for the round, its pane bound as
# the reviewer through the real binding stack, the prompt's line typed into it, and the window closed again by
# its mark. The agent is a stand-in that writes what it is typed to a file; the readiness wait, the revision and
# the prompt file are fakes, so only tmux runs.
RSpec.describe Workspace::WorkflowReviewRound, "against real tmux" do
  tmux_missing = !system("command -v tmux >/dev/null 2>&1")

  let(:tmpdir) { File.realpath(Dir.mktmpdir("ws-review", "/tmp")) }
  let(:socket) { "wsrev#{Process.pid}#{rand(100_000)}" }
  let(:shim) { File.join(tmpdir, "bin", "tmux") }
  let(:config) { Workspace::Config.new(workspace_dir: tmpdir) }
  let(:tmux) { Workspace::Tmux.new(config: config) }
  let(:bindings) { Workspace::PaneBindings.new(path: File.join(tmpdir, "bindings.json")) }
  let(:locator) { Workspace::PaneLocator.new(tmux: tmux) }
  let(:binder) { Workspace::Commands::Binding.new(bindings: bindings, locator: locator, tmux: tmux, output: StringIO.new) }
  let(:snapshot_client) do
    instance_double(Workspace::AgentSnapshotClient).tap do |client|
      allow(client).to receive(:fetch).and_raise(Workspace::AgentSnapshotClient::Unavailable.new("no daemon in this spec", reason: :no_daemon))
    end
  end
  let(:panes) do
    Workspace::WorkflowPanes.new(config: config, bindings: bindings, tmux: tmux, locator: locator, binder: binder, snapshot_client: snapshot_client,
      agent_ensurer: ->(name:) { Workspace::Commands::EnsureAgent::Result.new(:running) }, error_output: StringIO.new,
      clock: -> { Time.now + slept.sum }, sleeper: ->(seconds) { slept << seconds })
  end
  let(:slept) { [] }
  let(:typed) { File.join(tmpdir, "typed.txt") }
  let(:agent) { File.join(tmpdir, "bin", "fake-claude") }
  let(:main_agent) { instance_double(Workspace::MainAgent, spawn_command: agent) }
  let(:store) { RecordingRunStore.new }
  let(:change) { RecordingRunChange.new(store.runs) }
  let(:worktree) { File.join(tmpdir, "checkout").tap { |dir| FileUtils.mkdir_p(dir) } }
  let(:runner) do
    described_class.new(store: store, change: change, tmux: tmux, panes: panes, readiness: RecordingPaneReadiness.new(tmux: tmux), main_agent: main_agent,
      revision: RecordingReviewRevision.new({revision: "rev1", problem: nil}), prompt: RecordingWorkflowPrompt.new, round_dirs: RecordingReviewTally.new,
      holder: -> { {"pid" => Process.pid, "started" => "now"} }, shell: "/bin/sh")
  end

  around do |example|
    skip "tmux is not installed" if tmux_missing
    FileUtils.mkdir_p(File.dirname(shim))
    File.write(shim, "#!/bin/sh\nexec #{`command -v tmux`.strip} -L #{socket} -f /dev/null \"$@\"\n")
    File.chmod(0o755, shim)
    File.write(agent, "#!/bin/sh\nexec cat > '#{typed}'\n")
    File.chmod(0o755, agent)
    saved = ENV.to_h.slice("PATH", "TMUX", "TMUX_PANE")
    ENV["PATH"] = "#{File.dirname(shim)}:#{saved["PATH"]}"
    ENV.delete("TMUX")
    ENV.delete("TMUX_PANE")
    system(shim, "new-session", "-d", "-s", "app", "-x", "200", "-y", "50")
    begin
      example.run
    ensure
      system(shim, "kill-server", err: File::NULL, out: File::NULL)
      saved.each { |key, value| ENV[key] = value }
      FileUtils.remove_entry(tmpdir)
    end
  end

  def windows = `#{shim} list-windows -t app -F '\#{window_id} \#{window_name} \#{@workspace-review}'`.lines.map(&:split)

  def wait_for(seconds = 5)
    deadline = Time.now + seconds
    sleep 0.05 until yield || Time.now > deadline
    yield
  end

  def add_run
    store.runs["wr_1"] = {"id" => "wr_1", "workflow" => "flow", "workspace" => "app", "project" => "app", "worktree" => worktree,
                          "artifacts_dir" => File.join(worktree, ".workflow", "wr_1"), "state" => "running", "current" => "plan", "reason" => nil,
                          "definition" => {"id" => "flow", "steps" => [{"id" => "plan", "produces" => [], "review" => {"from" => %w[skeptic], "need" => 1}}]},
                          "steps" => {"plan" => {"state" => "reviewing", "review_rounds" => 1,
                                                 "review" => {"round" => 1, "delivery" => "delivering", "started_at" => Time.now.utc.iso8601(3)},
                                                 "attempts" => [{"n" => 1, "outcome" => "checks_passed"}]}}}
  end

  # The daemon as it sees every pane of the session right after the review window's agent started: the SessionStart
  # hook gave it a row, and the start-up screen still counts as working.
  # +unnamed+ reads come first: the row the SessionStart hook made before a scan named the agent.
  def daemon_rows(unnamed: 0, **row)
    reads = 0
    allow(snapshot_client).to receive(:fetch) do
      reads += 1
      ids = `#{shim} list-panes -s -t app -F "\#{pane_id}"`.split
      {"panes" => ids.map { |id|
        {"pane_id" => id, "kind" => "claude", "state" => "working", "state_changed_by" => "screen", "hook_mode" => "hooks",
         "user_prompt_at" => nil, "main_turn_over_since" => nil, "open_tools" => [], "subagents" => []}.merge((reads <= unnamed) ? {"kind" => "unknown", "hook_mode" => "none"} : row.transform_keys(&:to_s))
      }}
    end
  end

  it "types into the window it opened while the daemon calls the agent working from its start-up screen alone" do
    add_run
    daemon_rows

    runner.call("wr_1", {"step" => "plan", "attempt" => 1, "round" => 1})

    round = store.runs["wr_1"]["steps"]["plan"]["review"]
    expect(round).to include("delivery" => nil)
    expect(change.events.map { |event| event[1] }).to include("review_delivered")
    path = File.join(worktree, ".workflow", "wr_1", "steps", "plan.1.r1.review.md")
    expect(wait_for { File.exist?(typed) && File.read(typed).include?("Read #{path} and follow it.") }).to be(true)
  end

  it "waits for the daemon to name the agent in the window it opened, then types into it" do
    add_run
    daemon_rows(unnamed: 3)

    runner.call("wr_1", {"step" => "plan", "attempt" => 1, "round" => 1})

    expect(store.runs["wr_1"]["steps"]["plan"]["review"]).to include("delivery" => nil)
    expect(change.events.map { |event| event[1] }).to include("review_delivered")
    expect(slept).to eq([Workspace::WorkflowPanes::ROW_POLL] * 3)
  end

  it "fails the round pane_busy and closes the window when the daemon never names the agent in it" do
    add_run
    daemon_rows(unnamed: 1_000)

    runner.call("wr_1", {"step" => "plan", "attempt" => 1, "round" => 1})

    round = store.runs["wr_1"]["steps"]["plan"]["review"]
    expect(round).to include("delivery" => "failed")
    expect(round["failure"]).to include("code" => "pane_busy")
    expect(windows.map { |window| window[1] }).not_to include("review-plan")
  end

  it "refuses the window it opened when the daemon saw a prompt submitted there with no Stop after it" do
    add_run
    daemon_rows(user_prompt_at: Time.now.utc.iso8601(3))

    runner.call("wr_1", {"step" => "plan", "attempt" => 1, "round" => 1})

    round = store.runs["wr_1"]["steps"]["plan"]["review"]
    expect(round).to include("delivery" => "failed")
    expect(round["failure"]).to include("code" => "pane_busy")
    expect(change.events.map { |event| event[1] }).to include("review_delivery_failed")
    expect(windows.map { |window| window[1] }).not_to include("review-plan")
  end

  it "opens a window marked for the round, binds its pane as the reviewer, types the prompt's line, and closes it by its mark" do
    add_run

    runner.call("wr_1", {"step" => "plan", "attempt" => 1, "round" => 1})

    round = store.runs["wr_1"]["steps"]["plan"]["review"]
    expect(round).to include("delivery" => nil, "revision" => "rev1")
    expect(windows).to include([round["window"], "review-plan", "wr_1:plan:1"])
    expect(`#{shim} display-message -p -t #{round["pane"]} '\#{window_id}'`.strip).to eq(round["window"])
    entry = bindings.binding_for(round["pane"])
    expect(entry).to include("kind" => "run", "id" => "wr_1", "role" => "reviewer", "round" => 1, "step" => "plan", "session" => "app")
    expect(panes.review_pane_of("wr_1")).to eq(round["pane"])
    path = File.join(worktree, ".workflow", "wr_1", "steps", "plan.1.r1.review.md")
    expect(wait_for { File.exist?(typed) && File.read(typed).include?("Read #{path} and follow it.") }).to be(true)

    closed = runner.close("wr_1", {"workspace" => "app", "step" => "plan", "round" => 1, "pane" => nil})

    expect(closed).to eq([round["window"]])
    expect(windows.map(&:first)).not_to include(round["window"])
  end
end
