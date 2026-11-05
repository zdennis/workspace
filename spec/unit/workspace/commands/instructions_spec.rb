require "spec_helper"
require "stringio"
require "json"

RSpec.describe Workspace::Commands::Instructions do
  let(:composer) { instance_double(Workspace::InstructionComposer) }
  let(:bindings) { instance_double(Workspace::Commands::Binding) }
  let(:output) { StringIO.new }
  let(:packs) { [{"ref" => "play/orchestrator", "scope" => "builtin", "project" => nil, "path" => "/lib/play/orchestrator.md", "sha256" => "abc"}] }
  let(:result) { {"packs" => packs, "text" => "## From pack orchestrator (built-in)\n\nDelegate.\n"} }
  subject(:command) { described_class.new(composer: composer, bindings: bindings, output: output) }

  it "prints the composed text as it is" do
    allow(composer).to receive(:compose).with(packs: %w[orchestrator], cwd: "/work/app", binding: nil).and_return(result)

    command.compose(packs: %w[orchestrator], cwd: "/work/app")

    expect(output.string).to eq("## From pack orchestrator (built-in)\n\nDelegate.\n")
  end

  it "leaves the choice of packs to the composer when none is named" do
    allow(composer).to receive(:compose).and_return(result)

    command.compose(packs: [], cwd: "/work/app")

    expect(composer).to have_received(:compose).with(packs: nil, cwd: "/work/app", binding: nil)
  end

  it "hands the composer the pane's live binding, and none for a pane that is unbound or stale" do
    entry = {"kind" => "run", "id" => "wr_1", "pane_id" => "%5"}
    allow(bindings).to receive(:live).with(pane: "%5").and_return(entry)
    allow(bindings).to receive(:live).with(pane: "%6").and_return(nil)
    allow(composer).to receive(:compose).and_return(result)

    command.compose(packs: %w[binding], cwd: "/work/app", pane: "%5")
    command.compose(packs: %w[binding], cwd: "/work/app", pane: "%6")

    expect(composer).to have_received(:compose).with(packs: %w[binding], cwd: "/work/app", binding: entry).ordered
    expect(composer).to have_received(:compose).with(packs: %w[binding], cwd: "/work/app", binding: nil).ordered
  end

  it "prints one JSON document with the packs, the binding used and the text" do
    entry = {"kind" => "run", "id" => "wr_1", "pane_id" => "%5"}
    allow(bindings).to receive(:live).with(pane: "%5").and_return(entry)
    allow(composer).to receive(:compose).and_return(result)

    command.compose(packs: %w[orchestrator], cwd: "/work/app", pane: "%5", json: true)

    expect(output.string.lines.size).to eq(1)
    expect(JSON.parse(output.string)).to eq("schema_version" => 1, "ok" => true, "packs" => packs, "binding" => entry,
      "text" => "## From pack orchestrator (built-in)\n\nDelegate.\n")
    expect(JSON.parse(output.string).keys).to eq(%w[schema_version ok packs binding text])
  end

  it "reports a null binding in JSON without a pane" do
    allow(composer).to receive(:compose).and_return(result)

    command.compose(packs: [], cwd: "/work/app", json: true)

    expect(JSON.parse(output.string)).to include("binding" => nil)
  end

  it "prints nothing when a pack can't be composed" do
    allow(composer).to receive(:compose).and_raise(Workspace::Error.new("No library entry 'nope'.", code: "unknown_library_entry"))

    expect { command.compose(packs: %w[nope], cwd: "/work/app", json: true) }.to raise_error(Workspace::Error)
    expect(output.string).to be_empty
  end
  describe "compose --start" do
    let(:started) do
      {"packs" => [{"ref" => "play/notes", "scope" => "builtin", "project" => nil, "path" => "/lib/play/notes.md", "sha256" => "abc", "source" => "config"}],
       "text" => "## From pack notes (built-in)\n\nNotes.\n"}
    end

    it "prints the text start would send, and reads no binding" do
      allow(composer).to receive(:compose_start).with(cwd: "/work/app", packs: %w[review], none: false).and_return(started)

      command.compose(packs: %w[review], cwd: "/work/app", pane: "%5", start: true)

      expect(output.string).to eq("## From pack notes (built-in)\n\nNotes.\n")
      expect(bindings).not_to have_received(:live) if bindings.respond_to?(:live)
    end

    it "passes --no-packs on as none" do
      allow(composer).to receive(:compose_start).and_return("packs" => [], "text" => nil)

      command.compose(packs: [], cwd: "/work/app", start: true, no_packs: true)

      expect(composer).to have_received(:compose_start).with(cwd: "/work/app", packs: [], none: true)
      expect(output.string).to eq("")
    end

    it "keeps the document's shape and adds source to each pack" do
      allow(composer).to receive(:compose_start).and_return(started)

      command.compose(packs: [], cwd: "/work/app", start: true, json: true)

      doc = JSON.parse(output.string)
      expect(doc.keys).to eq(%w[schema_version ok packs binding text])
      expect(doc["packs"].first).to include("ref" => "play/notes", "source" => "config")
      expect(doc["binding"]).to be_nil
    end
  end
end
