require "spec_helper"
require "stringio"

RSpec.describe "Workspace.build_cli wiring" do
  it "builds a LaunchHookCheck into the launcher" do
    launcher = instance_double(Workspace::CLI::Launcher)
    allow(Workspace::CLI::Launcher).to receive(:new).and_return(launcher)

    CLITestHelpers.build_cli(output: StringIO.new, error_output: StringIO.new, input: StringIO.new, env: {}, exit_handler: FakeExitHandler)

    expect(Workspace::CLI::Launcher).to have_received(:new).with(hash_including(hook_check: an_instance_of(Workspace::LaunchHookCheck)))
  end

  it "gives the CLI and Launch the same ClaudeTrust" do
    trust = instance_double(Workspace::ClaudeTrust)
    allow(Workspace::ClaudeTrust).to receive(:new).and_return(trust)
    allow(Workspace::Commands::Launch).to receive(:new).and_return(instance_double(Workspace::Commands::Launch))
    allow(Workspace::CLI).to receive(:new).and_return(instance_double(Workspace::CLI))

    CLITestHelpers.build_cli(output: StringIO.new, error_output: StringIO.new, input: StringIO.new, env: {}, exit_handler: FakeExitHandler)

    expect(Workspace::Commands::Launch).to have_received(:new).with(hash_including(claude_trust: trust))
    expect(Workspace::CLI).to have_received(:new).with(hash_including(claude_trust: trust))
  end
end
