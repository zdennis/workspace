require "spec_helper"

RSpec.describe Workspace::SkillHarnesses do
  include SkillsFixture

  def build(on_path: [], env: {})
    described_class.new(home: home, env: env, which: ->(exe) { on_path.include?(exe) })
  end

  it "names the four harnesses and their skills directories under the home" do
    dirs = build.all.to_h { |h| [h.key, h.dir] }

    expect(dirs).to eq("claude" => "#{home}/.claude/skills", "codex" => "#{home}/.codex/skills",
      "pi" => "#{home}/.pi/agent/skills", "opencode" => "#{home}/.config/opencode/skills")
  end

  it "finds a harness by its program on PATH alone" do
    expect(build(on_path: ["pi"]).found.map(&:key)).to eq(["pi"])
  end

  it "finds a harness by its config directory alone" do
    FileUtils.mkdir_p("#{home}/.claude")

    expect(build.found.map(&:key)).to eq(["claude"])
  end

  it "finds nothing when neither is there" do
    expect(build.found).to eq([])
  end

  it "honours CODEX_HOME" do
    codex_home = File.join(@tmp, "codex-elsewhere")
    FileUtils.mkdir_p(codex_home)
    harnesses = build(env: {"CODEX_HOME" => codex_home})

    expect(harnesses.all.find { |h| h.key == "codex" }.dir).to eq("#{codex_home}/skills")
    expect(harnesses.found.map(&:key)).to eq(["codex"])
  end

  it "links ~/.agents/skills only when it exists, and never creates it" do
    harnesses = build

    expect(harnesses.agents_dir?).to be(false)
    expect(harnesses.known_dirs).to eq([])
    expect(File.exist?("#{home}/.agents")).to be(false)

    FileUtils.mkdir_p("#{home}/.agents/skills")
    expect(harnesses.agents_dir?).to be(true)
    expect(harnesses.known_dirs).to eq(["#{home}/.agents/skills"])
  end

  it "lists known directories of harnesses that are not found too, for uninstall" do
    FileUtils.mkdir_p("#{home}/.codex/skills")

    expect(build.known_dirs).to eq(["#{home}/.codex/skills"])
  end
end
