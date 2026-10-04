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
  describe "#play and #play_prompt" do
    let(:global) { library.global_store }
    let(:project) { library.project_store("app") }

    before do
      resolve_cwd_to("app")
      global.write("play", "kickoff", "# Global kickoff\n")
      global.write("prompt", "kickoff", "Prompt kickoff\n")
      global.write("play", "review", "# Review\n")
    end

    it "resolves a bare name to the effective play, project before global, with the body hash" do
      project.write("play", "kickoff", "# Project kickoff\n")

      play = library.play("kickoff", cwd: "/work/app")

      expect(play).to eq("ref" => "play/kickoff", "scope" => "project", "path" => project.path_for("play", "kickoff"),
        "sha256" => Digest::SHA256.hexdigest("# Project kickoff\n"))
      expect(library.play("play/review", cwd: "/work/app")).to include("scope" => "global", "path" => global.path_for("play", "review"))
    end

    it "expands a ~ root before naming its project" do
      project.write("play", "kickoff", "# Project kickoff\n")
      allow(lineage).to receive(:resolve).with(cwd: File.expand_path("~/Code/app"))
        .and_return(Workspace::WorkspaceLineage::Lineage.new(name: "app"))

      expect(library.play("kickoff", cwd: "~/Code/app")).to include("scope" => "project")
    end

    it "searches only global without a cwd" do
      project.write("play", "kickoff", "# Project kickoff\n")

      expect(library.play("kickoff", cwd: nil)).to include("scope" => "global")
    end

    it "refuses a prompt as usage, pointing at --prompt" do
      expect { library.play("prompt/kickoff", cwd: "/work/app") }
        .to raise_error(Workspace::UsageError, /--play takes a play.*--prompt "\$\(workspace library show prompt\/kickoff\)"/m)
    end

    it "fails an unknown play with unknown_library_entry" do
      expect { library.play("nope", cwd: "/work/app") }.to raise_error(Workspace::Error) { |e|
        expect(e.code).to eq("unknown_library_entry")
        expect(e.details).to eq("ref" => "play/nope", "scopes" => ["project:app", "global"])
      }
    end

    it "fails a play whose link target is gone with library_source_missing" do
      global.link("play", "gone", File.join(@dir, "evicted.md"))

      expect { library.play("gone", cwd: "/work/app") }.to raise_error(Workspace::Error) { |e|
        expect(e.code).to eq("library_source_missing")
        expect(e.details).to eq("ref" => "play/gone", "path" => global.path_for("play", "gone"))
      }
    end

    it "fails a play that exists but can not be read" do
      global.write("play", "locked", "secret\n")
      File.chmod(0o000, global.path_for("play", "locked"))
      skip "running as root reads anything" if File.readable?(global.path_for("play", "locked"))

      expect { library.play("locked", cwd: "/work/app") }.to raise_error(Workspace::Error) { |e| expect(e.code).to eq("library_source_missing") }
    end

    it "points the agent at the path, then adds the prompt text after a blank line" do
      play = {"path" => "/lib/play/kickoff.md"}

      expect(library.play_prompt(play, nil)).to eq("Read \"/lib/play/kickoff.md\" and follow it.")
      expect(library.play_prompt(play, "Start at CLI27.")).to eq("Read \"/lib/play/kickoff.md\" and follow it.\n\nStart at CLI27.")
    end

    it "binds the pane a play was sent to by the play ref, with its path as the instructions" do
      play = {"ref" => "play/kickoff", "scope" => "global", "path" => "/lib/play/kickoff.md", "sha256" => "abc"}

      expect(library.play_binding(play)).to eq("kind" => "play", "id" => "play/kickoff", "instructions" => "/lib/play/kickoff.md")
    end
  end
end
