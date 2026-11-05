RSpec.describe Workspace::RunResult do
  let(:attrs) do
    {
      uuid: "abc-123",
      project: "myproject",
      command: "echo hi",
      status: 0,
      stdout: "hi\n",
      stderr: "",
      started_at: "2024-01-01T00:00:00Z",
      finished_at: "2024-01-01T00:00:01Z"
    }
  end

  subject(:result) { described_class.new(**attrs) }

  describe "#to_h" do
    it "returns a plain hash with string keys" do
      h = result.to_h
      expect(h["uuid"]).to eq("abc-123")
      expect(h["status"]).to eq(0)
      expect(h["stdout"]).to eq("hi\n")
    end
  end

  describe "#to_json / .from_json round-trip" do
    it "survives a round-trip" do
      parsed = described_class.from_json(result.to_json)
      expect(parsed.uuid).to eq(result.uuid)
      expect(parsed.project).to eq(result.project)
      expect(parsed.command).to eq(result.command)
      expect(parsed.status).to eq(result.status)
      expect(parsed.stdout).to eq(result.stdout)
      expect(parsed.stderr).to eq(result.stderr)
    end
  end

  describe ".from_json" do
    it "tolerates nil optional fields" do
      json = JSON.generate({
        "uuid" => "x", "project" => nil, "command" => nil,
        "status" => 1, "stdout" => "", "stderr" => "",
        "started_at" => nil, "finished_at" => "2024-01-01T00:00:02Z"
      })
      result = described_class.from_json(json)
      expect(result.project).to be_nil
      expect(result.command).to be_nil
    end
  end
end
