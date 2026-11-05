require "spec_helper"
require "stringio"
require "tmpdir"
require "fileutils"

RSpec.describe Workspace::Commands::AgentExecutables do
  let(:tmp) { Dir.mktmpdir }
  let(:bin) { File.join(tmp, "bin").tap { |d| FileUtils.mkdir_p(d) } }
  let(:output) { StringIO.new }
  let(:project_settings) { instance_double(Workspace::ProjectSettings) }
  let(:agent_commands) { Workspace::AgentCommands.new(config_resolver: Workspace::ConfigResolver.new(project_settings: project_settings)) }
  let(:scanner) { Workspace::AgentExecutables.new(agent_commands: agent_commands, path: bin) }
  let(:project_config) { instance_double(Workspace::ProjectConfig) }
  let(:global) { {} }

  subject(:command) { described_class.new(executables: scanner, project_config: project_config, output: output) }

  before do
    %w[claude claude-dev codex].each { |n| File.write(File.join(bin, n), "#!/bin/sh\n").then { File.chmod(0o755, File.join(bin, n)) } }
    allow(project_settings).to receive(:load_global) { global }
    allow(project_settings).to receive(:load).and_return({})
    allow(project_config).to receive(:existing_name) { |name| (name.downcase == "api") ? "api" : nil }
  end

  after { FileUtils.rm_rf(tmp) }

  def json
    JSON.parse(output.string)
  end

  describe "--json" do
    it "prints one document in the envelope, workspace first, with the scan's fields" do
      command.call(name: "API", json: true)

      expect(json.keys).to eq(%w[schema_version ok workspace path_dirs executables effective kind])
      expect(json).to include("schema_version" => 1, "ok" => true, "workspace" => "api", "kind" => "claude")
      expect(json["path_dirs"]).to eq([bin])
      expect(json["executables"].map { |r| r["name"] }).to eq(%w[claude claude-dev codex])
      expect(json["effective"]["claude"]).to include("program" => "claude", "layer" => "default", "found" => true)
    end

    it "reports workspace null outside a workspace" do
      command.call(json: true)

      expect(json["workspace"]).to be_nil
    end

    it "uses the detected workspace when no name is given" do
      command.call(detected: "web", json: true)

      expect(json["workspace"]).to eq("web")
    end

    it "keeps only the family asked for" do
      command.call(kind: "codex", json: true)

      expect(json["executables"].map { |r| r["kind"] }.uniq).to eq(["codex"])
      expect(json["effective"].keys).to include("claude", "codex")
    end

    it "reports the layer of a configured program that is not on PATH" do
      global["agent"] = {"commands" => {"claude" => "/old/bin/claude-x"}}

      command.call(json: true)

      expect(json["executables"]).to include(a_hash_including("name" => "/old/bin/claude-x", "source" => "configured", "found" => false))
      expect(json["effective"]["claude"]).to include("layer" => "global", "found" => false, "path" => nil)
    end
  end

  describe "errors" do
    it "refuses an unknown kind with the known ones" do
      expect { command.call(kind: "gemini", json: true) }.to raise_error(Workspace::Error) { |e|
        expect(e.code).to eq("unknown_agent_kind")
        expect(e.details).to eq("kind" => "gemini", "known" => Workspace::AgentProvider.all.map(&:key))
      }
      expect(output.string).to be_empty
    end

    it "refuses an unknown workspace" do
      expect { command.call(name: "nope") }.to raise_error(Workspace::Error) { |e|
        expect(e.code).to eq("unknown_workspace")
        expect(e.details).to eq("name" => "nope")
      }
    end
  end

  describe "text" do
    it "prints a section per kind and marks what each runs" do
      global["agent"] = {"commands" => {"claude" => "claude-dev"}}

      command.call(name: "api")

      text = output.string
      expect(text).to include("Workspace: api").and include("Main agent kind: claude")
      expect(text).to include("claude (runs claude-dev, from global settings)")
      expect(text).to match(/^    claude  #{Regexp.escape(File.join(bin, "claude"))}$/)
      expect(text).to match(/^  \* claude-dev  /)
      expect(text).to include("codex (runs codex, from the default)").and match(/^  \* codex  /)
      expect(text).to match(/opencode \(runs opencode, from the default\)\n  none found/)
    end

    it "says global settings outside a workspace and shows a configured program as not found" do
      global["agent"] = {"commands" => {"claude" => "/old/bin/claude-x"}}

      command.call(kind: "claude")

      expect(output.string).to include("Workspace: none (global settings)")
      expect(output.string).to match(%r{^  \* /old/bin/claude-x  not found$})
    end
  end
end
