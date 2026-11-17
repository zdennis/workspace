require "tmpdir"

RSpec.describe Workspace::ReviewRoundPath, ".linked_below?" do
  let(:tmpdir) { Dir.mktmpdir }

  after { FileUtils.remove_entry(tmpdir) }

  it "finds a link below the base, or the base itself when included, and passes missing parts" do
    base = File.join(tmpdir, "base")
    FileUtils.mkdir_p(base)
    File.symlink(tmpdir, File.join(base, "link"))
    File.symlink(tmpdir, File.join(tmpdir, "linkbase"))

    expect(described_class.linked_below?(base, File.join(base, "link", "x"))).to be(true)
    expect(described_class.linked_below?(base, File.join(base, "new", "x"))).to be(false)
    expect(described_class.linked_below?(File.join(tmpdir, "linkbase"), File.join(tmpdir, "linkbase", "x"))).to be(true)
    expect(described_class.linked_below?(File.join(tmpdir, "linkbase"), File.join(tmpdir, "linkbase", "x"), include_base: false)).to be(false)
  end
end
