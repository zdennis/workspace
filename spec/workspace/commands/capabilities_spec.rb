require "spec_helper"
require "stringio"
require "tmpdir"
require "fileutils"

RSpec.describe Workspace::Commands::Capabilities do
  let(:output) { StringIO.new }
  let(:config) { instance_double(Workspace::Config, event_log_file: "/home/z/.workspace-events.jsonl", run_dir: "/home/z/.local/workspace/run", library_dir: "/home/z/.config/workspace/library") }
  let(:bin_dir) { Dir.mktmpdir("capabilities-bin") }
  let(:path_env) { bin_dir }
  subject(:command) { described_class.new(config: config, path_env: path_env, output: output) }

  after { FileUtils.remove_entry(bin_dir) }

  def install(name, mode: 0o755)
    path = File.join(bin_dir, name)
    File.write(path, "#!/bin/sh\n")
    File.chmod(mode, path)
    path
  end

  def document
    JSON.parse(output.string)
  end

  describe "#call with json: true" do
    it "prints one enveloped document, schema_version and ok first" do
      command.call(json: true)

      expect(output.string.lines.size).to eq(1)
      expect(document.keys.first(3)).to eq(%w[schema_version ok version])
      expect(document).to include("schema_version" => 1, "ok" => true, "version" => Workspace::VERSION)
    end

    it "reports each feature as an integer revision, 0 meaning unsupported" do
      command.call(json: true)

      features = document["features"]
      expect(features.values).to all(be_a(Integer))
      expect(features).to include("prune_safe" => 1)
      expect(features).to include("envelope" => 1, "error_codes" => 1, "no_input" => 1, "name_scope" => 1, "action_json" => 1, "sessions" => 1)
      expect(features).to include("snapshot" => 2, "agent_send" => 1, "focus_pane" => 1, "actions_manifest" => 0)
      expect(features).to include("config_json" => 1, "tmux_show" => 1, "state_done" => 1, "tasks" => 1, "event_emitters" => 1, "daemon_control" => 2, "ui_open" => 1, "pane_bindings" => 2, "library" => 3, "library_play" => 2, "library_copy" => 1, "instructions" => 1)
    end

    it "reports the exit codes the CLI uses" do
      command.call(json: true)

      expect(document["exit_codes"]).to eq("ok" => 0, "failed" => 1, "not_submitted" => 2, "partial" => 3, "lock_cleared" => 4, "timeout" => 75)
    end

    it "reports the event log, run and library directories from config" do
      command.call(json: true)

      expect(document["paths"]).to eq("event_log" => "/home/z/.workspace-events.jsonl", "run_dir" => "/home/z/.local/workspace/run", "library" => "/home/z/.config/workspace/library")
    end

    it "reports the path of each dependency found on PATH" do
      install("window-tool")
      install("tmux")

      command.call(json: true)

      expect(document["dependencies"]).to eq(
        "window_tool" => {"path" => File.join(bin_dir, "window-tool")},
        "gh" => {"path" => nil},
        "tmux" => {"path" => File.join(bin_dir, "tmux")}
      )
    end

    it "ignores a PATH entry that is not executable or is a directory" do
      install("gh", mode: 0o644)
      FileUtils.mkdir_p(File.join(bin_dir, "tmux"))

      command.call(json: true)

      expect(document["dependencies"]["gh"]).to eq("path" => nil)
      expect(document["dependencies"]["tmux"]).to eq("path" => nil)
    end

    it "uses the first match in PATH order" do
      other = Dir.mktmpdir("capabilities-bin2")
      File.write(File.join(other, "gh"), "#!/bin/sh\n")
      File.chmod(0o755, File.join(other, "gh"))
      install("gh")

      described_class.new(config: config, path_env: [other, bin_dir].join(":"), output: output).call(json: true)

      expect(document["dependencies"]["gh"]).to eq("path" => File.join(other, "gh"))
    ensure
      FileUtils.remove_entry(other)
    end

    it "copes with a missing or empty PATH" do
      described_class.new(config: config, path_env: nil, output: output).call(json: true)

      expect(document["dependencies"].values).to all(eq("path" => nil))
    end

    it "spawns no process" do
      expect(Open3).not_to receive(:capture3)
      expect(Open3).not_to receive(:capture2e)
      expect(Kernel).not_to receive(:system)

      command.call(json: true)
    end
  end

  describe "#call without json" do
    it "prints the version, features and dependencies as text" do
      install("gh")

      command.call

      expect(output.string).to include("workspace #{Workspace::VERSION}")
      expect(output.string).to match(/^  envelope +1$/)
      expect(output.string).to match(/^  snapshot +2$/)
      expect(output.string).to include("  gh          #{File.join(bin_dir, "gh")}")
      expect(output.string).to include("  tmux        not found")
    end
  end

  it "lists every feature in docs/README.capabilities.md" do
    doc = File.read(File.expand_path("../../../docs/README.capabilities.md", __dir__))
    missing = described_class::FEATURES.keys.reject { |feature| doc.include?("`#{feature}`") }
    expect(missing).to eq([])
  end
end
