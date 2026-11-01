require "spec_helper"
require "tmpdir"

RSpec.describe Workspace::WorkflowRouter do
  let(:rows) do
    [
      {"id" => "rpiv", "use_when" => "Build a feature.", "applies_to" => [], "problems" => []},
      {"id" => "pr-feedback", "use_when" => "A pull request has review feedback.", "applies_to" => ["github_pr", "branch"], "problems" => []},
      {"id" => "broken", "use_when" => nil, "applies_to" => [], "problems" => ["can't be read (Errno::EACCES)"]}
    ]
  end
  let(:catalog) { instance_double(Workspace::WorkflowCatalog, list: rows) }
  let(:dir) { Dir.mktmpdir }
  let(:settings) { Workspace::ProjectSettings.new(config: instance_double(Workspace::Config, workspace_config_dir: dir)) }
  let(:resolver) { Workspace::ConfigResolver.new(project_settings: settings) }
  subject(:router) { described_class.new(catalog: catalog, workflow_defaults: Workspace::WorkflowDefaults.new(config_resolver: resolver)) }

  after { FileUtils.rm_rf(dir) }

  def write(name, text)
    path = (name == :global) ? settings.global_config_path : settings.project_config_path(name)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, text)
  end

  it "uses the project's default over the global one, and reports the layer" do
    write(:global, "workflows:\n  by_ref:\n    jira: pr-feedback\n")
    write("app", "workflows:\n  by_ref:\n    jira: rpiv\n")

    expect(router.route(kind: "jira", workspace: "app")).to eq("workflow" => "rpiv", "kind" => "jira", "source" => "default", "scope" => "project", "key" => "workflows.by_ref.jira", "definition_source" => nil)
  end

  it "falls back to the global default and says so" do
    write(:global, "workflows:\n  by_ref:\n    jira: rpiv\n")

    expect(router.route(kind: "jira", workspace: "app")).to include("workflow" => "rpiv", "source" => "default", "scope" => "global")
  end

  it "reads the global value when the project file does not parse, as a start with no id does" do
    write(:global, "workflows:\n  by_ref:\n    jira: rpiv\n")
    write("app", "workflow: [unclosed\n")

    expect(router.route(kind: "jira", workspace: "app")).to include("workflow" => "rpiv", "scope" => "global")
  end

  it "takes workflows.default when no by_ref key answers, by_ref winning over it" do
    write(:global, "workflows:\n  default: rpiv\n")
    expect(router.route(kind: "jira", workspace: "app")).to include("workflow" => "rpiv", "key" => "workflows.default", "scope" => "global", "source" => "default")

    write("app", "workflows:\n  default: pr-feedback\n")
    write(:global, "workflows:\n  by_ref:\n    branch: rpiv\n")
    expect(router.route(kind: "branch", workspace: "app")).to include("workflow" => "rpiv", "key" => "workflows.by_ref.branch")
  end

  it "gives a start with no id the same fits, every workflow fitting a prompt" do
    expect(router.unrouted("jira")).to include("reason" => "broken_definition", "key" => "workflows.by_ref.jira", "broken" => ["broken"])
    expect(router.unrouted("jira")["candidates"].map { |c| c["id"] }).to eq(%w[rpiv])
    expect(router.unrouted("prompt")["candidates"].map { |c| c["id"] }).to eq(%w[rpiv pr-feedback])
  end

  it "lists the definitions of the project a worktree workspace belongs to, and reports where the chosen one was found" do
    rows.replace([rows[0].merge("source" => "project")])

    expect(router.route(kind: "github_pr", workspace: "app.worktree-fix")).to include("workflow" => "rpiv", "definition_source" => "project")
    expect(catalog).to have_received(:list).with(project: "app")
  end

  context "without a default" do
    it "uses the one workflow that fits, with no scope" do
      rows.replace([rows[0]])

      expect(router.route(kind: "github_pr", workspace: "app")).to include("workflow" => "rpiv", "source" => "only_fit", "scope" => nil)
    end

    it "refuses several fits, listing each with its use_when" do
      rows.pop

      expect { router.route(kind: "github_pr", workspace: "app") }.to raise_error(Workspace::Error) { |e|
        expect(e.code).to eq("no_default_workflow")
        expect(e.message).to include("Several workflows fit github_pr. Pick one:", "pr-feedback   A pull request has review feedback.")
        expect(e.details).to include("reason" => "several", "broken" => [], "key" => "workflows.by_ref.github_pr")
        expect(e.details["candidates"].map { |c| c["id"] }).to eq(%w[rpiv pr-feedback])
      }
    end

    it "does not take the only fit while a definition is broken" do
      rows.delete_at(1)

      expect { router.route(kind: "jira", workspace: "app") }.to raise_error(Workspace::Error) { |e|
        expect(e.code).to eq("no_default_workflow")
        expect(e.details).to include("reason" => "broken_definition", "broken" => ["broken"])
        expect(e.details["candidates"].map { |c| c["id"] }).to eq(["rpiv"])
        expect(e.message).to include("One readable workflow fits jira:", "Could not be read, so may fit: broken")
      }
    end

    it "names the broken ones when nothing readable fits" do
      rows.replace([rows[1], rows[2]])

      expect { router.route(kind: "jira", workspace: "app") }.to raise_error(Workspace::Error) { |e|
        expect(e.message).to include("No readable workflow fits jira.", "broken")
        expect(e.details["candidates"]).to eq([])
      }
    end

    it "says none fit when nothing is broken" do
      rows.replace([rows[1]])

      expect { router.route(kind: "jira", workspace: "app") }.to raise_error(Workspace::Error) { |e|
        expect(e.message).to start_with("No readable workflow fits jira.")
        expect(e.details).to include("reason" => "none_fit", "broken" => [])
      }
    end

    it "escapes control characters in a use_when and a broken id" do
      rows[0]["use_when"] = "Build \e[31mred"
      rows[2]["id"] = "bad\e[0m"

      expect { router.route(kind: "github_pr", workspace: "app") }.to raise_error(Workspace::Error) { |e| expect(e.message).not_to include("\e") }
    end

    it "names the project in the command it prints, so the command works from any checkout" do
      expect { router.route(kind: "jira", workspace: "app", registered: false) }.to raise_error(Workspace::Error) { |e|
        expect(e.message).to include("`workspace config set workflows.by_ref.jira ID`")
      }
      expect { router.route(kind: "jira", workspace: "app") }.to raise_error(Workspace::Error) { |e|
        expect(e.message).to include("`workspace config set workflows.by_ref.jira ID --scope project --name app`")
      }
    end
  end

  it "routes a valid default past a broken unrelated file" do
    write("app", "workflows:\n  by_ref:\n    jira: rpiv\n")

    expect(router.route(kind: "jira", workspace: "app")).to include("workflow" => "rpiv")
  end

  it "refuses a default that names a broken definition, even with force" do
    write("app", "workflows:\n  by_ref:\n    jira: broken\n")

    expect { router.route(kind: "jira", workspace: "app", force: true) }.to raise_error(Workspace::Error) { |e|
      expect(e.code).to eq("invalid_workflow_default")
      expect(e.details).to include("reason" => "unknown_workflow", "workflow" => "broken", "key" => "workflows.by_ref.jira")
    }
  end

  it "refuses a stored value that is not an id" do
    write("app", "workflows:\n  by_ref:\n    jira: \"Not An Id\"\n")

    expect { router.route(kind: "jira", workspace: "app") }.to raise_error(Workspace::Error) { |e| expect(e.details["reason"]).to eq("invalid_value") }
  end

  it "refuses a default whose applies_to leaves out the kind, unless forced" do
    write("app", "workflows:\n  by_ref:\n    jira: pr-feedback\n")

    expect { router.route(kind: "jira", workspace: "app") }.to raise_error(Workspace::Error) { |e|
      expect(e.code).to eq("invalid_workflow_default")
      expect(e.details).to include("reason" => "not_for_kind", "applies_to" => %w[github_pr branch])
      expect(e.message).to include("Pass --force")
    }
    expect(router.route(kind: "jira", workspace: "app", force: true)).to include("workflow" => "pr-feedback", "source" => "default")
  end
end
