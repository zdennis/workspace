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

  {"main" => "show_main.json", "main.worktree-a" => "show_worktree.json"}.each do |workspace, file|
    it "keeps the document for #{workspace} as in #{file}" do
      actual = JSON.pretty_generate(report.show(workspace)).gsub(config_dir, "<CONFIG>") + "\n"
      path = File.join(fixtures, file)
      File.write(path, actual) if ENV["UPDATE_GOLDEN"]
      expect(actual).to eq(File.read(path))
    end
  end
end
