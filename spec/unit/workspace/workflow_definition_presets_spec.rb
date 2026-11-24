require "spec_helper"
require "json"
require "digest"

# R24's guard: a definition with no import: anywhere reads exactly as it did before imports existed. Each shipped
# preset's file digest, resolved digest, checked hash (as canonical JSON), problems and warnings are pinned here;
# a change to a preset's file updates its pin on purpose.
RSpec.describe Workspace::WorkflowDefinition do
  pins = {
    "bugfix" => {sha256: "0809245135af9b3d3bb4715a8f660b4edabf7d196617bc17e8eed800a5fc532a", resolved_sha256: "0809245135af9b3d3bb4715a8f660b4edabf7d196617bc17e8eed800a5fc532a", to_h: "f67c1cfbafe5018c2f557010fd64564e667af25bb6deb8b34cfe2827d7ebe195"},
    "explore-parallel" => {sha256: "55d2085d2fd45d5caae5356c847a66f7f961ade405b507b273cd6a6b3f072e0b", resolved_sha256: "55d2085d2fd45d5caae5356c847a66f7f961ade405b507b273cd6a6b3f072e0b", to_h: "037fa990ee86f5eeab630d2a18a583b4a26545a93f99868e076b4d7d8daa0eac"},
    "explore" => {sha256: "0c9103d9fd3a39c92cafb2a04b11b801793ed3941f810538ba4be1a9fa02f3ae", resolved_sha256: "0c9103d9fd3a39c92cafb2a04b11b801793ed3941f810538ba4be1a9fa02f3ae", to_h: "546c52d5747ccba4ba40c3219df144c0b4ad771e89f1c0d736f2ce42fbacb17e"},
    "investigate" => {sha256: "d8f97197f6618be2d906398c9b56ddb602140d1073aa45de54f1840f3261c71f", resolved_sha256: "d8f97197f6618be2d906398c9b56ddb602140d1073aa45de54f1840f3261c71f", to_h: "2e7f41928cd67fe6de2a63b94091fb7e065cf100d151c4bdd462156746155269"},
    "pr-feedback" => {sha256: "7deb5a59a8dadad680ad126978028368380ae33236f1e7b9378c26b4066a1e9b", resolved_sha256: "7deb5a59a8dadad680ad126978028368380ae33236f1e7b9378c26b4066a1e9b", to_h: "4df5458de814383fa9ec87bc5ecdab9d3693c9ca2b4d3230a565c3cd658d6ab5"},
    "rpiv-auto-approve-v2" => {sha256: "cd370228d6d147a0209a8cceb3b915cf6eaae264047be96ba335ef8291c981b7", resolved_sha256: "396b6c3e59a3c76ac2d7942fb41a6555515b7133b06b33e2fc62f31927553810", to_h: "7e986f4cf55de61066151006b008c140c44cefa623603455888286cc5cddcfb3"},
    "rpiv-auto-approve" => {sha256: "0e658ea5efb2b2df984f814c4b06e98c6b717852fde9a039d9d92ecbbd31adb8", resolved_sha256: "24065a5e3b65e92697f161f282ddc17d7c8d688a5eb42e18c5b6f2a13e8119a2", to_h: "6bb06737e158b68ebe83d5a90bb686236c7003e0b0fa9a074569555f36345cb5"},
    "rpiv" => {sha256: "69edfbfa525406b80090106941b15d9020f4217099a7e66c99241a1134ece3b0", resolved_sha256: "74df81dcb0af0917c7fbc61dfa3fafda64dc106d442b7b752aa235d9e2dc28dd", to_h: "ec3b679f3e3bbe939a78922785d23b1ff89a76e9b38d8cc430fd5649b1b1f761"}
  }

  def canonical(value)
    case value
    when Hash then value.sort_by { |key, _| key.to_s }.to_h { |key, each| [key.to_s, canonical(each)] }
    when Array then value.map { |each| canonical(each) }
    else value
    end
  end

  it "pins every shipped preset" do
    shipped = Dir[File.join(PresetSimulation::WORKFLOWS, "*.yml")].map { |path| File.basename(path, ".yml") }

    expect(shipped).to match_array(pins.keys)
  end

  pins.each do |id, pin|
    it "reads #{id} with the pinned digests, checked hash, no problems and no warnings" do
      definition = PresetSimulation.definition(id)

      expect(definition.sha256).to eq(pin[:sha256])
      expect(definition.resolved_sha256).to eq(pin[:resolved_sha256])
      expect(Digest::SHA256.hexdigest(JSON.generate(canonical(definition.to_h)))).to eq(pin[:to_h])
      expect(definition.warnings).to eq([])
    end
  end

  %w[rpiv rpiv-auto-approve rpiv-auto-approve-v2].each do |id|
    it "checks #{id}'s plan with the step check-ids verb and no inline Ruby" do
      plan = PresetSimulation.definition(id).to_h["steps"].find { |step| step["id"] == "plan" }
      run = plan["status"]["run"]

      expect(run).to eq("workspace step check-ids --prefix R --defined requirements.md --allow-missing --plan-details")
      expect(run).not_to include("ruby")
    end
  end
end
