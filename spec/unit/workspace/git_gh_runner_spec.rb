require "stringio"

RSpec.describe Workspace::Git, "#checkout_pr_worktree with a gh_runner" do
  let(:output) { StringIO.new }
  let(:status_class) do
    Struct.new(:ok) do
      def success? = ok
    end
  end
  let(:calls) { [] }
  let(:reply) { ["", "", status_class.new(true)] }
  let(:gh_runner) do
    ->(env, *cmd, chdir:) do
      calls << {env: env, cmd: cmd, chdir: chdir}
      reply
    end
  end

  subject(:git) { described_class.new(output: output, gh_runner: gh_runner) }

  it "runs gh pr checkout with prompts off, from chdir, and nothing else" do
    git.checkout_pr_worktree("/wt/pr-835", number: "835", repo: nil, branch: "pr-835", chdir: "/repo", quiet: true)

    expect(calls).to eq([{env: {"GH_PROMPT_DISABLED" => "1"},
                          cmd: %w[gh pr checkout 835 --worktree /wt/pr-835 --branch pr-835], chdir: "/repo"}])
  end

  it "reports a gh that is too old" do
    reply[1] = "unknown flag: --worktree"
    reply[2] = status_class.new(false)
    expect { git.checkout_pr_worktree("/wt", number: "1", repo: nil, branch: "b", chdir: "/repo", quiet: true) }
      .to raise_error(Workspace::Error, /too old/)
  end

  it "reports a missing gh" do
    missing = ->(*, **) { raise Errno::ENOENT, "gh" }
    expect { described_class.new(output: output, gh_runner: missing).checkout_pr_worktree("/wt", number: "1", repo: nil, branch: "b", chdir: "/repo", quiet: true) }
      .to raise_error(Workspace::Error, /`gh` is not installed/)
  end
end
