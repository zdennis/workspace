require "spec_helper"
require "tmpdir"

RSpec.describe Workspace::SkillSource, ".stable_dir" do
  around do |example|
    Dir.mktmpdir do |dir|
      @tmp = File.realpath(dir)
      example.run
    end
  end

  let(:keg) { File.join(@tmp, "prefix", "Cellar", "workspace", "0.75.0", "libexec") }

  it "gives the opt keg's libexec for a directory inside a Cellar keg whose opt link exists" do
    FileUtils.mkdir_p(keg)
    FileUtils.mkdir_p(File.join(@tmp, "prefix", "opt"))
    File.symlink(File.dirname(keg), File.join(@tmp, "prefix", "opt", "workspace"))

    expect(described_class.stable_dir(keg)).to eq(File.join(@tmp, "prefix", "opt", "workspace", "libexec"))
  end

  it "gives the directory itself inside a keg with no opt link" do
    FileUtils.mkdir_p(keg)

    expect(described_class.stable_dir(keg)).to eq(keg)
  end

  it "gives the directory itself outside any keg, and for one that doesn't exist" do
    expect(described_class.stable_dir(@tmp)).to eq(@tmp)
    expect(described_class.stable_dir(File.join(@tmp, "gone"))).to eq(File.join(@tmp, "gone"))
  end
end
