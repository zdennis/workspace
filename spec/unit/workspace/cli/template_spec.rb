require "spec_helper"
require "stringio"

RSpec.describe Workspace::CLI::Template do
  let(:out) { StringIO.new }
  let(:err) { StringIO.new }
  let(:detector) { RecordingProjectDetector.new("/src/app" => "app") }
  let(:template_command) { instance_double(Workspace::Commands::Template, list: nil, show: nil, path: nil, variables: nil, render: true) }

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
    expect { run("bogus") }.to raise_error(Workspace::UsageError, /Unknown tmuxinator template subcommand: bogus/)
  end

  it "hands variables its kind, and the workspace only when --name names one" do
    run("variables", "--kind", "worktree", "--json")
    run("variables", "--name", "api")

    expect(template_command).to have_received(:variables).with(kind: "worktree", workspace: nil, json: true)
    expect(template_command).to have_received(:variables).with(kind: nil, workspace: "api", json: false)
  end

  it "renders for the detected workspace, with the set and the workspace that picks it" do
    run("render", "team", "--kind", "project", "--diff", "--json")

    expect(template_command).to have_received(:render).with(set: "team", file: nil, kind: "project", workspace: "app", context: "app",
      sample: false, diff: true, json: true)
  end

  it "renders a sample with no workspace but the one that chooses the set, and a file as given" do
    run("render", "--sample", "--file", "./w.yml", "--kind", "worktree")

    expect(template_command).to have_received(:render).with(set: nil, file: "./w.yml", kind: "worktree", workspace: nil, context: "app",
      sample: true, diff: false, json: false)
  end

  it "exits 1 when render says the file had an error" do
    allow(template_command).to receive(:render).and_return(false)

    expect { run("render", "--sample") }.to raise_error(FakeSystemExit) { |e| expect(e.status).to eq(1) }
  end

  it "refuses render flags on the other verbs, and a stray argument to variables" do
    expect { run("show", "--sample") }.to raise_error(Workspace::UsageError, /--sample does not apply to 'template show'/)
    expect { run("variables", "--file", "x") }.to raise_error(Workspace::UsageError, /--file does not apply/)
    expect { run("variables", "team") }.to raise_error(Workspace::UsageError, /Unexpected argument: team/)
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
