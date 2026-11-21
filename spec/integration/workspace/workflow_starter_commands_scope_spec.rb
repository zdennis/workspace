require "spec_helper"
require "tmpdir"

# `commands.test` set at one worktree's workspace scope is what that workspace's run reads; a sibling
# worktree with no value is refused, and a value at project scope reaches every worktree.
RSpec.describe Workspace::WorkflowStarter do
  let(:dir) { Dir.mktmpdir("ws-starter-scope") }
  let(:settings) { Workspace::ProjectSettings.new(config: Struct.new(:workspace_config_dir).new(File.join(dir, "config"))) }
  let(:commands_config) { Workspace::CommandsConfig.new(config_resolver: Workspace::ConfigResolver.new(project_settings: settings)) }
  let(:store) { RecordingRunStore.new }
  let(:lineages) do
    {"x" => Workspace::WorkspaceLineage::Lineage.new(name: "app", worktree: "app.worktree-x", git_common_dir: File.join(dir, ".git")),
     "y" => Workspace::WorkspaceLineage::Lineage.new(name: "app", worktree: "app.worktree-y", git_common_dir: File.join(dir, ".git"))}
  end
  let(:lineage) { instance_double(Workspace::WorkspaceLineage) }
  let(:starter) do
    described_class.new(change: RecordingRunChange.new(store.runs), store: store, prompt: RecordingWorkflowPrompt.new(text: "t", packs: []),
      dispatch: RecordingDispatch.new, lineage: lineage, commands_config: commands_config,
      guard: instance_double(Workspace::WorkflowGuard, head: "abc", check: nil),
      gate_note: instance_double(Workspace::WorkflowGateNote, notes_dir_of: File.join(dir, "notes")), workspace_known: ->(name) { name == "app" })
  end
  let(:definition) { Workspace::WorkflowDefinition.parse("steps:\n  build:\n    prompt: Build.\n    status: {command: test}\n", id: "flow", source: "global", path: "/defs/flow.yml") }

  after { FileUtils.rm_rf(dir) }

  def preflight(key)
    allow(lineage).to receive(:resolve).and_return(lineages.fetch(key))
    starter.preflight(definition: definition, workspace: "app.worktree-#{key}", worktree: dir, inputs: {})
  end

  it "passes for the worktree that has the command at its own scope and refuses a sibling with none, offering project scope" do
    settings.save("app.worktree-x", {"commands" => {"test" => "bin/wt-test"}})

    expect(preflight("x")).to include("workspace" => "app.worktree-x", "project" => "app")
    expect { preflight("y") }.to raise_error(Workspace::Error, /app\.worktree-y has none.*--name app\.worktree-y.*once for the whole project.*--name app$/m) { |error|
      expect(error.code).to eq("workflow_command_unset")
    }
  end

  it "lets a command at project scope reach a worktree with none of its own" do
    settings.save("app", {"commands" => {"test" => "bin/test"}})

    expect(preflight("y")).to include("workspace" => "app.worktree-y")
  end
end
