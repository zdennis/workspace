require "spec_helper"
require "tmpdir"

RSpec.describe Workspace::DevConfig do
  def project_settings_with(dir:)
    fake_path_config = Struct.new(:workspace_config_dir).new(dir)
    Workspace::ProjectSettings.new(config: fake_path_config)
  end

  describe "#defaults" do
    it "matches an empty config without reading any file" do
      dir = Dir.mktmpdir("ws-dev-config")
      dev_config = described_class.new(project_settings: project_settings_with(dir: dir))

      expect(dev_config.defaults).to eq(dev_config.for_project("myapp"))
    end
  end

  describe "#for_project with an unparseable config" do
    it "raises ConfigParseError rather than reading it as empty" do
      dir = Dir.mktmpdir("ws-dev-config")
      FileUtils.mkdir_p(File.join(dir, "projects"))
      File.write(File.join(dir, "projects", "myapp.yml"), "a: [\n")
      dev_config = described_class.new(project_settings: project_settings_with(dir: dir))

      expect { dev_config.for_project("myapp") }.to raise_error(Workspace::ConfigParseError)
    end
  end

  describe "#configured? and #instructions?" do
    def config_for(dev)
      dir = Dir.mktmpdir("ws-dev-config")
      settings = project_settings_with(dir: dir)
      settings.save("myapp", {"dev" => dev}) if dev
      described_class.new(project_settings: settings)
    end

    it "is configured only when dev.up holds a command" do
      expect(config_for(nil).configured?("myapp")).to be(false)
      expect(config_for({"ready" => "port:3000"}).configured?("myapp")).to be(false)
      expect(config_for({"up" => "  "}).configured?("myapp")).to be(false)
      expect(config_for({"up" => "./start-dev"}).configured?("myapp")).to be(true)
    end

    it "is not thrown off by a bad duration elsewhere in the dev block" do
      expect(config_for({"up" => "./start-dev", "stop_timeout" => "soon"}).configured?("myapp")).to be(true)
    end

    it "wants instructions unless dev.instructions is false, as a string or a boolean" do
      expect(config_for(nil).instructions?("myapp")).to be(true)
      expect(config_for({"instructions" => "true"}).instructions?("myapp")).to be(true)
      expect(config_for({"instructions" => "false"}).instructions?("myapp")).to be(false)
      expect(config_for({"instructions" => false}).instructions?("myapp")).to be(false)
    end
  end

  describe "#release_on_session_end?" do
    def config_for(dev)
      dir = Dir.mktmpdir("ws-dev-config")
      settings = project_settings_with(dir: dir)
      settings.save("myapp", {"dev" => dev}) if dev
      described_class.new(project_settings: settings)
    end

    it "is true unless the key is false, as a string or a boolean" do
      expect(config_for(nil).release_on_session_end?("myapp")).to be(true)
      expect(config_for({"release_on_session_end" => true}).release_on_session_end?("myapp")).to be(true)
      expect(config_for({"release_on_session_end" => "false"}).release_on_session_end?("myapp")).to be(false)
      expect(config_for({"release_on_session_end" => false}).release_on_session_end?("myapp")).to be(false)
    end

    it "raises ConfigParseError for a file that cannot be parsed" do
      dir = Dir.mktmpdir("ws-dev-config")
      FileUtils.mkdir_p(File.join(dir, "projects"))
      File.write(File.join(dir, "projects", "myapp.yml"), "a: [\n")

      expect { described_class.new(project_settings: project_settings_with(dir: dir)).release_on_session_end?("myapp") }
        .to raise_error(Workspace::ConfigParseError)
    end
  end

  describe "#for_project" do
    it "returns nils and the default timeouts when nothing is configured" do
      dir = Dir.mktmpdir("ws-dev-config")
      dev_config = described_class.new(project_settings: project_settings_with(dir: dir))

      result = dev_config.for_project("myapp")

      expect(result).to eq(up: nil, ready: nil, stop_timeout: Workspace::DevConfig::DEFAULT_STOP_TIMEOUT,
        startup_timeout: Workspace::DevConfig::DEFAULT_STARTUP_TIMEOUT,
        ready_timeout: Workspace::DevConfig::DEFAULT_READY_TIMEOUT,
        kill_grace: Workspace::ProcessHolderStopper::KILL_GRACE_SECONDS)
    end

    it "returns the configured up, ready, and timeouts" do
      dir = Dir.mktmpdir("ws-dev-config")
      project_settings = project_settings_with(dir: dir)
      project_settings.save("myapp", {"dev" => {"up" => "./start-dev", "ready" => "port:3000", "stop_timeout" => "30s",
                                                "startup_timeout" => "45s", "ready_timeout" => "5m", "kill_grace" => "10s"}})
      dev_config = described_class.new(project_settings: project_settings)

      result = dev_config.for_project("myapp")

      expect(result).to eq(up: "./start-dev", ready: "port:3000", stop_timeout: 30.0, startup_timeout: 45.0,
        ready_timeout: 300.0, kill_grace: 10.0)
    end

    it "raises Workspace::Error for an invalid stored stop_timeout" do
      dir = Dir.mktmpdir("ws-dev-config")
      project_settings = project_settings_with(dir: dir)
      project_settings.save("myapp", {"dev" => {"stop_timeout" => "soon"}})
      dev_config = described_class.new(project_settings: project_settings)

      expect { dev_config.for_project("myapp") }.to raise_error(Workspace::Error, /Invalid dev.stop_timeout/)
    end

    ["startup_timeout", "ready_timeout"].each do |key|
      it "raises Workspace::Error for an invalid stored #{key}" do
        dir = Dir.mktmpdir("ws-dev-config")
        project_settings = project_settings_with(dir: dir)
        project_settings.save("myapp", {"dev" => {key => "soon"}})
        dev_config = described_class.new(project_settings: project_settings)

        expect { dev_config.for_project("myapp") }.to raise_error(Workspace::Error, /Invalid dev.#{key}/)
      end
    end

    it "raises Workspace::Error for a stored kill_grace over the 60s cap" do
      dir = Dir.mktmpdir("ws-dev-config")
      project_settings = project_settings_with(dir: dir)
      project_settings.save("myapp", {"dev" => {"kill_grace" => "61s"}})
      dev_config = described_class.new(project_settings: project_settings)

      expect { dev_config.for_project("myapp") }.to raise_error(Workspace::Error, /Invalid dev.kill_grace/)
    end

    it "raises Workspace::Error for a non-positive stored kill_grace" do
      dir = Dir.mktmpdir("ws-dev-config")
      project_settings = project_settings_with(dir: dir)
      project_settings.save("myapp", {"dev" => {"kill_grace" => "0"}})
      dev_config = described_class.new(project_settings: project_settings)

      expect { dev_config.for_project("myapp") }.to raise_error(Workspace::Error, /Invalid dev.kill_grace/)
    end
  end
end
