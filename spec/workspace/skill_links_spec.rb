require "spec_helper"

RSpec.describe Workspace::SkillLinks do
  include SkillsFixture

  let(:dir) { File.join(home, ".claude", "skills") }
  let(:clock_time) { Time.utc(2026, 10, 30, 12, 0, 0) }
  subject(:links) { described_class.new(state_dir: state_dir, clock: -> { clock_time }) }

  def plan = links.plan(dir, root, SkillsFixture::NAMES)

  def outcomes(plan) = plan.steps.to_h { |s| [s.name, s.outcome] }

  def install!
    links.apply(plan)
  end

  describe "#plan and #apply" do
    it "links all four whole directories, with no links per file, and creates the skills directory" do
      result = plan
      links.apply(result)

      expect(outcomes(result).values).to all(eq("linked"))
      SkillsFixture::NAMES.each do |name|
        expect(File.symlink?("#{dir}/#{name}")).to be(true)
        expect(File.readlink("#{dir}/#{name}")).to eq("#{root}/#{name}")
      end
      expect(Dir.children(dir).sort).to eq(SkillsFixture::NAMES)
      expect(Dir.children(root + "/workspace").map { |c| File.symlink?("#{root}/workspace/#{c}") }).to all(be(false))
    end

    it "lets ../workspace/references resolve through the link" do
      install!
      File.write("#{root}/workspace-inbox/SKILL.md", "[c](../workspace/references/machine-contract.md)\n")

      expect(File.exist?(File.expand_path("../workspace/references/machine-contract.md", "#{dir}/workspace-inbox/"))).to be(true)
    end

    it "says unchanged on our link to the same target" do
      install!

      expect(outcomes(plan).values).to all(eq("unchanged"))
    end

    it "relinks our link to another root, and a dangling one" do
      FileUtils.mkdir_p(dir)
      other = File.join(@tmp, "other-checkout")
      build_checkout(other)
      File.symlink("#{other}/lib/skills/workspace", "#{dir}/workspace")
      File.symlink("#{@tmp}/gone-workspace/lib/skills/workspace-inbox", "#{dir}/workspace-inbox")

      result = plan
      links.apply(result)

      expect(outcomes(result)).to include("workspace" => "relinked", "workspace-inbox" => "relinked", "workspace-agent-run" => "linked")
      expect(File.readlink("#{dir}/workspace")).to eq("#{root}/workspace")
      expect(File.readlink("#{dir}/workspace-inbox")).to eq("#{root}/workspace-inbox")
    end

    it "adopts a real directory equal to the source (ignoring .DS_Store), backing it up outside the skills directory" do
      FileUtils.mkdir_p(dir)
      FileUtils.cp_r("#{root}/workspace", "#{dir}/workspace")
      File.write("#{dir}/workspace/.DS_Store", "junk")

      result = plan
      links.apply(result)

      step = result.steps.find { |s| s.name == "workspace" }
      expect(step.outcome).to eq("adopted")
      expect(File.symlink?("#{dir}/workspace")).to be(true)
      expect(step.backup).to start_with("#{state_dir}/skill-backups/20261030-120000/")
      expect(File.read("#{step.backup}/SKILL.md")).to include("name: workspace")
      expect(Dir.children(dir)).not_to include(a_string_matching(/backup|old/))
    end

    it "refuses a real directory with other content, prints the mv, and links none of the four" do
      FileUtils.mkdir_p("#{dir}/workspace-inbox")
      File.write("#{dir}/workspace-inbox/SKILL.md", "mine")

      result = plan
      links.apply(result)

      expect(outcomes(result)).to eq("workspace" => "skipped", "workspace-agent-run" => "skipped", "workspace-inbox" => "refused", "workspace-lifecycle" => "skipped")
      refused = result.steps.find { |s| s.outcome == "refused" }
      expect(refused.code).to eq("skill_path_exists")
      expect(refused.mv).to eq("mkdir -p #{File.join(state_dir, "skill-backups/20261030-120000", dir.gsub(/[^A-Za-z0-9._-]+/, "_")).shellescape} && mv #{"#{dir}/workspace-inbox".shellescape} #{File.join(state_dir, "skill-backups/20261030-120000", dir.gsub(/[^A-Za-z0-9._-]+/, "_")).shellescape}/")
      expect(File.read("#{dir}/workspace-inbox/SKILL.md")).to eq("mine")
      expect(Dir.children(dir)).to eq(["workspace-inbox"])
    end

    it "runs the printed mv as written" do
      FileUtils.mkdir_p("#{dir}/workspace")
      File.write("#{dir}/workspace/SKILL.md", "mine")
      refused = plan.steps.find { |s| s.outcome == "refused" }

      expect(system(refused.mv)).to be(true)
      expect(File.exist?("#{dir}/workspace")).to be(false)
      expect(plan.steps.map(&:outcome)).to all(eq("linked"))
    end

    it "refuses a regular file" do
      FileUtils.mkdir_p(dir)
      File.write("#{dir}/workspace", "x")

      result = plan

      expect(result.steps.find { |s| s.name == "workspace" }).to have_attributes(outcome: "refused", code: "skill_path_exists")
    end

    it "refuses someone else's link and leaves it alone" do
      FileUtils.mkdir_p(dir)
      File.symlink("/somewhere/else/skills/workspace", "#{dir}/workspace")

      result = plan
      links.apply(result)

      expect(result.steps.find { |s| s.name == "workspace" }).to have_attributes(outcome: "refused", code: "skill_link_foreign")
      expect(File.readlink("#{dir}/workspace")).to eq("/somewhere/else/skills/workspace")
      expect(Dir.children(dir)).to eq(["workspace"])
    end

    it "treats a link into another project's lib/skills (no bin/workspace) as foreign when it resolves" do
      other = File.join(@tmp, "other")
      FileUtils.mkdir_p("#{other}/lib/skills/workspace")
      FileUtils.mkdir_p(dir)
      File.symlink("#{other}/lib/skills/workspace", "#{dir}/workspace")

      expect(plan.steps.find { |s| s.name == "workspace" }.code).to eq("skill_link_foreign")
    end

    it "writes through a skills directory that is itself a link, with a warning naming the real path" do
      real = File.join(@tmp, "dotfiles-skills")
      FileUtils.mkdir_p(real)
      FileUtils.mkdir_p(File.dirname(dir))
      File.symlink(real, dir)

      result = plan
      links.apply(result)

      expect(result.warnings.first).to include(real)
      expect(File.symlink?("#{real}/workspace")).to be(true)
    end

    it "refuses all four when the skills directory path is a file" do
      FileUtils.mkdir_p(File.dirname(dir))
      File.write(dir, "x")

      expect(plan.steps.map(&:outcome)).to all(eq("refused"))
    end

    it "never touches other entries of the skills directory, such as synced/" do
      FileUtils.mkdir_p("#{dir}/synced")
      File.write("#{dir}/synced/a.md", "a")

      install!

      expect(File.read("#{dir}/synced/a.md")).to eq("a")
    end

    it "undoes what it did in a directory when a later write fails, leaving no half-state" do
      FileUtils.mkdir_p(dir)
      FileUtils.cp_r("#{root}/workspace-lifecycle", "#{dir}/workspace-lifecycle")
      result = plan
      calls = 0
      allow(File).to receive(:rename).and_wrap_original do |original, *args|
        calls += 1
        raise Errno::EACCES, "denied" if calls == 4
        original.call(*args)
      end

      links.apply(result)

      expect(result.steps.map(&:outcome)).to all(eq("failed"))
      expect(Dir.children(dir)).to eq(["workspace-lifecycle"])
      expect(File.symlink?("#{dir}/workspace-lifecycle")).to be(false)
      expect(File.read("#{dir}/workspace-lifecycle/SKILL.md")).to include("name: workspace-lifecycle")
    end
  end

  it "undoes a relink and an adopt when a later write fails, and leaves unchanged steps unchanged" do
    FileUtils.mkdir_p(dir)
    File.symlink("#{root}/workspace", "#{dir}/workspace")
    other = File.join(@tmp, "other-checkout")
    build_checkout(other)
    File.symlink("#{other}/lib/skills/workspace-agent-run", "#{dir}/workspace-agent-run")
    FileUtils.cp_r("#{root}/workspace-inbox", "#{dir}/workspace-inbox")
    result = plan
    calls = 0
    allow(File).to receive(:rename).and_wrap_original do |original, *args|
      calls += 1
      raise Errno::EACCES, "denied" if calls == 3
      original.call(*args)
    end

    links.apply(result)

    expect(result.steps.to_h { |s| [s.name, s.outcome] }).to include("workspace" => "unchanged", "workspace-agent-run" => "failed", "workspace-inbox" => "failed")
    expect(File.readlink("#{dir}/workspace-agent-run")).to eq("#{other}/lib/skills/workspace-agent-run")
    expect(File.directory?("#{dir}/workspace-inbox") && !File.symlink?("#{dir}/workspace-inbox")).to be(true)
    expect(File.read("#{dir}/workspace-inbox/SKILL.md")).to include("name: workspace-inbox")
    expect(Dir.children(dir).grep(/tmp/)).to eq([])
  end

  it "refuses, writing nothing, when the skills directory is a dangling link" do
    FileUtils.mkdir_p(File.dirname(dir))
    File.symlink(File.join(@tmp, "gone"), dir)
    result = plan

    links.apply(result)

    expect(result.steps.map(&:outcome)).to all(eq("refused"))
    expect(result.steps.first.code).to eq("skill_path_exists")
    expect(File.exist?(File.join(@tmp, "gone"))).to be(false)
  end

  it "refuses a skills directory that is a link to the source, so the source is never moved or replaced" do
    FileUtils.mkdir_p(File.dirname(dir))
    File.symlink(root, dir)
    result = plan

    links.apply(result)

    expect(result.steps.map(&:outcome)).to all(eq("refused"))
    expect(SkillsFixture::NAMES.map { |n| File.symlink?("#{root}/#{n}") }).to all(be(false))
    expect(File.exist?("#{root}/workspace/SKILL.md")).to be(true)
    expect(Dir.exist?(state_dir)).to be(false)
  end

  it "relinks a link into a versioned Cellar path rather than calling it current, so it moves to the stable opt path" do
    FileUtils.mkdir_p(dir)
    keg = File.join(@tmp, "prefix", "Cellar", "workspace", "0.75.0", "libexec")
    build_checkout(keg)
    opt_root = File.join(@tmp, "prefix", "opt", "workspace", "libexec", "lib", "skills")
    FileUtils.mkdir_p(File.join(@tmp, "prefix", "opt"))
    File.symlink(File.join(@tmp, "prefix", "Cellar", "workspace", "0.75.0"), File.join(@tmp, "prefix", "opt", "workspace"))
    File.symlink("#{keg}/lib/skills/workspace", "#{dir}/workspace")

    result = links.plan(dir, opt_root, SkillsFixture::NAMES)

    expect(result.steps.find { |s| s.name == "workspace" }.outcome).to eq("relinked")
  end

  it "does not claim a dangling link into some other project as ours" do
    FileUtils.mkdir_p(dir)
    File.symlink("/nonexistent/otherproj/lib/skills/workspace", "#{dir}/workspace")

    expect(links.ours?("#{dir}/workspace", "workspace")).to be(false)
    expect(plan.steps.find { |s| s.name == "workspace" }.code).to eq("skill_link_foreign")
  end

  describe "#removal_steps and #remove" do
    it "removes our links including dangling ones, and reports what it leaves" do
      FileUtils.mkdir_p("#{dir}/workspace-inbox")
      File.symlink("#{root}/workspace", "#{dir}/workspace")
      File.symlink("#{@tmp}/gone-workspace/lib/skills/workspace-agent-run", "#{dir}/workspace-agent-run")
      File.symlink("/elsewhere/workspace-lifecycle", "#{dir}/workspace-lifecycle")

      steps = links.removal_steps(dir, SkillsFixture::NAMES)
      steps.each { |step| links.remove(step) if step.outcome == "removed" }

      expect(steps.to_h { |s| [s.name, [s.outcome, s.code]] }).to eq(
        "workspace" => ["removed", nil], "workspace-agent-run" => ["removed", nil],
        "workspace-inbox" => ["left", "skill_path_exists"], "workspace-lifecycle" => ["left", "skill_link_foreign"]
      )
      expect(Dir.children(dir).sort).to eq(%w[workspace-inbox workspace-lifecycle])
    end
  end
end
