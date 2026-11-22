require "spec_helper"
require "tmpdir"

require File.join(PROJECT_ROOT, "script", "demo_calculator2", "series_registry")

RSpec.describe DemoCalculator2::SeriesRegistry do
  let(:dir) { Dir.mktmpdir("series-registry") }
  let(:clock) { -> { Time.utc(2026, 1, 2, 3, 4, 5) } }
  let(:alive) { ->(pid, _started) { pid == 111 } }
  let(:registry) { described_class.new(dir, clock: clock, pid: 111, host: "h", alive: alive) }
  let(:driver_key) { DemoCalculator2::SharedValues::DRIVER_KEY }
  let(:old_driver) { "ruby /gone/script/demo_calculator2/merge_test_methods %O %A %B" }

  after { FileUtils.remove_entry(dir) }

  it "registers an id with pid, start time and host, and records items incrementally" do
    registry.register("a", workspaces: ["ws-a"])
    registry.record("a", workspaces: ["ws-a", "ws-a-b"], branches: ["br"], refs: ["r"])
    expect(registry.entries["a"]).to include("pid" => 111, "host" => "h", "started_at" => "2026-01-02T03:04:05Z",
      "workspaces" => ["ws-a", "ws-a-b"], "branches" => ["br"], "refs" => ["r"])
    expect(JSON.parse(File.read(File.join(dir, "series.json")))["schema"]).to eq(1)
  end

  it "adds a value idempotently" do
    registry.register("a")
    expect(registry.add("a", "attributes:x", "x", state: :absent)).to eq(:added)
    expect(registry.add("a", "attributes:x", "x", state: :equal)).to eq(:unchanged)
    expect(registry.shared["attributes:x"]).to include("added_by" => "a", "replaced" => nil)
  end

  it "never returns a preexisting key for undo" do
    registry.register("a")
    expect(registry.add("a", "attributes:x", "x", state: :equal)).to eq(:preexisting)
    expect(registry.shared["attributes:x"]["added_by"]).to eq("preexisting")
    expect(registry.remove("a").map { |u| u["key"] }).to eq(["exclude:/runs/a/"])
    expect(registry.shared).to be_empty
  end

  it "refuses a foreign-live value without take-over" do
    registry.register("a")
    expect { registry.add("a", driver_key, "new", state: :foreign_live, live: old_driver) }
      .to raise_error(described_class::Refusal, /merge.calc-demo-tests.driver.*--take-over/m)
    expect(registry.shared).to be_empty
  end

  it "records dangling and take-over values with replaced, and the last remove returns it" do
    registry.register("a")
    registry.add("a", driver_key, "new", state: :dangling, live: old_driver)
    registry.add("a", "workflows.sources:/me/demo/calculator2/workflows", "/me/demo/calculator2/workflows",
      state: :foreign_live, take_over: true, live: "/w03/demo/calculator2/workflows")
    expect(registry.shared[driver_key]["replaced"]).to eq("value" => old_driver, "owner_path" => "/gone")
    undo = registry.remove("a")
    replaced = undo.to_h { |u| [u["key"], u["replaced"]] }
    expect(replaced[driver_key]).to eq("value" => old_driver, "owner_path" => "/gone")
    expect(replaced["workflows.sources:/me/demo/calculator2/workflows"]["owner_path"]).to eq("/w03")
  end

  it "keeps shared keys while another id is registered and returns them when empty" do
    registry.register("a")
    registry.register("b2")
    registry.add("a", "attributes:x", "x", state: :absent)
    registry.add("a", "exclude:/runs/a/", "/runs/a/", state: :absent)
    first = registry.remove("a")
    expect(first.map { |u| u["key"] }).to eq(["exclude:/runs/a/"])
    expect(registry.shared.keys).to eq(["attributes:x"])
    last = registry.remove("b2")
    expect(last.map { |u| u["key"] }).to eq(["exclude:/runs/b2/", "attributes:x"])
    expect(registry.shared).to be_empty
  end

  it "removes the per-id exclude with its id and returns its value" do
    registry.register("a")
    registry.add("a", "exclude:/runs/a/", "/runs/a/", state: :absent)
    expect(registry.remove("a")).to include("key" => "exclude:/runs/a/", "value" => "/runs/a/", "replaced" => nil)
  end

  it "records an id's own sources entries and always returns them on its remove, even while another id is registered" do
    registry.register("a")
    registry.register("b2")
    registry.record("a", sources: ["/wt/a/demo/calculator2/workflows"])
    registry.record("a", sources: ["/wt/a/demo/calculator2/workflows", "/wt/b/demo/calculator2/workflows"])
    expect(registry.entries["a"]["sources"]).to eq(["/wt/a/demo/calculator2/workflows", "/wt/b/demo/calculator2/workflows"])
    expect(registry.remove("a")).to include(
      {"key" => "workflows.sources:/wt/a/demo/calculator2/workflows", "value" => "/wt/a/demo/calculator2/workflows", "replaced" => nil},
      {"key" => "workflows.sources:/wt/b/demo/calculator2/workflows", "value" => "/wt/b/demo/calculator2/workflows", "replaced" => nil}
    )
    expect(registry.entries.keys).to eq(["b2"])
  end

  it "reports ids whose process is gone as stale" do
    registry.register("a")
    described_class.new(dir, clock: clock, pid: 222, host: "h", alive: alive).register("b2")
    expect(registry.stale).to eq(["b2"])
  end

  it "writes no file or directory in read-only mode" do
    nested = File.join(dir, "nested", "demo-calc2")
    ro = described_class.new(nested, read_only: true)
    expect(ro.entries).to eq({})
    expect(ro.stale).to eq([])
    expect { ro.register("a") }.to raise_error(described_class::ReadOnly)
    expect(File.exist?(File.join(dir, "nested"))).to be(false)
  end

  it "loses no update with two threads writing under the lock" do
    other = described_class.new(dir, clock: clock, pid: 111, host: "h", alive: alive)
    threads = [registry, other].map do |r|
      Thread.new { 25.times { |i| r.register("#{r.equal?(registry) ? "x" : "y"}#{i}") } }
    end
    threads.each(&:join)
    expect(registry.entries.size).to eq(50)
  end
  it "keeps the first old value when a second id takes over the same key" do
    registry.register("a")
    registry.register("b2")
    registry.add("a", driver_key, "new", state: :dangling, live: old_driver)
    expect(registry.add("b2", driver_key, "newer", state: :foreign_live, take_over: true, live: "ruby /a/script/demo_calculator2/merge_test_methods %O %A %B")).to eq(:unchanged)
    expect(registry.shared[driver_key]).to include("added_by" => "a", "value" => "newer")
    registry.remove("a")
    undo = registry.remove("b2").find { |u| u["key"] == driver_key }
    expect(undo["replaced"]).to eq("value" => old_driver, "owner_path" => "/gone")
  end

  it "never hands back a preexisting entry after a take-over" do
    registry.register("a")
    registry.add("a", driver_key, "same", state: :equal)
    registry.add("a", driver_key, "other", state: :foreign_live, take_over: true, live: old_driver)
    expect(registry.shared[driver_key]).to include("added_by" => "preexisting", "replaced" => nil)
    expect(registry.remove("a").map { |u| u["key"] }).to eq(["exclude:/runs/a/"])
  end

  it "returns nothing to undo for an unregistered id" do
    expect(registry.remove("zz")).to eq([])
  end

  describe "a corrupt series.json" do
    let(:file) { File.join(dir, "series.json") }

    ["{not json", "[]", '{"series": []}', '{"shared": "x"}'].each do |body|
      it "raises Corrupt and leaves #{body.inspect} untouched, for writers and read-only readers" do
        File.write(file, body)
        ro = described_class.new(dir, read_only: true)
        expect { registry.register("a") }.to raise_error(described_class::Corrupt)
        expect { registry.entries }.to raise_error(described_class::Corrupt)
        expect { ro.entries }.to raise_error(described_class::Corrupt)
        expect { ro.stale }.to raise_error(described_class::Corrupt)
        expect(File.read(file)).to eq(body)
      end
    end

    it "reads a missing file as empty" do
      expect(registry.entries).to eq({})
    end
  end
end
