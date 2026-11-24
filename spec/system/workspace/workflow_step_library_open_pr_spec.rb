require "spec_helper"
require "tmpdir"
require "open3"

RSpec.describe "the open_pr library step's proof" do
  let(:step) { YAML.safe_load_file(File.join(PROJECT_ROOT, "lib", "workflows", "steps", "open_pr.yml")).dig("steps", "open_pr") }
  let(:command) { step.dig("status", "run") }

  around do |example|
    Dir.mktmpdir("open-pr") do |dir|
      @dir = File.realpath(dir)
      example.run
    end
  end

  let(:repo) { File.join(@dir, "repo") }
  let(:artifacts) { File.join(@dir, "artifacts") }
  let(:bin) { File.join(@dir, "bin") }
  let(:called) { File.join(@dir, "gh-called") }

  def git(*args)
    out, status = Open3.capture2e({"GIT_CONFIG_GLOBAL" => "/dev/null", "GIT_CONFIG_NOSYSTEM" => "1"},
      "git", "-C", repo, "-c", "user.name=t", "-c", "user.email=t@example.com", "-c", "commit.gpgsign=false", *args)
    raise "git #{args.join(" ")}: #{out}" unless status.success?
    out.strip
  end

  let(:expected_args) { 'pr view 42 --json state,headRefOid --jq .state+" "+.headRefOid' }

  # A fake gh that records its arguments, exits 64 for any call but the expected one, then prints a canned line or exits non-zero.
  def fake_gh(line, exit_code: 0)
    path = File.join(bin, "gh")
    File.write(path, "#!/bin/sh\necho \"$*\" >> '#{called}'\n[ \"$*\" = '#{expected_args}' ] || exit 64\n#{"echo '#{line}'\n" if line}exit #{exit_code}\n")
    File.chmod(0o755, path)
  end

  def pr_file(text)
    File.write(File.join(artifacts, "pr.md"), text)
  end

  def check_exit
    env = {"WORKSPACE_RUN_ARTIFACTS" => artifacts, "PATH" => "#{bin}:/usr/bin:/bin"}
    _out, status = Open3.capture2e(env, "sh", "-c", command, chdir: repo)
    status.exitstatus
  end

  before do
    FileUtils.mkdir_p([repo, artifacts, bin])
    git("init", "-q", "-b", "main")
    File.write(File.join(repo, "a"), "x\n")
    git("add", "-A")
    git("commit", "-q", "-m", "start")
    @head = git("rev-parse", "HEAD")
  end

  it "passes when the pull request is open at the branch's HEAD" do
    pr_file("pr: 42\nhttps://example.com/pull/42\n")
    fake_gh("OPEN #{@head}")
    expect(check_exit).to eq(0)
    expect(File.read(called).strip).to eq(expected_args)
  end

  ["pr: 42 \n", "pr: 42\r\n", "pr: 42\r"].each do |text|
    it "passes with trailing whitespace or a CR on line 1 (#{text.inspect})" do
      pr_file(text)
      fake_gh("OPEN #{@head}")
      expect(check_exit).to eq(0)
      expect(File.read(called).strip).to eq(expected_args)
    end
  end

  it "fails when the pull request is closed" do
    pr_file("pr: 42\n")
    fake_gh("CLOSED #{@head}")
    expect(check_exit).to eq(1)
    expect(File.read(called).strip).to eq(expected_args)
  end

  it "fails when the pull request's head is not HEAD" do
    pr_file("pr: 42\n")
    fake_gh("OPEN #{"0" * 40}")
    expect(check_exit).to eq(1)
    expect(File.read(called).strip).to eq(expected_args)
  end

  it "fails on a non-digit number without calling gh" do
    pr_file("pr: abc\n")
    fake_gh("OPEN #{@head}")
    expect(check_exit).to eq(1)
    expect(File.exist?(called)).to be(false)
  end

  it "fails when pr.md is missing, without calling gh" do
    fake_gh("OPEN #{@head}")
    expect([1, 2]).to include(check_exit) # sed's own failure: 1 for BSD sed, 2 for GNU
    expect(File.exist?(called)).to be(false)
  end

  it "fails when gh exits non-zero" do
    pr_file("pr: 42\n")
    fake_gh(nil, exit_code: 1)
    expect(check_exit).to eq(1)
    expect(File.read(called).strip).to eq(expected_args)
  end
end
