require "spec_helper"

RSpec.describe Workspace::WorkflowArgv do
  describe ".split" do
    it "splits like a shell" do
      expect(described_class.split(%(check --flag "a b" 'c d'))).to eq([["check", "--flag", "a b", "c d"], nil])
    end

    it "reports an unbalanced quote" do
      expect(described_class.split(%(check "oops))).to eq([nil, "has an unbalanced quote"])
    end

    it "reports an empty string" do
      expect(described_class.split("  ")).to eq([nil, "is empty"])
    end
  end

  describe ".problems" do
    def problems(text, inputs: [])
      described_class.problems(described_class.split(text).first, inputs: inputs)
    end

    it "accepts every scalar, list and declared input" do
      text = "check {{checkout}} {{artifacts}} {{workspace}} {{branch}} {{run}} {{run.base_sha}} {{attempt.head_before}} {{inputs.mode}} -- {{changed.files}} {{changed.tests}} {{run.changed.files}}"
      expect(problems(text, inputs: ["mode"])).to eq([[], []])
    end

    it "names an unknown placeholder" do
      p, = problems("check {{nope}}")
      expect(p.first).to start_with("uses {{nope}}, which nothing supplies (known: {{checkout}}")
    end

    it "does not know an undeclared input" do
      p, = problems("check {{inputs.mode}}")
      expect(p.first).to include("{{inputs.mode}}")
    end

    it "refuses a list inside a larger word" do
      p, = problems("check -- x{{changed.files}}")
      expect(p).to eq(["uses {{changed.files}} inside the word \"x{{changed.files}}\"; a list must be an argument of its own"])
    end

    it "refuses a placeholder in the program" do
      p, = problems("{{checkout}}/bin/check")
      expect(p).to eq(["has {{checkout}} in the program (argument 1), which must be a fixed program"])
    end

    it "refuses an empty program" do
      p, = described_class.problems(["", "foo"], inputs: [])
      expect(p).to eq(["has an empty program (argument 1)"])
    end

    it "reports a placeholder with spaces as malformed" do
      p, = problems("check {{ changed.files }}")
      expect(p.size).to eq(2)
      expect(p).to all(include("malformed placeholder"))
    end

    it "accepts single braces" do
      expect(problems("check a{b}c")).to eq([[], []])
    end

    it "refuses {{run.changed.files}} inside a word" do
      p, = problems("check -- x{{run.changed.files}}y")
      expect(p).to eq(["uses {{run.changed.files}} inside the word \"x{{run.changed.files}}y\"; a list must be an argument of its own"])
    end

    it "names an unknown placeholder in the program" do
      p, = problems("{{nope}}/check")
      expect(p.first).to start_with("uses {{nope}}, which nothing supplies")
    end

    it "warns about a list with no -- before it" do
      p, w = problems("check {{changed.files}}")
      expect(p).to eq([])
      expect(w).to eq(["{{changed.files}} has no `--` argument before it, so a path starting with `-` would read as an option"])
    end

    it "does not warn when -- comes first" do
      expect(problems("check -- {{changed.files}}")).to eq([[], []])
    end
  end

  describe ".render" do
    let(:scalars) { {"checkout" => "/a b/c", "branch" => "x;y", "inputs.q" => %(it's "q")} }

    it "fills scalars and keeps each value one argument" do
      argv = described_class.render(["check", "--c={{checkout}}", "{{branch}}", "{{inputs.q}}"], scalars: scalars, lists: {})
      expect(argv).to eq(["check", "--c=/a b/c", "x;y", %(it's "q")])
    end

    it "does not re-split or re-expand substituted values" do
      argv = described_class.render(["check", "{{branch}}"], scalars: {"branch" => "{{checkout}} $HOME"}, lists: {})
      expect(argv).to eq(["check", "{{checkout}} $HOME"])
    end

    it "replaces a whole-argument list by its items" do
      argv = described_class.render(["check", "--", "{{changed.files}}"], scalars: {}, lists: {"changed.files" => ["a b.rb", "-x;.rb"]})
      expect(argv).to eq(["check", "--", "a b.rb", "-x;.rb"])
    end

    it "gives no arguments for an empty or missing list" do
      expect(described_class.render(["check", "--", "{{changed.tests}}"], scalars: {}, lists: {"changed.tests" => []})).to eq(["check", "--"])
      expect(described_class.render(["check", "{{run.changed.files}}"], scalars: {}, lists: {})).to eq(["check"])
    end

    it "expands ~/ in the program only" do
      argv = described_class.render(["~/bin/check", "~/x"], scalars: {}, lists: {})
      expect(argv).to eq([File.expand_path("~/bin/check"), "~/x"])
    end

    it "leaves the template unchanged" do
      template = ["check", "{{branch}}"].freeze
      expect { described_class.render(template, scalars: {"branch" => "b"}, lists: {}) }.not_to raise_error
      expect(template).to eq(["check", "{{branch}}"])
    end

    it "does not raise on a value that is not valid UTF-8" do
      bad = (+"caf\xC3").force_encoding("UTF-8")
      argv = described_class.render(["check", "é{{branch}}"], scalars: {"branch" => bad}, lists: {})
      expect(argv.last.bytes).to eq("é".bytes + [99, 97, 102, 195])
    end

    it "does not raise on a binary value beside non-ASCII text" do
      argv = described_class.render(["check", "é{{branch}}"], scalars: {"branch" => "é".b}, lists: {})
      expect(argv.last.bytes).to eq("éé".bytes)
    end
  end
end
