require "tmpdir"

RSpec.describe Workspace::StatuslineRenderer do
  let(:renderer) { described_class.new }

  it "renders model, directory, context bar, cost, and duration" do
    payload = {
      "model" => {"display_name" => "Opus"},
      "cwd" => "/tmp/myproject",
      "cost" => {"total_cost_usd" => 1.234, "total_duration_ms" => 125_000},
      "context_window" => {"used_percentage" => 42}
    }

    output = renderer.render(payload)
    expect(output).to include("Opus")
    expect(output).to include("myproject")
    expect(output).to include("42% ctx")
    expect(output).to include("$1.23")
    expect(output).to include("2m 5s")
  end

  it "never makes a network call: no usage/session fields appear" do
    payload = {"model" => {"display_name" => "Sonnet"}, "context_window" => {"used_percentage" => 5}}
    output = renderer.render(payload)
    expect(output).not_to match(/session|weekly|resets/i)
  end

  it "defaults missing fields instead of raising" do
    expect { renderer.render({}) }.not_to raise_error
    expect(renderer.render({})).to include("0% ctx")
  end

  it "shows the git branch when cwd is a git repo" do
    Dir.mktmpdir do |dir|
      system("git", "-C", dir, "init", "-q", "-b", "main")
      output = renderer.render({"cwd" => dir})
      expect(output).to include("main")
    end
  end

  it "omits the branch when cwd is not a git repo" do
    Dir.mktmpdir do |dir|
      output = renderer.render({"cwd" => dir})
      first_line = output.lines.first
      expect(first_line).not_to include(" | ")
    end
  end

  it "never raises even on unexpected payload shapes" do
    expect { renderer.render({"model" => "not-a-hash"}) }.not_to raise_error
  end
end
