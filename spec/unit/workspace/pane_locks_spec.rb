# frozen_string_literal: true

require "spec_helper"

RSpec.describe Workspace::PaneLocks do
  subject(:locks) { described_class.new }

  it "answers the same Mutex for the same pane" do
    expect(locks.for("%1")).to be_a(Mutex)
    expect(locks.for("%1")).to equal(locks.for("%1"))
  end

  it "answers a different Mutex for another pane" do
    expect(locks.for("%1")).not_to equal(locks.for("%2"))
  end

  it "answers one Mutex to threads asking at once" do
    found = Array.new(8) { Thread.new { locks.for("%1") } }.map(&:value)
    expect(found.uniq(&:object_id).size).to eq(1)
  end

  it "does not share locks between instances" do
    expect(locks.for("%1")).not_to equal(described_class.new.for("%1"))
  end
end
