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
    "rpiv-auto-approve-v2" => {sha256: "e621f9b2e619be47fe707b424736ff5ab8a35f23adca5bafaba6f75087671cd3", resolved_sha256: "abd0dbd3e9d38ebf60dd97debbf233f807648bdf893f89fb16dde17e7cbe3361", to_h: "c83069b35d56346ae707e40635da569cd26658bb96be225760f86f9ab2338666"},
    "rpiv-auto-approve" => {sha256: "780c2a6d29da14ac6991a4e33a02d8ee4da03260acf8ae77d2ed3eec60ad3469", resolved_sha256: "7c09eb104d91df1832637b0c6fb68a6790c31f8a7a31567539255e705987662d", to_h: "7da1e4df26480695fd7de29082d6f0566d882e98eeebc784b46841ff09f1008e"},
    "rpiv" => {sha256: "7a0bceb968260d537573248169c34e2d6f87d88f8468b5ccf87501b1073de266", resolved_sha256: "048076d4f2c37dac096b3f9d74c9cd09b725cd1ce14543becf2ff91b82f0acf3", to_h: "483da6d92e6e98b8690358d5aec97731b05b1f2fbea17a23bc40f8321346c263"}
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
end
