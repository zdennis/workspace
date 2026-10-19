require "spec_helper"
require "json"

# Pins `config show --json` so a change to how config is layered can't alter
# what the report says unnoticed. Regenerate the files with UPDATE_GOLDEN=1.
RSpec.describe Workspace::ConfigReport, "golden documents" do
  fixtures = File.expand_path("../fixtures/config_layering", __dir__)
  config_dir = File.join(fixtures, "config")

  let(:config) { instance_double(Workspace::Config, workspace_config_dir: config_dir) }
  let(:settings) { Workspace::ProjectSettings.new(config: config) }
  let(:roots) { {"main" => "/src/main", "main.worktree-a" => "/src/main/.worktrees/a"} }
  let(:project_config) { instance_double(Workspace::ProjectConfig, available_projects: roots.keys) }
  let(:git) { Workspace::Git.new }
  let(:notes_dir) { Workspace::NotesDir.new(git: git, home: "/home/me") }
  subject(:report) { described_class.new(project_settings: settings, project_config: project_config, notes_dir: notes_dir) }

  before do
    allow(project_config).to receive(:project_root_for) { |name| roots[name] }
    allow(git).to receive(:worktree_branch) { |path| "feature/#{File.basename(path)}" }
  end

  {"main" => "show_main.json", "main.worktree-a" => "show_worktree.json", "main.worktree-b" => "show_worktree_broken.json"}.each do |workspace, file|
    it "keeps the document for #{workspace} as in #{file}" do
      actual = JSON.pretty_generate(report.show(workspace)).gsub(config_dir, "<CONFIG>") + "\n"
      path = File.join(fixtures, file)
      File.write(path, actual) if ENV["UPDATE_GOLDEN"]
      expect(actual).to eq(File.read(path))
    end
  end

  # The golden documents from before the table was widened (show_*_v1.json). A key's `effective` and `source` may differ
  # only where a value sits in a layer the widening newly allows; every other key must read exactly as it did.
  describe "against the documents from before the layer table was widened" do
    # Keys whose value sits in a layer the widening newly allows: the old golden read them as default.
    newly_allowed = {
      "main" => %w[handoff.auto],
      "main.worktree-a" => %w[handoff.auto alerts.idle_after]
    }

    # Keys the widening made settable per layer, so their `target_layer` and `affects` changed in a worktree: they now
    # write to the worktree's own file and reach only that worktree. Any other key must keep v1's values.
    widened = %w[dev.up dev.ready dev.startup_timeout dev.ready_timeout dev.release_on_session_end dev.instructions
      alerts.notify alerts.idle_after agentd.poll_interval handoff.threshold handoff.check_prompt handoff.resume_prompt
      handoff.auto commands.test commands.lint notes.instructions plan.stall_seconds]
    # Keys whose `problems` changed: a value in a newly allowed layer is no longer `not_read`.
    problems_changed = {"main" => %w[handoff.auto], "main.worktree-a" => %w[handoff.auto alerts.idle_after]}

    {"main" => ["show_main_v1.json", "show_main.json"], "main.worktree-a" => ["show_worktree_v1.json", "show_worktree.json"]}.each do |workspace, (old_file, new_file)|
      it "changes #{workspace} only by the added fields and the values in newly allowed layers" do
        old = JSON.parse(File.read(File.join(fixtures, old_file)))
        now = JSON.parse(File.read(File.join(fixtures, new_file)))
        added = %w[overridable_in layers doc choices min max unit]
        # Keys declared since v1 have no old document to compare with.
        since_v1 = %w[launch.restore_window_position events.rotate_size spine.template spine.auto codex.hooks.install]
        now = now.merge("keys" => now["keys"].reject { |k| since_v1.include?(k["key"]) })

        expect(now.except("keys", "unknown_keys")).to eq(old.except("keys", "unknown_keys"))
        expect(now["keys"].map { |k| k["key"] }).to eq(old["keys"].map { |k| k["key"] })
        old["keys"].zip(now["keys"]).each do |was, is|
          key = was["key"]
          unless newly_allowed.fetch(workspace, []).include?(key)
            expect(is.slice("value", "effective", "source", "source_file", "line", "column", "masked", "default", "scope", "type"))
              .to eq(was.slice("value", "effective", "source", "source_file", "line", "column", "masked", "default", "scope", "type")), "#{workspace} #{key}"
          end
          expect(is.keys - added).to eq(was.keys), "#{workspace} #{key}"
          if workspace == "main.worktree-a" && widened.include?(key)
            expect(is.slice("target_layer", "affects")).to eq({"target_layer" => "worktree", "affects" => ["main.worktree-a"]}), "#{workspace} #{key}"
          else
            expect(is.slice("target_layer", "affects")).to eq(was.slice("target_layer", "affects")), "#{workspace} #{key}"
          end
          next if problems_changed.fetch(workspace, []).include?(key)
          expect(is["problems"]).to eq(was["problems"]), "#{workspace} #{key}"
        end

        expect(now["keys"].select { |k| newly_allowed.fetch(workspace, []).include?(k["key"]) }.map { |k| [k["key"], k["source"]] })
          .to all(satisfy { |_key, source| %w[global worktree].include?(source) })
      end
    end
  end
end
