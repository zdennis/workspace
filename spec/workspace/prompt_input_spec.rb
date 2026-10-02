require "stringio"

RSpec.describe Workspace::PromptInput do
  describe ".env_truthy?" do
    it "reads WORKSPACE_NO_INPUT as set unless empty, 0, or false" do
      expect(described_class.env_truthy?({"WORKSPACE_NO_INPUT" => "1"})).to be true
      expect(described_class.env_truthy?({"WORKSPACE_NO_INPUT" => "yes"})).to be true
      expect(described_class.env_truthy?({"WORKSPACE_NO_INPUT" => ""})).to be false
      expect(described_class.env_truthy?({"WORKSPACE_NO_INPUT" => "0"})).to be false
      expect(described_class.env_truthy?({"WORKSPACE_NO_INPUT" => "false"})).to be false
      expect(described_class.env_truthy?({})).to be false
    end
  end

  it "passes reads through to the wrapped stream" do
    input = described_class.new(StringIO.new("y\nrest"))

    expect(input.gets).to eq("y\n")
    expect(input.read).to eq("rest")
  end

  it "starts accepting input unless told otherwise" do
    expect(described_class.new(StringIO.new).no_input?).to be false
    expect(described_class.new(StringIO.new, no_input: true).no_input?).to be true
  end

  it "switches to refusing with no_input!" do
    input = described_class.new(StringIO.new)
    input.no_input!
    expect(input.no_input?).to be true
  end
end

RSpec.describe Workspace::Prompt do
  let(:output) { StringIO.new }

  it "prints the prompt and reads a line from a plain stream" do
    answer = described_class.ask(StringIO.new("y\n"), output, "Go? [y/N] ")

    expect(answer).to eq("y\n")
    expect(output.string).to eq("Go? [y/N] ")
  end

  it "reads a line from a guarded stream that accepts input" do
    input = Workspace::PromptInput.new(StringIO.new("n\n"))
    expect(described_class.ask(input, output, "Go? ")).to eq("n\n")
  end

  it "returns nil at end of input" do
    expect(described_class.ask(StringIO.new, output, "Go? ")).to be_nil
  end

  context "under no-input" do
    let(:input) { Workspace::PromptInput.new(StringIO.new("y\n"), no_input: true) }

    it "refuses with confirmation_required, naming the prompt, and prints and reads nothing" do
      expect { described_class.ask(input, output, "  Remove it? [y/N] ") }.to raise_error(Workspace::Error) { |e|
        expect(e.code).to eq("confirmation_required")
        expect(e.message).to eq("Can't ask \"Remove it? [y/N]\" with --no-input (or WORKSPACE_NO_INPUT) set.")
        expect(e.details).to eq({"prompt" => "Remove it? [y/N]"})
        expect(e.retry).to be_nil
      }
      expect(output.string).to eq("")
      expect(input.read).to eq("y\n")
    end

    it "offers the flags that answer for the caller" do
      expect { described_class.ask(input, output, "Go? ", retry_flags: ["--force"], destructive: true) }.to raise_error(Workspace::Error) { |e|
        expect(e.retry).to eq({"flags" => ["--force"], "destructive" => true})
      }
    end
  end
end

RSpec.describe "Workspace.build_cli" do
  it "refuses prompts when WORKSPACE_NO_INPUT is set" do
    out = StringIO.new
    cli = Workspace.build_cli(output: out, error_output: StringIO.new, input: StringIO.new, env: {"WORKSPACE_NO_INPUT" => "1"})
    input = cli.instance_variable_get(:@input)

    expect(input).to be_no_input
  end

  it "accepts prompts otherwise" do
    cli = Workspace.build_cli(output: StringIO.new, error_output: StringIO.new, input: StringIO.new, env: {})

    expect(cli.instance_variable_get(:@input)).not_to be_no_input
  end
end
