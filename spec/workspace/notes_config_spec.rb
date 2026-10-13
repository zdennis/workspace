RSpec.describe Workspace::NotesConfig do
  let(:project_settings) { instance_double(Workspace::ProjectSettings) }
  subject(:config) { described_class.new(project_settings: project_settings) }

  def stored(value)
    allow(project_settings).to receive(:load).with("app").and_return(value)
  end

  it "is on when notes.instructions is unset" do
    stored({})
    expect(config.instructions?("app")).to be(true)
    stored({"notes" => {"dir" => "/x"}})
    expect(config.instructions?("app")).to be(true)
  end

  it "is off only for false, written as a boolean or as the string config set stores" do
    [false, "false"].each do |value|
      stored({"notes" => {"instructions" => value}})
      expect(config.instructions?("app")).to be(false)
    end
  end

  it "is on for true, and for a notes block that is not a mapping" do
    stored({"notes" => {"instructions" => "true"}})
    expect(config.instructions?("app")).to be(true)
    stored({"notes" => "oops"})
    expect(config.instructions?("app")).to be(true)
  end
end
