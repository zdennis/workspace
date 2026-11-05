require "spec_helper"
require "tmpdir"
require "open3"
require "stringio"
require "yaml"
require "json"

RSpec.describe Workspace::Commands::Finish, "with a real repository" do
  around do |example|
    Dir.mktmpdir("finish-int") do |dir|
      @dir = File.realpath(dir)
      example.run
    end
  end

  let(:remote) { File.join(@dir, "remote.git") }
  let(:repo) { File.join(@dir, "app") }
  let(:worktree) { File.join(@dir, "app-feature") }
  let(:config_path) { File.join(@dir, "workspace.app.worktree-feature.yml") }
  let(:output) { StringIO.new }
  let(:real_git) { Workspace::Git.new(output: StringIO.new, input: StringIO.new) }
  let(:project_config) { double("project_config", config_path_for: config_path) }
  let(:kill_command) { double("kill_command", notes_inside_worktree: nil, dev_stopped: false, call: nil) }
  let(:project_detector) { instance_double(Workspace::ProjectDetector) }

  subject(:command) do
    described_class.new(git: real_git, project_config: project_config, kill_command: kill_command,
      project_detector: project_detector, output: output, error_output: StringIO.new, input: StringIO.new)
  end

  def git(path, *args)
    out, status = Open3.capture2e("git", "-C", path, "-c", "user.name=t", "-c", "user.email=t@example.com", *args)
    raise out unless status.success?
    out
  end

  def commit(path, name)
    File.write(File.join(path, name), name)
    git(path, "add", name)
    git(path, "commit", "-q", "-m", name)
  end

  before do
    Open3.capture2e("git", "init", "-q", "--bare", "-b", "main", remote)
    Open3.capture2e("git", "init", "-q", "-b", "main", repo)
    git(repo, "remote", "add", "origin", remote)
    commit(repo, "base")
    git(repo, "push", "-q", "-u", "origin", "main")
    git(repo, "worktree", "add", "-q", "-b", "feature", worktree)
    commit(worktree, "work")
    git(worktree, "push", "-q", "-u", "origin", "feature")
    File.write(config_path, YAML.dump("name" => "app-feature", "root" => worktree))
  end

  def outcome
    command.call("app.worktree-feature", json: true, working_dir: @dir)
    JSON.parse(output.string)["outcome"]
  end

  it "reports pushed while the branch's commits are not on origin's default branch" do
    expect(outcome).to eq("pushed")
  end

  it "reports merged once origin's default branch holds the branch's commits" do
    git(worktree, "push", "-q", "origin", "feature:main")

    expect(outcome).to eq("merged")
  end

  it "reports merged for a branch with no commits of its own" do
    git(worktree, "reset", "-q", "--hard", "main")
    git(worktree, "push", "-q", "-f", "origin", "feature")

    expect(outcome).to eq("merged")
  end
end
