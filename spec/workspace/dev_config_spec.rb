require "spec_helper"
require "tmpdir"

RSpec.describe Workspace::DevConfig do
  def project_settings_with(dir:)
    fake_path_config = Struct.new(:workspace_config_dir).new(dir)
    Workspace::ProjectSettings.new(config: fake_path_config)
  end

  describe ".parse_duration" do
    it "parses a plain number of seconds" do
      expect(described_class.parse_duration("20")).to eq(20.0)
    end

    it "parses a number with a trailing s" do
      expect(described_class.parse_duration("20s")).to eq(20.0)
    end

    it "accepts a Numeric directly" do
      expect(described_class.parse_duration(20)).to eq(20.0)
    end

    it "parses minute and hour suffixes" do
      expect(described_class.parse_duration("5m")).to eq(300.0)
      expect(described_class.parse_duration("1.5h")).to eq(5400.0)
      expect(described_class.parse_duration("2M")).to eq(120.0)
    end

    it "rejects an unknown unit" do
      expect { described_class.parse_duration("5d") }.to raise_error(ArgumentError)
    end

    it "raises ArgumentError for an unparseable value" do
      expect { described_class.parse_duration("soon") }.to raise_error(ArgumentError)
    end
  end

  describe "#for_project" do
    it "returns nils and the default stop_timeout when nothing is configured" do
      dir = Dir.mktmpdir("ws-dev-config")
      dev_config = described_class.new(project_settings: project_settings_with(dir: dir))

      result = dev_config.for_project("myapp")

      expect(result).to eq(up: nil, ready: nil, stop_timeout: Workspace::DevConfig::DEFAULT_STOP_TIMEOUT)
    end

    it "returns the configured up, ready, and stop_timeout" do
      dir = Dir.mktmpdir("ws-dev-config")
      project_settings = project_settings_with(dir: dir)
      project_settings.save("myapp", {"dev" => {"up" => "./start-dev", "ready" => "port:3000", "stop_timeout" => "30s"}})
      dev_config = described_class.new(project_settings: project_settings)

      result = dev_config.for_project("myapp")

      expect(result).to eq(up: "./start-dev", ready: "port:3000", stop_timeout: 30.0)
    end

    it "raises Workspace::Error for an invalid stored stop_timeout" do
      dir = Dir.mktmpdir("ws-dev-config")
      project_settings = project_settings_with(dir: dir)
      project_settings.save("myapp", {"dev" => {"stop_timeout" => "soon"}})
      dev_config = described_class.new(project_settings: project_settings)

      expect { dev_config.for_project("myapp") }.to raise_error(Workspace::Error, /Invalid dev.stop_timeout/)
    end
  end
end
