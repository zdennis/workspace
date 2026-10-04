require "spec_helper"
require "tmpdir"

RSpec.describe Workspace::Library do
  around do |example|
    Dir.mktmpdir("library") do |dir|
      @dir = dir
      example.run
    end
  end

  let(:config) { instance_double(Workspace::Config, library_dir: File.join(@dir, "library"), builtin_library_dir: File.join(@dir, "builtin")) }
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
    it "searches the project of cwd, then global, then built-in, when cwd is a known workspace" do
      resolve_cwd_to("app")

      stores = library.stores(cwd: "/work/app")
      expect(stores.map { |s| [s.scope, s.project] }).to eq([["project", "app"], ["global", nil], ["builtin", nil]])
      expect(stores[0].dir).to eq(File.join(@dir, "library/projects/app"))
      expect(stores[1].dir).to eq(File.join(@dir, "library/global"))
      expect(stores[2].dir).to eq(File.join(@dir, "builtin"))
    end

    it "skips the project scope when cwd is not a known workspace" do
      resolve_cwd_to("Downloads")

      expect(library.stores(cwd: "/work/app").map(&:scope)).to eq(%w[global builtin])
    end

    it "narrows to one scope with --global, --builtin or --project NAME" do
      expect(library.stores(scope: "global", cwd: "/work/app").map(&:scope)).to eq(["global"])
      expect(library.stores(scope: "builtin", cwd: "/work/app").map(&:scope)).to eq(["builtin"])
      expect(library.stores(scope: "project", project: "other").map(&:project)).to eq(["other"])
      expect(library.stores(project: "other").map(&:project)).to eq(["other", nil, nil])
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
    it "refuses the built-in scope, which is read-only" do
      expect { library.write_store(scope: "builtin", cwd: "/work/app") }.to raise_error(Workspace::UsageError, /can't be changed/)
    end

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
      expect { library.resolve("tool/x", [global]) }.to raise_error(Workspace::UsageError, /Unknown kind 'tool'/)
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

    it "falls back to a built-in play, which a global play of the same name hides" do
      builtin = library.builtin_store
      builtin.write("play", "orchestrator", "Delegate.\n")
      builtin.write("play", "review", "Built-in review.\n")

      expect(library.play("orchestrator", cwd: "/work/app")).to eq("ref" => "play/orchestrator", "scope" => "builtin",
        "path" => builtin.path_for("play", "orchestrator"), "sha256" => Digest::SHA256.hexdigest("Delegate.\n"))
      expect(library.play("review", cwd: "/work/app")).to include("scope" => "global")
      expect(library.entries(library.stores(cwd: "/work/app"), kind: "play").map { |e| [e["name"], e["scope"], e["effective"]] })
        .to eq([["kickoff", "global", true], ["orchestrator", "builtin", true], ["review", "global", true], ["review", "builtin", false]])
    end

    it "refuses a prompt as usage, pointing at --prompt" do
      expect { library.play("prompt/kickoff", cwd: "/work/app") }
        .to raise_error(Workspace::UsageError, /--play takes a play.*--prompt "\$\(workspace library show prompt\/kickoff\)"/m)
    end

    it "refuses an agent or skill as usage, without the --prompt hint" do
      global.write("skill", "kickoff", "# Skill\n")

      expect { library.play("skill/kickoff", cwd: "/work/app") }.to raise_error(Workspace::UsageError) { |e|
        expect(e.message).to eq("--play takes a play, and 'skill/kickoff' is a skill.")
      }
    end

    it "fails an unknown play with unknown_library_entry" do
      expect { library.play("nope", cwd: "/work/app") }.to raise_error(Workspace::Error) { |e|
        expect(e.code).to eq("unknown_library_entry")
        expect(e.details).to eq("ref" => "play/nope", "scopes" => ["project:app", "global", "builtin"])
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

  describe "a bare name beside a built-in entry" do
    before do
      resolve_cwd_to("app")
      library.builtin_store.write("play", "review", "Built-in review.\n")
    end

    it "prefers a project or global entry of another kind to the built-in one" do
      library.global_store.write("prompt", "review", "Review this.\n")
      stores = library.stores(cwd: "/work/app")

      expect(library.resolve("review", stores)).to include("ref" => "prompt/review", "scope" => "global")
      expect(library.resolve("play/review", stores)).to include("ref" => "play/review", "scope" => "builtin")
    end

    it "resolves to the built-in entry when no other scope has the name" do
      expect(library.resolve("review", library.stores(cwd: "/work/app"))).to include("ref" => "play/review", "scope" => "builtin")
    end

    it "is still ambiguous between two kinds of the user's own, naming only those" do
      library.global_store.write("prompt", "review", "Review this.\n")
      library.project_store("app").write("agent", "review", "You review.\n")

      expect { library.resolve("review", library.stores(cwd: "/work/app")) }.to raise_error(Workspace::Error) { |e|
        expect(e.code).to eq("ambiguous_library_entry")
        expect(e.details["candidates"]).to eq(%w[agent/review prompt/review])
      }
    end
  end

  describe "#pack" do
    let(:global) { library.global_store }
    let(:project) { library.project_store("app") }
    let(:builtin) { library.builtin_store }

    before do
      resolve_cwd_to("app")
      builtin.write("play", "review", "Built-in review.\n")
      global.write("play", "review", "My own review.\n")
      global.write("play", "house-rules", "Global rules.\n")
      global.write("prompt", "kickoff", "Go.\n")
    end

    it "uses the built-in pack even when a project or global play has its name" do
      project.write("play", "review", "The project's review.\n")

      pack, body = library.pack("review", cwd: "/work/app")

      expect(pack).to eq("ref" => "play/review", "scope" => "builtin", "project" => nil,
        "path" => builtin.path_for("play", "review"), "sha256" => Digest::SHA256.hexdigest("Built-in review.\n"))
      expect(body).to eq("Built-in review.\n")
      expect(library.play("review", cwd: "/work/app")).to include("scope" => "project")
    end

    it "takes any other play as a pack, project before global" do
      expect(library.pack("play/house-rules", cwd: "/work/app").first).to include("scope" => "global", "project" => nil)

      project.write("play", "house-rules", "Project rules.\n")

      pack, body = library.pack("house-rules", cwd: "/work/app")
      expect(pack).to include("scope" => "project", "project" => "app", "path" => project.path_for("play", "house-rules"))
      expect(body).to eq("Project rules.\n")
      expect(library.pack("house-rules", cwd: nil).first).to include("scope" => "global")
    end

    it "refuses another kind as usage, naming --pack and without the --prompt hint" do
      expect { library.pack("prompt/kickoff", cwd: "/work/app") }.to raise_error(Workspace::UsageError) { |e|
        expect(e.message).to eq("--pack takes a play, and 'prompt/kickoff' is a prompt.")
      }
    end

    it "fails an unknown pack with unknown_library_entry, naming the scopes in the order searched" do
      expect { library.pack("nope", cwd: "/work/app") }.to raise_error(Workspace::Error) { |e|
        expect(e.code).to eq("unknown_library_entry")
        expect(e.details).to eq("ref" => "play/nope", "scopes" => ["builtin", "project:app", "global"])
      }
    end

    it "fails a pack whose link target is gone with library_source_missing" do
      global.link("play", "gone", File.join(@dir, "evicted.md"))

      expect { library.pack("gone", cwd: "/work/app") }.to raise_error(Workspace::Error) { |e|
        expect(e.code).to eq("library_source_missing")
        expect(e.details).to eq("ref" => "play/gone", "path" => global.path_for("play", "gone"))
      }
    end
  end

  describe "#copyable" do
    let(:global) { library.global_store }
    let(:project) { library.project_store("app") }

    before do
      resolve_cwd_to("app")
      global.write("agent", "reviewer", "global\n")
      global.write("skill", "tests", "# Tests\n")
      global.write("play", "tests", "# A play\n")
    end

    it "resolves a bare name in the flag's kind, project before global" do
      project.write("agent", "reviewer", "project\n")

      expect(library.copyable("agent", "reviewer", cwd: "/work/app")).to eq("ref" => "agent/reviewer", "kind" => "agent",
        "name" => "reviewer", "scope" => "project", "path" => project.path_for("agent", "reviewer"))
      expect(library.copyable("skill", "tests", cwd: "/work/app")).to include("ref" => "skill/tests",
        "path" => global.path_for("skill", "tests"))
      expect(library.copyable("skill", "skill/tests", cwd: nil)).to include("scope" => "global")
    end

    it "refuses an entry of another kind as usage" do
      expect { library.copyable("agent", "play/tests", cwd: "/work/app") }
        .to raise_error(Workspace::UsageError, /--agent takes an agent, and 'play\/tests' is a play/)
      expect { library.copyable("play", "tests", cwd: "/work/app") }.to raise_error(ArgumentError)
    end

    it "fails an unknown name with unknown_library_entry" do
      expect { library.copyable("skill", "nope", cwd: "/work/app") }.to raise_error(Workspace::Error) { |e|
        expect(e.code).to eq("unknown_library_entry")
        expect(e.details).to eq("ref" => "skill/nope", "scopes" => ["project:app", "global"])
      }
    end

    it "never copies from the built-in store, which holds plays only" do
      library.builtin_store.write("agent", "shipped", "built-in\n")

      expect { library.copyable("agent", "shipped", cwd: "/work/app") }.to raise_error(Workspace::Error) { |e|
        expect(e.code).to eq("unknown_library_entry")
        expect(e.details["scopes"]).to eq(["project:app", "global"])
      }
    end

    it "fails an entry whose link target is gone with library_source_missing" do
      global.link("skill", "gone", File.join(@dir, "evicted"))

      expect { library.copyable("skill", "gone", cwd: "/work/app") }.to raise_error(Workspace::Error) { |e|
        expect(e.code).to eq("library_source_missing")
        expect(e.details).to eq("ref" => "skill/gone", "path" => global.path_for("skill", "gone"))
      }
    end
  end
end
