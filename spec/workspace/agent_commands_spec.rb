require "spec_helper"

RSpec.describe Workspace::AgentCommands do
  let(:global) { {} }
  let(:project_settings) { instance_double(Workspace::ProjectSettings) }
  subject(:agent_commands) { described_class.new(config_resolver: Workspace::ConfigResolver.new(project_settings: project_settings)) }

  before do
    allow(project_settings).to receive(:load_global) { global }
    allow(project_settings).to receive(:load).and_return({})
  end

  def stub_file(name, data)
    allow(project_settings).to receive(:load).with(name).and_return(data)
  end

  it "defaults to claude and each provider's executable" do
    expect(agent_commands.kind("app")).to eq("claude")
    Workspace::AgentProvider.all.each do |provider|
      expect(agent_commands.command_for("app", provider.key)).to eq(provider.executable)
    end
  end

  describe "#executable_for" do
    let(:global) { {"agent" => {"commands" => {"claude" => "FOO=1 /opt/bin/claude-dev --x", "codex" => "codex-g"}}} }

    it "is the program of the workspace's command" do
      stub_file("app", {"agent" => {"commands" => {"codex" => "exec codex-p"}}})

      expect(agent_commands.executable_for("app", "claude")).to eq("claude-dev")
      expect(agent_commands.executable_for("app", "codex")).to eq("codex-p")
    end

    it "reads the global layer alone without a workspace" do
      stub_file("app", {"agent" => {"commands" => {"codex" => "codex-p"}}})

      expect(agent_commands.executable_for(nil, "codex")).to eq("codex-g")
      expect(agent_commands.executable_for(nil, "pi")).to eq("pi")
    end

    it "is the provider's executable when the command has no program" do
      stub_file("app", {"agent" => {"commands" => {"claude" => "FOO=1"}}})

      expect(agent_commands.executable_for("app", "claude")).to eq("claude")
    end
  end

  describe "#layer_for, #effective_command_for and #configured_commands_for" do
    let(:global) { {"agent" => {"commands" => {"claude" => "claude-g"}}} }

    it "names the winning layer, default when none sets it" do
      stub_file("app", {"agent" => {"commands" => {"codex" => "codex-p"}}})
      stub_file("app.worktree-x", {"agent" => {"commands" => {"claude" => "claude-w"}}})

      expect(agent_commands.layer_for("app.worktree-x", "claude")).to eq("worktree")
      expect(agent_commands.layer_for("app.worktree-x", "codex")).to eq("project")
      expect(agent_commands.layer_for("app", "claude")).to eq("global")
      expect(agent_commands.layer_for(nil, "pi")).to eq("default")
    end

    it "reads the global layer alone without a workspace" do
      stub_file("app", {"agent" => {"commands" => {"claude" => "claude-p"}}})

      expect(agent_commands.layer_for(nil, "claude")).to eq("global")
      expect(agent_commands.effective_command_for(nil, "claude")).to eq("claude-g")
      expect(agent_commands.configured_commands_for(nil, "claude")).to eq(["claude-g"])
    end

    it "lists every applicable layer\x27s command, highest first" do
      stub_file("app", {"agent" => {"commands" => {"claude" => "claude-p"}}})

      expect(agent_commands.configured_commands_for("app", "claude")).to eq(%w[claude-p claude-g])
    end

    it "calls the layer default when its value does not parse" do
      stub_file("app", {"agent" => {"commands" => {"claude" => "  "}}})

      expect(agent_commands.layer_for("app", "claude")).to eq("default")
      expect(agent_commands.configured_commands_for("app", "claude")).to eq(["claude-g"])
    end

    it "raises for an unknown kind" do
      expect { agent_commands.layer_for("app", "nope") }.to raise_error(ArgumentError)
      expect { agent_commands.configured_commands_for("app", "nope") }.to raise_error(ArgumentError)
    end
  end

  context "with a global value" do
    let(:global) { {"agent" => {"kind" => "codex", "commands" => {"claude" => "claude-dev"}}} }

    it "applies to every workspace" do
      expect(agent_commands.kind("app")).to eq("codex")
      expect(agent_commands.command_for("app", "claude")).to eq("claude-dev")
      expect(agent_commands.command_for("app", "codex")).to eq("codex")
    end

    it "is overridden by the project" do
      stub_file("app", {"agent" => {"commands" => {"claude" => "claude-notes"}}})

      expect(agent_commands.command_for("app", "claude")).to eq("claude-notes")
    end

    it "is overridden by the worktree over the project" do
      stub_file("app", {"agent" => {"kind" => "pi", "commands" => {"claude" => "claude-notes"}}})
      stub_file("app.worktree-x", {"agent" => {"kind" => "opencode", "commands" => {"claude" => "~/bin/claude-wt --x"}}})

      expect(agent_commands.kind("app.worktree-x")).to eq("opencode")
      expect(agent_commands.command_for("app.worktree-x", "claude")).to eq("~/bin/claude-wt --x")
      expect(agent_commands.kind("app")).to eq("pi")
    end
  end

  describe "#names_for" do
    it "is the executable alone when nothing is set" do
      expect(agent_commands.names_for("app", "claude")).to eq(["claude"])
    end

    it "adds the first program word's basename from each applicable layer" do
      global["agent"] = {"commands" => {"claude" => "/opt/bin/claude-dev --flag"}}
      stub_file("app", {"agent" => {"commands" => {"claude" => "claude-notes"}}})
      stub_file("app.worktree-x", {"agent" => {"commands" => {"claude" => "claude-wt"}}})

      expect(agent_commands.names_for("app.worktree-x", "claude")).to eq(%w[claude claude-wt claude-notes claude-dev])
      expect(agent_commands.names_for("app", "claude")).to eq(%w[claude claude-notes claude-dev])
    end

    it "skips a layer whose value does not parse" do
      stub_file("app", {"agent" => {"commands" => {"claude" => "  "}}})

      expect(agent_commands.names_for("app", "claude")).to eq(["claude"])
    end
  end

  it "falls back to the default for a value that does not parse" do
    stub_file("app", {"agent" => {"kind" => "emacs", "commands" => {"claude" => "   "}}})

    expect(agent_commands.kind("app")).to eq("claude")
    expect(agent_commands.command_for("app", "claude")).to eq("claude")
  end

  it "raises for an unknown kind" do
    expect { agent_commands.command_for("app", "emacs") }.to raise_error(ArgumentError, /unknown agent kind/)
    expect { agent_commands.names_for("app", "emacs") }.to raise_error(ArgumentError, /unknown agent kind/)
  end

  it "falls back to the defaults when a project config file can't be parsed" do
    allow(project_settings).to receive(:load).with("app").and_raise(Workspace::ConfigParseError.new("/c/app.yml", "bad yaml"))

    expect(agent_commands.kind("app")).to eq("claude")
    expect(agent_commands.command_for("app", "codex")).to eq("codex")
    expect(agent_commands.names_for("app", "codex")).to eq(["codex"])
  end

  it "falls back to the defaults when a worktree config file can't be parsed" do
    allow(project_settings).to receive(:load).with("app.worktree-x").and_raise(Workspace::ConfigParseError.new("/c/x.yml", "bad yaml"))

    expect(agent_commands.kind("app.worktree-x")).to eq("claude")
    expect(agent_commands.command_for("app.worktree-x", "codex")).to eq("codex")
    expect(agent_commands.names_for("app.worktree-x", "codex")).to eq(["codex"])
  end

  it "names the program past environment settings and wrapper words in names_for" do
    global["agent"] = {"commands" => {"codex" => "FOO=1 codex-dev"}}
    stub_file("app", {"agent" => {"commands" => {"codex" => "env X=1 /opt/bin/codex-dev"}}})

    expect(agent_commands.names_for("app", "codex")).to eq(%w[codex codex-dev])
  end

  describe ".program_words" do
    it "starts at the program, past VAR=value words and wrapper words" do
      expect(described_class.program_words("FOO=1 codex-dev --x")).to eq(%w[codex-dev --x])
      expect(described_class.program_words("env X=1 claude-dev")).to eq(%w[claude-dev])
      expect(described_class.program_words("exec bundle exec claude-dev -p")).to eq(%w[claude-dev -p])
    end

    it "is empty for a command with no program" do
      expect(described_class.program_words("  ")).to eq([])
      expect(described_class.program_words("FOO=1")).to eq([])
    end
  end

  describe ".program_for" do
    it "is the program's basename" do
      expect(described_class.program_for("claude-dev --x")).to eq("claude-dev")
      expect(described_class.program_for("env X=1 /opt/bin/claude-dev")).to eq("claude-dev")
      expect(described_class.program_for("exec bundle exec claude-dev")).to eq("claude-dev")
    end

    it "is nil for a command with no program" do
      expect(described_class.program_for("  ")).to be_nil
      expect(described_class.program_for("FOO=1")).to be_nil
    end
  end

  describe "#aliases_for" do
    it "is empty with no configured commands" do
      expect(agent_commands.aliases_for("app")).to eq({})
    end

    context "with a configured claude command" do
      let(:global) { {"agent" => {"commands" => {"claude" => "/opt/bin/claude-dev --x", "codex" => "codex"}}} }

      it "lists the extra names per kind, never the provider's own executable" do
        expect(agent_commands.aliases_for("app")).to eq("claude" => ["claude-dev"])
      end
    end
  end

  describe "#detector and #detector_options" do
    let(:global) { {"agent" => {"commands" => {"claude" => "claude-dev"}}} }

    it "binds the workspace's names to a detector" do
      expect(agent_commands.detector("app")).to eq(Workspace::AgentDetector.new(aliases: {"claude" => ["claude-dev"]}))
      expect(agent_commands.detector_options("app")).to eq(detector: Workspace::AgentDetector.new(aliases: {"claude" => ["claude-dev"]}))
    end

    context "with nothing configured" do
      let(:global) { {} }

      it "gives the default detector and no options" do
        expect(agent_commands.detector("app")).to eq(Workspace::AgentDetector.new)
        expect(agent_commands.detector_options("app")).to eq({})
      end
    end
  end
end
