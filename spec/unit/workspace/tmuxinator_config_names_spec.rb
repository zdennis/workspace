require "spec_helper"
require "tmpdir"

RSpec.describe Workspace::TmuxinatorConfigNames do
  let(:tmpdir) { Dir.mktmpdir }
  let(:config) { instance_double(Workspace::Config, tmuxinator_dir: tmpdir) }

  after { FileUtils.remove_entry(tmpdir) }

  def touch(*names) = names.each { |n| File.write(File.join(tmpdir, n), "") }

  it "lists the workspace names sorted, without template files or other files" do
    touch "workspace.b.yml", "workspace.a.yml", "workspace.a.worktree-x.yml",
      "workspace.project-foo-template.yml", "other.yml", "workspace.notes.txt"

    expect(described_class.new(config: config).call).to eq(%w[a a.worktree-x b])
  end

  it "is empty when the directory holds no configs" do
    expect(described_class.new(config: config).call).to eq([])
  end

  it "answers available_projects as call does" do
    touch "workspace.a.yml"

    expect(described_class.new(config: config).available_projects).to eq(%w[a])
  end
end
