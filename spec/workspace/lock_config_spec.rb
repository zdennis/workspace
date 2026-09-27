require "spec_helper"
require "tmpdir"

RSpec.describe Workspace::LockConfig do
  let(:dir) { Dir.mktmpdir("ws-lock-config") }
  let(:project_settings) { Workspace::ProjectSettings.new(config: Struct.new(:workspace_config_dir).new(dir)) }
  let(:error_output) { StringIO.new }
  let(:lock_config) { described_class.new(project_settings: project_settings, error_output: error_output) }

  after { FileUtils.remove_entry(dir) }

  describe ".parse_idle_grace" do
    it "parses seconds and durations" do
      expect(described_class.parse_idle_grace("90")).to eq(90.0)
      expect(described_class.parse_idle_grace("10m")).to eq(600.0)
    end

    it "rejects zero, negative and malformed values" do
      ["0", "0m", "-1", "later"].each do |bad|
        expect { described_class.parse_idle_grace(bad) }.to raise_error(ArgumentError)
      end
    end
  end

  describe "#idle_grace_for" do
    it "defaults to 5 minutes when unset" do
      expect(lock_config.idle_grace_for("app")).to eq(300)
    end

    it "reads locks.idle_grace from the project config" do
      project_settings.save("app", {"locks" => {"idle_grace" => "10m"}})

      expect(lock_config.idle_grace_for("app")).to eq(600.0)
    end

    it "warns and falls back to the default on an invalid stored value" do
      project_settings.save("app", {"locks" => {"idle_grace" => "0"}})

      expect(lock_config.idle_grace_for("app")).to eq(300)
      expect(error_output.string).to include("Warning: invalid locks.idle_grace for 'app'", "using 300s")
    end

    it "ignores a locks key that is not a mapping" do
      project_settings.save("app", {"locks" => "nope"})

      expect(lock_config.idle_grace_for("app")).to eq(300)
    end
  end

  describe ".parse_kill_grace" do
    it "parses seconds and durations" do
      expect(described_class.parse_kill_grace("0.5")).to eq(0.5)
      expect(described_class.parse_kill_grace("10s")).to eq(10.0)
    end

    it "rejects zero, negative and malformed values" do
      ["0", "0s", "-1", "later"].each do |bad|
        expect { described_class.parse_kill_grace(bad) }.to raise_error(ArgumentError)
      end
    end
  end

  describe "#kill_grace_for" do
    it "defaults to 2 seconds when unset" do
      expect(lock_config.kill_grace_for("app")).to eq(2)
    end

    it "reads locks.kill_grace from the project config" do
      project_settings.save("app", {"locks" => {"kill_grace" => "10s"}})

      expect(lock_config.kill_grace_for("app")).to eq(10.0)
    end

    it "warns and falls back to the default on an invalid stored value" do
      project_settings.save("app", {"locks" => {"kill_grace" => "0"}})

      expect(lock_config.kill_grace_for("app")).to eq(2)
      expect(error_output.string).to include("Warning: invalid locks.kill_grace for 'app'", "using 2s")
    end
  end
end
