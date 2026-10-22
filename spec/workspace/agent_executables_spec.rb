require "spec_helper"
require "tmpdir"
require "fileutils"

RSpec.describe Workspace::AgentExecutables do
  let(:tmp) { Dir.mktmpdir }
  let(:bin) { File.join(tmp, "bin").tap { |d| FileUtils.mkdir_p(d) } }
  let(:other) { File.join(tmp, "other").tap { |d| FileUtils.mkdir_p(d) } }
  let(:global) { {} }
  let(:project_settings) { instance_double(Workspace::ProjectSettings) }
  let(:agent_commands) { Workspace::AgentCommands.new(config_resolver: Workspace::ConfigResolver.new(project_settings: project_settings)) }
  let(:path) { [bin, other].join(":") }
  subject(:executables) { described_class.new(agent_commands: agent_commands, path: path) }

  before do
    allow(project_settings).to receive(:load_global) { global }
    allow(project_settings).to receive(:load).and_return({})
  end

  after { FileUtils.chmod_R(0o755, tmp) && FileUtils.rm_rf(tmp) }

  def make(dir, name, mode: 0o755)
    File.join(dir, name).tap do |file|
      File.write(file, "#!/bin/sh\n")
      File.chmod(mode, file)
    end
  end

  def names(result, kind = nil)
    rows = result["executables"]
    rows = rows.select { |row| row["kind"] == kind } if kind
    rows.map { |row| row["name"] }
  end

  describe "matching" do
    before do
      %w[claude claude-dev claude-opus codex pi pick piconv pip3 claudette claude_dev].each { |n| make(bin, n) }
      FileUtils.mkdir(File.join(bin, "claude-x"))
      make(bin, "claude-y", mode: 0o644)
      File.symlink(File.join(tmp, "missing"), File.join(bin, "claude-broken"))
    end

    it "lists the provider executables and their dash variants only" do
      result = executables.call

      expect(names(result)).to eq(%w[claude claude-dev claude-opus codex pi])
    end

    it "marks the provider's own executable builtin and sorts it first within the kind" do
      rows = executables.call["executables"].select { |row| row["kind"] == "claude" }

      expect(rows.map { |row| row["builtin"] }).to eq([true, false, false])
      expect(rows.first).to include("path" => File.join(bin, "claude"), "source" => "path", "found" => true, "shadowed" => [])
    end

    it "orders kinds as AgentProvider.all does" do
      kinds = executables.call["executables"].map { |row| row["kind"] }

      expect(kinds.uniq).to eq(%w[claude codex pi])
    end

    it "follows a symlink to an executable file" do
      File.symlink(File.join(bin, "codex"), File.join(bin, "codex-link"))

      expect(names(executables.call, "codex")).to eq(%w[codex codex-link])
    end

    it "filters by kind" do
      expect(names(executables.call(kind: "codex"))).to eq(%w[codex])
    end

    it "rejects an unknown kind" do
      expect { executables.call(kind: "nope") }.to raise_error(ArgumentError, /unknown agent kind/)
    end
  end

  describe "PATH handling" do
    it "reports the first hit and lists later paths as shadowed" do
      first = make(bin, "claude-dev")
      second = make(other, "claude-dev")

      row = executables.call["executables"].first

      expect(row).to include("path" => first, "shadowed" => [second])
    end

    it "ignores relative and empty entries and files that are not directories" do
      Dir.chdir(bin) do
        make(bin, "claude")
        FileUtils.mkdir_p("bin")
        make("bin", "codex")
        file = make(other, "not-a-dir")
        result = described_class.new(agent_commands: agent_commands, path: ["", ".", "bin", file].join(":")).call

        expect(result["path_dirs"]).to eq([])
        expect(result["executables"]).to eq([])
      end
    end

    it "skips an unreadable directory" do
      skip "root reads everything" if Process.uid.zero?
      make(other, "codex")
      FileUtils.chmod(0o000, other)

      expect(names(executables.call)).to eq([])
    end

    it "reports the directories it scans" do
      expect(executables.call["path_dirs"]).to eq([bin, other])
    end
  end

  describe "effective" do
    let(:global) { {"agent" => {"commands" => {"claude" => "claude-dev"}}} }

    before { %w[claude claude-dev claude-opus claude-haiku codex].each { |n| make(bin, n) } }

    def stub_file(name, data)
      allow(project_settings).to receive(:load).with(name).and_return(data)
    end

    it "reads the global layer alone without a workspace" do
      stub_file("app", {"agent" => {"commands" => {"claude" => "claude-opus"}}})

      expect(executables.call["effective"]["claude"]).to eq(
        "program" => "claude-dev", "path" => File.join(bin, "claude-dev"), "layer" => "global", "found" => true
      )
    end

    it "shows the worktree layer when it sets the command" do
      stub_file("app", {"agent" => {"commands" => {"claude" => "claude-opus"}}})
      stub_file("app.worktree-feat", {"agent" => {"commands" => {"claude" => "claude-haiku"}}})

      expect(executables.call(workspace: "app.worktree-feat")["effective"]["claude"])
        .to include("program" => "claude-haiku", "layer" => "worktree", "found" => true)
    end

    it "falls back to the project layer when the worktree sets nothing" do
      stub_file("app", {"agent" => {"commands" => {"claude" => "claude-opus"}}})
      stub_file("app.worktree-feat", {})

      expect(executables.call(workspace: "app.worktree-feat")["effective"]["claude"])
        .to include("program" => "claude-opus", "layer" => "project")
    end

    it "uses the default layer and the provider executable when nothing is set" do
      expect(executables.call["effective"]["codex"])
        .to eq("program" => "codex", "path" => File.join(bin, "codex"), "layer" => "default", "found" => true)
    end

    it "reports a program that is not on PATH as not found" do
      expect(executables.call["effective"]["pi"]).to eq("program" => "pi", "path" => nil, "layer" => "default", "found" => false)
    end

    it "reports the effective agent kind" do
      expect(executables.call["kind"]).to eq("claude")
      stub_file("app", {"agent" => {"kind" => "codex"}})

      expect(executables.call(workspace: "app")["kind"]).to eq("codex")
    end

    it "resolves an absolute path as written" do
      absolute = make(other, "claude-abs")
      stub_file("app", {"agent" => {"commands" => {"claude" => "FOO=1 #{absolute} --x"}}})

      expect(executables.call(workspace: "app")["effective"]["claude"])
        .to include("program" => "claude-abs", "path" => absolute, "found" => true)
    end
  end

  describe "configured values that do not resolve" do
    it "adds a configured row for a missing bare program, without the rest of the command" do
      stub = {"agent" => {"commands" => {"claude" => "FOO=secret claude-gone --token=abc"}}}
      allow(project_settings).to receive(:load).with("app").and_return(stub)
      make(bin, "claude")

      row = executables.call(workspace: "app", kind: "claude")["executables"].last

      expect(row).to eq(
        "kind" => "claude", "name" => "claude-gone", "path" => nil, "source" => "configured",
        "found" => false, "builtin" => false, "shadowed" => []
      )
    end

    it "keeps an absolute path as the name and path" do
      missing = File.join(tmp, "old", "opencode-x")
      allow(project_settings).to receive(:load_global).and_return({"agent" => {"commands" => {"opencode" => missing}}})

      row = executables.call(kind: "opencode")["executables"].first

      expect(row).to include("name" => missing, "path" => missing, "source" => "configured", "found" => false)
    end

    it "adds a row for a non-executable absolute path" do
      file = make(other, "claude-nox", mode: 0o644)
      allow(project_settings).to receive(:load_global).and_return({"agent" => {"commands" => {"claude" => file}}})

      expect(executables.call(kind: "claude")["executables"].map { |r| [r["name"], r["found"]] }).to eq([[file, false]])
    end

    it "adds no row for a program found on PATH" do
      make(bin, "claude-dev")
      allow(project_settings).to receive(:load_global).and_return({"agent" => {"commands" => {"claude" => "claude-dev"}}})

      expect(executables.call["executables"].map { |r| r["source"] }).to eq(%w[path])
    end

    it "covers every applicable layer, so a shadowed stale value stays visible" do
      allow(project_settings).to receive(:load_global).and_return({"agent" => {"commands" => {"claude" => "claude-old"}}})
      allow(project_settings).to receive(:load).with("app").and_return({"agent" => {"commands" => {"claude" => "claude-new"}}})

      expect(names(executables.call(workspace: "app"))).to match_array(%w[claude-new claude-old])
    end
  end

  it "does not resolve a relative path with a slash through PATH" do
    make(bin, "claude-dev")
    allow(project_settings).to receive(:load_global).and_return({"agent" => {"commands" => {"claude" => "tools/claude-dev"}}})

    expect(executables.call["effective"]["claude"]).to include("found" => false, "path" => nil)
  end

  it "finds an absolute executable outside PATH without a configured row" do
    absolute = make(tmp, "claude-off")
    allow(project_settings).to receive(:load_global).and_return({"agent" => {"commands" => {"claude" => absolute}}})

    result = executables.call(kind: "claude")

    expect(result["effective"]["claude"]).to include("found" => true, "path" => absolute)
    expect(result["executables"]).to eq([])
  end

  it "caps the rows at 200 and says so" do
    210.times { |i| make(bin, format("claude-%03d", i)) }

    result = executables.call

    expect(result["executables"].size).to eq(200)
    expect(result["truncated"]).to be(true)
  end

  it "omits truncated when nothing was cut" do
    expect(executables.call).not_to have_key("truncated")
  end
end
