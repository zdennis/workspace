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

  describe ".parse_ps_timeout" do
    it "parses seconds and durations" do
      expect(described_class.parse_ps_timeout("15")).to eq(15.0)
      expect(described_class.parse_ps_timeout("1m")).to eq(60.0)
    end

    it "rejects zero, negative and malformed values" do
      ["0", "0m", "-1", "later"].each do |bad|
        expect { described_class.parse_ps_timeout(bad) }.to raise_error(ArgumentError)
      end
    end
  end

  describe "#ps_timeout_for" do
    it "defaults to 5 seconds when unset" do
      expect(lock_config.ps_timeout_for("app")).to eq(Workspace::ProcessTree::DEFAULT_TIMEOUT)
    end

    it "reads locks.ps_timeout from the project config" do
      project_settings.save("app", {"locks" => {"ps_timeout" => "15s"}})

      expect(lock_config.ps_timeout_for("app")).to eq(15.0)
    end

    it "warns and falls back to the default on an invalid stored value" do
      project_settings.save("app", {"locks" => {"ps_timeout" => "0"}})

      expect(lock_config.ps_timeout_for("app")).to eq(Workspace::ProcessTree::DEFAULT_TIMEOUT)
      expect(error_output.string).to include("Warning: invalid locks.ps_timeout for 'app'", "using #{Workspace::ProcessTree::DEFAULT_TIMEOUT}s")
    end

    it "ignores a locks key that is not a mapping" do
      project_settings.save("app", {"locks" => "nope"})

      expect(lock_config.ps_timeout_for("app")).to eq(Workspace::ProcessTree::DEFAULT_TIMEOUT)
    end
  end

  describe ".parse_reap_interval" do
    it "parses seconds and durations" do
      expect(described_class.parse_reap_interval("60")).to eq(60.0)
      expect(described_class.parse_reap_interval("2m")).to eq(120.0)
    end

    it "rejects zero, negative and malformed values" do
      ["0", "0m", "-1", "later"].each do |bad|
        expect { described_class.parse_reap_interval(bad) }.to raise_error(ArgumentError)
      end
    end
  end

  describe "#reap_interval_for" do
    it "defaults to 30 seconds when unset" do
      expect(lock_config.reap_interval_for("app")).to eq(Workspace::LockReaper::DEFAULT_INTERVAL)
    end

    it "reads locks.reap_interval from the project config" do
      project_settings.save("app", {"locks" => {"reap_interval" => "2m"}})

      expect(lock_config.reap_interval_for("app")).to eq(120.0)
    end

    it "warns and falls back to the default on an invalid stored value" do
      project_settings.save("app", {"locks" => {"reap_interval" => "0"}})

      expect(lock_config.reap_interval_for("app")).to eq(Workspace::LockReaper::DEFAULT_INTERVAL)
      expect(error_output.string).to include("Warning: invalid locks.reap_interval for 'app'", "using #{Workspace::LockReaper::DEFAULT_INTERVAL}s")
    end

    it "ignores a locks key that is not a mapping" do
      project_settings.save("app", {"locks" => "nope"})

      expect(lock_config.reap_interval_for("app")).to eq(Workspace::LockReaper::DEFAULT_INTERVAL)
    end
  end
end
