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

  it "composes the default packs when none is named" do
    allow(composer).to receive(:compose).and_return(result)

    command.compose(packs: [], cwd: "/work/app")

    expect(composer).to have_received(:compose).with(packs: %w[binding orchestrator commits], cwd: "/work/app", binding: nil)
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
end
