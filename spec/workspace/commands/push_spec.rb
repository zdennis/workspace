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
  # No gh call unless a spec allows one.
  let(:pr_status) { instance_double(Workspace::PullRequestStatus) }
  subject(:command) { described_class.new(git: git, checkout: checkout, pr_status: pr_status, output: output) }

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
      "remote_branch" => "feature/x", "outcome" => "pushed", "forced" => false)

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
      expect(e.details["reason"]).to eq("upstream_has_other_commits")
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
      expect(e.details["reason"]).to eq("would_delete_commits")
    }
    expect(remote_tip).to eq(pushed_tip)
  end

  it "refuses a branch whose upstream is not origin/<branch>" do
    sh("push", "-q", "origin", "feature/x:renamed", dir: wt)
    sh("branch", "-q", "--set-upstream-to=origin/renamed", dir: wt)
    renamed_tip = rev("refs/heads/renamed", dir: remote)

    expect { command.call(working_dir: wt) }.to raise_error(Workspace::Error) { |e|
      expect(e.code).to eq("push_rejected")
      expect(e.details).not_to have_key("pr_check")
      expect(e.details["upstream"]).to eq("origin/renamed")
      expect(e.details["reason"]).to eq("upstream_mismatch")
    }
    _, feature_on_remote = sh_status("rev-parse", "--verify", "--quiet", "refs/heads/feature/x", dir: remote)
    expect(feature_on_remote).to be(false)
    expect(rev("refs/heads/renamed", dir: remote)).to eq(renamed_tip)
  end

  it "refuses to force when the reflog no longer shows the replaced commits" do
    push_feature
    rebase_feature
    sh("reflog", "expire", "--expire=now", "--all", dir: wt)

    expect { command.call(working_dir: wt) }.to raise_error(Workspace::Error) { |e| expect([e.code, e.details["reason"]]).to eq(["push_rejected", "upstream_has_other_commits"]) }
  end

  it "reports push_failed (not protected_branch) when a pre-receive hook only declines the push" do
    hook = File.join(remote, "hooks", "pre-receive")
    File.write(hook, "#!/bin/sh\necho 'no pushes today' >&2\nexit 1\n")
    File.chmod(0o755, hook)

    expect { command.call(working_dir: wt) }.to raise_error(Workspace::Error) { |e|
      expect(e.code).to eq("push_failed")
      expect(e.details).to include("permanent" => true)
      expect(e.details["stderr"]).to include("no pushes today")
      expect(e.retry).to be_nil
    }
  end

  it "reports push_rejected when the remote has the branch at another commit and there is no upstream" do
    base = rev("HEAD", dir: wt)
    commit_file("theirs.txt", "theirs\n", "theirs", dir: wt)
    sh("push", "-q", "origin", "HEAD:refs/heads/feature/x", dir: wt)
    sh("reset", "-q", "--hard", base, dir: wt)
    commit_file("mine.txt", "mine\n", "mine", dir: wt)
    theirs = remote_tip

    expect { command.call(working_dir: wt) }.to raise_error(Workspace::Error) { |e|
      expect(e.code).to eq("push_rejected")
      expect(e.details).to include("reason" => "origin_refused", "permanent" => true)
    }
    expect(remote_tip).to eq(theirs)
  end

  it "reports no_remote when the remote is not a repository" do
    sh("remote", "set-url", "origin", File.join(@dir, "nowhere.git"))

    expect { command.call(working_dir: wt) }.to raise_error(Workspace::Error) { |e|
      expect(e.code).to eq("no_remote")
      expect(e.message).to start_with("Could not push 'feature/x'")
    }
  end

  it "reports push_network with a retry hint when the push cannot reach the host" do
    allow(git).to receive(:push).and_return([false, "fatal: unable to access 'https://x.test/a.git/': Could not resolve host: x.test\n"])

    expect { command.call(working_dir: wt) }.to raise_error(Workspace::Error) { |e|
      expect(e.code).to eq("push_network")
      expect(e.details).to include("permanent" => false)
      expect(e.retry).to eq("flags" => [], "destructive" => false)
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
    git_missing = Workspace::Git.new(output: StringIO.new, input: StringIO.new, runner: ->(argv, chdir:, timeout:, env: {}) { raise Errno::ENOENT })
    cmd = described_class.new(git: git_missing, checkout: checkout, pr_status: pr_status, output: output)

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
  it "leases a forced push on the upstream commit it compared, without asking gh" do
    push_feature
    old_tip = remote_tip
    rebase_feature
    allow(git).to receive(:push).and_call_original

    expect(run_json).to include("outcome" => "pushed", "forced" => true)
    expect(git).to have_received(:push).with(wt, "feature/x", set_upstream: false, dest: nil, lease: old_tip)
  end

  it "asks gh nothing for a pr-N branch whose upstream is on another remote" do
    push_feature
    sh("remote", "add", "upstream", remote, dir: wt)
    sh("fetch", "-q", "upstream", dir: wt)
    sh("switch", "-q", "-c", "pr-123", "--track", "upstream/feature/x", dir: wt)

    expect { command.call(working_dir: wt) }.to raise_error(Workspace::Error) { |e|
      expect(e.details).to include("reason" => "upstream_mismatch", "upstream" => "upstream/feature/x")
      expect(e.details).not_to have_key("pr_check")
    }
  end

  it "pushes a branch named +foo to +foo, never forcing origin's foo" do
    sh("push", "-q", "origin", "main:refs/heads/foo", dir: wt)
    foo_tip = rev("refs/heads/foo", dir: remote)
    sh("switch", "-q", "-c", "+foo", dir: wt)
    commit_file("plus.txt", "plus\n", "plus", dir: wt)

    expect(run_json).to include("branch" => "+foo", "outcome" => "pushed", "forced" => false)
    expect(rev("refs/heads/foo", dir: remote)).to eq(foo_tip)
    expect(rev("refs/heads/+foo", dir: remote)).to eq(rev("HEAD", dir: wt))
  end

  context "with a pull request checkout (pr-N tracking origin/<head>)" do
    let(:origin_url) { "git@github.com:acme/api.git" }
    let(:overrides) { {} }

    def head_facts
      {"available" => true, "state" => "OPEN", "cross_repository" => false, "head_ref" => "feature/x",
       "head_sha" => remote_tip, "head_owner" => "Acme", "head_name" => "API"}.merge(overrides)
    end

    def pr_branch_on_remote?
      sh_status("rev-parse", "--verify", "--quiet", "refs/heads/pr-123", dir: remote).last
    end

    before do
      push_feature
      sh("switch", "-q", "-c", "pr-123", "--track", "origin/feature/x", dir: wt)
      allow(git).to receive(:remote_url).with(wt).and_return(origin_url)
      allow(git).to receive(:push_urls).with(wt).and_return([origin_url])
      allow(pr_status).to receive(:head) { head_facts }
    end

    it "pushes to the pull request's head branch once gh confirms it" do
      commit_file("fix.txt", "fix\n", "fix", dir: wt)

      expect(run_json).to include("branch" => "pr-123", "remote_branch" => "feature/x", "outcome" => "pushed", "forced" => false)
      expect(remote_tip).to eq(rev("HEAD", dir: wt))
      expect(pr_branch_on_remote?).to be(false)
      expect(pr_status).to have_received(:head).with(wt, number: 123, repo: "github.com/acme/api")
    end

    it "says where it pushed" do
      commit_file("fix.txt", "fix\n", "fix", dir: wt)
      command.call(working_dir: wt)
      rebase_feature
      command.call(working_dir: wt)

      expect(output.string.lines.map(&:chomp)).to eq([
        "Pushed pr-123 to origin/feature/x (pull request #123).",
        "Force-pushed pr-123 to origin/feature/x (pull request #123) (with lease) after a rebase."
      ])
    end

    it "leases a push after a rebase on the head commit gh gave" do
      head = remote_tip
      rebase_feature
      allow(git).to receive(:push).and_call_original

      expect(run_json).to include("remote_branch" => "feature/x", "outcome" => "pushed", "forced" => true)
      expect(git).to have_received(:push).with(wt, "pr-123", set_upstream: false, dest: "feature/x", lease: head)
      expect(remote_tip).to eq(rev("HEAD", dir: wt))
      expect(pr_branch_on_remote?).to be(false)
    end

    it "reports up_to_date with the head branch" do
      expect(run_json).to include("remote_branch" => "feature/x", "outcome" => "up_to_date")
    end

    shared_examples "a refused pull request push" do |check, permanent: true|
      it "refuses with pr_check #{check} and pushes nothing" do
        commit_file("fix.txt", "fix\n", "fix", dir: wt)
        before_tip = remote_tip

        expect { command.call(json: true, working_dir: wt) }.to raise_error(Workspace::Error) { |e|
          expect(e.code).to eq("push_rejected")
          expect(e.details).to include("reason" => "upstream_mismatch", "pr_check" => check, "branch" => "pr-123", "permanent" => permanent)
        }
        expect(remote_tip).to eq(before_tip)
        expect(pr_branch_on_remote?).to be(false)
      end
    end

    {
      "pr_closed" => {"state" => "MERGED"},
      "cross_repository" => {"cross_repository" => true},
      "head_mismatch" => {"head_ref" => "feature/y"},
      "repo_mismatch" => {"head_owner" => "someone-else"},
      "sha_mismatch" => {"head_sha" => "0" * 40}
    }.each do |check, facts|
      context "when gh says #{facts}" do
        let(:overrides) { facts }

        include_examples "a refused pull request push", check
      end
    end

    context "when gh is missing" do
      let(:overrides) { {"available" => false, "reason" => "gh_missing"} }

      include_examples "a refused pull request push", "gh_missing", permanent: false
    end

    context "when gh runs past its time limit" do
      let(:overrides) { {"available" => false, "reason" => "timeout"} }

      include_examples "a refused pull request push", "gh_failed", permanent: false

      it "says it timed out and that the same command may pass" do
        expect { command.call(working_dir: wt) }.to raise_error(Workspace::Error) { |e|
          expect(e.details).to include("timed_out" => true)
          expect(e.retry).to eq("flags" => [], "destructive" => false)
        }
      end
    end

    it "marks other gh failures not timed out, with no retry hint" do
      allow(pr_status).to receive(:head).and_return("available" => false, "reason" => "error", "detail" => "HTTP 502")

      expect { command.call(working_dir: wt) }.to raise_error(Workspace::Error) { |e|
        expect(e.details).to include("pr_check" => "gh_failed", "timed_out" => false, "permanent" => false)
        expect(e.retry).to be_nil
      }
    end

    it "refuses with sha_mismatch when origin moved after gh answered" do
      gh_head = remote_tip
      allow(pr_status).to receive(:head) { head_facts.merge("head_sha" => gh_head) }
      clone_other
      sh("switch", "-q", "feature/x", dir: other)
      commit_file("teammate.txt", "hi\n", "teammate work", dir: other)
      sh("push", "-q", "origin", "feature/x", dir: other)
      teammate_tip = remote_tip
      commit_file("fix.txt", "fix\n", "fix", dir: wt)

      expect { command.call(working_dir: wt) }.to raise_error(Workspace::Error) { |e|
        expect(e.details).to include("pr_check" => "sha_mismatch", "permanent" => true)
      }
      expect(remote_tip).to eq(teammate_tip)
    end

    it "sends the lease with full refs to git on the forced path" do
      head = remote_tip
      rebase_feature
      argvs = []
      recording = Workspace::Git.new(output: StringIO.new, input: StringIO.new, runner: ->(argv, **opts) {
        argvs << argv
        Workspace::TimedProcess.run(argv, **opts)
      })
      allow(recording).to receive(:remote_url).with(wt).and_return(origin_url)
      allow(recording).to receive(:push_urls).with(wt).and_return([origin_url])
      cmd = described_class.new(git: recording, checkout: checkout, pr_status: pr_status, output: output)

      cmd.call(working_dir: wt)

      expect(argvs.select { |a| a[1] == "push" }).to eq([["git", "push", "--force-with-lease=refs/heads/feature/x:#{head}", "origin",
        "refs/heads/pr-123:refs/heads/feature/x"]])
      expect(remote_tip).to eq(rev("HEAD", dir: wt))
    end

    context "when git lists no push URL" do
      before { allow(git).to receive(:push_urls).with(wt).and_return([]) }

      include_examples "a refused pull request push", "repo_mismatch"
    end

    context "when git can't list the push URLs" do
      before { allow(git).to receive(:push_urls).with(wt).and_return(nil) }

      include_examples "a refused pull request push", "repo_mismatch"
    end

    it "pushes a pr-N branch with no upstream to its own name, with no gh call" do
      sh("branch", "-q", "--unset-upstream", dir: wt)
      commit_file("fix.txt", "fix\n", "fix", dir: wt)
      feature_tip = remote_tip

      expect(run_json).to include("branch" => "pr-123", "remote_branch" => "pr-123", "outcome" => "pushed")
      expect(pr_status).not_to have_received(:head)
      expect(remote_tip).to eq(feature_tip)
      expect(rev("refs/heads/pr-123", dir: remote)).to eq(rev("HEAD", dir: wt))
    end

    it "gives gh's first line for not_logged_in and gh_failed" do
      {"not_logged_in" => "To get started with GitHub CLI, please run:  gh auth login", "error" => "GraphQL: Could not resolve"}.each do |reason, detail|
        allow(pr_status).to receive(:head).and_return("available" => false, "reason" => reason, "detail" => detail)

        expect { command.call(working_dir: wt) }.to raise_error(Workspace::Error) { |e|
          expect(e.details).to include("pr_check" => (reason == "error") ? "gh_failed" : "not_logged_in", "detail" => detail)
        }
      end
    end

    it "refuses a head repository gh does not name" do
      allow(pr_status).to receive(:head) { head_facts.merge("head_owner" => nil, "head_name" => nil) }

      expect { command.call(working_dir: wt) }.to raise_error(Workspace::Error) { |e| expect(e.details["pr_check"]).to eq("repo_mismatch") }
    end

    it "reports a head commit that is not a commit id, or none, as gh_failed" do
      ["--upload-pack=x", nil].each do |sha|
        allow(pr_status).to receive(:head) { head_facts.merge("head_sha" => sha) }

        expect { command.call(working_dir: wt) }.to raise_error(Workspace::Error) { |e| expect(e.details).to include("pr_check" => "gh_failed", "timed_out" => false) }
      end
    end

    context "when a push URL names another repository" do
      before { allow(git).to receive(:push_urls).with(wt).and_return([origin_url, "https://github.com/evil/api.git"]) }

      include_examples "a refused pull request push", "repo_mismatch"

      it "asks gh nothing" do
        expect { command.call(working_dir: wt) }.to raise_error(Workspace::Error)
        expect(pr_status).not_to have_received(:head)
      end
    end

    context "when origin's URL is not a GitHub repository URL" do
      let(:origin_url) { "/srv/git/api.git" }

      include_examples "a refused pull request push", "repo_mismatch"
    end

    context "when the head branch is the default branch" do
      before { sh("branch", "-q", "--set-upstream-to=origin/main", dir: wt) }

      it "refuses with pr_check default_branch, asking gh nothing" do
        expect { command.call(working_dir: wt) }.to raise_error(Workspace::Error) { |e|
          expect(e.details).to include("reason" => "upstream_mismatch", "pr_check" => "default_branch", "upstream" => "origin/main")
        }
        expect(pr_status).not_to have_received(:head)
        expect(rev("refs/heads/main", dir: remote)).to eq(rev("main"))
      end
    end
  end
end
