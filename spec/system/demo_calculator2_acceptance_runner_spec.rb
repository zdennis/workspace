require "spec_helper"
require "open3"
require "tmpdir"
require "fileutils"

RSpec.describe "script/demo_calculator2/acceptance_runner", type: :system do
  runner = File.join(PROJECT_ROOT, "script", "demo_calculator2", "acceptance_runner")
  reference = File.join(PROJECT_ROOT, "spec", "fixtures", "demo_calculator", "reference")
  acceptance = File.join(PROJECT_ROOT, "demo", "calculator2", "acceptance")
  ref = "refs/demo-calc2/acceptance-base"

  def git(dir, *args)
    out, err, st = Open3.capture3("git", "-C", dir, *args)
    raise "git #{args.join(" ")}: #{err}" unless st.success?
    out
  end

  def run_runner(runner, dir, *args, env: {})
    Bundler.with_unbundled_env { Open3.capture3(env, runner, *args, chdir: dir) }
  end

  def build_repo(dir, acceptance, calc_source, ref)
    git(dir, "init", "-q")
    git(dir, "config", "user.email", "t@example.com")
    git(dir, "config", "user.name", "t")
    FileUtils.mkdir_p(File.join(dir, "demo", "calculator2"))
    FileUtils.cp_r(acceptance, File.join(dir, "demo", "calculator2", "acceptance"))
    git(dir, "add", "-A")
    git(dir, "commit", "-q", "-m", "base")
    git(dir, "update-ref", ref, "HEAD")
    FileUtils.cp_r(File.join(calc_source, "."), File.join(dir, "demo", "calculator2")) if calc_source
    # Nothing under acceptance in the working tree may influence the run.
    FileUtils.rm_rf(File.join(dir, "demo", "calculator2", "acceptance"))
    git(dir, "add", "-A")
    git(dir, "commit", "-q", "--allow-empty", "-m", "work")
  end

  def build_custom_repo(dir, ref, body)
    git(dir, "init", "-q")
    git(dir, "config", "user.email", "t@example.com")
    git(dir, "config", "user.name", "t")
    FileUtils.mkdir_p(File.join(dir, "demo", "calculator2", "acceptance"))
    File.write(File.join(dir, "demo", "calculator2", "acceptance", "group_1_x_test.rb"), body)
    git(dir, "add", "-A")
    git(dir, "commit", "-q", "-m", "base")
    git(dir, "update-ref", ref, "HEAD")
  end

  it "counts the failures it does not show past the eighth" do
    tests = (1..10).map { |n| "  def test_n#{n}\n    flunk \"no #{n}\"\n  end\n" }.join
    build_custom_repo(dir, ref, "require \"minitest/autorun\"\nclass G1 < Minitest::Test\n#{tests}end\n")
    out, _, status = run_runner(runner, dir, "demo/calculator2/goals/01-x.md")
    expect(status.exitstatus).to eq(1)
    expect(out).to include("(2 more failures not shown)")
  end

  it "exits 2 when the ref holds no test file for a group the goal asks for" do
    build_custom_repo(dir, ref, "require \"minitest/autorun\"\nclass G1 < Minitest::Test\n  def test_ok = assert(true)\nend\n")
    _, err, status = run_runner(runner, dir, "demo/calculator2/goals/02-y.md")
    expect(status.exitstatus).to eq(2)
    expect(err).to include("group 2 test file missing")
  end

  around do |example|
    Dir.mktmpdir { |dir|
      @dir = [dir]
      example.run
    }
  end

  let(:dir) { @dir.first }

  it "rejects a goal file name that maps to no group" do
    _, err, status = run_runner(runner, dir, "goals/notes.md")
    expect(status.exitstatus).to eq(2)
    expect(err).to include("0N-name.md")
  end

  it "rejects a missing goal argument" do
    _, err, status = run_runner(runner, dir)
    expect(status.exitstatus).to eq(2)
    expect(err).to include("usage")
  end

  it "says the ref is missing" do
    git(dir, "init", "-q")
    _, err, status = run_runner(runner, dir, "demo/calculator2/goals/01-add-sub.md")
    expect(status.exitstatus).to eq(2)
    expect(err).to include("acceptance ref is missing")
  end

  it "passes groups 1 and 2 against a working calculator, from the checkout root" do
    build_repo(dir, acceptance, reference, ref)
    out, err, status = run_runner(runner, dir, "demo/calculator2/goals/02-mul-div.md")
    expect(status.exitstatus).to eq(0), "#{out}\n#{err}"
    expect(out).to include("group 1: pass", "group 2: pass")
  end

  it "accepts --root and a ref from the environment" do
    build_repo(dir, acceptance, reference, ref)
    git(dir, "update-ref", "refs/other/base", ref)
    out, err, status = run_runner(runner, PROJECT_ROOT, "--root", dir, "01-add-sub.md", env: {"CALC2_ACCEPTANCE_REF" => "refs/other/base"})
    expect(status.exitstatus).to eq(0), "#{out}\n#{err}"
  end

  it "uses the git toplevel as root when run from a subdirectory" do
    build_repo(dir, acceptance, reference, ref)
    sub = File.join(dir, "demo", "calculator2")
    out, err, status = run_runner(runner, sub, "goals/01-add-sub.md")
    expect(status.exitstatus).to eq(0), "#{out}\n#{err}"
  end

  it "exits 2 outside a git repository without --root" do
    _, err, status = run_runner(runner, dir, "01-add-sub.md")
    expect(status.exitstatus).to eq(2)
    expect(err).to include("not inside a git repository")
  end

  it "refuses with exit 1 when untracked files are present" do
    build_repo(dir, acceptance, reference, ref)
    File.write(File.join(dir, "stray.txt"), "x")
    out, _, status = run_runner(runner, dir, "demo/calculator2/goals/01-add-sub.md")
    expect(status.exitstatus).to eq(1)
    expect(out).to include("untracked files")
    expect(out).not_to include("group 1")
  end

  it "prints only a generic line when a failing group has no recognisable summary" do
    build_custom_repo(dir, ref, "puts \"SECRET_SOURCE_LINE\"\nexit 3\n")
    out, _, status = run_runner(runner, dir, "demo/calculator2/goals/01-x.md")
    expect(status.exitstatus).to eq(1)
    expect(out).to include("group 1 failed (no summary)")
    expect(out).not_to include("SECRET_SOURCE_LINE")
  end

  it "fails with a short summary that holds no test source" do
    build_repo(dir, acceptance, nil, ref)
    FileUtils.mkdir_p(File.join(dir, "demo", "calculator2", "bin"))
    File.write(File.join(dir, "demo", "calculator2", "bin", "calc"), "puts 99\n")
    git(dir, "add", "-A")
    git(dir, "commit", "-q", "-m", "calc")
    out, _, status = run_runner(runner, dir, "demo/calculator2/goals/01-add-sub.md")
    expect(status.exitstatus).to eq(1)
    expect(out).to include("group 1: FAIL", "FAILED group 1 test_addition")
    expect(out.lines.size).to be < 40
    expect(out).not_to include("assert_value", "def test_", "Group1AddSubTest", "support.rb")
  end
end
