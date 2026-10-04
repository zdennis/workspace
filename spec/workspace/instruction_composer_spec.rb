require "spec_helper"
require "tmpdir"
require "digest"

RSpec.describe Workspace::InstructionComposer do
  around do |example|
    Dir.mktmpdir("composer") do |dir|
      @dir = dir
      example.run
    end
  end

  let(:builtin_dir) { File.join(@dir, "builtin") }
  let(:config) { instance_double(Workspace::Config, library_dir: File.join(@dir, "library"), builtin_library_dir: builtin_dir) }
  let(:lineage) { instance_double(Workspace::WorkspaceLineage) }
  let(:project_config) { instance_double(Workspace::ProjectConfig) }
  let(:library) { Workspace::Library.new(config: config, lineage: lineage, project_config: project_config) }
  let(:project_settings) { instance_double(Workspace::ProjectSettings, load: {}) }
  let(:commands_config) { Workspace::CommandsConfig.new(project_settings: project_settings) }
  let(:pane_bindings) { Workspace::PaneBindings.new(path: File.join(@dir, "bindings.json")) }
  subject(:composer) do
    described_class.new(library: library, lineage: lineage, commands_config: commands_config, pane_bindings: pane_bindings)
  end

  before do
    allow(project_config).to receive(:exists?) { |name| name == "app" }
    allow(lineage).to receive(:resolve).with(cwd: "/work/app").and_return(Workspace::WorkspaceLineage::Lineage.new(name: "app"))
    library.builtin_store.write("play", "binding", "---\ndescription: Bound panes\n---\nRead your instructions file.\n")
    library.builtin_store.write("play", "orchestrator", "---\ndescription: Delegate\n---\nDelegate the work.\n\n- Small tasks.\n")
    library.builtin_store.write("play", "commits", "Run the tests before committing.\n")
    library.builtin_store.write("play", "review", "Review the diff.\n")
  end

  it "composes the default packs in order, each under a heading naming where it came from, without frontmatter" do
    result = composer.compose(cwd: "/work/app", packs: described_class::DEFAULT_PACKS)

    expect(result["text"]).to eq(<<~TEXT)
      ## From pack binding (built-in)

      Read your instructions file.

      ## From pack orchestrator (built-in)

      Delegate the work.

      - Small tasks.

      ## From pack commits (built-in)

      Run the tests before committing.
    TEXT
    expect(result["packs"]).to eq([
      {"ref" => "play/binding", "scope" => "builtin", "project" => nil, "path" => library.builtin_store.path_for("play", "binding"),
       "sha256" => Digest::SHA256.hexdigest("---\ndescription: Bound panes\n---\nRead your instructions file.\n")},
      {"ref" => "play/orchestrator", "scope" => "builtin", "project" => nil, "path" => library.builtin_store.path_for("play", "orchestrator"),
       "sha256" => Digest::SHA256.hexdigest("---\ndescription: Delegate\n---\nDelegate the work.\n\n- Small tasks.\n")},
      {"ref" => "play/commits", "scope" => "builtin", "project" => nil, "path" => library.builtin_store.path_for("play", "commits"),
       "sha256" => Digest::SHA256.hexdigest("Run the tests before committing.\n")}
    ])
  end

  it "composes the packs named, in the order given, a repeated name once" do
    result = composer.compose(cwd: "/work/app", packs: %w[review play/orchestrator review])

    expect(result["packs"].map { |p| p["ref"] }).to eq(%w[play/review play/orchestrator])
    expect(result["text"]).to eq("## From pack review (built-in)\n\nReview the diff.\n\n## From pack orchestrator (built-in)\n\nDelegate the work.\n\n- Small tasks.\n")
  end

  it "takes a project or global play as a pack and says which library it came from" do
    library.global_store.write("play", "house-rules", "# House rules\n\nNo force pushes.\n")
    library.project_store("app").write("play", "app-rules", "Use the staging database.\n")

    result = composer.compose(cwd: "/work/app", packs: %w[house-rules app-rules])

    expect(result["text"]).to eq("## From pack house-rules (global)\n\n# House rules\n\nNo force pushes.\n\n" \
      "## From pack app-rules (project app)\n\nUse the staging database.\n")
    expect(result["packs"].map { |p| p.values_at("scope", "project") }).to eq([["global", nil], ["project", "app"]])
  end

  it "keeps the built-in pack when a global or project play has its name" do
    library.global_store.write("play", "review", "My own review.\n")
    library.project_store("app").write("play", "commits", "My own commits.\n")

    result = composer.compose(cwd: "/work/app", packs: %w[review commits])

    expect(result["packs"].map { |p| p["scope"] }).to eq(%w[builtin builtin])
    expect(result["text"]).to include("Review the diff.").and include("Run the tests before committing.")
    expect(result["text"]).not_to include("My own")
  end

  it "follows the binding pack with the pane's binding, as the SessionStart hook words it" do
    binding = {"kind" => "run", "id" => "wr_1", "workspace" => "app", "step" => "plan", "attempt" => 2,
               "instructions" => "/runs/wr_1/plan.md", "artifacts" => "/runs/wr_1"}

    result = composer.compose(cwd: "/work/app", packs: %w[binding review], binding: binding)

    expect(result["text"]).to eq(<<~TEXT)
      ## From pack binding (built-in)

      Read your instructions file.

      This pane's binding:

      This pane is bound to workflow run wr_1 in app.
      Step: plan (attempt 2).
      Instructions: /runs/wr_1/plan.md. Reread them if your context was compacted.
      Artifacts: /runs/wr_1.

      ## From pack review (built-in)

      Review the diff.
    TEXT
  end

  it "words a play binding as a play, and adds no binding when the binding pack is not composed" do
    binding = {"kind" => "play", "id" => "play/kickoff", "workspace" => "app", "instructions" => "/lib/kickoff.md"}

    expect(composer.compose(cwd: "/work/app", packs: %w[binding], binding: binding)["text"])
      .to include("This pane's binding:\n\nThis pane is following play play/kickoff in app.\nInstructions: /lib/kickoff.md.")
    expect(composer.compose(cwd: "/work/app", packs: %w[review], binding: binding)["text"]).to eq("## From pack review (built-in)\n\nReview the diff.\n")
  end

  it "follows the commits pack with the project's test and lint commands, read from its parent project" do
    allow(lineage).to receive(:resolve).with(cwd: "/work/app/.worktrees/fix").and_return(Workspace::WorkspaceLineage::Lineage.new(name: "app"))
    allow(project_settings).to receive(:load).with("app").and_return("commands" => {"test" => "bundle exec rspec", "lint" => "bundle exec standardrb"})

    result = composer.compose(cwd: "/work/app/.worktrees/fix", packs: %w[commits])

    expect(result["text"]).to eq(<<~TEXT)
      ## From pack commits (built-in)

      Run the tests before committing.

      Test command for this project: `bundle exec rspec`
      Lint command for this project: `bundle exec standardrb`
    TEXT
  end

  it "names only the command that is set" do
    allow(project_settings).to receive(:load).with("app").and_return("commands" => {"lint" => "npm run lint"})

    expect(composer.compose(cwd: "/work/app", packs: %w[commits])["text"])
      .to eq("## From pack commits (built-in)\n\nRun the tests before committing.\n\nLint command for this project: `npm run lint`\n")
  end

  it "fences a command that holds backticks, and puts a command of several lines in a block" do
    allow(project_settings).to receive(:load).with("app")
      .and_return("commands" => {"test" => "rspec `git diff --name-only`", "lint" => "cd web &&\nnpm run lint"})

    expect(composer.compose(cwd: "/work/app", packs: %w[commits])["text"]).to eq(<<~TEXT)
      ## From pack commits (built-in)

      Run the tests before committing.

      Test command for this project: `` rspec `git diff --name-only` ``

      Lint command for this project:

      ```sh
      cd web &&
      npm run lint
      ```
    TEXT
  end

  it "uses a block fence longer than a run of backticks inside the command" do
    allow(project_settings).to receive(:load).with("app").and_return("commands" => {"test" => "cat <<EOF\n```\nEOF"})

    expect(composer.compose(cwd: "/work/app", packs: %w[commits])["text"]).to include("````sh\ncat <<EOF\n```\nEOF\n````\n")
  end

  it "strips only a frontmatter block of key: value lines, and an empty one" do
    library.global_store.write("play", "ruled", "---\nA rule opened this play.\n\n---\nAnd text follows.\n")
    library.global_store.write("play", "empty-front", "---\n---\nBody.\n")
    library.global_store.write("play", "folded", "---\ndescription: >\n  Folded over\n  two lines\ntags: [a]\n\n---\nBody.\n")

    text = composer.compose(cwd: "/work/app", packs: %w[ruled empty-front folded])["text"]

    expect(text).to eq("## From pack ruled (global)\n\n---\nA rule opened this play.\n\n---\nAnd text follows.\n\n" \
      "## From pack empty-front (global)\n\nBody.\n\n## From pack folded (global)\n\nBody.\n")
  end

  it "adds generated lines to the built-in packs only, never to a play that merely has the name" do
    FileUtils.rm(library.builtin_store.path_for("play", "commits"))
    FileUtils.rm(library.builtin_store.path_for("play", "binding"))
    library.global_store.write("play", "commits", "My commit rules.\n")
    library.global_store.write("play", "binding", "My binding rules.\n")
    allow(project_settings).to receive(:load).with("app").and_return("commands" => {"test" => "bin/test"})

    text = composer.compose(cwd: "/work/app", packs: %w[commits binding], binding: {"kind" => "run", "id" => "wr_1"})["text"]

    expect(text).to eq("## From pack commits (global)\n\nMy commit rules.\n\n## From pack binding (global)\n\nMy binding rules.\n")
  end

  it "reads no project config when the commits pack is not composed" do
    composer.compose(cwd: "/work/app", packs: %w[review])

    expect(project_settings).not_to have_received(:load)
  end

  it "fails an unknown pack, a pack of another kind, and one that can't be read, composing nothing" do
    library.global_store.write("prompt", "kickoff", "Go.\n")
    library.global_store.link("play", "gone", File.join(@dir, "evicted.md"))

    expect { composer.compose(cwd: "/work/app", packs: %w[review nope]) }.to raise_error(Workspace::Error) { |e|
      expect(e.code).to eq("unknown_library_entry")
      expect(e.details).to eq("ref" => "play/nope", "scopes" => ["builtin", "project:app", "global"])
    }
    expect { composer.compose(cwd: "/work/app", packs: %w[prompt/kickoff]) }.to raise_error(Workspace::UsageError, /--pack takes a play/)
    expect { composer.compose(cwd: "/work/app", packs: %w[Bad_Name]) }.to raise_error(Workspace::UsageError, /not a valid library name/)
    expect { composer.compose(cwd: "/work/app", packs: %w[gone]) }.to raise_error(Workspace::Error) { |e| expect(e.code).to eq("library_source_missing") }
  end

  it "lets a project config that can't be parsed stop the commits pack" do
    allow(project_settings).to receive(:load).with("app").and_raise(Workspace::ConfigParseError.new("/c/app.yml", "bad yaml"))

    expect { composer.compose(cwd: "/work/app", packs: %w[commits]) }.to raise_error(Workspace::ConfigParseError)
  end
end

RSpec.describe Workspace::InstructionComposer, "with the packs workspace ships" do
  let(:builtin_dir) { Workspace::Config.new.builtin_library_dir }
  let(:config) { instance_double(Workspace::Config, library_dir: "/nonexistent/library", builtin_library_dir: builtin_dir) }
  let(:lineage) { instance_double(Workspace::WorkspaceLineage, resolve: Workspace::WorkspaceLineage::Lineage.new(name: "app")) }
  let(:project_config) { instance_double(Workspace::ProjectConfig, exists?: false) }
  let(:library) { Workspace::Library.new(config: config, lineage: lineage, project_config: project_config) }
  let(:commands_config) { Workspace::CommandsConfig.new(project_settings: instance_double(Workspace::ProjectSettings, load: {})) }
  subject(:composer) do
    described_class.new(library: library, lineage: lineage, commands_config: commands_config,
      pane_bindings: Workspace::PaneBindings.new(path: "/nonexistent/bindings.json"))
  end

  it "ships exactly the four packs, as plays, each readable with a description" do
    shipped = Workspace::LibraryStore.new(dir: builtin_dir, scope: "builtin")

    expect(Dir.children(builtin_dir)).to eq(["play"])
    expect(shipped.entries.map { |e| e["ref"] }).to eq(%w[play/binding play/commits play/orchestrator play/review])
    expect(shipped.entries).to all(include("readable" => true, "link" => nil, "description" => a_string_matching(/\A\S.{10,}/)))
  end

  it "composes every shipped pack with its heading and no frontmatter" do
    text = composer.compose(cwd: "/work/app", packs: %w[binding orchestrator commits review])["text"]

    expect(text.scan(/^## From pack (\S+) \(built-in\)$/).flatten).to eq(%w[binding orchestrator commits review])
    expect(text).not_to match(/^---$|^description:/)
    expect(text).to include("workspace ask").and include("`model:` on every Agent call").and include("Co-Authored-By").and include("PASS or BLOCKING")
  end

  it "composes the default packs from the shipped ones" do
    expect(described_class::DEFAULT_PACKS).to eq(%w[binding orchestrator commits])
    expect(composer.compose(cwd: "/work/app", packs: described_class::DEFAULT_PACKS)["packs"].map { |p| p["scope"] }).to eq(%w[builtin builtin builtin])
  end
end
