require "tmpdir"

RSpec.describe Workspace::WindowPositions do
  let(:dir) { Dir.mktmpdir }
  let(:now) { Time.utc(2026, 10, 19, 12, 0, 0) }
  let(:positions) { described_class.new(dir: dir, clock: -> { now }) }
  let(:bounds) { {x: 10, y: 20, width: 800, height: 600} }
  let(:screen) { {x: 0, y: 0, width: 1728, height: 1117} }

  after { FileUtils.remove_entry(dir) }

  it "keeps the file in the workspace's own directory" do
    expect(positions.path_for("proj")).to eq(File.join(dir, "proj", "window.json"))
  end

  it "round-trips bounds, screen and the save time" do
    positions.write("proj", bounds, screen)

    expect(positions.read("proj")).to eq(bounds: bounds, screen: screen, saved_at: "2026-10-19T12:00:00Z")
  end

  it "writes the documented format" do
    positions.write("proj", bounds, screen)

    expect(JSON.parse(File.read(positions.path_for("proj")))).to eq(
      "version" => 1,
      "bounds" => {"x" => 10, "y" => 20, "width" => 800, "height" => 600},
      "screen" => {"x" => 0, "y" => 0, "width" => 1728, "height" => 1117},
      "saved_at" => "2026-10-19T12:00:00Z"
    )
  end

  it "reads a position saved without a known screen" do
    positions.write("proj", bounds)

    expect(positions.read("proj")[:screen]).to be_nil
  end

  it "replaces an earlier position and leaves no temp file behind" do
    positions.write("proj", bounds, screen)
    positions.write("proj", bounds.merge(x: 99), screen)

    expect(positions.read("proj")[:bounds][:x]).to eq(99)
    expect(Dir.children(File.join(dir, "proj"))).to eq(["window.json"])
  end

  it "keeps the old file when the rename cannot happen" do
    positions.write("proj", bounds, screen)
    allow(File).to receive(:rename).and_raise(Errno::EACCES)

    positions.write("proj", bounds.merge(x: 99), screen)

    expect(positions.read("proj")[:bounds][:x]).to eq(10)
    expect(Dir.children(File.join(dir, "proj"))).to eq(["window.json"])
  end

  it "reads nil when nothing was saved" do
    expect(positions.read("proj")).to be_nil
  end

  it "raises a workspace error for a corrupt file and leaves it alone" do
    FileUtils.mkdir_p(File.join(dir, "proj"))
    File.write(positions.path_for("proj"), "{not json")

    expect { positions.read("proj") }.to raise_error(Workspace::Error, /Could not read/)
    expect(File.read(positions.path_for("proj"))).to eq("{not json")
  end

  it "raises for a file of another version or with unusable bounds" do
    FileUtils.mkdir_p(File.join(dir, "proj"))
    File.write(positions.path_for("proj"), '{"version":2,"bounds":{"x":1,"y":1,"width":1,"height":1}}')
    expect { positions.read("proj") }.to raise_error(Workspace::Error, /not a window position/)

    File.write(positions.path_for("proj"), '{"version":1,"bounds":{"x":"a"}}')
    expect { positions.read("proj") }.to raise_error(Workspace::Error, /no usable bounds/)
  end

  it "never reads, writes or deletes outside its directory for a name that is not one path component" do
    outside = File.join(File.dirname(dir), "window.json")
    ["..", ".", "", "a/b", "../x"].each do |name|
      expect(positions.path_for(name)).to be_nil
      positions.write(name, bounds, screen)
      positions.delete(name)
      expect(positions.read(name)).to be_nil
    end
    expect(File.exist?(outside)).to be false
    expect(Dir.children(dir)).to eq([])
  end

  it "saves nothing when a bounds value is not a number, keeping the old file" do
    positions.write("proj", bounds, screen)

    positions.write("proj", bounds.merge(x: nil), screen)

    expect(positions.read("proj")[:bounds]).to eq(bounds)
  end

  it "deletes the file, and deleting twice is fine" do
    positions.write("proj", bounds, screen)

    positions.delete("proj")
    positions.delete("proj")

    expect(positions.read("proj")).to be_nil
  end
end
