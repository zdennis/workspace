require "spec_helper"
require "tmpdir"

RSpec.describe Workspace::MainAgent do
  around do |example|
    Dir.mktmpdir("main-agent") do |dir|
      @dir = dir
      example.run
    end
  end

  let(:project_config) { instance_double(Workspace::ProjectConfig) }
  subject(:main_agent) { described_class.new(project_config: project_config) }

  def config_with(panes, name: "app")
    path = File.join(@dir, "#{name}.yml")
    File.write(path, YAML.dump({"name" => name, "windows" => [{"w" => {"panes" => panes}}]}))
    allow(project_config).to receive(:config_path_for).with(name).and_return(path)
  end

  it "is claude for a project with no config yet, since the templates run Claude Code" do
    allow(project_config).to receive(:config_path_for).with("app").and_return(File.join(@dir, "none.yml"))

    expect(main_agent.kind("app")).to eq("claude")
  end

  it "finds claude in the template's fallback command" do
    config_with(["ascii-banner x", "claude --dangerously-skip-permissions --continue || claude --dangerously-skip-permissions", "echo hi", "workspace agentd --debug"])

    expect(main_agent.kind("app")).to eq("claude")
  end

  it "finds another agent, and the first agent pane when several run" do
    config_with(["echo hi", "FOO=1 codex --yolo", "claude"])

    expect(main_agent.kind("app")).to eq("codex")
  end

  it "reads panes written as titled mappings and command lists" do
    config_with([{"agent" => "opencode"}, {"other" => ["cd src", "claude"]}])

    expect(main_agent.kind("app")).to eq("opencode")
  end

  it "reads a window written as a bare list of panes" do
    config_with(["echo hi"])
    path = File.join(@dir, "app.yml")
    File.write(path, YAML.dump({"windows" => [{"w" => ["claude"]}]}))

    expect(main_agent.kind("app")).to eq("claude")
  end

  it "does not take a window's root or layout for a pane command" do
    path = File.join(@dir, "app.yml")
    File.write(path, YAML.dump({"windows" => [{"w" => {"root" => "~/src/pi", "layout" => "main", "panes" => ["echo hi", "codex"]}}]}))
    allow(project_config).to receive(:config_path_for).with("app").and_return(path)

    expect(main_agent.kind("app")).to eq("codex")
  end

  it "sees through exec, env, bundle exec, a path and a separator" do
    ["exec claude", "env A=1 claude", "bundle exec codex", "cd src && /usr/local/bin/claude", "nohup claude; echo"].each do |command|
      config_with([command])
      expect(main_agent.kind("app")).to eq(command.include?("codex") ? "codex" : "claude")
    end
  end

  it "does not take a word in an echo or a path for an agent" do
    config_with(["echo 'run claude here'", "cat ~/claude/notes.md"])

    expect(main_agent.kind("app")).to eq("none")
  end

  it "is none when no pane runs a known agent, and when the config cannot be read" do
    config_with(["echo hi"])
    expect(main_agent.kind("app")).to eq("none")

    path = File.join(@dir, "bad.yml")
    File.write(path, "a: [\n")
    allow(project_config).to receive(:config_path_for).with("bad").and_return(path)
    expect(main_agent.kind("bad")).to eq("none")
  end

  describe "#spawn_command" do
    let(:template_command) { "claude --dangerously-skip-permissions --continue || claude --dangerously-skip-permissions" }

    before do
      allow(project_config).to receive(:agent_pane_command) { |kind| (kind == "claude") ? template_command : kind }
      allow(project_config).to receive(:with_configured_program) { |text, *| text }
    end

    it "passes the fresh part, the kind and the workspace to with_configured_program" do
      config_with(["claude --flag --continue || claude --flag"])
      allow(project_config).to receive(:with_configured_program).with("claude --flag", "claude", "app").and_return("swapped --flag")

      expect(main_agent.spawn_command("app", "claude")).to eq("swapped --flag")
    end

    it "takes the workspace's own pane command for the kind, without the part that resumes a conversation" do
      config_with(["echo hi", "claude --dangerously-skip-permissions --model opus --continue || claude --dangerously-skip-permissions --model opus"])

      expect(main_agent.spawn_command("app", "claude")).to eq("claude --dangerously-skip-permissions --model opus")
    end

    it "keeps an environment prefix and flags of another agent's pane" do
      config_with(["FOO=1 codex --yolo"])

      expect(main_agent.spawn_command("app", "codex")).to eq("FOO=1 codex --yolo")
    end

    it "falls back to the command a new worktree config runs for the kind when the workspace runs another agent" do
      config_with(["codex --yolo"])

      expect(main_agent.spawn_command("app", "claude")).to eq("claude --dangerously-skip-permissions")
      expect(main_agent.spawn_command("app", "opencode")).to eq("opencode")
    end

    it "falls back the same way with no config, and to the executable when every command resumes" do
      allow(project_config).to receive(:config_path_for).with("app").and_return(File.join(@dir, "none.yml"))
      expect(main_agent.spawn_command("app", "claude")).to eq("claude --dangerously-skip-permissions")

      allow(project_config).to receive(:agent_pane_command).and_return("claude --resume")
      expect(main_agent.spawn_command("app", "claude")).to eq("claude")

      allow(project_config).to receive(:agent_pane_command).and_return(nil)
      expect(main_agent.spawn_command("app", "claude")).to eq("claude")
    end

    it "falls back past a config that can't be parsed, and keeps only the agent part of a chained pane" do
      path = File.join(@dir, "bad.yml")
      File.write(path, "a: [\n")
      allow(project_config).to receive(:config_path_for).with("bad").and_return(path)
      expect(main_agent.spawn_command("bad", "claude")).to eq("claude --dangerously-skip-permissions")

      config_with(["cd src && codex --yolo"])
      expect(main_agent.spawn_command("app", "codex")).to eq("codex --yolo")
    end

    it "rejects an unknown kind" do
      expect { main_agent.spawn_command("app", "vim") }.to raise_error(ArgumentError)
    end
  end

  context "with a configured claude command" do
    let(:agent_commands) do
      ps = instance_double(Workspace::ProjectSettings, load_global: {"agent" => {"commands" => {"claude" => "claude-dev"}}}, load: {})
      Workspace::AgentCommands.new(config_resolver: Workspace::ConfigResolver.new(project_settings: ps))
    end
    subject(:main_agent) { described_class.new(project_config: project_config, agent_commands: agent_commands) }
    let(:project_config) do
      config = double("config", worktree_template_path: File.join(Dir.tmpdir, "no-such-template.yml"))
      Workspace::ProjectConfig.new(config: config, git: nil, output: StringIO.new, agent_commands: agent_commands)
    end

    it "takes a pane running claude-dev as claude" do
      config_with(["echo hi", "claude-dev --dangerously-skip-permissions --continue || claude-dev"])

      expect(main_agent.kind("app")).to eq("claude")
    end

    context "when the configured value is an absolute path" do
      let(:agent_commands) do
        ps = instance_double(Workspace::ProjectSettings, load_global: {"agent" => {"commands" => {"claude" => "/abs/claude-dev"}}}, load: {})
        Workspace::AgentCommands.new(config_resolver: Workspace::ConfigResolver.new(project_settings: ps))
      end

      it "takes a pane starting with that path as claude, and spawns it by that path" do
        config_with(["echo hi", "/abs/claude-dev --dangerously-skip-permissions --continue || /abs/claude-dev --dangerously-skip-permissions"])
        allow(project_config).to receive(:agent_pane_command).and_return(nil)

        expect(main_agent.kind("app")).to eq("claude")
        expect(main_agent.spawn_command("app", "claude")).to eq("/abs/claude-dev --dangerously-skip-permissions")
      end
    end

    it "still takes plain claude as claude" do
      config_with(["claude"])

      expect(main_agent.kind("app")).to eq("claude")
    end

    it "does not take claude-dev for an agent when none is configured" do
      config_with(["claude-dev"])

      expect(described_class.new(project_config: project_config).kind("app")).to eq("none")
    end

    describe "#spawn_command" do
      before { allow(project_config).to receive(:agent_pane_command) { |kind, _workspace = nil| "#{kind}-template" } }

      it "swaps the stale fallback half for the configured command" do
        config_with(["claude-dev --continue || claude"])

        expect(main_agent.spawn_command("app", "claude")).to eq("claude-dev")
      end

      it "swaps the program of a plain claude pane, keeping its flags" do
        config_with(["claude --flag --continue || claude --flag"])

        expect(main_agent.spawn_command("app", "claude")).to eq("claude-dev --flag")
      end

      it "still reads an old config with a plain claude second half as claude" do
        config_with(["mycl --continue || claude"])

        expect(main_agent.kind("app")).to eq("claude")
      end

      it "recognizes the configured program in the workspace's own pane and drops the resuming part" do
        config_with(["claude-dev --dangerously-skip-permissions --continue || claude-dev --dangerously-skip-permissions"])

        expect(main_agent.spawn_command("app", "claude")).to eq("claude-dev --dangerously-skip-permissions")
      end

      it "asks the project config for the workspace's template command" do
        config_with(["codex"])
        allow(project_config).to receive(:agent_pane_command).with("claude", "app").and_return("claude-dev --x")

        expect(main_agent.spawn_command("app", "claude")).to eq("claude-dev --x")
      end

      it "falls back to the configured command when every command resumes" do
        config_with(["claude-dev --continue"])
        allow(project_config).to receive(:agent_pane_command).and_return(nil)

        expect(main_agent.spawn_command("app", "claude")).to eq("claude-dev")
        expect(main_agent.spawn_command("app", "codex")).to eq("codex")
      end
    end
  end

  context "with no agent command set and a real ProjectConfig" do
    let(:agent_commands) do
      ps = instance_double(Workspace::ProjectSettings, load_global: {}, load: {})
      Workspace::AgentCommands.new(config_resolver: Workspace::ConfigResolver.new(project_settings: ps))
    end
    subject(:main_agent) { described_class.new(project_config: project_config, agent_commands: agent_commands) }
    let(:project_config) do
      config = double("config", worktree_template_path: File.join(Dir.tmpdir, "no-such-template.yml"))
      Workspace::ProjectConfig.new(config: config, git: nil, output: StringIO.new, agent_commands: agent_commands)
    end

    it "spawns the pane's fresh part with its flags when the program is plain claude" do
      config_with(["claude --flag --continue || claude --flag"])

      expect(main_agent.spawn_command("app", "claude")).to eq("claude --flag")
    end

    it "returns a codex pane's fresh part unchanged" do
      config_with(["FOO=1 codex --yolo"])

      expect(main_agent.spawn_command("app", "codex")).to eq("FOO=1 codex --yolo")
    end
  end

  describe "#spawn_command without AgentCommands" do
    let(:project_config) { instance_double(Workspace::ProjectConfig) }
    subject(:main_agent) { described_class.new(project_config: project_config, agent_commands: nil) }

    it "falls back to the provider's executable and ignores a claude-dev pane" do
      path = File.join(Dir.tmpdir, "main-agent-nil-#{Process.pid}.yml")
      File.write(path, YAML.dump({"windows" => [{"w" => {"panes" => ["claude-dev --continue"]}}]}))
      allow(project_config).to receive(:config_path_for).with("app").and_return(path)
      allow(project_config).to receive(:agent_pane_command).and_return(nil)

      expect(main_agent.spawn_command("app", "claude")).to eq("claude")
    ensure
      File.delete(path) if path && File.exist?(path)
    end
  end
end
