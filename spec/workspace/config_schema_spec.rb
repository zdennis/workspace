require "spec_helper"

RSpec.describe Workspace::ConfigSchema do
  let(:root) { File.expand_path("../..", __dir__) }

  it "lists the settable keys in the order `config set` has always reported them" do
    expect(described_class.project_keys.map(&:name)).to eq(%w[dev.up dev.ready dev.stop_timeout dev.startup_timeout dev.ready_timeout dev.kill_grace locks.idle_grace locks.ps_timeout locks.reap_interval alerts.notify alerts.idle_after handoff.threshold handoff.check_prompt handoff.resume_prompt])
    expect(described_class.global_keys.map(&:name)).to eq(%w[statusline.command context.source context.pattern launch.headless])
  end

  it "names the keys a running daemon only reads at startup" do
    expect(described_class.restart_required_names).to eq(%w[locks.ps_timeout locks.reap_interval alerts.notify alerts.idle_after])
  end

  it "tells settable keys from keys that are only documented" do
    expect(described_class.settable?("dev.up")).to be true
    expect(described_class.settable?("hooks")).to be false
    expect(described_class.settable?("dev.bogus")).to be false
  end

  it "has a description for every key" do
    expect(described_class.all).to all(satisfy { |key| !key.doc.to_s.strip.empty? })
  end

  describe ".default" do
    it "holds the default every reader falls back to" do
      expect(described_class.default("dev.stop_timeout")).to eq(20)
      expect(described_class.default("dev.startup_timeout")).to eq(30)
      expect(described_class.default("dev.ready_timeout")).to eq(120)
      expect(described_class.default("dev.kill_grace")).to eq(2)
      expect(described_class.default("locks.idle_grace")).to eq(300)
      expect(described_class.default("locks.ps_timeout")).to eq(5)
      expect(described_class.default("locks.reap_interval")).to eq(30)
      expect(described_class.default("alerts.idle_after")).to eq(600)
      expect(described_class.default("handoff.threshold")).to eq(11)
      expect(described_class.default("alerts.notify")).to be_nil
    end
  end

  describe ".parse" do
    it "parses durations and returns seconds" do
      expect(described_class.parse("dev.stop_timeout", "5m")).to eq(300.0)
      expect(described_class.parse("dev.stop_timeout", "0")).to eq(0.0)
    end

    it "requires positive durations where the key says so" do
      expect { described_class.parse("dev.ready_timeout", "0") }.to raise_error(ArgumentError, /greater than 0/)
      expect { described_class.parse("locks.idle_grace", "0") }.to raise_error(ArgumentError, /greater than 0/)
    end

    it "caps and ranges durations" do
      expect { described_class.parse("dev.kill_grace", "61") }.to raise_error(ArgumentError, /at most 60s/)
      expect { described_class.parse("locks.ps_timeout", "0.5") }.to raise_error(ArgumentError, /at least 1s and at most 60s/)
      expect(described_class.parse("locks.ps_timeout", "1m")).to eq(60.0)
    end

    it "checks a handoff threshold, a notify command, a prompt and launch.headless" do
      expect(described_class.parse("handoff.threshold", "42")).to eq(42)
      expect { described_class.parse("handoff.threshold", "101") }.to raise_error(ArgumentError, /between 1 and 100/)
      expect(described_class.parse("alerts.notify", "  say hi ")).to eq("say hi")
      expect { described_class.parse("alerts.notify", " ") }.to raise_error(ArgumentError, /blank/)
      expect { described_class.parse("handoff.check_prompt", " ") }.to raise_error(ArgumentError, /blank/)
      expect(described_class.parse("launch.headless", "true")).to eq("true")
      expect { described_class.parse("launch.headless", "yes") }.to raise_error(ArgumentError, /"true" or "false"/)
    end

    it "checks context.source and context.pattern" do
      expect(described_class.parse("context.source", "scrape")).to eq("scrape")
      expect { described_class.parse("context.source", "x") }.to raise_error(ArgumentError, /"statusline" or "scrape"/)
      expect { described_class.parse("context.pattern", "no group") }.to raise_error(ArgumentError, /exactly one capture group/)
      expect { described_class.parse("context.pattern", "(") }.to raise_error(RegexpError)
      expect(described_class.parse("context.pattern", "(\\d+)% ctx")).to eq("(\\d+)% ctx")
      expect { described_class.parse("context.pattern", "[(]x(a)(b)") }.to raise_error(ArgumentError, /exactly one/)
    end

    it "passes free-text keys through" do
      expect(described_class.parse("dev.up", "bin/dev")).to eq("bin/dev")
    end
  end

  describe "readers" do
    it "declares every key a reader fetches" do
      reader_keys = %w[dev_config lock_config alert_config handoff_config].flat_map do |file|
        source = File.read(File.join(root, "lib/workspace/#{file}.rb"))
        section = {"dev_config" => "dev", "lock_config" => "locks", "alert_config" => "alerts", "handoff_config" => "handoff"}.fetch(file)
        source.scan(/ConfigSchema\.(?:key|default|parse)\("([a-z_.]+)"/).flatten.tap do |names|
          expect(names).to all(start_with("#{section}."))
        end
      end
      expect(reader_keys.uniq - described_class.all.map(&:name)).to eq([])
    end
  end
end
