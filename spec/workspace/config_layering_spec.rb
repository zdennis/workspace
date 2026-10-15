require "spec_helper"

RSpec.describe Workspace::ConfigLayering do
  def key(resolve:, overridable_in: nil, name: "dev.ready_timeout", scope: :project)
    Workspace::ConfigSchema::Key.new(name: name, scope: scope, resolve: resolve, overridable_in: overridable_in, doc: "x", settable: true)
  end

  describe ".read_order" do
    it "reads an :own_then_parent key from the worktree alone in a worktree and from the project in a main checkout" do
      k = Workspace::ConfigSchema.key("notes.dir")
      expect(described_class.read_order(k, worktree: true)).to eq(["worktree"])
      expect(described_class.read_order(k, worktree: false)).to eq(["project"])
    end

    it "reads a :layered key worktree, project, global, limited to its overridable_in" do
      all = key(resolve: :layered, overridable_in: %i[global project worktree])
      expect(described_class.read_order(all, worktree: true)).to eq(%w[worktree project global])
      expect(described_class.read_order(all, worktree: false)).to eq(%w[project global])
      narrow = key(resolve: :layered, overridable_in: %i[project worktree])
      expect(described_class.read_order(narrow, worktree: true)).to eq(%w[worktree project])
      expect(described_class.read_order(key(resolve: :layered, overridable_in: %i[global project]), worktree: true)).to eq(%w[project global])
    end

    it "reads :parent from the project and :global from the global file whatever the workspace" do
      [true, false].each do |worktree|
        expect(described_class.read_order(key(resolve: :parent), worktree: worktree)).to eq(["project"])
        expect(described_class.read_order(key(resolve: :global), worktree: worktree)).to eq(["global"])
      end
    end

    it "has no order for :own, :merge and :none, which ConfigReport handles itself" do
      %i[own merge none].each { |mode| expect(described_class.read_order(key(resolve: mode), worktree: true)).to eq([]) }
    end

    it "takes a key name" do
      expect(described_class.read_order("dev.up", worktree: true)).to eq(["project"])
    end
  end

  describe "upto" do
    let(:layered) { key(resolve: :layered, overridable_in: %i[global project worktree]) }

    it "drops the layers above it from the read order" do
      expect(described_class.read_order(layered, worktree: true, upto: "project")).to eq(%w[project global])
      expect(described_class.read_order(layered, worktree: true, upto: "global")).to eq(%w[global])
      expect(described_class.read_order("notes.dir", worktree: true, upto: "project")).to eq([])
    end

    it "limits hits to the kept layers" do
      data = {"worktree" => {"dev" => {"ready_timeout" => 3}}, "project" => {"dev" => {"ready_timeout" => 2}}}
      expect(described_class.hits(layered, data, worktree: true, upto: "project").map(&:layer)).to eq(["project"])
      expect(described_class.hits(layered, data, worktree: true, upto: "global")).to eq([])
    end

    it "refuses any other value" do
      expect { described_class.read_order(layered, worktree: true, upto: "worktree") }.to raise_error(ArgumentError, /upto/)
    end
  end

  describe ".hits" do
    let(:layered) { key(resolve: :layered, overridable_in: %i[global project worktree]) }

    it "lists the layers that hold a value, highest first, so the first is the winner" do
      data = {"worktree" => {"dev" => {"ready_timeout" => "5s"}}, "project" => {"dev" => {"ready_timeout" => "9s"}}, "global" => {"dev" => {"ready_timeout" => "1m"}}}
      hits = described_class.hits(layered, data, worktree: true)
      expect(hits.map(&:layer)).to eq(%w[worktree project global])
      expect(hits.map(&:value)).to eq(%w[5s 9s 1m])
    end

    it "falls through to the next layer for each pair: default < global < project < worktree" do
      expect(described_class.hits(layered, {}, worktree: true)).to eq([])
      expect(described_class.hits(layered, {"global" => {"dev" => {"ready_timeout" => 1}}}, worktree: true).map(&:layer)).to eq(["global"])
      both = {"global" => {"dev" => {"ready_timeout" => 1}}, "project" => {"dev" => {"ready_timeout" => 2}}}
      expect(described_class.hits(layered, both, worktree: true).first.layer).to eq("project")
      both["worktree"] = {"dev" => {"ready_timeout" => 3}}
      expect(described_class.hits(layered, both, worktree: true).first.layer).to eq("worktree")
      expect(described_class.hits(layered, both, worktree: false).first.layer).to eq("project")
    end

    it "treats a nil value, a missing section and a non-Hash section as unset" do
      data = {"worktree" => {"dev" => nil}, "project" => {"dev" => "oops"}, "global" => {"dev" => {"ready_timeout" => nil}}}
      expect(described_class.hits(layered, data, worktree: true)).to eq([])
      expect(described_class.hits(layered, {"project" => nil}, worktree: true)).to eq([])
    end

    it "keeps a value that won't parse as the winner instead of falling through" do
      data = {"project" => {"dev" => {"ready_timeout" => "soon"}}, "global" => {"dev" => {"ready_timeout" => "1m"}}}
      expect(described_class.hits(layered, data, worktree: false).map(&:value)).to eq(%w[soon 1m])
    end

    it "does not let a worktree read the project's notes.dir" do
      data = {"project" => {"notes" => {"dir" => "/p"}}}
      expect(described_class.hits("notes.dir", data, worktree: true)).to eq([])
      expect(described_class.hits("notes.dir", data, worktree: false).map(&:value)).to eq(["/p"])
    end
  end

  describe ".default_layer against ConfigReport#target_layer" do
    fixtures = File.expand_path("../fixtures/config_layering", __dir__)
    let(:config) { instance_double(Workspace::Config, workspace_config_dir: File.join(fixtures, "config")) }
    let(:roots) { {"main" => "/src/main", "main.worktree-a" => "/src/main/.worktrees/a"} }
    let(:project_config) { instance_double(Workspace::ProjectConfig, available_projects: roots.keys) }
    let(:git) { Workspace::Git.new }
    let(:report) do
      Workspace::ConfigReport.new(
        project_settings: Workspace::ProjectSettings.new(config: config),
        project_config: project_config,
        notes_dir: Workspace::NotesDir.new(git: git, home: "/home/me")
      )
    end

    before do
      allow(project_config).to receive(:project_root_for) { |name| roots[name] }
      allow(git).to receive(:worktree_branch) { |path| "feature/#{File.basename(path)}" }
    end

    # Known disagreements; none today.
    known_disagreements = {}

    {"main" => false, "main.worktree-a" => true}.each do |workspace, worktree|
      it "agrees for every schema key in #{workspace}" do
        rows = report.show(workspace)["keys"].to_h { |row| [[row["key"], row["scope"]], row["target_layer"]] }
        expect(rows.keys).to match_array(Workspace::ConfigSchema.all.map { |k| [k.name, k.scope.to_s] })
        Workspace::ConfigSchema.all.each do |schema_key|
          expected = schema_key.settable? ? described_class.default_layer(schema_key, worktree: worktree) : nil
          expected = known_disagreements.fetch([schema_key.name, worktree], expected)
          expect(rows[[schema_key.name, schema_key.scope.to_s]]).to eq(expected), "#{schema_key.name} (worktree: #{worktree})"
        end
      end
    end
  end

  describe ".default_layer" do
    it "gives today's `config set` target" do
      expect(described_class.default_layer("context.source", worktree: true)).to eq("global")
      expect(described_class.default_layer("notes.dir", worktree: true)).to eq("worktree")
      expect(described_class.default_layer("notes.dir", worktree: false)).to eq("project")
      expect(described_class.default_layer("dev.up", worktree: true)).to eq("project")
    end
  end
end
