require "spec_helper"
require "stringio"

# build_cli resolves the working directory's project through git, so this runs in the system tier.
RSpec.describe Workspace::CLI::SessionEventWiring do
  it "is given by build_cli the bin/workspace path DevSessionRelease got before" do
    release = {}
    allow(Workspace::DevSessionRelease).to receive(:new) { |**kwargs| release.merge!(kwargs) && double("release") }

    Workspace.build_cli(output: StringIO.new, error_output: StringIO.new, input: StringIO.new, tmux: FakeTmux.new)

    expect(release[:executable]).to eq(File.join(PROJECT_ROOT, "bin", "workspace"))
  end
end
