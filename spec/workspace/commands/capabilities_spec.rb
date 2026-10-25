require "spec_helper"
require "stringio"
require "tmpdir"
require "fileutils"

RSpec.describe Workspace::Commands::Capabilities do
  let(:output) { StringIO.new }
  let(:config) { instance_double(Workspace::Config, event_log_file: "/home/z/.workspace-events.jsonl", hook_events_dir: "/home/z/.local/state/workspace/.events", run_dir: "/home/z/.local/workspace/run", library_dir: "/home/z/.config/workspace/library") }
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
      expect(features).to include("prune_safe" => 2)
      expect(features).to include("envelope" => 1, "error_codes" => 1, "no_input" => 1, "name_scope" => 1, "action_json" => 1, "sessions" => 2)
      expect(features).to include("snapshot" => 6, "agent_send" => 1, "focus_pane" => 1, "focus_cycle" => 1, "actions_manifest" => 0)
      expect(features).to include("config_json" => 2, "config_scopes" => 2, "tmux_show" => 1, "state_done" => 1, "tasks" => 1, "event_emitters" => 2, "daemon_control" => 4, "ui_open" => 3, "pane_bindings" => 3, "library" => 5, "spine_init" => 2, "library_play" => 3, "library_recipes" => 1, "library_copy" => 4, "library_installed" => 1, "instructions" => 1, "start_packs" => 2, "handoff_auto" => 2, "handoff_codex" => 1, "handoff_wait" => 1, "inbox" => 4, "ask_withdraw" => 1, "ask_deliver" => 1, "review" => 1, "review_patch" => 1, "add_json" => 1, "start_agent" => 1, "start_plan" => 1, "plan_progress" => 1, "spine_events" => 2, "agent_status" => 1, "agent_queue" => 1, "agent_send_interrupt" => 1, "agent_hooks" => 1, "codex_waiting" => 1, "projects_multi" => 1, "json_envelope" => 1, "remove" => 1, "promote" => 1, "bookkeeping_excluded" => 1)
    end

    it "reports the exit codes the CLI uses" do
      command.call(json: true)

      expect(document["exit_codes"]).to eq("ok" => 0, "failed" => 1, "not_submitted" => 2, "partial" => 3, "lock_cleared" => 4, "timeout" => 75)
    end

    it "reports the event log, run and library directories from config" do
      command.call(json: true)

      expect(document["paths"]).to eq("event_log" => "/home/z/.workspace-events.jsonl", "hook_events" => "/home/z/.local/state/workspace/.events", "run_dir" => "/home/z/.local/workspace/run", "library" => "/home/z/.config/workspace/library")
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

    it "reports the workflow feature" do
      command.call(json: true)

      expect(document["features"]).to include("workflow" => 2)
    end

    it "reports the restore feature" do
      command.call(json: true)

      expect(document["features"]).to include("restore" => 1)
    end

    it "reports lock JSON at the revision that can carry a workflow run as a holder" do
      command.call(json: true)

      expect(document["features"]).to include("locks_json" => 2)
    end

    it "reports window_state once the lists carry window_alive" do
      command.call(json: true)

      expect(document["features"]).to include("window_state" => 1)
    end

    it "reports window_position once launch restores a saved window position" do
      command.call(json: true)

      expect(document["features"]).to include("window_position" => 1)
    end

    it "reports notes once notes dir exists" do
      command.call(json: true)

      expect(document["features"]).to include("notes" => 2)
    end

    it "reports agent_spawn once launch and run name the pane they used" do
      command.call(json: true)

      expect(document["features"]).to include("agent_spawn" => 1)
    end

    it "reports ahead_of_base once the snapshot counts commits ahead of the base branch" do
      command.call(json: true)

      expect(document["features"]).to include("ahead_of_base" => 1, "spawn_cleanup" => 2)
    end

    it "reports agent_commands once the agent's command can be configured" do
      command.call(json: true)

      expect(document["features"]).to include("agent_commands" => 1)
    end

    it "reports agent_executables once the agent programs on PATH can be listed" do
      command.call(json: true)

      expect(document["features"]).to include("agent_executables" => 1)
    end

    it "reports cleanup_dry_run once cleanup can report without acting" do
      command.call(json: true)

      expect(document["features"]).to include("cleanup_dry_run" => 1)
    end

    it "reports dev_queue 2 once dev status carries queue positions, agent state and events" do
      command.call(json: true)

      expect(document["features"]).to include("dev_queue" => 2)
    end

    it "reports dev_down_holder 1 once dev down refuses another workspace's holder with dev_held_by" do
      command.call(json: true)

      expect(document["features"]).to include("dev_down_holder" => 1)
    end

    it "reports plan 5 once plan start can ask for a draft" do
      command.call(json: true)

      expect(document["features"]).to include("plan" => 5)
    end

    it "reports ticket 2 once ticket list and start --slug exist" do
      command.call(json: true)

      expect(document["features"]).to include("ticket" => 2)
    end

    it "reports goal 2 once goal show and goal list exist" do
      command.call(json: true)

      expect(document["features"]).to include("goal" => 2)
    end

    it "reports spine 3 once spine show has roll-ups, --stage, --body and the check counts" do
      command.call(json: true)

      expect(document["features"]).to include("spine" => 3)
    end

    it "reports spine_eval 3 once spine show --evaluate judges the check and infers stages without a spine/" do
      command.call(json: true)

      expect(document["features"]).to include("spine_eval" => 3)
    end

    it "reports spine_set 3 once spine set keeps the check in step with the status" do
      command.call(json: true)

      expect(document["features"]).to include("spine_set" => 3)
    end

    it "reports spine_start 2 once spine start writes, delivers, binds and reopens a failed check" do
      command.call(json: true)

      expect(document["features"]).to include("spine_start" => 2)
    end

    it "reports spine_fanout 1 once spine start --fan-out starts the sub-stages of a stage" do
      command.call(json: true)

      expect(document["features"]).to include("spine_fanout" => 1)
    end

    it "reports spine_verify 1 and spine_set 3 once spine verify records a check" do
      command.call(json: true)
      expect(document["features"]).to include("spine_verify" => 1, "spine_set" => 3)
    end

    it "reports spine_check 1 once spine check ticks Done when items" do
      command.call(json: true)

      expect(document["features"]).to include("spine_check" => 1)
    end

    it "reports spine_goal 1 once spine goal set writes goal.md" do
      command.call(json: true)

      expect(document["features"]).to include("spine_goal" => 1)
    end

    it "reports spine_pack 4 once the spine pack teaches reporting done and the handoff stop" do
      command.call(json: true)

      expect(document["features"]).to include("spine_pack" => 4)
    end

    it "reports spine_report 1 once the daemon records owner_finished" do
      command.call(json: true)

      expect(document["features"]).to include("spine_report" => 1)
    end

    it "reports lifecycle_current 1 once stop, kill, finish, remove, restore and dir default to the current workspace" do
      command.call(json: true)

      expect(document["features"]).to include("lifecycle_current" => 1)
    end

    it "reports launch_prompt_status 1 once the closing line tells a lost prompt" do
      command.call(json: true)

      expect(document["features"]).to include("launch_prompt_status" => 1)
    end

    it "reports split_cwd 1 once splits start in the workspace folder" do
      command.call(json: true)

      expect(document["features"]).to include("split_cwd" => 1)
    end

    it "reports pr_create 1 once pr create exists" do
      command.call(json: true)

      expect(document["features"]).to include("pr_create" => 2)
    end

    it "reports rebase 2 once rebase and push exist" do
      command.call(json: true)

      expect(document["features"]).to include("rebase" => 3)
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
      expect(output.string).to match(/^  snapshot +6$/)
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
