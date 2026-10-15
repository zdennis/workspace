require "spec_helper"
require "tmpdir"
require "stringio"

# A worktree file that can't be parsed now matters for the keys a worktree may override: the readers that fail on a
# bad config file raise, the ones that warn use the default for the whole section, and `config show` says unreadable.
RSpec.describe "a worktree config file that can't be parsed" do
  let(:dir) { Dir.mktmpdir("ws-broken-worktree") }
  let(:settings) { Workspace::ProjectSettings.new(config: Struct.new(:workspace_config_dir).new(dir)) }
  let(:resolver) { Workspace::ConfigResolver.new(project_settings: settings) }
  let(:error_output) { StringIO.new }

  before do
    settings.save("app", {"dev" => {"ready_timeout" => "90s"}, "alerts" => {"idle_after" => "20m"}, "commands" => {"test" => "bin/test"}, "notes" => {"instructions" => false}})
    File.write(settings.project_config_path("app.worktree-x"), "dev: [\n")
  end

  after { FileUtils.rm_rf(dir) }

  it "stops the readers that fail on a bad config file (DevConfig, CommandsConfig, NotesConfig)" do
    expect { Workspace::DevConfig.new(config_resolver: resolver).for_project("app.worktree-x") }.to raise_error(Workspace::ConfigParseError)
    expect { Workspace::CommandsConfig.new(config_resolver: resolver).for_project("app.worktree-x") }.to raise_error(Workspace::ConfigParseError)
    expect { Workspace::NotesConfig.new(config_resolver: resolver).instructions?("app.worktree-x") }.to raise_error(Workspace::ConfigParseError)
  end

  it "makes the readers that warn (AlertConfig, HandoffConfig, AgentdConfig, PlanConfig) warn and use the defaults" do
    alerts = Workspace::AlertConfig.new(config_resolver: resolver, error_output: error_output).for_workspace("app.worktree-x")
    expect(alerts[:idle_after]).to eq(600)
    expect(Workspace::HandoffConfig.new(config_resolver: resolver, error_output: error_output).auto?("app.worktree-x")).to be(false)
    expect(Workspace::AgentdConfig.new(config_resolver: resolver, error_output: error_output).poll_interval_for("app.worktree-x")).to eq(10)
    expect(Workspace::PlanConfig.new(config_resolver: resolver, error_output: error_output).stall_seconds_for("app.worktree-x")).to eq(300)
    expect(error_output.string).to include("Cannot parse").and include("worktree-x.yml")
  end

  it "leaves the parent project's own reads alone" do
    expect(Workspace::DevConfig.new(config_resolver: resolver).for_project("app")).to include(ready_timeout: 90)
  end

  it "shows a widened key as unreadable in the worktree, a project-only key as the project's value, and the project as it was" do
    report = Workspace::ConfigReport.new(project_settings: settings, project_config: instance_double(Workspace::ProjectConfig, available_projects: %w[app app.worktree-x], project_root_for: nil),
      notes_dir: Workspace::NotesDir.new(git: Workspace::Git.new, home: "/home/me"))
    rows = report.show("app.worktree-x")["keys"].to_h { |row| [row["key"], row] }

    expect(rows["dev.ready_timeout"]).to include("source" => "unreadable", "effective" => nil)
    expect(rows["alerts.idle_after"]).to include("source" => "unreadable", "effective" => nil)
    expect(rows["dev.stop_timeout"]).to include("source" => "default", "effective" => 20)
    expect(report.show("app")["keys"].find { |row| row["key"] == "dev.ready_timeout" }).to include("source" => "project", "effective" => 90)
  end
end
