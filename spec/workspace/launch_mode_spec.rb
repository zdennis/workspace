RSpec.describe Workspace::LaunchMode do
  def mode(platform: "arm64-darwin23", env: {}, osascript: true, global: {})
    settings = CLITestHelpers::FakeProjectSettings.new
    settings.define_singleton_method(:load_global) { global }
    described_class.new(project_settings: settings, platform: platform, env: env,
      which: ->(exe) { exe == "osascript" && osascript })
  end

  it "uses iTerm2 on macOS with osascript and no CI" do
    decision = mode.resolve
    expect(decision.headless?).to be false
    expect(decision.reason).to eq("iTerm2")
  end

  it "is headless off macOS" do
    expect(mode(platform: "x86_64-linux").resolve).to have_attributes(headless: true, reason: "not macOS")
  end

  it "is headless when osascript is missing" do
    expect(mode(osascript: false).resolve).to have_attributes(headless: true, reason: "osascript not found")
  end

  it "is headless when CI is set, but not when it is false or 0" do
    expect(mode(env: {"CI" => "true"}).resolve.headless?).to be true
    expect(mode(env: {"CI" => "false"}).resolve.headless?).to be false
    expect(mode(env: {"CI" => "0"}).resolve.headless?).to be false
    expect(mode(env: {"CI" => ""}).resolve.headless?).to be false
  end

  it "lets launch.headless override the automatic choice either way" do
    expect(mode(platform: "x86_64-linux", global: {"launch" => {"headless" => "false"}}).resolve)
      .to have_attributes(headless: false, reason: "launch.headless is false")
    expect(mode(global: {"launch" => {"headless" => "true"}}).resolve.headless?).to be true
  end

  it "lets an explicit flag beat the config key and the automatic choice" do
    expect(mode(global: {"launch" => {"headless" => "true"}}).resolve(false))
      .to have_attributes(headless: false, reason: "--no-headless")
    expect(mode.resolve(true)).to have_attributes(headless: true, reason: "--headless")
  end

  describe ".parse_config" do
    it "accepts true and false only" do
      expect(described_class.parse_config("true")).to eq("true")
      expect(described_class.parse_config("false")).to eq("false")
      expect { described_class.parse_config("yes") }.to raise_error(ArgumentError, /"true" or "false"/)
    end
  end
end
