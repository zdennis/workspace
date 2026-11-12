require "spec_helper"
require "digest"
require "tmpdir"

RSpec.describe Workspace::LegacyTmuxinatorTemplates do
  around do |example|
    Dir.mktmpdir("legacy-templates") do |dir|
      @dir = dir
      example.run
    end
  end

  def sha(path) = Digest::SHA256.file(path).hexdigest

  def copy(name, text)
    File.join(@dir, name).tap { |path| File.write(path, text) }
  end

  # The project file as `0e41749b` first shipped it.
  def old_project = File.read(File.join(PROJECT_ROOT, "spec", "fixtures", "legacy_templates", "old", "project-0e41749b.yml"))

  it "lists the sha of each pre-placeholder copy in spec/fixtures/legacy_templates/*.yml" do
    %i[project worktree].each do |kind|
      expect(described_class::SHIPPED_SHAS[kind]).to include(sha(File.join(PROJECT_ROOT, "spec", "fixtures", "legacy_templates", "#{kind}.yml")))
    end
  end

  it "lists the sha of each file of the shipped default set, so changing the set means adding to the list" do
    %i[project worktree].each do |kind|
      expect(described_class::SHIPPED_SHAS[kind]).to include(sha(File.join(PROJECT_ROOT, "lib", "library", "template", "default", "#{kind}.yml")))
    end
  end

  it "holds only full sha256 digests, each once" do
    described_class::SHIPPED_SHAS.each_value do |shas|
      expect(shas).to all(match(/\A\h{64}\z/))
      expect(shas.uniq).to eq(shas)
    end
  end

  it "takes a stock copy of an earlier shipped version as not edited" do
    path = copy("old.yml", old_project)
    expect(described_class::SHIPPED_SHAS[:project]).to include(sha(path))
    expect(described_class.edited?(:project, path)).to be(false)
  end

  it "takes a one-byte change as edited" do
    path = copy("old.yml", old_project.sub("Ready to work", "Ready to w0rk"))
    expect(described_class.edited?(:project, path)).to be(true)
  end

  it "checks the list of the kind asked" do
    path = copy("project.yml", File.read(File.join(PROJECT_ROOT, "lib", "library", "template", "default", "project.yml")))
    expect(described_class.edited?(:project, path)).to be(false)
    expect(described_class.edited?(:worktree, path)).to be(true)
  end

  it "takes a missing file as not edited" do
    expect(described_class.edited?(:project, File.join(@dir, "none.yml"))).to be(false)
  end

  it "names the files init installs" do
    expect(described_class.path(:project, "/t")).to eq("/t/workspace.project-template.yml")
    expect(described_class.path(:worktree, "/t")).to eq("/t/workspace.project-worktree-template.yml")
  end
end
