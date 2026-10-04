require "spec_helper"

RSpec.describe Workspace::CommandsConfig do
  let(:project_settings) { instance_double(Workspace::ProjectSettings) }
  subject(:config) { described_class.new(project_settings: project_settings) }

  it "reads the project's test and lint commands" do
    allow(project_settings).to receive(:load).with("app").and_return("commands" => {"test" => "bundle exec rspec", "lint" => " npm run lint "})

    expect(config.for_project("app")).to eq(test: "bundle exec rspec", lint: "npm run lint")
  end

  it "is nil for a command the project hasn't set" do
    allow(project_settings).to receive(:load).with("app").and_return("commands" => {"test" => "bin/test"})
    allow(project_settings).to receive(:load).with("bare").and_return({})

    expect(config.for_project("app")).to eq(test: "bin/test", lint: nil)
    expect(config.for_project("bare")).to eq(test: nil, lint: nil)
  end

  it "treats a stored value config set would refuse as unset" do
    allow(project_settings).to receive(:load).with("app").and_return("commands" => {"test" => "  ", "lint" => ["a"]})
    allow(project_settings).to receive(:load).with("odd").and_return("commands" => "bin/test")

    expect(config.for_project("app")).to eq(test: nil, lint: nil)
    expect(config.for_project("odd")).to eq(test: nil, lint: nil)
  end

  it "lets a config file that can't be parsed stop the caller" do
    allow(project_settings).to receive(:load).with("app").and_raise(Workspace::ConfigParseError.new("/c/app.yml", "bad yaml"))

    expect { config.for_project("app") }.to raise_error(Workspace::ConfigParseError)
  end
end
