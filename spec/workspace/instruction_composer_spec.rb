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
  let(:project_settings) { instance_double(Workspace::ProjectSettings, load: {}, load_global: {}) }
  let(:commands_config) { Workspace::CommandsConfig.new(config_resolver: Workspace::ConfigResolver.new(project_settings: project_settings)) }
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
  describe "the layers of a workflow step" do
    let(:workflow) { {"name" => "rpiv", "include" => %w[review], "text" => "You are working on PROJ-1.\n"} }
    let(:step) { {"name" => "plan", "include" => %w[commits review], "text" => "Write plan.md.\n"} }

    it "puts the default packs first, then the workflow's packs and text, the step's packs and prompt, and the attempt's context" do
      result = composer.compose(cwd: "/work/app", packs: %w[binding], workflow: workflow, step: step,
        attempt: ["The plan step was rejected at its gate: too big.", "Note for this run: keep it small."])

      expect(result["text"]).to eq(<<~TEXT)
        ## From pack binding (built-in)

        Read your instructions file.

        ## From pack review (built-in)

        Review the diff.

        ## From workflow rpiv

        You are working on PROJ-1.

        ## From pack commits (built-in)

        Run the tests before committing.

        ## From step plan

        Write plan.md.

        ## For this attempt

        The plan step was rejected at its gate: too big.

        Note for this run: keep it small.
      TEXT
      expect(result["packs"].map { |pack| pack["ref"] }).to eq(%w[play/binding play/review play/commits])
    end

    it "composes a pack once, where it is first named, across the layers" do
      result = composer.compose(cwd: "/work/app", packs: %w[binding review], workflow: workflow.merge("include" => %w[binding]),
        step: step.merge("include" => %w[review]))

      expect(result["text"].scan(/^## From .*$/)).to eq(["## From pack binding (built-in)", "## From pack review (built-in)", "## From workflow rpiv", "## From step plan"])
    end

    it "leaves out a workflow with no instructions of its own, and an attempt with nothing to say" do
      result = composer.compose(cwd: "/work/app", packs: %w[binding], workflow: {"name" => "rpiv", "include" => [], "text" => nil},
        step: {"name" => "plan", "include" => [], "text" => "Write plan.md."}, attempt: [])

      expect(result["text"]).to eq("## From pack binding (built-in)\n\nRead your instructions file.\n\n## From step plan\n\nWrite plan.md.\n")
    end

    it "fails for a pack a layer names that doesn't exist" do
      expect { composer.compose(cwd: "/work/app", packs: %w[binding], step: step.merge("include" => %w[ghost])) }
        .to raise_error(Workspace::Error) { |error| expect(error.code).to eq("unknown_library_entry") }
    end
  end

  describe "the default packs" do
    let(:global) { {} }
    let(:settings) { instance_double(Workspace::ProjectSettings, load: {}, load_global: global) }
    subject(:composer) do
      described_class.new(library: library, lineage: lineage, commands_config: commands_config, pane_bindings: pane_bindings,
        workflow_config: Workspace::WorkflowConfig.new(config_resolver: Workspace::ConfigResolver.new(project_settings: settings)))
    end

    it "are binding, orchestrator and commits when no pack is named and workflows.defaults.include is unset" do
      expect(composer.compose(cwd: "/work/app", packs: nil)["packs"].map { |pack| pack["ref"] }).to eq(%w[play/binding play/orchestrator play/commits])
    end

    it "are the packs workflows.defaults.include names" do
      global["workflows"] = {"defaults" => {"include" => "binding, review"}}

      expect(composer.default_packs).to eq(%w[binding review])
      expect(composer.compose(cwd: "/work/app", packs: nil)["packs"].map { |pack| pack["ref"] }).to eq(%w[play/binding play/review])
    end

    it "are the built-in three for a composer with no config to read" do
      plain = described_class.new(library: library, lineage: lineage, commands_config: commands_config, pane_bindings: pane_bindings)

      expect(plain.compose(cwd: "/work/app", packs: nil)["packs"].size).to eq(3)
    end
  end

  describe "#start_packs and #compose_start" do
    let(:notes_config) { Workspace::NotesConfig.new(config_resolver: Workspace::ConfigResolver.new(project_settings: project_settings)) }
    subject(:composer) do
      described_class.new(library: library, lineage: lineage, commands_config: commands_config, pane_bindings: pane_bindings, notes_config: notes_config)
    end

    before { library.builtin_store.write("play", "notes", "Notes go in the notes directory.\n") }

    it "lists the notes pack as coming from config when notes.instructions is unset" do
      expect(composer.start_packs(cwd: "/work/app")).to eq([{"name" => "notes", "source" => "config"}])
    end

    it "lists no automatic pack when notes.instructions is false, as a string or a boolean" do
      [false, "false"].each do |value|
        allow(project_settings).to receive(:load).with("app").and_return({"notes" => {"instructions" => value}})
        expect(composer.start_packs(cwd: "/work/app")).to eq([])
      end
    end

    it "keeps the notes pack when notes.instructions is true" do
      allow(project_settings).to receive(:load).with("app").and_return({"notes" => {"instructions" => "true"}})

      expect(composer.start_packs(cwd: "/work/app")).to eq([{"name" => "notes", "source" => "config"}])
    end

    it "adds --pack names after the automatic ones, once each, with the play/ prefix dropped" do
      packs = composer.start_packs(cwd: "/work/app", packs: %w[review play/notes review])

      expect(packs).to eq([{"name" => "notes", "source" => "config"}, {"name" => "review", "source" => "flag"}])
    end

    it "drops the automatic packs with none: true, and refuses it beside named packs" do
      expect(composer.start_packs(cwd: "/work/app", none: true)).to eq([])
      expect(composer.start_packs(cwd: "/work/app", packs: %w[review], none: false).map { |p| p["name"] }).to eq(%w[notes review])
      expect { composer.start_packs(cwd: "/work/app", packs: %w[review], none: true) }.to raise_error(Workspace::UsageError, /--no-packs cannot be combined with --pack/)
    end

    it "adds no automatic pack when no notes config is wired" do
      bare = described_class.new(library: library, lineage: lineage, commands_config: commands_config, pane_bindings: pane_bindings)

      expect(bare.start_packs(cwd: "/work/app")).to eq([])
    end

    it "composes the packs under their headings and marks each with its source" do
      result = composer.compose_start(cwd: "/work/app", packs: %w[review])

      expect(result["text"]).to eq("## From pack notes (built-in)\n\nNotes go in the notes directory.\n\n## From pack review (built-in)\n\nReview the diff.\n")
      expect(result["packs"].map { |p| [p["ref"], p["source"]] }).to eq([["play/notes", "config"], ["play/review", "flag"]])
    end

    it "has no text and no packs when none applies" do
      expect(composer.compose_start(cwd: "/work/app", none: true)).to eq("packs" => [], "text" => nil, "skipped" => [])
    end

    it "fails with unknown_library_entry for a pack that does not exist" do
      expect { composer.compose_start(cwd: "/work/app", packs: %w[nope]) }.to raise_error(Workspace::Error) { |e| expect(e.code).to eq("unknown_library_entry") }
    end

    it "builds the rows start --json and launch --json report" do
      packs = composer.compose_start(cwd: "/work/app", packs: %w[review])["packs"]

      expect(described_class.delivery_rows(packs, delivered: true, pane: "%4")).to eq([
        {"name" => "notes", "source" => "config", "delivered" => true, "pane" => "%4"},
        {"name" => "review", "source" => "flag", "delivered" => true, "pane" => "%4"}
      ])
    end

    describe "the spine pack" do
      let(:spine) { instance_double(Workspace::Commands::Spine) }
      subject(:composer) do
        described_class.new(library: library, lineage: lineage, commands_config: commands_config, pane_bindings: pane_bindings,
          notes_config: notes_config, dev_config: dev_config, spine: spine)
      end
      let(:dev_config) { Workspace::DevConfig.new(config_resolver: Workspace::ConfigResolver.new(project_settings: project_settings)) }

      before { library.builtin_store.write("play", "spine", "Keep the spine current.\n") }

      it "comes from config, after notes, when the workspace has a spine/" do
        allow(spine).to receive(:exists?).with(name: "app").and_return(true)

        expect(composer.start_packs(cwd: "/work/app")).to eq([{"name" => "notes", "source" => "config"}, {"name" => "spine", "source" => "config"}])
        expect(composer.compose_start(cwd: "/work/app")["packs"].map { |p| [p["ref"], p["scope"], p["source"]] })
          .to eq([["play/notes", "builtin", "config"], ["play/spine", "builtin", "config"]])
      end

      it "sits between notes and dev" do
        library.builtin_store.write("play", "dev", "Queue.\n")
        allow(spine).to receive(:exists?).and_return(true)
        allow(project_settings).to receive(:load).with("app").and_return({"dev" => {"up" => "./start-dev"}})

        expect(composer.start_packs(cwd: "/work/app").map { |p| p["name"] }).to eq(%w[notes spine dev])
      end

      it "is not listed without a spine/, and not with --no-packs" do
        allow(spine).to receive(:exists?).and_return(false)
        expect(composer.start_packs(cwd: "/work/app").map { |p| p["name"] }).to eq(%w[notes])

        allow(spine).to receive(:exists?).and_return(true)
        expect(composer.start_packs(cwd: "/work/app", none: true)).to eq([])
      end

      it "is kept when notes.instructions is false, and listed once when also named with --pack" do
        allow(spine).to receive(:exists?).and_return(true)
        allow(project_settings).to receive(:load).with("app").and_return({"notes" => {"instructions" => "false"}})

        expect(composer.start_packs(cwd: "/work/app").map { |p| p["name"] }).to eq(%w[spine])
        expect(composer.start_packs(cwd: "/work/app", packs: %w[play/spine]).map { |p| [p["name"], p["source"]] }).to eq([["spine", "config"]])
      end

      it "is not added when no spine was wired" do
        expect(described_class.new(library: library, lineage: lineage, commands_config: commands_config, pane_bindings: pane_bindings,
          notes_config: notes_config).start_packs(cwd: "/work/app").map { |p| p["name"] }).to eq(%w[notes])
      end

      it "is bound with the other delivered packs, so SessionStart repeats it" do
        allow(spine).to receive(:exists?).and_return(true)
        names = Workspace::InstructionComposer.pack_names(composer.compose_start(cwd: "/work/app")["packs"])

        expect(library.packs_binding(names)).to include("packs" => %w[notes spine])
      end
    end

    describe "the dev pack" do
      let(:dev_config) { Workspace::DevConfig.new(config_resolver: Workspace::ConfigResolver.new(project_settings: project_settings)) }
      subject(:composer) do
        described_class.new(library: library, lineage: lineage, commands_config: commands_config, pane_bindings: pane_bindings,
          notes_config: notes_config, dev_config: dev_config)
      end

      def dev(block)
        allow(project_settings).to receive(:load).with("app").and_return({"dev" => block})
      end

      before { library.builtin_store.write("play", "dev", "Queue for the dev environment.\n") }

      it "is not sent when the project has no dev.up" do
        expect(composer.start_packs(cwd: "/work/app").map { |p| p["name"] }).to eq(%w[notes])
        dev("ready" => "port:3000")
        expect(composer.start_packs(cwd: "/work/app").map { |p| p["name"] }).to eq(%w[notes])
      end

      it "comes from config, after notes, when dev.up is set" do
        dev("up" => "./start-dev")

        expect(composer.start_packs(cwd: "/work/app")).to eq([{"name" => "notes", "source" => "config"}, {"name" => "dev", "source" => "config"}])
      end

      it "is left out when dev.instructions is false, and kept when notes.instructions is false" do
        dev("up" => "./start-dev", "instructions" => "false")
        expect(composer.start_packs(cwd: "/work/app").map { |p| p["name"] }).to eq(%w[notes])
        allow(project_settings).to receive(:load).with("app").and_return({"dev" => {"up" => "./start-dev"}, "notes" => {"instructions" => "false"}})
        expect(composer.start_packs(cwd: "/work/app").map { |p| p["name"] }).to eq(%w[dev])
      end

      it "is dropped by none: true, and named once when --pack also names it (the config source wins)" do
        dev("up" => "./start-dev")

        expect(composer.start_packs(cwd: "/work/app", none: true)).to eq([])
        expect(composer.start_packs(cwd: "/work/app", packs: %w[play/dev review])).to eq([
          {"name" => "notes", "source" => "config"}, {"name" => "dev", "source" => "config"}, {"name" => "review", "source" => "flag"}
        ])
      end

      it "is composed and reported like the other packs" do
        dev("up" => "./start-dev")
        result = composer.compose_start(cwd: "/work/app")

        expect(result["text"]).to include("## From pack dev (built-in)\n\nQueue for the dev environment.")
        expect(described_class.delivery_rows(result["packs"], delivered: true, pane: "%4").map { |r| r["name"] }).to eq(%w[notes dev])
        expect(result["skipped"]).to eq([])
      end

      it "adds no dev pack when no dev config is wired" do
        dev("up" => "./start-dev")
        bare = described_class.new(library: library, lineage: lineage, commands_config: commands_config, pane_bindings: pane_bindings, notes_config: notes_config)

        expect(bare.start_packs(cwd: "/work/app").map { |p| p["name"] }).to eq(%w[notes])
      end

      it "is left out of #compose by skip:, however the pack is named" do
        result = composer.compose(cwd: "/work/app", packs: %w[review play/dev dev commits], skip: %w[dev])

        expect(result["packs"].map { |p| p["ref"] }).to eq(%w[play/review play/commits])
        expect(result["text"]).not_to include("dev environment")
      end

      it "composes dev when nothing is skipped" do
        expect(composer.compose(cwd: "/work/app", packs: %w[dev])["packs"].map { |p| p["ref"] }).to eq(%w[play/dev])
      end
    end

    describe "the handoff pack" do
      let(:handoff_config) { Workspace::HandoffConfig.new(config_resolver: Workspace::ConfigResolver.new(project_settings: project_settings), error_output: StringIO.new) }
      let(:main_agent) { instance_double(Workspace::MainAgent, kind: "claude") }
      subject(:composer) do
        described_class.new(library: library, lineage: lineage, commands_config: commands_config, pane_bindings: pane_bindings,
          notes_config: notes_config, handoff_config: handoff_config, main_agent: main_agent)
      end

      def auto(value)
        allow(project_settings).to receive(:load).with("app").and_return({"handoff" => {"auto" => value}})
      end

      before { library.builtin_store.write("play", "handoff", "Run the check after every task.\n") }

      it "is not sent when handoff.auto is unset or false" do
        expect(composer.start_packs(cwd: "/work/app").map { |p| p["name"] }).to eq(%w[notes])
        auto("false")
        expect(composer.start_packs(cwd: "/work/app").map { |p| p["name"] }).to eq(%w[notes])
      end

      it "comes from config, after notes, when handoff.auto is true and the main agent is Claude Code" do
        auto("true")

        expect(composer.start_packs(cwd: "/work/app")).to eq([{"name" => "notes", "source" => "config"}, {"name" => "handoff", "source" => "config"}])
      end

      it "reads the worktree's own value over the parent project's, and the parent's when the worktree sets none, with no lineage wired into HandoffConfig" do
        allow(lineage).to receive(:resolve).with(cwd: "/work/app/.worktrees/fix")
          .and_return(Workspace::WorkspaceLineage::Lineage.new(name: "app", worktree: "app.worktree-fix", is_worktree: true))
        allow(project_settings).to receive(:load).with("app").and_return({"handoff" => {"auto" => "true"}})
        allow(project_settings).to receive(:load).with("app.worktree-fix").and_return({"handoff" => {"auto" => "false"}, "notes" => {"instructions" => false}})
        expect(composer.start_packs(cwd: "/work/app/.worktrees/fix").map { |p| p["name"] }).to eq([])

        allow(project_settings).to receive(:load).with("app.worktree-fix").and_return({"notes" => {"instructions" => false}})
        expect(composer.start_packs(cwd: "/work/app/.worktrees/fix").map { |p| p["name"] }).to eq(%w[handoff])
      end

      it "comes from the flag with handoff: true, whatever the key says, and is left out with handoff: false" do
        expect(composer.start_packs(cwd: "/work/app", handoff: true)).to eq([{"name" => "notes", "source" => "config"}, {"name" => "handoff", "source" => "flag"}])
        auto("true")
        expect(composer.start_packs(cwd: "/work/app", handoff: false).map { |p| p["name"] }).to eq(%w[notes])
      end

      it "is dropped by none: true unless the flag asks for it, which is a usage error" do
        auto("true")

        expect(composer.start_packs(cwd: "/work/app", none: true)).to eq([])
        expect { composer.start_packs(cwd: "/work/app", none: true, handoff: true) }.to raise_error(Workspace::UsageError, /--no-packs cannot be combined with --handoff/)
        expect(composer.start_packs(cwd: "/work/app", none: true, handoff: false)).to eq([])
      end

      it "is skipped with a reason and a warning when the config asks for it and the main agent is not Claude Code" do
        auto("true")
        allow(main_agent).to receive(:kind).with("app").and_return("opencode")

        result = composer.compose_start(cwd: "/work/app")

        expect(result["packs"].map { |p| p["ref"] }).to eq(%w[play/notes])
        expect(result["skipped"]).to eq([{"name" => "handoff", "source" => "config", "reason" => "handoff_unsupported_agent",
                                          "message" => "the handoff pack was not sent to app: handoff.auto is on, but its main agent is opencode and the pack needs Claude Code or Codex"}])
      end

      it "is sent when the main agent is Codex, from the config and from the flag" do
        allow(main_agent).to receive(:kind).with("app").and_return("codex")
        auto("true")

        expect(composer.start_packs(cwd: "/work/app").map { |p| [p["name"], p["source"]] }).to eq([%w[notes config], %w[handoff config]])
        expect(composer.start_packs(cwd: "/work/app", handoff: true).last).to eq("name" => "handoff", "source" => "flag")
        expect(composer.compose_start(cwd: "/work/app")["skipped"]).to eq([])
      end

      it "judges the agent kind a new workspace is given, not the project's" do
        allow(main_agent).to receive(:kind).with("app").and_return("opencode")
        auto("true")

        expect(composer.start_packs(cwd: "/work/app", agent_kind: "codex").map { |p| p["name"] }).to eq(%w[notes handoff])
        expect(composer.compose_start(cwd: "/work/app", agent_kind: "pi")["skipped"].first["reason"]).to eq("handoff_unsupported_agent")
        expect { composer.start_packs(cwd: "/work/app", handoff: true, agent_kind: "pi") }.to raise_error(Workspace::Error) { |e|
          expect(e.details).to eq("kind" => "pi")
        }
      end

      it "describes a project that runs no known agent as such" do
        auto("true")
        allow(main_agent).to receive(:kind).and_return("none")

        expect(composer.compose_start(cwd: "/work/app")["skipped"].first["message"]).to include("runs no coding agent")
      end

      it "is refused with handoff_unsupported_agent and the agent kind when the flag asks for it" do
        allow(main_agent).to receive(:kind).with("app").and_return("opencode")

        expect { composer.compose_start(cwd: "/work/app", handoff: true) }.to raise_error(Workspace::Error) { |e|
          expect(e.code).to eq("handoff_unsupported_agent")
          expect(e.details).to eq("kind" => "opencode")
        }
      end

      it "composes the handoff text under its heading and marks it with its source" do
        result = composer.compose_start(cwd: "/work/app", handoff: true)

        expect(result["text"]).to include("## From pack handoff (built-in)\n\nRun the check after every task.")
        expect(result["packs"].map { |p| [p["ref"], p["source"]] }).to eq([["play/notes", "config"], ["play/handoff", "flag"]])
      end

      it "adds a skipped row beside the delivered ones" do
        auto("true")
        allow(main_agent).to receive(:kind).and_return("opencode")
        result = composer.compose_start(cwd: "/work/app")

        expect(described_class.delivery_rows(result["packs"], delivered: true, pane: "%4", skipped: result["skipped"])).to eq([
          {"name" => "notes", "source" => "config", "delivered" => true, "pane" => "%4"},
          {"name" => "handoff", "source" => "config", "delivered" => false, "pane" => nil, "reason" => "handoff_unsupported_agent"}
        ])
      end

      it "treats a flag-sourced handoff pack as required, so a failed send is an error" do
        result = composer.compose_start(cwd: "/work/app", handoff: true)

        expect(described_class.optional_prompt?(result, prompt: nil, play: nil)).to be(false)
      end

      it "refuses the flag when no handoff config or main agent was wired, and adds nothing from config" do
        bare = described_class.new(library: library, lineage: lineage, commands_config: commands_config, pane_bindings: pane_bindings, notes_config: notes_config)

        expect { bare.start_packs(cwd: "/work/app", handoff: true) }.to raise_error(Workspace::Error, /--handoff is not available/)
        expect(bare.start_packs(cwd: "/work/app").map { |p| p["name"] }).to eq(%w[notes])
      end
    end
  end
end

RSpec.describe Workspace::InstructionComposer, "with the packs workspace ships" do
  let(:builtin_dir) { Workspace::Config.new.builtin_library_dir }
  let(:config) { instance_double(Workspace::Config, library_dir: "/nonexistent/library", builtin_library_dir: builtin_dir) }
  let(:lineage) { instance_double(Workspace::WorkspaceLineage, resolve: Workspace::WorkspaceLineage::Lineage.new(name: "app")) }
  let(:project_config) { instance_double(Workspace::ProjectConfig, exists?: false) }
  let(:library) { Workspace::Library.new(config: config, lineage: lineage, project_config: project_config) }
  let(:commands_config) { Workspace::CommandsConfig.new(config_resolver: Workspace::ConfigResolver.new(project_settings: instance_double(Workspace::ProjectSettings, load: {}, load_global: {}))) }
  subject(:composer) do
    described_class.new(library: library, lineage: lineage, commands_config: commands_config,
      pane_bindings: Workspace::PaneBindings.new(path: "/nonexistent/bindings.json"))
  end

  it "ships exactly the ten packs, as plays, each readable with a description" do
    shipped = Workspace::LibraryStore.new(dir: builtin_dir, scope: "builtin")

    expect(Dir.children(builtin_dir).sort).to eq(%w[play spine])
    plays = shipped.entries(kind: "play")
    expect(plays.map { |e| e["ref"] }).to eq(%w[play/binding play/commits play/dev play/handoff play/implementation-plan play/notes play/orchestrator play/research play/review play/spine])
    expect(plays).to all(include("readable" => true, "link" => nil, "description" => a_string_matching(/\A\S.{10,}/)))
  end

  it "composes the research pack by name: findings note in the notes directory, no repository changes" do
    result = composer.compose(cwd: "/work/app", packs: %w[research])

    expect(result["packs"].map { |p| [p["ref"], p["scope"]] }).to eq([["play/research", "builtin"]])
    expect(result["text"]).to include("`workspace notes dir --create`").and include("-findings.md").and include("do not commit")
  end

  it "composes the notes pack by name, telling the agent to ask workspace for the directory and never to commit it" do
    result = composer.compose(cwd: "/work/app", packs: %w[notes])

    expect(result["packs"].map { |p| [p["ref"], p["scope"]] }).to eq([["play/notes", "builtin"]])
    expect(result["text"]).to start_with("## From pack notes (built-in)\n\nKeep your working notes in this workspace's notes directory")
    expect(result["text"]).to include("`workspace notes dir --create`").and include("`IMPLEMENTATION_PLAN.md`").and include("Never commit the notes.")
    expect(result["text"]).not_to match(/^---$|^description:/)
  end

  it "composes the spine pack by name: spine set for each change, the stage's own files only, nothing marked done unchecked" do
    result = composer.compose(cwd: "/work/app", packs: %w[spine])

    expect(result["packs"].map { |p| [p["ref"], p["scope"]] }).to eq([["play/spine", "builtin"]])
    expect(result["text"]).to start_with("## From pack spine (built-in)\n\nThis workspace has a plan spine")
    expect(result["text"]).to include("`workspace notes dir`", "workspace spine set <stage-path> --status in_progress",
      '--status blocked --note "<why, one line>"', "## Done when", "--status completed", "`gates`", "`depends_on`", "`artifacts:`")
    expect(result["text"]).not_to match(/^---$|^description:/)
  end

  it "composes the dev pack by name, with the real exit codes of dev wait and the commands that release the environment" do
    text = composer.compose(cwd: "/work/app", packs: %w[dev])["text"]

    expect(text).to start_with("## From pack dev (built-in)\n\nThis project has one dev environment")
    expect(text).not_to match(/^---$|^description:/)
    expect(text).to include("`workspace dev up --queue`", "`workspace dev wait --max-wait 90s`", "`workspace dev status`", "`workspace dev leave`", "`workspace dev down`", "`--force`")
    expect(text.scan(/^- (\d+):/).flatten).to eq(%w[0 75 1 4 6])
  end

  it "composes every shipped pack with its heading and no frontmatter" do
    text = composer.compose(cwd: "/work/app", packs: %w[binding orchestrator commits review])["text"]

    expect(text.scan(/^## From pack (\S+) \(built-in\)$/).flatten).to eq(%w[binding orchestrator commits review])
    expect(text).not_to match(/^---$|^description:/)
    expect(text).to include("workspace ask").and include("`model:` on every Agent call").and include("Co-Authored-By").and include("PASS or BLOCKING")
  end

  it "tells an agent in a workflow run about `step status` and `step done`, in the binding pack" do
    text = composer.compose(cwd: "/work/app", packs: %w[binding])["text"]

    expect(text).to include("`workspace step status`").and include("`workspace step done --status fail --summary")
  end

  it "composes the default packs from the shipped ones" do
    expect(described_class::DEFAULT_PACKS).to eq(%w[binding orchestrator commits])
    expect(composer.compose(cwd: "/work/app", packs: described_class::DEFAULT_PACKS)["packs"].map { |p| p["scope"] }).to eq(%w[builtin builtin builtin])
  end
end
