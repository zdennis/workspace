require "spec_helper"
require "stringio"

RSpec.describe Workspace::CLI::Template do
  let(:out) { StringIO.new }
  let(:err) { StringIO.new }
  let(:detector) { RecordingProjectDetector.new("/src/app" => "app") }
  let(:template_command) { instance_double(Workspace::Commands::Template, list: nil, show: nil, path: nil) }

  def family(command = template_command)
    names = Workspace::CLI::Names.new(project_config: CLITestHelpers::FakeProjectConfig.new, project_detector: detector,
      lineage: CLITestHelpers::FakeLineage.new, working_dir: "/src/app")
    described_class.new(template_command: command, common: Workspace::CLI::Common.new, names: names, working_dir: "/src/app")
  end

  def invocation(help_asked: false)
    Workspace::CLI::Invocation.new(output: Workspace::OutputGate.new(out), error_output: err, exit_handler: FakeExitHandler, help_asked: help_asked, quiet: false, env: {})
  end

  def run(*args, command: template_command)
    family(command).call("template", args, invocation)
  end

  it "lists for the workspace of the working directory, with the scope and the directory" do
    run("list", "--scope", "global", "--json")

    expect(template_command).to have_received(:list).with(workspace: "app", scope: "global", cwd: "/src/app", json: true)
  end

  it "takes --name over the detected workspace" do
    run("show", "--name", "api.worktree-x")

    expect(template_command).to have_received(:show).with(set: nil, kind: nil, workspace: "api.worktree-x", json: false)
  end

  it "hands a named set and a kind to show and path, flags in any order" do
    run("show", "team", "--kind", "worktree", "--json")
    run("--kind", "project", "path", "team")

    expect(template_command).to have_received(:show).with(set: "team", kind: "worktree", workspace: "app", json: true)
    expect(template_command).to have_received(:path).with(set: "team", kind: "project", workspace: "app", json: false)
  end

  it "reads the global settings when no workspace is detected" do
    family_here = described_class.new(template_command: template_command, common: Workspace::CLI::Common.new,
      names: Workspace::CLI::Names.new(project_config: CLITestHelpers::FakeProjectConfig.new, project_detector: RecordingProjectDetector.new({}),
        lineage: CLITestHelpers::FakeLineage.new, working_dir: "/elsewhere"), working_dir: "/elsewhere")

    family_here.call("template", ["path"], invocation)

    expect(template_command).to have_received(:path).with(set: nil, kind: nil, workspace: nil, json: false)
  end

  it "shows the overview for a bare template, and refuses an unknown subcommand" do
    run
    expect(out.string).to include("Usage: workspace template list", "Subcommands:")
    expect { run("render") }.to raise_error(Workspace::UsageError, /Unknown tmuxinator template subcommand: render/)
  end

  it "refuses a flag the verb does not take" do
    expect { run("list", "--kind", "project") }.to raise_error(Workspace::UsageError, /--kind does not apply to 'template list'/)
    expect { run("show", "--scope", "global") }.to raise_error(Workspace::UsageError, /--scope does not apply to 'template show'/)
  end

  it "refuses a stray argument" do
    expect { run("list", "team") }.to raise_error(Workspace::UsageError, /Unexpected argument: team/)
    expect { run("show", "a", "b") }.to raise_error(Workspace::UsageError, /Unexpected argument: b/)
  end

  it "parses before it asks for a command, so a bad flag is a usage error even unwired" do
    expect { run("list", "--bogus", command: nil) }.to raise_error(OptionParser::InvalidOption)
    expect { run("list", command: nil) }.to raise_error(Workspace::Error, /template is not available/)
  end

  it "prints the verb's page for --help and the overview for a bare --help, calling nothing" do
    run("show", "--help")
    expect(out.string).to start_with("Usage: workspace template show")

    out.truncate(0)
    run("--help")
    expect(out.string).to include("Usage: workspace template list", "Subcommands:")
    expect(template_command).not_to have_received(:show)
  end
end
