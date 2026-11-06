require "spec_helper"
require "tmpdir"

RSpec.describe Workspace::WorkflowDeny do
  let(:dir) { Dir.mktmpdir("ws-deny") }
  let(:store) { Workspace::WorkflowRunStore.new(dir: File.join(dir, "runs"), archive_dir: File.join(dir, "archive")) }
  let(:bound_run) { instance_double(Workspace::BoundRun, run_id: "wr_1") }
  let(:event_log) { instance_double(Workspace::EventLog, record: true) }
  let(:patterns) { ["git push*", "gh pr comment*"] }
  let(:state) { "running" }
  let(:run) do
    {"id" => "wr_1", "workflow" => "investigate", "workspace" => "app", "current" => "fix", "state" => state,
     "definition" => {"deny" => patterns, "steps" => [{"id" => "fix"}]}, "steps" => {"fix" => {"attempts" => []}}}
  end

  subject(:deny) { described_class.new(bound_run: bound_run, run_store: store, event_log: event_log) }

  before do
    FileUtils.mkdir_p(File.join(dir, "runs"))
    File.write(File.join(dir, "runs", "wr_1.json"), JSON.generate(run))
  end

  after { FileUtils.remove_entry(dir) }

  def check(command, tool: "Bash")
    deny.check(tool_name: tool, tool_input: {"command" => command})
  end

  it "denies a matching command with the workflow, step and pattern" do
    expect(check("git push origin HEAD")).to eq('denied by workflow investigate, step fix: "git push*". Report this and stop.')
  end

  it "writes command_denied to the run's history and the event log" do
    check("git push origin HEAD")

    line = JSON.parse(File.readlines(File.join(dir, "runs", "wr_1.events.jsonl")).last)
    expect(line).to include("type" => "command_denied", "step" => "fix", "pattern" => "git push*", "command" => "git push origin HEAD")
    expect(event_log).to have_received(:record).with(type: "command_denied", project: "app", data: hash_including("run_id" => "wr_1", "pattern" => "git push*"))
  end

  [
    "FOO=1 git push", "  git push", "cd x && git push", "a; git push", "a | git push", "a || git push", "a\ngit push",
    "echo $(( $(git push) ))", "echo a#b; git push", "echo $(( ((1)) << 2 ))\ngit push", 'sudo -u "a b" git push',
    "env -u X git push", "env -C dir git push", "cat <<< x\ngit push", "cat <<<x; git push", "echo $((1<<2))\ngit push",
    "# <<EOF\ngit push", "git -C \"a b\" push", "git -c 'a b=c' push", "gh -R 'o r' pr comment 1",
    "cat <<-EOF\n\tx\n\tEOF\ngit push", "cat <<'EOF'\n git push\nEOF\ngit push", "(cat <<EOF\nx\nEOF\n) ; git push",
    "git  push", "git\tpush", "gh  pr  comment 1", "git -C x push", "git -c a=b -C x push origin", "git --no-pager push", "git --git-dir=x push",
    "/usr/bin/git push", "sudo -u root git push", "gh -R o/r pr comment 1", "git commit -F - <<EOF\nmsg\nEOF\ngit push", "sudo git push", "sudo -E git push", "env -i FOO=1 git push", "command git push", "echo $(git push)", "echo `git push`", "gh pr comment 1 --body x"
  ].each do |command|
    it "denies #{command.inspect}" do
      expect(check(command)).to match(/denied by workflow/)
    end
  end

  [
    'git commit -m "a; git push"', "(cat <<EOF\ngit push\nEOF\n)", "(echo) ; cat <<EOF\ngit push\nEOF", "echo $((1))\ncat <<EOF\ngit push\nEOF", "# git push", "cat <<EOF\n\tEOF\ngit push\nEOF", "cat <<EOF\n  EOF\ngit push\nEOF", "cat <<-EOF\n  EOF\ngit push\nEOF",
    "cat <<EOF\nEOF \ngit push\nEOF", "git commit -F - <<EOF\ngit push\nit's\nEOF\ngit status", "cat <<-'X'\n git push\n X", "cat <<EOF\ngit push", "echo 'git push'", "git status", "git pull", "echo git push", "workspace push"
  ].each do |command|
    it "allows #{command.inspect}" do
      expect(check(command)).to be_nil
    end
  end

  it "allows other tools, and a Bash call without a command" do
    expect(check("git push", tool: "Edit")).to be_nil
    expect(deny.check(tool_name: "Bash", tool_input: nil)).to be_nil
    expect(deny.check(tool_name: "Bash", tool_input: {"command" => 5})).to be_nil
  end

  it "reads nothing when the pane is not bound to a run" do
    allow(bound_run).to receive(:run_id).and_return(nil)
    expect(store).not_to receive(:find)

    expect(check("git push")).to be_nil
  end

  context "when the run has no deny key" do
    let(:patterns) { nil }

    it "allows everything" do
      expect(check("git push")).to be_nil
    end
  end

  context "when the run has finished" do
    let(:state) { "completed" }

    it "allows everything" do
      expect(check("git push")).to be_nil
    end
  end

  it "allows the command when the run file is gone" do
    File.delete(File.join(dir, "runs", "wr_1.json"))

    expect(check("git push")).to be_nil
  end

  it "escapes control characters of the definition in the message" do
    run["definition"]["deny"] = ["git push\e*"]
    run["workflow"] = "a\e[2Jb"
    File.write(File.join(dir, "runs", "wr_1.json"), JSON.generate(run))

    expect(check("git push\e[31m")).not_to include("\e")
  end

  it "does not take long on a pattern of many wildcards against a long command" do
    run["definition"]["deny"] = ["*a*a*a*a*a*a*a*b"]
    File.write(File.join(dir, "runs", "wr_1.json"), JSON.generate(run))

    started = Time.now
    check("a" * 3000)
    expect(Time.now - started).to be < 2
  end
  it "allows the command when the run file is corrupt" do
    File.write(File.join(dir, "runs", "wr_1.json"), "{")

    expect(check("git push")).to be_nil
  end

  ["git push", ["x", 3]].each do |bad|
    context "with a stored deny of #{bad.inspect}" do
      let(:patterns) { bad }

      it "allows everything" do
        expect(check("git push")).to be_nil
      end
    end
  end

  context "with a real BoundRun" do
    let(:tmux) { instance_double(Workspace::Tmux) }
    let(:bindings) { Workspace::PaneBindings.new(path: File.join(dir, "bindings.json"), error_output: StringIO.new) }
    let(:bound_run) { Workspace::BoundRun.new(pane_bindings: bindings, tmux: tmux, env: {"TMUX_PANE" => "%4"}) }

    before do
      allow(tmux).to receive(:session_name_for_pane).with("%4").and_return("app")
      allow(tmux).to receive(:pane_slot).with("%4").and_return("app:0.1")
    end

    it "denies for a live run binding" do
      bindings.bind("%4", {"kind" => "run", "id" => "wr_1", "session" => "app", "pane_slot" => "app:0.1"})

      expect(check("git push")).to match(/denied/)
    end

    it "allows for a stale run binding" do
      bindings.bind("%4", {"kind" => "run", "id" => "wr_1", "session" => "old", "pane_slot" => "app:0.1"})

      expect(check("git push")).to be_nil
    end

    it "allows for a play binding" do
      bindings.bind("%4", {"kind" => "play", "id" => "wr_1", "session" => "app", "pane_slot" => "app:0.1"})

      expect(check("git push")).to be_nil
    end
  end
  context "with a pattern that names the program's path" do
    let(:patterns) { ["/usr/bin/git*"] }

    it "matches the command as written, and not the same program without a path" do
      expect(check("/usr/bin/git status")).to match(/denied/)
      expect(check("git status")).to be_nil
    end
  end
end
