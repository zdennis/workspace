require "spec_helper"
require "tmpdir"

RSpec.describe Workspace::Library do
  around do |example|
    Dir.mktmpdir("library") do |dir|
      @dir = dir
      example.run
    end
  end

  let(:config) { instance_double(Workspace::Config, library_dir: File.join(@dir, "library")) }
  let(:lineage) { instance_double(Workspace::WorkspaceLineage) }
  let(:project_config) { instance_double(Workspace::ProjectConfig) }
  subject(:library) { described_class.new(config: config, lineage: lineage, project_config: project_config) }

  def resolve_cwd_to(name)
    allow(lineage).to receive(:resolve).with(cwd: "/work/app").and_return(Workspace::WorkspaceLineage::Lineage.new(name: name))
  end

  before do
    allow(project_config).to receive(:exists?) { |name| %w[app other].include?(name) }
  end

  describe "#stores" do
    it "searches the project of cwd, then global, when cwd is a known workspace" do
      resolve_cwd_to("app")

      stores = library.stores(cwd: "/work/app")
      expect(stores.map { |s| [s.scope, s.project] }).to eq([["project", "app"], ["global", nil]])
      expect(stores.first.dir).to eq(File.join(@dir, "library/projects/app"))
      expect(stores.last.dir).to eq(File.join(@dir, "library/global"))
    end

    it "skips the project scope when cwd is not a known workspace" do
      resolve_cwd_to("Downloads")

      expect(library.stores(cwd: "/work/app").map(&:scope)).to eq(["global"])
    end

    it "narrows to one scope with --global or --project NAME" do
      expect(library.stores(scope: "global", cwd: "/work/app").map(&:scope)).to eq(["global"])
      expect(library.stores(scope: "project", project: "other").map(&:project)).to eq(["other"])
      expect(library.stores(project: "other").map(&:project)).to eq(["other", nil])
    end

    it "rejects --project for a workspace list doesn't know, including the one resolved from cwd" do
      resolve_cwd_to("Downloads")

      expect { library.stores(scope: "project", project: "nope") }.to raise_error(Workspace::Error) { |e|
        expect(e.code).to eq("unknown_workspace")
        expect(e.details).to eq("name" => "nope")
      }
      expect { library.stores(scope: "project", cwd: "/work/app") }.to raise_error(Workspace::Error, /Downloads/)
    end
  end

  describe "#write_store" do
    it "is global unless the scope is project" do
      resolve_cwd_to("app")

      expect(library.write_store(cwd: "/work/app").scope).to eq("global")
      expect(library.write_store(scope: "global").scope).to eq("global")
      expect(library.write_store(scope: "project", cwd: "/work/app").project).to eq("app")
      expect(library.write_store(scope: "project", project: "other").project).to eq("other")
    end
  end

  describe "#entries and #resolve" do
    let(:global) { library.global_store }
    let(:project) { library.project_store("app") }

    before do
      global.write("play", "kickoff", "# Global kickoff\n")
      global.write("play", "review", "# Review\n")
      global.write("prompt", "kickoff", "Prompt kickoff\n")
      project.write("play", "kickoff", "# Project kickoff\n")
    end

    it "sorts by kind then name with the project entry before and effective over the global one" do
      entries = library.entries([project, global])

      expect(entries.map { |e| [e["ref"], e["scope"], e["effective"]] }).to eq([
        ["play/kickoff", "project", true], ["play/kickoff", "global", false],
        ["play/review", "global", true], ["prompt/kickoff", "global", true]
      ])
      expect(library.entries([project, global], kind: "prompt").map { |e| e["ref"] }).to eq(["prompt/kickoff"])
    end

    it "resolves kind/name to the effective entry" do
      expect(library.resolve("play/kickoff", [project, global])).to include("scope" => "project", "effective" => true)
      expect(library.resolve("play/kickoff", [global])).to include("scope" => "global")
      expect(library.resolve("review", [project, global])).to include("ref" => "play/review")
    end

    it "fails a bare name two kinds have, naming both" do
      expect { library.resolve("kickoff", [project, global]) }.to raise_error(Workspace::Error) { |e|
        expect(e.code).to eq("ambiguous_library_entry")
        expect(e.details).to eq("ref" => "kickoff", "candidates" => ["play/kickoff", "prompt/kickoff"])
      }
    end

    it "fails an unknown ref, naming the scopes searched" do
      expect { library.resolve("play/nope", [project, global]) }.to raise_error(Workspace::Error) { |e|
        expect(e.code).to eq("unknown_library_entry")
        expect(e.details).to eq("ref" => "play/nope", "scopes" => ["project:app", "global"])
      }
    end

    it "rejects a bad kind or name as usage" do
      expect { library.resolve("skill/x", [global]) }.to raise_error(Workspace::UsageError, /Unknown kind 'skill'/)
      expect { library.resolve("play/Bad Name", [global]) }.to raise_error(Workspace::UsageError, /not a valid library name/)
      expect { library.resolve("../x", [global]) }.to raise_error(Workspace::UsageError, /Unknown kind/)
      expect { library.resolve("", [global]) }.to raise_error(Workspace::UsageError, /not a valid library name/)
    end
  end
end
