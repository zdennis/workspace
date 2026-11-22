require "spec_helper"
require "shellwords"

load File.join(PROJECT_ROOT, "script", "demo-calculator2")

RSpec.describe DemoCalculator2::SharedValues do
  let(:driver_key) { described_class::DRIVER_KEY }
  let(:wanted) { described_class::DRIVER_COMMAND }
  let(:existing) { ->(path) { path == "/live" } }
  let(:state) { ->(key, live, **opts) { described_class.classify(key, live: live, wanted: opts.delete(:wanted) || wanted, path_exists: existing, owner_running: false, **opts) } }

  def absolute(path) = "ruby #{Shellwords.escape(path)}/script/demo_calculator2/merge_test_methods %O %A %B"

  describe ".driver_path" do
    it "reads the checkout out of the absolute form, spaces included" do
      expect(described_class.driver_path(absolute("/a b/live"))).to eq("/a b/live")
    end

    it "is nil for the path-agnostic form and for another command" do
      expect(described_class.driver_path(wanted)).to be_nil
      expect(described_class.driver_path("ruby other %O %A %B")).to be_nil
    end
  end

  describe ".classify for the driver key" do
    it "is absent with no value" do
      expect(state.call(driver_key, nil)).to eq(:absent)
    end

    it "is equal for our value" do
      expect(state.call(driver_key, wanted)).to eq(:equal)
    end

    it "is foreign_live for an absolute path that exists" do
      expect(state.call(driver_key, absolute("/live"))).to eq(:foreign_live)
    end

    it "is dangling for an absolute path that does not exist" do
      expect(state.call(driver_key, absolute("/gone"))).to eq(:dangling)
    end

    it "is foreign_live for a command it cannot read a checkout from" do
      expect(state.call(driver_key, "ruby other %O %A %B")).to eq(:foreign_live)
    end

    it "is dangling for another key with a different value" do
      expect(state.call("git-config:merge.calc-demo-tests.name", "old", wanted: "new")).to eq(:dangling)
      expect(state.call("git-config:merge.calc-demo-tests.name", "new", wanted: "new")).to eq(:equal)
    end
  end

  describe ".classify for the attributes line" do
    let(:line) { "demo/calculator2/test/calc_test.rb merge=calc-demo-tests" }
    let(:key) { "attributes:#{line}" }

    it "is absent with no line, equal for ours, dangling for another driver on the file" do
      expect(state.call(key, nil, wanted: line)).to eq(:absent)
      expect(state.call(key, line, wanted: line)).to eq(:equal)
      expect(state.call(key, "demo/calculator2/test/calc_test.rb merge=union", wanted: line)).to eq(:dangling)
    end
  end

  describe ".classify for a sources list" do
    let(:ours) { "/ours/demo/calculator2/workflows" }
    let(:key) { "workflows.sources:#{ours}" }
    let(:call) { ->(live, **opts) { described_class.classify(key, live: live, wanted: ours, path_exists: ->(path) { path.start_with?("/live") }, owner_running: false, **opts) } }

    it "is absent with no calculator2 entry" do
      expect(call.call([])).to eq(:absent)
      expect(call.call(["/unrelated/workflows"])).to eq(:absent)
    end

    it "is equal when ours is in the list with nothing shadowing it" do
      expect(call.call(["/unrelated/workflows", ours])).to eq(:equal)
      expect(call.call("/unrelated/workflows, #{ours}")).to eq(:equal)
    end

    it "is dangling for a missing directory ahead of ours" do
      expect(call.call(["/gone/demo/calculator2/workflows", ours])).to eq(:dangling)
    end

    it "is foreign_live for an existing directory ahead of ours whose definitions differ" do
      expect(call.call(["/live/demo/calculator2/workflows", ours])).to eq(:foreign_live)
    end

    it "is equal for an existing directory ahead of ours with the same definitions" do
      expect(call.call(["/live/demo/calculator2/workflows", ours], same_definitions: ->(_) { true })).to eq(:equal)
    end
  end

  describe ".refusal" do
    it "names the key, the live value and the owner" do
      message = described_class.refusal(driver_key, "v", "/live")
      expect(message).to include(driver_key, '"v"', "/live", "--take-over")
    end
  end
end
