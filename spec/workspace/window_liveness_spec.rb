require "spec_helper"

class FakeWindowLivenessManager
  attr_reader :calls

  def initialize(ids: Set.new, error: nil)
    @ids = ids
    @error = error
    @calls = 0
  end

  def live_window_ids
    @calls += 1
    raise @error if @error
    @ids
  end
end

RSpec.describe Workspace::WindowLiveness do
  def build(**opts) = described_class.new(window_manager: FakeWindowLivenessManager.new(**opts))

  it "reports true for a recorded window iTerm has and false for one it does not" do
    entries = {"a" => {"iterm_window_id" => 10}, "b" => {"iterm_window_id" => 11}}
    expect(build(ids: Set.new([10])).call(entries)).to eq("a" => true, "b" => false)
  end

  it "reports false for an entry with no recorded window" do
    expect(build(ids: Set.new([10])).call("a" => {"unique_id" => "u"})).to eq("a" => false)
  end

  it "compares string window ids as integers" do
    expect(build(ids: Set.new([10])).call("a" => {"iterm_window_id" => "10"})).to eq("a" => true)
  end

  it "reports nil for a headless entry" do
    entries = {"h" => {"headless" => true}, "a" => {"iterm_window_id" => 10}}
    expect(build(ids: Set.new([10])).call(entries)).to eq("h" => nil, "a" => true)
  end

  it "lists windows once for any number of entries" do
    manager = FakeWindowLivenessManager.new(ids: Set.new([1]))
    described_class.new(window_manager: manager).call("a" => {"iterm_window_id" => 1}, "b" => {"iterm_window_id" => 2})
    expect(manager.calls).to eq(1)
  end

  it "does not ask iTerm when every entry is headless" do
    manager = FakeWindowLivenessManager.new
    result = described_class.new(window_manager: manager).call("h" => {"headless" => true})
    expect(result).to eq("h" => nil)
    expect(manager.calls).to eq(0)
  end

  it "does not ask iTerm when there are no entries" do
    manager = FakeWindowLivenessManager.new
    expect(described_class.new(window_manager: manager).call({})).to eq({})
    expect(manager.calls).to eq(0)
  end

  it "reports nil for every windowed entry when the windows cannot be listed" do
    entries = {"a" => {"iterm_window_id" => 10}, "h" => {"headless" => true}}
    expect(build(error: Workspace::Error.new("window-tool list failed")).call(entries)).to eq("a" => nil, "h" => nil)
  end

  it "reports nil when running window-tool raises a system error" do
    expect(build(error: Errno::ENOENT.new("window-tool")).call("a" => {"iterm_window_id" => 1})).to eq("a" => nil)
  end

  it "reports nil when window-tool prints something that is not JSON" do
    expect(build(error: JSON::ParserError.new("unexpected token")).call("a" => {"iterm_window_id" => 1})).to eq("a" => nil)
  end
end
