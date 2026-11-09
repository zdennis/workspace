require "spec_helper"

RSpec.describe Workspace::WorkflowInputs do
  let(:data) do
    {"id" => "demo",
     "inputs" => {
       "task" => {"required" => true, "description" => "what to do"},
       "topic" => {"required" => false, "pattern" => "[a-z]+"}
     }}
  end

  it "returns every declared input as a string, unset ones empty" do
    expect(described_class.check(data, {task: "go"})).to eq("task" => "go", "topic" => "")
  end

  it "treats nil inputs as none given" do
    expect { described_class.check(data, nil) }.to raise_error(Workspace::Error) { |e| expect(e.code).to eq("input_required") }
  end

  it "refuses an undeclared input as a usage error naming the declared ones" do
    expect { described_class.check(data, {"task" => "x", "nope" => "1"}) }
      .to raise_error(Workspace::UsageError, 'Workflow demo has no input "nope" (inputs: task, topic).')
  end

  it "says none when the workflow declares no inputs" do
    expect { described_class.check({"id" => "bare", "inputs" => {}}, {"a" => "1"}) }
      .to raise_error(Workspace::UsageError, /\(inputs: none\)\./)
  end

  it "refuses a blank required input with input_required and its description" do
    expect { described_class.check(data, {"task" => "  "}) }.to raise_error(Workspace::Error) { |e|
      expect(e.message).to eq("Workflow demo needs input task. Pass --input task=VALUE.")
      expect(e.code).to eq("input_required")
      expect(e.details).to eq("workflow" => "demo", "inputs" => [{"name" => "task", "description" => "what to do"}])
    }
  end

  it "refuses a value that misses its pattern without echoing it" do
    expect { described_class.check(data, {"task" => "x", "topic" => "Bad Value"}) }.to raise_error(Workspace::Error) { |e|
      expect(e.code).to eq("invalid_input")
      expect(e.message).to eq("Input topic of workflow demo does not match its pattern [a-z]+.")
      expect(e.message).not_to include("Bad Value")
      expect(e.details).to eq("workflow" => "demo", "input" => "topic", "pattern" => "[a-z]+")
    }
  end

  it "refuses a value longer than the limit even when it would match" do
    long = "a" * (described_class::INPUT_VALUE_LIMIT + 1)
    expect { described_class.check(data, {"task" => "x", "topic" => long}) }.to raise_error(Workspace::Error) { |e| expect(e.code).to eq("invalid_input") }
  end

  it "passes an empty value for a patterned input" do
    expect(described_class.check(data, {"task" => "x", "topic" => ""})).to include("topic" => "")
  end

  it "treats a pattern that is not a valid regexp as a mismatch" do
    bad = {"id" => "demo", "inputs" => {"t" => {"pattern" => "("}}}
    expect { described_class.check(bad, {"t" => "x"}) }.to raise_error(Workspace::Error) { |e| expect(e.code).to eq("invalid_input") }
  end
end
