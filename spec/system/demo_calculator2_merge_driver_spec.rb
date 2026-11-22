require "spec_helper"
require "tmpdir"
require "open3"
require "shellwords"

# git runs the driver itself: two branches add test methods to the same spot of calc_test.rb, where `merge=union` interleaved their `end` lines.
RSpec.describe "calc_test.rb merge driver" do
  let(:tmp) { Dir.mktmpdir }
  let(:driver) { File.join(PROJECT_ROOT, "script", "demo_calculator2", "merge_test_methods") }
  let(:path) { "demo/calculator2/test/calc_test.rb" }

  after { FileUtils.rm_rf(tmp) }

  def git(*args, check: true)
    out, status = Open3.capture2e("git", "-C", tmp, *args)
    raise "git #{args.join(" ")}: #{out}" if check && !status.success?
    [out, status.success?]
  end

  def commit_method(name, body)
    text = File.read(File.join(tmp, path)).sub(/^end\n\z/, "  def #{name}\n    #{body}\n  end\nend\n")
    File.write(File.join(tmp, path), text)
    git("commit", "-qam", name)
  end

  before do
    git("init", "-q", "-b", "main")
    git("config", "user.email", "t@example.com")
    git("config", "user.name", "t")
    git("config", "merge.calc-demo-tests.driver", "ruby #{Shellwords.escape(driver)} %O %A %B")
    FileUtils.mkdir_p(File.dirname(File.join(tmp, path)))
    File.write(File.join(tmp, path), "require \"minitest/autorun\"\n\nclass CalcTest < Minitest::Test\n  def test_smoke\n    assert true\n  end\nend\n")
    FileUtils.mkdir_p(File.join(tmp, ".git", "info"))
    File.write(File.join(tmp, ".git", "info", "attributes"), "#{path} merge=calc-demo-tests\n")
    git("add", "-A")
    git("commit", "-qm", "base")
    git("checkout", "-qb", "lane-b")
    commit_method("test_json", "assert_equal 1, 1")
    git("checkout", "-q", "main")
  end

  it "merges both lanes' added methods into a file that parses" do
    commit_method("test_add", "assert_equal 3, 1 + 2")
    _, ok = git("merge", "--no-edit", "lane-b")
    expect(ok).to be(true)
    merged = File.read(File.join(tmp, path))
    expect(merged).to include("def test_add", "def test_json", "def test_smoke")
    _, status = Open3.capture2e("ruby", "-c", File.join(tmp, path))
    expect(status.success?).to be(true)
  end

  it "reports a conflict when the lanes add the same name with different bodies" do
    commit_method("test_json", "assert_equal 2, 2")
    out, ok = git("merge", "--no-edit", "lane-b", check: false)
    expect(ok).to be(false)
    expect(out).to include("CONFLICT")
  end
end
