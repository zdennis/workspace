require "spec_helper"
require "tmpdir"
require "yaml"

RSpec.describe Workspace::PermissionPolicyConfig do
  let(:dir) { Dir.mktmpdir("ws-permcfg") }
  let(:settings) { Workspace::ProjectSettings.new(config: Struct.new(:workspace_config_dir).new(File.join(dir, "config"))) }
  let(:resolver) { Workspace::ConfigResolver.new(project_settings: settings) }
  let(:run_store) { Workspace::WorkflowRunStore.new(dir: File.join(dir, "runs"), archive_dir: File.join(dir, "archive")) }
  let(:run_id) { nil }
  let(:bound_run) { instance_double(Workspace::BoundRun, run_id_strict: run_id) }
  let(:logger) { instance_double(Workspace::Logger, debug: nil) }

  subject(:config) { described_class.new(config_resolver: resolver, bound_run: bound_run, run_store: run_store, logger: logger) }

  before do
    FileUtils.mkdir_p(File.join(dir, "config", "projects"))
    FileUtils.mkdir_p(File.join(dir, "runs"))
  end

  after { FileUtils.remove_entry(dir) }

  def write_config(name, data, raw: nil)
    path = (name == :global) ? File.join(dir, "config", "config.yml") : File.join(dir, "config", "projects", "#{name}.yml")
    File.write(path, raw || YAML.dump(data))
  end

  def policy = config.policy(workspace: "app.worktree-x", project: "app")

  def configured? = config.configured?(workspace: "app.worktree-x", project: "app")

  def decide(command) = policy.decide(tool_name: "Bash", tool_input: {"command" => command}, cwd: dir)

  def agent(**permissions) = {"agent" => {"permissions" => permissions.transform_keys(&:to_s)}}

  def write_run(state:, permissions: nil, hang_guard: nil)
    definition = {"steps" => [{"id" => "fix"}]}
    definition["hang_guard"] = hang_guard unless hang_guard.nil?
    definition["permissions"] = permissions if permissions
    File.write(File.join(dir, "runs", "wr_1.json"), JSON.generate("id" => "wr_1", "workflow" => "w", "workspace" => "app", "current" => "fix",
      "state" => state, "definition" => definition, "steps" => {"fix" => {"attempts" => []}}))
  end

  it "is nil and unconfigured with no files" do
    expect(policy).to be_nil
    expect(configured?).to be(false)
  end

  it "joins the rules of the global, project and worktree files and names each source" do
    write_config(:global, agent(rules: [{"tool" => "Bash", "pattern" => "rm *", "action" => "deny"}]))
    write_config("app", agent(rules: [{"tool" => "Bash", "action" => "allow"}]))
    write_config("app.worktree-x", agent(rules: [{"tool" => "Bash", "pattern" => "git push*", "action" => "ask"}]))

    expect(decide("rm x")).to eq(action: "deny", rule: "global:rules[0]")
    expect(decide("git push")).to eq(action: "ask", rule: "worktree:rules[0]")
    expect(decide("ls")).to eq(action: "allow", rule: "project:rules[0]")
    expect(configured?).to be(true)
  end

  it "applies the most restrictive default of the layers that set one" do
    write_config(:global, agent(default: "deny"))
    write_config("app", agent(default: "allow"))

    expect(decide("ls")).to eq(action: "deny", rule: "global:default")
  end

  it "gives nil but still configured for a broken global value" do
    write_config("app", agent(rules: [{"tool" => "Bash", "action" => "deny"}]))
    write_config(:global, agent(rules: "everything"))

    expect(policy).to be_nil
    expect(configured?).to be(true)
  end

  it "gives nil but configured for a project file that is not valid YAML" do
    write_config("app", nil, raw: "agent: [unclosed")

    expect(policy).to be_nil
    expect(configured?).to be(true)
  end

  {
    "a global file that is not valid YAML" => "agent: [",
    "a global file with symbol keys" => ":agent:\n  :permissions:\n    :default: deny\n",
    "a global file with an alias" => "a: &x\n  tool: Bash\nagent:\n  permissions:\n    rules:\n    - *x\n",
    "a global file whose top level is a list" => "- agent\n- permissions\n"
  }.each do |name, raw|
    it "gives nil, never the looser project default, for #{name}" do
      write_config(:global, nil, raw: raw)
      write_config("app", agent(default: "allow"))

      expect(policy).to be_nil
      expect(configured?).to be(true)
    end
  end

  {
    "permissions that is a scalar" => "agent:\n  permissions: deny\n",
    "an agent that is a scalar" => "agent: deny\n",
    "rules directly under permissions" => "agent:\n  permissions:\n  - tool: Bash\n    action: deny\n",
    "a misspelled rules key" => "agent:\n  permissions:\n    rule:\n    - tool: Bash\n      action: deny\n",
    "a misspelled default key" => "agent:\n  permissions:\n    defualt: deny\n",
    "a flat dotted rules key" => "agent.permissions.rules:\n- tool: Bash\n  action: deny\n",
    "a flat dotted default key" => "agent.permissions.default: deny\n"
  }.each do |name, raw|
    it "gives nil but configured for #{name}, beside a looser valid layer" do
      write_config(:global, nil, raw: raw)
      write_config("app", agent(default: "allow"))

      expect(policy).to be_nil
      expect(configured?).to be(true)
    end
  end

  it "gives nil but configured for a misspelled key with no other file" do
    write_config(:global, nil, raw: "agent:\n  permissions:\n    rule:\n    - tool: Bash\n      action: deny\n")

    expect(policy).to be_nil
    expect(configured?).to be(true)
  end

  it "reads an unreadable binding as an error, not an unbound pane" do
    write_config("app", agent(default: "allow"))
    allow(bound_run).to receive(:run_id_strict).and_raise(Workspace::Error.new("tmux gone", code: "tmux_failed"))

    expect(policy).to be_nil
  end

  context "with a bound run" do
    let(:run_id) { "wr_1" }

    it "adds a live run's rules as the last layer" do
      write_config("app", agent(default: "allow"))
      write_run(state: "running", permissions: [{"tool" => "Bash", "pattern" => "git push*", "action" => "deny"}])

      expect(decide("git push origin")).to eq(action: "deny", rule: "run:permissions[0]")
      expect(decide("ls")).to eq(action: "allow", rule: "project:default")
    end

    it "leaves a finished run's rules out" do
      write_run(state: "completed", permissions: [{"tool" => "Bash", "action" => "deny"}])

      expect(policy).to be_nil
      expect(configured?).to be(false)
    end

    it "gives nil for a run that does not exist" do
      write_config("app", agent(default: "allow"))

      expect(policy).to be_nil
      expect(configured?).to be(true)
    end
  end

  describe "#hang_guard" do
    def hang_guard = config.hang_guard(workspace: "app.worktree-x", project: "app")

    it "reads the defaults with no files" do
      expect(hang_guard).to eq(mode: "deny_with_hint", max_denies: 2)
    end

    it "lets the most specific layer win" do
      write_config(:global, agent(hang_guard: "off", hang_guard_max_denies: 5))
      write_config("app", agent(hang_guard: "deny_with_hint", hang_guard_max_denies: 3))
      expect(hang_guard).to eq(mode: "deny_with_hint", max_denies: 3)

      write_config("app.worktree-x", agent(hang_guard: "off"))
      expect(hang_guard).to eq(mode: "off", max_denies: 3)
    end

    it "reads a hand-written unquoted off, which YAML loads as false, as off" do
      write_config("app", nil, raw: "agent:\n  permissions:\n    hang_guard: off\n")
      expect(hang_guard[:mode]).to eq("off")
    end

    it "reads a bad value as the default of that key only" do
      write_config("app", agent(hang_guard: "bogus", hang_guard_max_denies: 4))
      expect(hang_guard).to eq(mode: "deny_with_hint", max_denies: 4)
    end

    it "reads the defaults when a file can't be parsed" do
      write_config("app", nil, raw: "agent: [")
      expect(hang_guard).to eq(mode: "deny_with_hint", max_denies: 2)
    end

    context "with a bound run" do
      let(:run_id) { "wr_1" }

      it "lets a live run's hang_guard beat every config layer, and leaves the cap to config" do
        write_config("app.worktree-x", agent(hang_guard: "deny_with_hint", hang_guard_max_denies: 4))
        write_run(state: "running", hang_guard: "off")
        expect(hang_guard).to eq(mode: "off", max_denies: 4)
      end

      it "lets a run's deny_with_hint beat a config off" do
        write_config("app.worktree-x", agent(hang_guard: "off"))
        write_run(state: "running", hang_guard: "deny_with_hint")
        expect(hang_guard[:mode]).to eq("deny_with_hint")
      end

      it "reads the config when the run sets none" do
        write_config("app.worktree-x", agent(hang_guard: "off"))
        write_run(state: "running")
        expect(hang_guard[:mode]).to eq("off")
      end

      it "ignores a finished run" do
        write_run(state: "completed", hang_guard: "off")
        expect(hang_guard[:mode]).to eq("deny_with_hint")
      end

      it "ignores a bad stored value" do
        write_run(state: "running", hang_guard: "bogus")
        expect(hang_guard[:mode]).to eq("deny_with_hint")
      end
    end

    it "keeps the rules working and the policy unconfigured when a layer holds only these keys" do
      write_config("app", agent(hang_guard: "off", hang_guard_max_denies: 1))
      expect(policy).to be_nil
      expect(configured?).to be(false)

      write_config("app", agent(hang_guard: "off", rules: [{"tool" => "Bash", "pattern" => "rm *", "action" => "deny"}]))
      expect(decide("rm x")).to eq(action: "deny", rule: "project:rules[0]")
    end
  end
end
