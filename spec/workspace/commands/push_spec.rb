require "spec_helper"
require "json"

RSpec.describe Workspace::Commands::Push do
  include RebaseRepos

  let(:output) { StringIO.new }
  let(:runner) { Workspace::TimedProcess.method(:run) }
  let(:git) { Workspace::Git.new(output: StringIO.new, input: StringIO.new, runner: runner) }
  let(:project_config) { instance_double(Workspace::ProjectConfig) }
  let(:project_detector) { instance_double(Workspace::ProjectDetector, detect: "api.worktree-x") }
  let(:checkout) { Workspace::WorkspaceCheckout.new(git: git, project_config: project_config, project_detector: project_detector) }
  subject(:command) { described_class.new(git: git, checkout: checkout, output: output) }

  before { allow(project_config).to receive(:project_root_for).with("api.worktree-x").and_return(wt) }

  def document = JSON.parse(output.string)

  def run_json
    command.call(json: true, working_dir: wt)
    document
  end

  def remote_tip = rev("refs/heads/feature/x", dir: remote)

  def push_feature
    sh("push", "-q", "-u", "origin", "feature/x", dir: wt)
  end

  # Moves main on, rebases the feature branch onto it, as `rebase` would.
  def rebase_feature
    commit_file("main.txt", "main\n", "main moves")
    sh("rebase", "-q", "main", dir: wt)
  end

  it "pushes a branch with no upstream and sets the upstream" do
    expect(run_json).to eq("schema_version" => 1, "ok" => true, "workspace" => "api.worktree-x", "branch" => "feature/x",
      "outcome" => "pushed", "forced" => false)

    expect(remote_tip).to eq(rev("HEAD", dir: wt))
    expect(sh("rev-parse", "--abbrev-ref", "feature/x@{u}", dir: wt).strip).to eq("origin/feature/x")
  end

  it "says up_to_date and pushes nothing when the upstream has the same commit" do
    push_feature

    expect(run_json).to include("outcome" => "up_to_date", "forced" => false)
  end

  it "pushes new commits plainly" do
    push_feature
    commit_file("more.txt", "more\n", "more work", dir: wt)

    expect(run_json).to include("outcome" => "pushed", "forced" => false)
    expect(remote_tip).to eq(rev("HEAD", dir: wt))
  end

  it "forces with a lease when a rebase replaced the commits the upstream has" do
    push_feature
    old_tip = remote_tip
    rebase_feature

    expect(run_json).to include("outcome" => "pushed", "forced" => true)
    expect(remote_tip).to eq(rev("HEAD", dir: wt))
    expect(remote_tip).not_to eq(old_tip)
  end

  it "refuses to force when the upstream has a commit the branch never had" do
    push_feature
    clone_other
    sh("switch", "-q", "feature/x", dir: other)
    commit_file("teammate.txt", "hi\n", "teammate work", dir: other)
    sh("push", "-q", "origin", "feature/x", dir: other)
    rebase_feature
    teammate_tip = remote_tip

    expect { command.call(working_dir: wt) }.to raise_error(Workspace::Error) { |e|
      expect(e.code).to eq("push_rejected")
      expect(e.details).to include("branch" => "feature/x", "upstream" => "origin/feature/x")
      expect(e.message).to include("never had")
    }
    expect(remote_tip).to eq(teammate_tip)
  end

  it "never pushes a branch that is only behind its upstream, since that would delete commits" do
    commit_file("more.txt", "more\n", "more work", dir: wt)
    push_feature
    pushed_tip = remote_tip
    sh("reset", "-q", "--hard", "HEAD~1", dir: wt)

    expect { command.call(working_dir: wt) }.to raise_error(Workspace::Error) { |e|
      expect(e.code).to eq("push_rejected")
      expect(e.message).to include("behind")
    }
    expect(remote_tip).to eq(pushed_tip)
  end

  it "refuses a branch whose upstream is not origin/<branch>" do
    sh("push", "-q", "origin", "feature/x:renamed", dir: wt)
    sh("branch", "-q", "--set-upstream-to=origin/renamed", dir: wt)

    expect { command.call(working_dir: wt) }.to raise_error(Workspace::Error) { |e|
      expect(e.code).to eq("push_rejected")
      expect(e.details["upstream"]).to eq("origin/renamed")
    }
  end

  it "refuses to force when the reflog no longer shows the replaced commits" do
    push_feature
    rebase_feature
    sh("reflog", "expire", "--expire=now", "--all", dir: wt)

    expect { command.call(working_dir: wt) }.to raise_error(Workspace::Error) { |e| expect(e.code).to eq("push_rejected") }
  end

  it "reports push_rejected when origin refuses the push" do
    hook = File.join(remote, "hooks", "pre-receive")
    File.write(hook, "#!/bin/sh\necho 'no pushes today' >&2\nexit 1\n")
    File.chmod(0o755, hook)

    expect { command.call(working_dir: wt) }.to raise_error(Workspace::Error) { |e|
      expect(e.code).to eq("push_rejected")
      expect(e.details["detail"]).to be_a(String)
    }
  end

  it "raises an uncoded error when the push fails for another reason" do
    sh("remote", "set-url", "origin", File.join(@dir, "nowhere.git"))

    expect { command.call(working_dir: wt) }.to raise_error(Workspace::Error) { |e|
      expect(e.code).to eq("error")
      expect(e.message).to start_with("Could not push 'feature/x'")
    }
  end

  it "raises fetch_failed when origin cannot be reached to compare" do
    push_feature
    sh("remote", "set-url", "origin", File.join(@dir, "nowhere.git"))

    expect { command.call(working_dir: wt) }.to raise_error(Workspace::Error) { |e|
      expect(e.code).to eq("fetch_failed")
      expect(e.details).to include("remote" => "origin")
    }
  end

  it "raises when the branch cannot be compared with its upstream" do
    push_feature
    allow(git).to receive(:behind_ahead).and_return(nil)

    expect { command.call(working_dir: wt) }.to raise_error(Workspace::Error, /could not compare/)
  end

  it "says git is not installed instead of raising ENOENT" do
    git_missing = Workspace::Git.new(output: StringIO.new, input: StringIO.new, runner: ->(argv, chdir:, timeout:) { raise Errno::ENOENT })
    cmd = described_class.new(git: git_missing, checkout: checkout, output: output)

    expect { cmd.call(working_dir: wt) }.to raise_error(Workspace::Error, "git is not installed.")
  end

  it "prints one sentence per outcome without --json" do
    command.call(working_dir: wt)
    command.call(working_dir: wt)
    rebase_feature
    command.call(working_dir: wt)

    expect(output.string.lines.map(&:chomp)).to eq([
      "Pushed feature/x.",
      "feature/x is already up to date on its upstream.",
      "Force-pushed feature/x (with lease) after a rebase."
    ])
  end
end
