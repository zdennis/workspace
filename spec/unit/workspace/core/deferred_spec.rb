require "spec_helper"
require File.join(PROJECT_ROOT, "lib/workspace/core/deferred")

RSpec.describe Workspace::Deferred do
  it "does not run the block at construction" do
    runs = 0
    described_class.new { runs += 1 }
    expect(runs).to eq(0)
  end

  it "runs the block once over several calls and delegates each" do
    runs = 0
    deferred = described_class.new {
      runs += 1
      [3, 1, 2]
    }
    expect(deferred.sort).to eq([1, 2, 3])
    expect(deferred.map { |x| x * 2 }).to eq([6, 2, 4])
    expect(deferred.first(2)).to eq([3, 1])
    expect(runs).to eq(1)
  end

  it "passes keyword arguments through" do
    target = Class.new { def go(a, b: 0) = a + b }.new
    expect(described_class.new { target }.go(1, b: 2)).to eq(3)
  end

  it "answers respond_to? from the built object" do
    deferred = described_class.new { "text" }
    expect(deferred.respond_to?(:upcase)).to be(true)
    expect(deferred.respond_to?(:nope)).to be(false)
  end

  it "lets an error from the block reach the caller and runs the block again next call" do
    runs = 0
    deferred = described_class.new {
      runs += 1
      raise "boom" if runs == 1
      "ok"
    }
    expect { deferred.upcase }.to raise_error(RuntimeError, "boom")
    expect(deferred.upcase).to eq("OK")
    expect(runs).to eq(2)
  end

  it "keeps a nil built value without running the block again" do
    runs = 0
    deferred = described_class.new {
      runs += 1
      nil
    }
    expect { deferred.foo }.to raise_error(NoMethodError)
    expect { deferred.bar }.to raise_error(NoMethodError)
    expect(runs).to eq(1)
  end

  it "needs a block" do
    expect { described_class.new }.to raise_error(ArgumentError)
  end
end
