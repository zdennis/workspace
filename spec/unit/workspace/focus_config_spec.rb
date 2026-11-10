require "spec_helper"

RSpec.describe Workspace::FocusConfig do
  let(:global) { {} }
  let(:project_settings) { instance_double(Workspace::ProjectSettings, load_global: global) }
  subject(:config) { described_class.new(config_resolver: Workspace::ConfigResolver.new(project_settings: project_settings)) }

  let(:default_steps) { [] }

  def parse(value) = Workspace::ConfigSchema.parse("focus.chain", value)

  def chain(value)
    global["focus"] = {"chain" => value}
    config.read
  end

  describe "the focus.chain parser" do
    it "accepts the default and gives back one line" do
      expect(parse(Workspace::ConfigSchema::DEFAULT_FOCUS_CHAIN)).to eq("focus")
      expect(Workspace::ConfigSchema.default("focus.chain")).to eq("focus")
    end

    {
      "" => /blank/,
      "   " => /blank/,
      "focus\n+ center" => /control character/,
      "focus + \"center" => /Unmatched/,
      "+ focus" => /start or end/,
      "focus +" => /start or end/,
      "focus + + center" => /two \+ in a row/,
      "center" => /first step must be a bare `focus`/,
      "focus --opacity 1" => /first step must be a bare `focus`/,
      "focus + close" => /unknown step "close"/,
      "focus + pick" => /unknown step "pick"/,
      "focus + dim + center" => /runs in the background.*put it last/,
      "focus + highlight + dim" => /runs in the background/,
      "focus + center id=3" => /"id=3"/,
      "focus + center title=x" => /"title=x"/,
      "focus + flash --app=Foo" => /"--app=Foo"/,
      "focus + flash --json" => /"--json"/,
      "focus + flash --exact" => /"--exact"/,
      "focus + flash --first" => /"--first"/,
      "focus + flash --verbose" => /"--verbose"/,
      "focus + flash --keep-going=1" => /"--keep-going=1"/,
      "focus + flash --help" => /"--help"/,
      "focus + flash -h" => /"-h"/,
      "focus + center 0" => /takes no positional/,
      "focus + maximize 0" => /takes no positional/,
      "focus + flash --color pink" => /unknown --color "pink"/,
      "focus + flash --color=pink" => /unknown --color "pink"/,
      "focus + flash --color" => /unknown --color ""/,
      3 => /window-tool steps/,
      true => /window-tool steps/,
      {"a" => 1} => /window-tool steps/,
      ["focus", nil] => /only strings and numbers/,
      ["focus", "+", true] => /only strings and numbers/,
      ["focus", {"a" => 1}] => /only strings and numbers/
    }.each do |value, message|
      it "refuses #{value.inspect}" do
        expect { parse(value) }.to raise_error(ArgumentError, message)
      end
    end

    it "accepts what window-tool takes" do
      expect(parse("focus + center + highlight --color red")).to eq("focus + center + highlight --color red")
      expect(parse("focus + highlight --color RED")).to eq("focus + highlight --color RED")
      expect(parse("focus + flash --color=Blue")).to eq("focus + flash --color=Blue")
      expect(parse("focus + dim --duration 0")).to eq("focus + dim --duration 0")
      expect(parse("focus + shake 12 6 + snap left")).to eq("focus + shake 12 6 + snap left")
      expect(parse("focus")).to eq("focus")
    end

    it "treats a string and a list with numbers alike" do
      list = ["focus", "+", "center", "+", "dim", "--opacity", 0.5, "--duration", 3]

      expect(parse(list)).to eq(parse("focus + center + dim --opacity 0.5 --duration 3"))
    end

    it "keeps a quoted argument through a round trip" do
      once = parse("focus + snap 'left half'")

      expect(once).to eq("focus + snap left\\ half")
      expect(parse(once)).to eq(once)
    end
  end

  describe "#read" do
    it "gives the default's steps when unset" do
      expect(config.read).to have_attributes(steps: default_steps, warning: nil)
    end

    it "splits the steps after the first on +" do
      expect(chain("focus + center + highlight --color red")).to have_attributes(steps: [["center"], %w[highlight --color red]], warning: nil)
    end

    it "gives no steps for focus alone" do
      expect(chain("focus")).to have_attributes(steps: [], warning: nil)
    end

    it "keeps shake and snap positionals and a zero duration" do
      expect(chain("focus + shake 12 6 + snap left + dim --duration 0").steps).to eq([%w[shake 12 6], %w[snap left], %w[dim --duration 0]])
    end

    it "reads a hand-edited list with numbers" do
      expect(chain(["focus", "+", "center", "+", "dim", "--opacity", 0.5, "--duration", 3]).steps).to eq([["center"], %w[dim --opacity 0.5 --duration 3]])
    end

    it "falls back to the default with a warning for a value config set would refuse" do
      ["focus + dim + center", "id=3", 3, ["focus", nil], ""].each do |bad|
        reading = chain(bad)

        expect(reading.steps).to eq(default_steps)
        expect(reading.warning).to start_with("focus.chain ").and end_with("using the default focus.chain.")
      end
    end

    it "falls back to the default with a warning when the global file can't be read" do
      allow(project_settings).to receive(:load_global).and_raise(Workspace::ConfigParseError.new("/c/config.yml", "bad"))
      reading = config.read

      expect(reading.steps).to eq(default_steps)
      expect(reading.warning).to include("global config can't be read", "/c/config.yml")
    end

    it "prints nothing" do
      expect { chain("focus + dim + center") }.not_to output.to_stdout
    end
  end
end
