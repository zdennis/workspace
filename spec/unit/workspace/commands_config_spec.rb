require "spec_helper"

RSpec.describe Workspace::CommandsConfig do
  let(:project_settings) { instance_double(Workspace::ProjectSettings, load_global: {}) }
  subject(:config) { described_class.new(config_resolver: Workspace::ConfigResolver.new(project_settings: project_settings)) }

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

  it "reads a worktree's own commands over the parent project's, key by key" do
    allow(project_settings).to receive(:load).with("app").and_return("commands" => {"test" => "bin/test", "lint" => "bin/lint"})
    allow(project_settings).to receive(:load).with("app.worktree-x").and_return("commands" => {"test" => "other"})

    expect(config.for_project("app.worktree-x")).to eq(test: "other", lint: "bin/lint")
  end

  describe "#test_files" do
    it "is empty when unset or refused, and not a role" do
      allow(project_settings).to receive(:load).with("app").and_return("commands" => {"test" => "bin/test"})
      allow(project_settings).to receive(:load).with("bad").and_return("commands" => {"test_files" => "  "})

      expect(config.test_files("app")).to eq([])
      expect(config.test_files("bad")).to eq([])
      expect(config.for_project("app").keys).to eq(%i[test lint])
    end

    it "reads a string or a YAML list" do
      allow(project_settings).to receive(:load).with("a").and_return("commands" => {"test_files" => "spec/**/*_spec.rb test/*_test.rb"})
      allow(project_settings).to receive(:load).with("b").and_return("commands" => {"test_files" => ["spec/*_spec.rb"]})

      expect(config.test_files("a")).to eq(%w[spec/**/*_spec.rb test/*_test.rb])
      expect(config.test_files("b")).to eq(%w[spec/*_spec.rb])
    end

    it "reads a worktree over its project" do
      allow(project_settings).to receive(:load).with("app").and_return("commands" => {"test_files" => "a/*.rb"})
      allow(project_settings).to receive(:load).with("app.worktree-x").and_return("commands" => {"test_files" => "b/*.rb"})
      allow(project_settings).to receive(:load).with("app.worktree-y").and_return({})

      expect(config.test_files("app.worktree-x")).to eq(%w[b/*.rb])
      expect(config.test_files("app.worktree-y")).to eq(%w[a/*.rb])
    end
  end
end
