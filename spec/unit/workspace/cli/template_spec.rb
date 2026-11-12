require "spec_helper"
require "stringio"
require "json"

RSpec.describe Workspace::CLI::Template do
  let(:out) { StringIO.new }
  let(:err) { StringIO.new }
  let(:detector) { RecordingProjectDetector.new("/src/app" => "app") }
  let(:template_command) { instance_double(Workspace::Commands::Template, list: nil, show: nil, path: nil, variables: nil, render: true, validate: true, diff: nil, status: nil, apply: {results: [], exit_code: 0}, new: {}, edit: {"outcome" => "edited"}, use: {}) }

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

  it "validates the named set or file for the detected workspace, and exits 1 when a file has an error" do
    run("validate", "team", "--kind", "worktree", "--json")
    run("validate", "--file", "./w.yml")

    expect(template_command).to have_received(:validate).with(set: "team", file: nil, kind: "worktree", workspace: "app", json: true)
    expect(template_command).to have_received(:validate).with(set: nil, file: "./w.yml", kind: nil, workspace: "app", json: false)
    allow(template_command).to receive(:validate).and_return(false)
    expect { run("validate") }.to raise_error(FakeSystemExit) { |e| expect(e.status).to eq(1) }
  end

  it "diffs the named set against --against, with no exit status of its own" do
    run("diff", "team", "--against", "old", "--kind", "project", "--json")

    expect(template_command).to have_received(:diff).with(set: "team", against: "old", kind: "project", workspace: "app", json: true)
  end

  it "refuses --against outside diff and --file on diff" do
    expect { run("validate", "--against", "x") }.to raise_error(Workspace::UsageError, /--against does not apply to 'template validate'/)
    expect { run("diff", "--file", "x") }.to raise_error(Workspace::UsageError, /--file does not apply to 'template diff'/)
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
  describe "status" do
    it "hands the names, the flags and the working directory to the command, not the detected workspace" do
      run("status", "app", "api", "--json")
      run("status", "--all")
      run("status", "--project")
      run("status", "--project", "api")
      run("status")

      expect(template_command).to have_received(:status).with(names: %w[app api], all: false, project: nil, cwd: "/src/app", json: true)
      expect(template_command).to have_received(:status).with(names: [], all: true, project: nil, cwd: "/src/app", json: false)
      expect(template_command).to have_received(:status).with(names: [], all: false, project: true, cwd: "/src/app", json: false)
      expect(template_command).to have_received(:status).with(names: [], all: false, project: "api", cwd: "/src/app", json: false)
      expect(template_command).to have_received(:status).with(names: [], all: false, project: nil, cwd: "/src/app", json: false).once
    end

    it "refuses a flag it has no use for" do
      expect { run("status", "--name", "app") }.to raise_error(Workspace::UsageError, /--name does not apply to 'template status'/)
      expect { run("list", "--all") }.to raise_error(Workspace::UsageError, /--all does not apply to 'template list'/)
    end

    it "still takes no names for list" do
      expect { run("list", "app") }.to raise_error(Workspace::UsageError, /Unexpected argument: app/)
    end
  end

  describe "apply" do
    it "hands the names and every flag to the command" do
      run("apply", "app", "api", "--dry-run", "--diff", "--force", "--rollback-all-on-error")
      run("apply", "--all")

      expect(template_command).to have_received(:apply).with(names: %w[app api], all: false, project: nil, cwd: "/src/app",
        dry_run: true, diff: true, force: true, rollback: true, json: false)
      expect(template_command).to have_received(:apply).with(names: [], all: true, project: nil, cwd: "/src/app",
        dry_run: false, diff: false, force: false, rollback: false, json: false)
    end

    it "prints the command's outcome as an action document under --json, exiting through its status" do
      allow(template_command).to receive(:apply).and_return(results: [{"workspace" => "app", "outcome" => "failed"}, {"workspace" => "api", "outcome" => "applied"}],
        status: "partial", exit_code: 3, warnings: [], extra: {"backup" => "id-1", "rolled_back" => false})

      expect { run("apply", "--all", "--json") }.to raise_error(FakeSystemExit) { |e| expect(e.status).to eq(3) }
      expect(JSON.parse(out.string)).to include("action" => "template apply", "status" => "partial", "backup" => "id-1", "rolled_back" => false)
    end

    it "exits with the command's code in text mode" do
      allow(template_command).to receive(:apply).and_return(results: [], status: "failed", exit_code: 1)

      expect { run("apply", "app") }.to raise_error(FakeSystemExit) { |e| expect(e.status).to eq(1) }
    end

    it "refuses the flags only apply takes on other verbs, and apply's unused ones" do
      expect { run("status", "--force") }.to raise_error(Workspace::UsageError, /--force does not apply to 'template status'/)
      expect { run("apply", "--name", "app") }.to raise_error(Workspace::UsageError, /--name does not apply to 'template apply'/)
    end
  end

  describe "new, edit and use" do
    it "makes a copy for the detected workspace, from --from, in --scope" do
      run("new", "team", "--from", "base", "--scope", "project")

      expect(template_command).to have_received(:new).with(name: "team", from: "base", scope: "project", workspace: "app", cwd: "/src/app")
    end

    it "selects a set for a kind and scope" do
      run("use", "team", "--kind", "worktree", "--scope", "global")

      expect(template_command).to have_received(:use).with(name: "team", scope: "global", kind: "worktree", workspace: "app", cwd: "/src/app")
    end

    it "needs a NAME for new and use, and refuses a second one" do
      expect { run("new") }.to raise_error(Workspace::UsageError, /'template new' needs a tmuxinator template NAME/)
      expect { run("use") }.to raise_error(Workspace::UsageError, /'template use' needs/)
      expect { run("use", "a", "b") }.to raise_error(Workspace::UsageError, /Unexpected argument: b/)
    end

    it "refuses the flags the verb does not take" do
      expect { run("new", "team", "--kind", "project") }.to raise_error(Workspace::UsageError, /--kind does not apply to 'template new'/)
      expect { run("edit", "team", "--scope", "global") }.to raise_error(Workspace::UsageError, /--scope does not apply to 'template edit'/)
      expect { run("use", "team", "--from", "x") }.to raise_error(Workspace::UsageError, /--from does not apply to 'template use'/)
    end

    it "prints the action document under --json" do
      allow(template_command).to receive(:use).and_return({"workspace" => nil, "outcome" => "selected", "template" => "team"})

      run("use", "team", "--json")

      doc = JSON.parse(out.string)
      expect(doc).to include("ok" => true, "action" => "template use", "status" => "ok")
      expect(doc["results"]).to eq([{"workspace" => nil, "outcome" => "selected", "template" => "team"}])
    end

    it "gives edit an opener unless --json, and exits 1 when a file has an error" do
      allow(template_command).to receive(:edit).and_return({"outcome" => "failed"})

      expect { run("edit", "team") }.to raise_error(FakeSystemExit) { |e| expect(e.status).to eq(1) }
      expect(template_command).to have_received(:edit).with(set: "team", kind: nil, workspace: "app", opener: an_instance_of(Proc))

      allow(template_command).to receive(:edit).and_return({"outcome" => "edited"})
      run("edit", "--kind", "project", "--json")
      expect(template_command).to have_received(:edit).with(set: nil, kind: "project", workspace: "app", opener: nil)
    end
  end
end
