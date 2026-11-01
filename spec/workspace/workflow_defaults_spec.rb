require "spec_helper"

RSpec.describe Workspace::WorkflowDefaults do
  let(:global) { {} }
  let(:projects) { {} }
  let(:project_settings) do
    instance_double(Workspace::ProjectSettings, load_global: global).tap do |settings|
      allow(settings).to receive(:load) { |name| projects.fetch(name, {}) }
    end
  end
  subject(:defaults) { described_class.new(config_resolver: Workspace::ConfigResolver.new(project_settings: project_settings)) }

  def bad_file(name)
    Workspace::ConfigParseError.new("/c/#{name}.yml", "bad")
  end

  it "is nil when nothing is set" do
    expect(defaults.id_for("jira")).to be_nil
    expect(defaults.id_for("jira", workspace: "app")).to be_nil
  end

  it "reads the named project under a worktree whose name doesn't show it" do
    projects["app"] = {"workflows" => {"default" => "explore"}}

    expect(defaults.lookup("jira", workspace: "app-feat", project: "app")).to eq({id: "explore", key: "workflows.default"})
    projects["app-feat"] = {"workflows" => {"default" => "investigate"}}
    expect(defaults.lookup("jira", workspace: "app-feat", project: "app")).to eq({id: "investigate", key: "workflows.default"})
  end

  it "prefers by_ref over default" do
    global["workflows"] = {"default" => "rpiv", "by_ref" => {"jira" => "investigate"}}

    expect(defaults.id_for("jira")).to eq("investigate")
    expect(defaults.id_for("branch")).to eq("rpiv")
  end

  it "prefers a global by_ref over a project default" do
    global["workflows"] = {"by_ref" => {"jira" => "investigate"}}
    projects["app"] = {"workflows" => {"default" => "explore"}}

    expect(defaults.id_for("jira", workspace: "app")).to eq("investigate")
    expect(defaults.id_for("branch", workspace: "app")).to eq("explore")
  end

  it "prefers a project value over a global one" do
    global["workflows"] = {"default" => "rpiv"}
    projects["app"] = {"workflows" => {"default" => "explore"}}

    expect(defaults.id_for("prompt", workspace: "app")).to eq("explore")
  end

  it "prefers a worktree value when the worktree workspace is named" do
    projects["app"] = {"workflows" => {"default" => "explore"}}
    projects["app.worktree-x"] = {"workflows" => {"default" => "investigate"}}

    expect(defaults.id_for("prompt", workspace: "app.worktree-x")).to eq("investigate")
    expect(defaults.id_for("prompt", workspace: "app")).to eq("explore")
  end

  it "ignores project files when no workspace is named" do
    global["workflows"] = {"default" => "rpiv"}
    projects["app"] = {"workflows" => {"default" => "explore"}}

    expect(defaults.id_for("branch")).to eq("rpiv")
  end

  it "falls back to the global values for both keys when a project file can't be parsed" do
    global["workflows"] = {"default" => "rpiv", "by_ref" => {"jira" => "investigate"}}
    allow(project_settings).to receive(:load).and_raise(bad_file("app"))

    expect(defaults.id_for("jira", workspace: "app")).to eq("investigate")
    expect(defaults.id_for("branch", workspace: "app")).to eq("rpiv")
  end

  it "reads a global file that can't be parsed as unset" do
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "config.yml"), "workflows: [\n")
      config = instance_double(Workspace::Config, workspace_config_dir: dir)
      settings = Workspace::ProjectSettings.new(config: config)
      reader = described_class.new(config_resolver: Workspace::ConfigResolver.new(project_settings: settings))

      expect(reader.id_for("jira")).to be_nil
      expect(reader.id_for("jira", workspace: "app")).to be_nil
    end
  end

  it "returns a malformed value unchanged" do
    global["workflows"] = {"default" => "Bad Id"}

    expect(defaults.id_for("branch")).to eq("Bad Id")
  end

  it "resolves each of the five kinds" do
    Workspace::ConfigSchema::WORKFLOW_REF_KINDS.each do |kind|
      global["workflows"] = {"by_ref" => {kind => "id-#{kind}"}}

      expect(defaults.id_for(kind)).to eq("id-#{kind}")
    end
  end

  it "raises KeyError for an undeclared kind" do
    expect { defaults.id_for("bogus") }.to raise_error(KeyError)
  end

  describe "#lookup" do
    it "is nil when neither key is set" do
      expect(defaults.lookup("jira")).to be_nil
    end

    it "reports workflows.by_ref.<kind> when it answers" do
      global["workflows"] = {"by_ref" => {"jira" => "investigate"}}

      expect(defaults.lookup("jira")).to eq(id: "investigate", key: "workflows.by_ref.jira")
    end

    it "reports workflows.default when it answers" do
      global["workflows"] = {"default" => "rpiv", "by_ref" => {"jira" => "investigate"}}

      expect(defaults.lookup("branch")).to eq(id: "rpiv", key: "workflows.default")
    end

    it "reports by_ref when both keys are set" do
      global["workflows"] = {"default" => "rpiv", "by_ref" => {"jira" => "investigate"}}

      expect(defaults.lookup("jira")[:key]).to eq("workflows.by_ref.jira")
    end

    it "reads only the global file with a nil workspace" do
      global["workflows"] = {"default" => "rpiv"}
      projects["app"] = {"workflows" => {"by_ref" => {"branch" => "explore"}}}

      expect(defaults.lookup("branch")).to eq(id: "rpiv", key: "workflows.default")
      expect(defaults.lookup("branch", workspace: "app")).to eq(id: "explore", key: "workflows.by_ref.branch")
    end

    it "reports the key that answered after a project file can't be parsed" do
      global["workflows"] = {"default" => "rpiv", "by_ref" => {"jira" => "investigate"}}
      allow(project_settings).to receive(:load).and_raise(bad_file("app"))

      expect(defaults.lookup("jira", workspace: "app")).to eq(id: "investigate", key: "workflows.by_ref.jira")
      expect(defaults.lookup("branch", workspace: "app")).to eq(id: "rpiv", key: "workflows.default")
    end
  end
end
