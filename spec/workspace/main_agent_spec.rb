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
end
