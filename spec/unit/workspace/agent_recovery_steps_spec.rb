require "spec_helper"

RSpec.describe Workspace::AgentRecoverySteps do
  let(:own) { ->(_attempt) { :own } }

  it "keeps the desk's own runners by default" do
    steps = described_class.new

    expect(steps.restart_runner(own)).to be(own)
    expect(steps.typed_runner(own)).to be(own)
  end

  it "swaps in fixed runners with .running, one kind at a time" do
    fixed = ->(_attempt) { :fixed }
    steps = described_class.running(typed: fixed)

    expect(steps.typed_runner(own)).to be(fixed)
    expect(steps.restart_runner(own)).to be(own)
  end
end
