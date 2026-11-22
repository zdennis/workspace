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

# The path-agnostic driver command, the add-only write of it, and a clean two-lane merge through `Lanes#integrate`, all in a tmp repo of its own.
RSpec.describe "calc_test.rb merge driver through Lanes" do
  let(:tmp) { File.realpath(Dir.mktmpdir) }
  let(:out_dir) { File.realpath(Dir.mktmpdir) }
  let(:record_path) { File.join(out_dir, "run.json") }
  let(:scripts) { "script/demo_calculator2" }
  let(:path) { "demo/calculator2/test/calc_test.rb" }
  let(:driver_key) { "merge.calc-demo-tests.driver" }
  let(:workspace_calls) { [] }
  let(:exec) do
    lambda do |argv, chdir:|
      case argv[0]
      when "git"
        out, status = Open3.capture2(*argv, chdir: chdir)
        [out, status.success?]
      when "ws-bin"
        workspace_calls << argv
        ["", false]
      else
        ["", true]
      end
    end
  end
  let(:lanes) do
    DemoCalculator2::Lanes.new(root: tmp, workspace: "ws-bin", lane_b: "ws-b", name: "ws", out: StringIO.new, err: StringIO.new, exec: exec)
  end

  before do
    load File.join(PROJECT_ROOT, "script", "demo-calculator2")
    git("init", "-q", "-b", "main")
    git("config", "user.email", "t@example.com")
    git("config", "user.name", "t")
    FileUtils.mkdir_p(File.join(tmp, File.dirname(path)))
    FileUtils.mkdir_p(File.join(tmp, scripts))
    %w[merge_test_methods test_names.rb].each { |file| FileUtils.cp(File.join(PROJECT_ROOT, scripts, file), File.join(tmp, scripts, file)) }
    File.write(File.join(tmp, path), "require \"minitest/autorun\"\n\nclass CalcTest < Minitest::Test\n  def test_smoke\n    assert true\n  end\nend\n")
    git("add", "-A")
    git("commit", "-qm", "base")
    File.write(record_path, JSON.generate("lanes" => {"b" => {"branch" => "lane-b"}}, "fork" => {"sha" => git("rev-parse", "HEAD").first.strip}))
    expect(ENV.keys & %w[GIT_DIR GIT_COMMON_DIR]).to be_empty
    expect(File.realpath(git("rev-parse", "--git-common-dir").first.strip, tmp)).to eq(File.join(tmp, ".git"))
  end

  after { FileUtils.rm_rf([tmp, out_dir]) }

  def git(*args, dir: tmp)
    out, status = Open3.capture2e("git", "-C", dir, *args)
    raise "git #{args.join(" ")}: #{out}" unless status.success?
    [out, true]
  end

  def configured_driver = Open3.capture2("git", "-C", tmp, "config", "--local", "--get", driver_key).first.strip

  def add_method(name, dir: tmp)
    file = File.join(dir, path)
    File.write(file, File.read(file).sub(/^end\n\z/, "  def #{name}\n    assert true\n  end\nend\n"))
    git("commit", "-qam", name, dir: dir)
  end

  def lane_b(*names)
    git("checkout", "-qb", "lane-b")
    names.each { |name| add_method(name) }
    git("checkout", "-q", "main")
  end

  # Lane B as the ownership rule allows: its own test file only, branched from the fork.
  def lane_b_own(*names)
    git("checkout", "-qb", "lane-b")
    body = names.map { |name| "  def #{name}\n    assert true\n  end\n" }.join
    File.write(File.join(tmp, "demo/calculator2/test/lane_b_test.rb"), "require \"minitest/autorun\"\n\nclass LaneBTest < Minitest::Test\n#{body}end\n")
    git("add", "-A")
    git("commit", "-qm", "lane b tests")
    git("checkout", "-q", "main")
  end

  def record = JSON.parse(File.read(record_path))

  it "writes a driver command that names no path, once, in this tmp repo only" do
    lanes.write_attributes(record_path)
    expect(configured_driver).to eq(DemoCalculator2::SharedValues::DRIVER_COMMAND)
    expect(File.read(File.join(tmp, ".git", "config"))).to include("merge_test_methods")
    expect(configured_driver).not_to include(tmp)
    expect(record["merge_driver"]).to include("written" => true, "replaced" => nil)
    lanes.write_attributes(record_path)
    expect(record["merge_driver"]).to include("written" => false)
  end

  it "has git expand the command through the shell from a linked worktree, using that worktree's copy of the script" do
    lanes.write_attributes(record_path)
    lane_b("test_json")
    linked = File.join(out_dir, "linked")
    git("worktree", "add", "-q", "-b", "lane-a", linked, "main")
    add_method("test_add", dir: linked)
    FileUtils.rm_rf(File.join(tmp, scripts))
    git("merge", "--no-edit", "lane-b", dir: linked)
    merged = File.read(File.join(linked, path))
    expect(merged).to include("def test_add", "def test_json", "def test_smoke")
    _, status = Open3.capture2e("ruby", "-c", File.join(linked, path))
    expect(status.success?).to be(true)
  end

  it "records first_pass true for a clean merge where each lane added tests" do
    lanes.write_attributes(record_path)
    lane_b_own("test_json", "test_repl")
    add_method("test_add")
    lanes.integrate(record)
    integration = record["integration"]
    expect(integration).to include("merge" => "clean", "first_pass" => true, "test" => true, "lint" => true, "acceptance" => true)
    expect(integration["test_names"]).to eq("ok" => true, "duplicates" => [])
    expect(workspace_calls).to be_empty
  end

  it "records first_pass false with the duplicates when only one side has a duplicated test name" do
    lanes.write_attributes(record_path)
    lane_b_own("test_json")
    add_method("test_json")
    add_method("test_json")
    expect { lanes.integrate(record) }.to raise_error(DemoCalculator::Refused)
    integration = record["integration"]
    expect(integration).to include("merge" => "clean", "first_pass" => false)
    expect(integration["test_names"]).to eq("ok" => false, "duplicates" => ["test_json"])
    expect(workspace_calls.map { |argv| argv[0, 5] }).to eq([%w[ws-bin work-queue add workflow integrate-merged]])
  end

  describe "the ownership check over real git" do
    let(:own_file) { "demo/calculator2/test/lane_b_test.rb" }

    def branch_commit(branch, files)
      git("checkout", "-qb", branch)
      files.each do |file, text|
        FileUtils.mkdir_p(File.dirname(File.join(tmp, file)))
        File.write(File.join(tmp, file), text)
      end
      git("add", "-A")
      git("commit", "-qm", branch)
      git("checkout", "-q", "main")
    end

    def head = git("rev-parse", "HEAD").first.strip

    def check(a_head = head) = lanes.ownership_problem(record, a_head)

    it "passes lane B's own file, or no test file, with lane A leaving it alone" do
      branch_commit("lane-b", own_file => "x\n", "demo/calculator2/lib/extra.rb" => "x = 1\n")
      add_method("test_add")
      expect(check).to be_nil
    end

    it "refuses a lane B that changed calc_test.rb" do
      branch_commit("lane-b", path => "changed\n")
      expect(check).to match(/lane B .* changed #{Regexp.escape(path)}/)
    end

    it "refuses another test file of lane B" do
      branch_commit("lane-b", "demo/calculator2/test/other_test.rb" => "x\n")
      expect(check).to match(/other_test\.rb/)
    end

    it "refuses a lane B that deleted a test file" do
      git("checkout", "-qb", "lane-b")
      git("rm", "-q", path)
      git("commit", "-qm", "lane b rm")
      git("checkout", "-q", "main")
      expect(check).to match(/changed #{Regexp.escape(path)}/)
    end

    it "refuses a lane B that renamed calc_test.rb away, naming both files" do
      git("checkout", "-qb", "lane-b")
      git("mv", path, "demo/calculator2/test/moved_test.rb")
      git("commit", "-qm", "rename")
      git("checkout", "-q", "main")
      expect(check).to include(path, "moved_test.rb")
    end

    it "refuses a lane A that changed lane B's test file" do
      branch_commit("lane-b", own_file => "x\n")
      File.write(File.join(tmp, own_file), "a\n")
      git("add", "-A")
      git("commit", "-qm", "a touches b")
      expect(check).to match(/lane A changed #{Regexp.escape(own_file)}/)
    end

    it "does not blame lane A for lane B's file once it is merged in" do
      branch_commit("lane-b", own_file => "x\n")
      git("merge", "-q", "--no-ff", "--no-edit", "lane-b")
      expect(check).to be_nil
    end

    it "does not blame lane B for lane A's edits that lane B merged into its own branch" do
      branch_commit("lane-b", own_file => "x\n")
      add_method("test_add")
      git("checkout", "-q", "lane-b")
      git("merge", "-q", "--no-ff", "--no-edit", "main")
      git("checkout", "-q", "main")
      expect(File.read(File.join(tmp, path))).to include("test_add")
      expect(check).to be_nil
    end

    it "reads lane A only up to the head recorded before the merge, so repair commits may edit lane B's file" do
      branch_commit("lane-b", own_file => "x\n")
      add_method("test_add")
      premerge = head
      git("merge", "-q", "--no-ff", "--no-edit", "lane-b")
      File.write(File.join(tmp, own_file), "repaired\n")
      git("commit", "-qam", "repair edits lane B's test")
      expect(check).to match(/lane A changed #{Regexp.escape(own_file)}/)
      expect(check(premerge)).to be_nil
      data = record.merge("integration" => {"merge" => "clean"}, "lane_b_check" => {"passed" => true, "premerge_head" => premerge})
      expect(lanes.ownership_a_head(data)).to eq(premerge)
      expect(check(lanes.ownership_a_head(data))).to be_nil
    end

    it "raises the infrastructure error when lane B's branch does not exist" do
      expect { check }.to raise_error(DemoCalculator2::OwnershipCheckFailed, /could not run: git rev-parse/)
    end
  end

  it "rewrites a driver that names a removed worktree" do
    gone = File.join(out_dir, "gone")
    git("config", "--local", driver_key, "ruby #{Shellwords.escape(gone)}/script/demo_calculator2/merge_test_methods %O %A %B")
    lanes.write_attributes(record_path)
    expect(configured_driver).to eq(DemoCalculator2::SharedValues::DRIVER_COMMAND)
    expect(record["merge_driver"]).to include("written" => true)
    expect(record.dig("merge_driver", "replaced")).to include(gone)
  end

  it "leaves a driver that names an existing worktree and refuses the run" do
    linked = File.join(out_dir, "linked")
    git("worktree", "add", "-q", "-b", "lane-a", linked, "main")
    old = "ruby #{Shellwords.escape(linked)}/script/demo_calculator2/merge_test_methods %O %A %B"
    git("config", "--local", driver_key, old)
    expect { lanes.write_attributes(record_path) }.to raise_error(DemoCalculator::Refused, /#{Regexp.escape(driver_key)}.*#{Regexp.escape(linked)}/m)
    expect(configured_driver).to eq(old)
    expect(File.exist?(File.join(tmp, ".git", "info", "attributes"))).to be(false)
  end
end
