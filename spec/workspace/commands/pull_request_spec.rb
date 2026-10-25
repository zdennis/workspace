require "spec_helper"
require "tmpdir"
require "open3"
require "json"

RSpec.describe Workspace::Commands::PullRequest do
  around do |example|
    Dir.mktmpdir("pr-cmd") do |dir|
      @dir = File.realpath(dir)
      example.run
    end
  end

  let(:remote) { File.join(@dir, "remote.git") }
  let(:repo) { File.join(@dir, "api") }
  let(:output) { StringIO.new }
  let(:git) { Workspace::Git.new(output: StringIO.new, input: StringIO.new, runner: runner) }
  let(:project_config) { instance_double(Workspace::ProjectConfig) }
  let(:project_detector) { instance_double(Workspace::ProjectDetector, detect: "api") }
  let(:status) { instance_double(Workspace::PullRequestStatus, call: {"available" => true, "found" => false}) }
  let(:calls) { [] }
  let(:gh_reply) { ["https://github.com/o/r/pull/41\n", "", true] }
  let(:runner) do
    lambda do |argv, chdir:, timeout:, env: {}|
      calls << {argv: argv, chdir: chdir, timeout: timeout}
      argv.include?("git") ? Workspace::TimedProcess.run(argv, chdir: chdir, timeout: timeout, env: env) : gh_reply
    end
  end
  subject(:command) do
    described_class.new(git: git, project_config: project_config, project_detector: project_detector, status: status, runner: runner, output: output)
  end

  def sh(*args, dir: repo)
    out, st = Open3.capture2e("git", "-C", dir, "-c", "user.name=t", "-c", "user.email=t@example.com", "-c", "gc.auto=0", "-c", "maintenance.auto=false", *args)
    raise out unless st.success?
    out
  end

  def document = JSON.parse(output.string)

  def gh_calls = calls.select { |c| c[:argv].first == "gh" }

  before do
    sh("init", "-q", "--bare", "-b", "main", remote, dir: @dir)
    FileUtils.mkdir_p(repo)
    sh("init", "-q", "-b", "main")
    sh("commit", "-q", "--allow-empty", "-m", "init")
    sh("remote", "add", "origin", remote)
    sh("push", "-q", "-u", "origin", "main")
    sh("switch", "-q", "-c", "feature/x")
    sh("commit", "-q", "--allow-empty", "-m", "work")
    allow(project_config).to receive(:project_root_for).with("api").and_return(repo)
  end

  describe "#create" do
    it "pushes a branch with no upstream, then runs gh pr create --fill" do
      command.create(working_dir: repo)

      expect(calls.map { |c| c[:argv] }).to eq([%w[git push -u origin feature/x], %w[gh pr create --fill]])
      expect(sh("rev-parse", "--abbrev-ref", "feature/x@{u}").strip).to eq("origin/feature/x")
      expect(calls.map { |c| c[:chdir] }.uniq).to eq([repo])
    end

    it "does not push when the branch already has an upstream" do
      sh("push", "-q", "-u", "origin", "feature/x")

      command.create(working_dir: repo)

      expect(calls.map { |c| c[:argv] }).to eq([%w[gh pr create --fill]])
    end

    it "adds --draft on request" do
      command.create(draft: true, working_dir: repo)

      expect(gh_calls.first[:argv]).to eq(%w[gh pr create --fill --draft])
    end

    it "returns the existing pull request without pushing or creating" do
      allow(status).to receive(:call).with(repo).and_return({"available" => true, "found" => true, "number" => 7, "url" => "https://github.com/o/r/pull/7"})

      command.create(json: true, working_dir: repo)

      expect(calls).to be_empty
      expect(document).to eq("schema_version" => 1, "ok" => true, "workspace" => "api", "outcome" => "existing",
        "url" => "https://github.com/o/r/pull/7", "number" => 7)
    end

    it "prints one JSON document and nothing else for a created pull request" do
      command.create(json: true, working_dir: repo)

      expect(document).to eq("schema_version" => 1, "ok" => true, "workspace" => "api", "outcome" => "created",
        "url" => "https://github.com/o/r/pull/41", "number" => 41)
    end

    context "when gh prints more than the URL" do
      let(:gh_reply) { ["Creating pull request\nhttps://github.com/o/r/pull/41\n", "", true] }

      it "uses the last line as the URL" do
        command.create(json: true, working_dir: repo)

        expect(document).to include("url" => "https://github.com/o/r/pull/41", "number" => 41)
      end
    end

    context "when gh succeeds but prints nothing" do
      let(:gh_reply) { ["\n", "", true] }

      it "raises instead of reporting a created pull request" do
        expect { command.create(json: true, working_dir: repo) }.to raise_error(Workspace::Error, /printed no pull request URL/)
      end
    end

    context "when the URL has no pull number" do
      let(:gh_reply) { ["https://example.test/review/abc\n", "", true] }

      it "reports a null number" do
        command.create(json: true, working_dir: repo)

        expect(document).to include("url" => "https://example.test/review/abc", "number" => nil)
      end
    end

    it "says in text what it did" do
      command.create(working_dir: repo)

      expect(output.string).to include("Pushed feature/x to origin")
      expect(output.string).to include("Created pull request: https://github.com/o/r/pull/41")
    end

    it "says in text that a pull request already exists" do
      allow(status).to receive(:call).and_return({"available" => true, "found" => true, "number" => 7, "url" => "https://github.com/o/r/pull/7"})

      command.create(working_dir: repo)

      expect(output.string).to eq("Pull request already exists: https://github.com/o/r/pull/7\n")
    end

    it "keeps push progress out of the JSON document" do
      command.create(json: true, working_dir: repo)

      expect(output.string.lines.size).to eq(1)
    end

    it "refuses with nothing_to_push when the branch has no commits ahead of its base" do
      sh("switch", "-q", "main")
      sh("switch", "-q", "-c", "empty")

      expect { command.create(working_dir: repo) }.to raise_error(Workspace::Error) { |e|
        expect(e.code).to eq("nothing_to_push")
        expect(e.details).to include("branch" => "empty", "base" => "origin/main")
      }
      expect(calls).to be_empty
    end

    it "carries on when no base branch can be found" do
      allow(git).to receive(:base_ref).and_return(nil)

      command.create(working_dir: repo)

      expect(gh_calls.size).to eq(1)
    end

    it "carries on when git cannot count the commits ahead of the base" do
      allow(git).to receive(:commits_ahead_of).and_return(nil)

      command.create(working_dir: repo)

      expect(gh_calls.size).to eq(1)
    end

    it "refuses a detached HEAD" do
      sh("switch", "-q", "--detach")

      expect { command.create(working_dir: repo) }.to raise_error(Workspace::Error, /detached HEAD/)
      expect(calls).to be_empty
    end

    it "names the push error when the push fails" do
      sh("remote", "set-url", "origin", File.join(@dir, "missing.git"))

      expect { command.create(working_dir: repo) }.to raise_error(Workspace::Error, /Could not push 'feature\/x'/) { |e| expect(e.code).to eq("no_remote") }
      expect(gh_calls).to be_empty
    end

    it "refuses with gh_unavailable (missing) when gh is not installed" do
      allow(status).to receive(:call).and_return({"available" => false, "reason" => "gh_missing"})

      expect { command.create(working_dir: repo) }.to raise_error(Workspace::Error) { |e|
        expect(e.code).to eq("gh_unavailable")
        expect(e.details).to include("reason" => "missing")
      }
      expect(calls).to be_empty
    end

    it "refuses with gh_unavailable (missing) when gh disappears before the create" do
      cmd = described_class.new(git: git, project_config: project_config, project_detector: project_detector, status: status,
        runner: ->(argv, chdir:, timeout:, env: {}) {
          raise Errno::ENOENT if argv.first == "gh"
          Workspace::TimedProcess.run(argv, chdir: chdir, timeout: timeout, env: env)
        }, output: output)

      expect { cmd.create(working_dir: repo) }.to raise_error(Workspace::Error) { |e|
        expect(e.code).to eq("gh_unavailable")
        expect(e.details).to include("reason" => "missing")
      }
    end

    it "refuses with gh_unavailable (not_logged_in) when gh says it has no login" do
      auth = "To get started with GitHub CLI, please run:  gh auth login\n"
      cmd = described_class.new(git: git, project_config: project_config, project_detector: project_detector, status: status,
        runner: ->(argv, chdir:, timeout:, env: {}) { argv.include?("git") ? Workspace::TimedProcess.run(argv, chdir: chdir, timeout: timeout, env: env) : ["", auth, false] }, output: output)

      expect { cmd.create(working_dir: repo) }.to raise_error(Workspace::Error) { |e|
        expect(e.code).to eq("gh_unavailable")
        expect(e.details).to include("reason" => "not_logged_in", "detail" => "To get started with GitHub CLI, please run:  gh auth login")
        expect(e.message).to include("gh auth login")
      }
    end

    it "raises gh's own message when the create fails for another reason" do
      cmd = described_class.new(git: git, project_config: project_config, project_detector: project_detector, status: status,
        runner: ->(argv, chdir:, timeout:, env: {}) { argv.include?("git") ? Workspace::TimedProcess.run(argv, chdir: chdir, timeout: timeout, env: env) : ["", "base branch not found\n", false] }, output: output)

      expect { cmd.create(working_dir: repo) }.to raise_error(Workspace::Error, /Could not open a PR for 'api': base branch not found/)
    end

    it "raises when gh does not answer in time" do
      cmd = described_class.new(git: git, project_config: project_config, project_detector: project_detector, status: status,
        runner: ->(argv, chdir:, timeout:, env: {}) {
          raise Timeout::Error if argv.first == "gh"
          Workspace::TimedProcess.run(argv, chdir: chdir, timeout: timeout, env: env)
        }, output: output)

      expect { cmd.create(working_dir: repo) }.to raise_error(Workspace::Error, /did not answer within #{described_class::CREATE_TIMEOUT} seconds/o)
    end

    it "raises when the push does not finish in time" do
      timing_out = ->(argv, chdir:, timeout:, env: {}) { raise Timeout::Error }
      cmd = described_class.new(git: Workspace::Git.new(output: StringIO.new, input: StringIO.new, runner: timing_out),
        project_config: project_config, project_detector: project_detector, status: status, runner: timing_out, output: output)

      expect { cmd.create(working_dir: repo) }.to raise_error(Workspace::Error, /git push of .feature\/x. did not finish within 120 seconds/)
    end

    it "says git is not installed when the push cannot start it" do
      missing = ->(argv, chdir:, timeout:, env: {}) { raise Errno::ENOENT }
      cmd = described_class.new(git: Workspace::Git.new(output: StringIO.new, input: StringIO.new, runner: missing),
        project_config: project_config, project_detector: project_detector, status: status, runner: missing, output: output)

      expect { cmd.create(working_dir: repo) }.to raise_error(Workspace::Error, "git is not installed.")
    end

    it "says the branch was pushed when the create fails afterwards, keeping the error's code" do
      auth = "To get started with GitHub CLI, please run:  gh auth login\n"
      failing = ->(argv, chdir:, timeout:, env: {}) { argv.include?("git") ? Workspace::TimedProcess.run(argv, chdir: chdir, timeout: timeout, env: env) : ["", auth, false] }
      cmd = described_class.new(git: git, project_config: project_config, project_detector: project_detector, status: status, runner: failing, output: output)

      expect { cmd.create(working_dir: repo) }.to raise_error(Workspace::Error) { |e|
        expect(e.code).to eq("gh_unavailable")
        expect(e.message).to include("'feature/x' was already pushed to origin")
      }
    end

    it "does not claim a push when the failure comes before one" do
      cmd = described_class.new(git: git, project_config: project_config, project_detector: project_detector, status: status,
        runner: ->(argv, chdir:, timeout:, env: {}) { raise Workspace::Error, "boom" }, output: output)
      sh("push", "-q", "-u", "origin", "feature/x")

      expect { cmd.create(working_dir: repo) }.to raise_error(Workspace::Error) { |e|
        expect(e.message).not_to include("already pushed")
      }
    end

    it "refuses with gh_unavailable (not_logged_in) before pushing when the lookup shows no login" do
      allow(status).to receive(:call).and_return({"available" => false, "reason" => "error", "detail" => "To get started with GitHub CLI, please run:  gh auth login"})

      expect { command.create(working_dir: repo) }.to raise_error(Workspace::Error) { |e|
        expect(e.code).to eq("gh_unavailable")
        expect(e.details).to include("reason" => "not_logged_in")
      }
      expect(calls).to be_empty
    end

    it "goes ahead to create when the lookup failed for a reason other than gh being missing" do
      allow(status).to receive(:call).and_return({"available" => false, "reason" => "timeout"})

      command.create(working_dir: repo)

      expect(gh_calls.size).to eq(1)
    end

    it "gives the create and the push their own time limits" do
      command.create(working_dir: repo)

      expect(calls.map { |c| c[:timeout] }).to eq([Workspace::Git::PUSH_TIMEOUT, described_class::CREATE_TIMEOUT])
    end

    it "finds the workspace from the working directory" do
      command.create(working_dir: repo)

      expect(project_detector).to have_received(:detect).with(repo)
    end

    it "uses --name instead of the working directory" do
      command.create(name: "api", working_dir: "/elsewhere")

      expect(project_detector).not_to have_received(:detect)
      expect(gh_calls.first[:chdir]).to eq(repo)
    end

    it "refuses with not_in_workspace when no workspace is found" do
      allow(project_detector).to receive(:detect).and_return(nil)

      expect { command.create(working_dir: "/nowhere") }.to raise_error(Workspace::Error) { |e|
        expect(e.code).to eq("not_in_workspace")
        expect(e.details).to eq("path" => "/nowhere")
      }
    end

    it "refuses with unknown_workspace when the name has no checkout" do
      allow(project_config).to receive(:project_root_for).with("ghost").and_return(nil)

      expect { command.create(name: "ghost") }.to raise_error(Workspace::Error) { |e|
        expect(e.code).to eq("unknown_workspace")
        expect(e.details).to eq("name" => "ghost")
      }
    end
  end

  describe "#find_or_create" do
    it "gives the existing pull request back" do
      allow(status).to receive(:call).and_return({"available" => true, "found" => true, "number" => 7, "url" => "https://github.com/o/r/pull/7"})

      expect(command.find_or_create(repo)).to eq("outcome" => "existing", "url" => "https://github.com/o/r/pull/7", "number" => 7)
    end

    it "never pushes and never checks commits, and runs the block only before a create" do
      yielded = []

      result = command.find_or_create(repo, label: "api") { yielded << :before }

      expect(yielded).to eq([:before])
      expect(result).to eq("outcome" => "created", "url" => "https://github.com/o/r/pull/41", "number" => 41)
      expect(calls.map { |c| c[:argv] }).to eq([%w[gh pr create --fill]])
    end

    it "does not run the block for an existing pull request" do
      allow(status).to receive(:call).and_return({"available" => true, "found" => true, "number" => 7, "url" => "https://github.com/o/r/pull/7"})
      yielded = []

      command.find_or_create(repo) { yielded << :before }

      expect(yielded).to be_empty
    end

    it "words a failed create without a label as a pull request" do
      cmd = described_class.new(git: git, project_config: project_config, project_detector: project_detector, status: status,
        runner: ->(*, **) { ["", "boom\n", false] }, output: output)

      expect { cmd.find_or_create(repo) }.to raise_error(Workspace::Error, "Could not open a pull request: boom")
    end

    it "names the label in a failed create" do
      cmd = described_class.new(git: git, project_config: project_config, project_detector: project_detector, status: status,
        runner: ->(*, **) { ["", "boom\n", false] }, output: output)

      expect { cmd.find_or_create(repo, label: "api.worktree-x") }.to raise_error(Workspace::Error, /Could not open a PR for 'api.worktree-x': boom/)
    end
  end
end
