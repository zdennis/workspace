require "spec_helper"
require "tmpdir"
require "stringio"

# agent.claude.trust_checkout is read from the global file only, so a `false` in a project or worktree file
# can't turn trust off and a `false` in the global file can.
RSpec.describe Workspace::ClaudeTrustConfig do
  let(:dir) { Dir.mktmpdir("ws-trust-config") }
  let(:settings) { Workspace::ProjectSettings.new(config: Struct.new(:workspace_config_dir).new(dir)) }
  let(:resolver) { Workspace::ConfigResolver.new(project_settings: settings) }
  let(:error_output) { StringIO.new }
  let(:off) { {"agent" => {"claude" => {"trust_checkout" => false}}} }

  subject(:config) { described_class.new(config_resolver: resolver, error_output: error_output) }

  after { FileUtils.rm_rf(dir) }

  it "is on when no file sets it" do
    expect(config.enabled?("app")).to be(true)
  end

  it "ignores false in the project and worktree files" do
    settings.save("app", off)
    settings.save("app.worktree-x", off)

    expect(config.enabled?("app")).to be(true)
    expect(config.enabled?("app.worktree-x")).to be(true)
  end

  it "honors false in the global file for every workspace" do
    settings.save_global(off)

    expect(config.enabled?("app")).to be(false)
    expect(config.enabled?("app.worktree-x")).to be(false)
  end

  it "keeps a global false when the project and worktree files say true" do
    on = {"agent" => {"claude" => {"trust_checkout" => true}}}
    settings.save_global(off)
    settings.save("app", on)
    settings.save("app.worktree-x", on)

    expect(config.enabled?("app")).to be(false)
    expect(config.enabled?("app.worktree-x")).to be(false)
  end
end
