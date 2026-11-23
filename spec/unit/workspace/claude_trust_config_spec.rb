require "stringio"

RSpec.describe Workspace::ClaudeTrustConfig do
  let(:error_output) { StringIO.new }
  let(:view) { instance_double(Workspace::ConfigResolver::View) }
  let(:resolver) { instance_double(Workspace::ConfigResolver, view: view) }

  subject(:config) { described_class.new(config_resolver: resolver, error_output: error_output) }

  it "is off when the key is unset" do
    allow(view).to receive(:raw).with("agent.claude.trust_checkout").and_return(nil)

    expect(config.enabled?("myapp")).to be(false)
  end

  it "reads true and false" do
    allow(view).to receive(:raw).with("agent.claude.trust_checkout").and_return("true", false)

    expect(config.enabled?("myapp")).to be(true)
    expect(config.enabled?("myapp")).to be(false)
  end

  it "falls back to the default with a warning for a bad value" do
    allow(view).to receive(:raw).and_return("maybe")

    expect(config.enabled?("myapp")).to be(false)
    expect(error_output.string).to include("invalid agent.claude.trust_checkout for 'myapp'")
  end

  it "falls back to the default with a warning when a config file can't be parsed" do
    allow(view).to receive(:raw).and_raise(Workspace::ConfigParseError.new("/x.yml", "bad yaml."))

    expect(config.enabled?("myapp")).to be(false)
    expect(error_output.string).to include("bad yaml.")
  end
end
