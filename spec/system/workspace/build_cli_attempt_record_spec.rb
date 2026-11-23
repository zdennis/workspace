require "spec_helper"
require "stringio"

# build_cli resolves the working directory's project through git, so this runs in the system tier.
RSpec.describe "build_cli's workflow attempt record" do
  it "is given the run store, so an attempt records its hang guard denies" do
    built = {}
    allow(Workspace::WorkflowAttemptRecord).to receive(:new) { |**kwargs| built.merge!(kwargs) && double("attempt_record") }

    Workspace.build_cli(output: StringIO.new, error_output: StringIO.new, input: StringIO.new, tmux: FakeTmux.new)

    expect(built[:run_store]).to be_a(Workspace::WorkflowRunStore)
  end
end
