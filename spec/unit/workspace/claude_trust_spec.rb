require "json"
require "stringio"
require "tmpdir"

RSpec.describe Workspace::ClaudeTrust do
  let(:home) { Dir.mktmpdir }
  let(:checkout) { File.realpath(Dir.mktmpdir) }
  let(:error_output) { StringIO.new }
  let(:config) { File.join(home, ".claude.json") }
  let(:trust) { described_class.new(env: {}, home: home, error_output: error_output) }

  after do
    FileUtils.rm_rf(home)
    FileUtils.rm_rf(checkout)
  end

  def write_config(doc)
    File.write(config, doc.is_a?(String) ? doc : JSON.pretty_generate(doc))
  end

  def projects
    JSON.parse(File.read(config))["projects"]
  end

  it "returns :missing and creates nothing when there is no config file" do
    expect(trust.trust(checkout)).to eq(:missing)
    expect(File.exist?(config)).to be(false)
  end

  it "leaves an unparseable file untouched and warns" do
    write_config("{not json")

    expect(trust.trust(checkout)).to eq(:unparseable)
    expect(File.read(config)).to eq("{not json")
    expect(error_output.string).to include(config, "unchanged")
  end

  it "returns :unparseable when projects is not a hash" do
    write_config("projects" => [])
    before = File.read(config)

    expect(trust.trust(checkout)).to eq(:unparseable)
    expect(File.read(config)).to eq(before)
  end

  it "returns :unparseable when an entry is not a hash" do
    write_config("projects" => {checkout => "x"})

    expect(trust.trust(checkout)).to eq(:unparseable)
  end

  it "returns :unparseable when the top level is not a hash" do
    write_config("[]")

    expect(trust.trust(checkout)).to eq(:unparseable)
  end

  it "leaves bytes and mtime alone when already trusted" do
    write_config("projects" => {checkout => {"hasTrustDialogAccepted" => true}})
    File.utime(Time.at(1_000_000), Time.at(1_000_000), config)
    before = File.read(config)

    expect(trust.trust(checkout)).to eq(:already)
    expect(File.read(config)).to eq(before)
    expect(File.mtime(config)).to eq(Time.at(1_000_000))
  end

  it "adds a new entry" do
    write_config("projects" => {})

    expect(trust.trust(checkout)).to eq(:trusted)
    expect(projects[checkout]).to eq("hasTrustDialogAccepted" => true)
  end

  it "creates projects when the key is absent" do
    write_config("theme" => "dark")

    expect(trust.trust(checkout)).to eq(:trusted)
    expect(projects[checkout]["hasTrustDialogAccepted"]).to be(true)
  end

  it "keeps an existing entry's other keys" do
    write_config("projects" => {checkout => {"allowedTools" => ["a"], "hasTrustDialogAccepted" => false}})

    trust.trust(checkout)

    expect(projects[checkout]).to eq("allowedTools" => ["a"], "hasTrustDialogAccepted" => true)
  end

  it "keeps other top-level keys and their order" do
    write_config("a" => 1, "projects" => {"/other" => {"x" => 1}}, "z" => 2)

    trust.trust(checkout)

    doc = JSON.parse(File.read(config))
    expect(doc.keys).to eq(%w[a projects z])
    expect(doc["projects"]["/other"]).to eq("x" => 1)
  end

  it "keys a symlinked directory by its real path" do
    write_config("projects" => {})
    link = File.join(home, "link")
    File.symlink(checkout, link)

    trust.trust(link)

    expect(projects.keys).to eq([File.realpath(checkout)])
  end

  it "uses an absolute CLAUDE_CONFIG_DIR" do
    dir = Dir.mktmpdir
    File.write(File.join(dir, ".claude.json"), "{}")
    t = described_class.new(env: {"CLAUDE_CONFIG_DIR" => dir}, home: home, error_output: error_output)

    expect(t.config_path).to eq(File.join(dir, ".claude.json"))
    expect(t.trust(checkout)).to eq(:trusted)
  ensure
    FileUtils.rm_rf(dir)
  end

  it "ignores a relative or empty CLAUDE_CONFIG_DIR" do
    %w[rel/dir].push("").each do |value|
      t = described_class.new(env: {"CLAUDE_CONFIG_DIR" => value}, home: home, error_output: error_output)
      expect(t.config_path).to eq(config)
    end
  end

  it "keeps the file mode" do
    write_config("projects" => {})
    File.chmod(0o644, config)

    trust.trust(checkout)

    expect(File.stat(config).mode & 0o777).to eq(0o644)
  end

  it "returns :skipped for a missing directory" do
    write_config("projects" => {})

    expect(trust.trust(File.join(home, "nope"))).to eq(:skipped)
  end

  it "redoes the write once when a concurrent writer dropped the flag" do
    write_config("projects" => {})
    calls = 0
    allow(File).to receive(:rename).and_wrap_original do |orig, from, to|
      calls += 1
      orig.call(from, to)
      File.write(to, JSON.pretty_generate("projects" => {}) + "\n") if calls == 1
    end

    expect(trust.trust(checkout)).to eq(:trusted)
    expect(calls).to eq(2)
    expect(projects[checkout]["hasTrustDialogAccepted"]).to be(true)
  end

  it "returns :unwritten with a warning when another writer replaces the file every time" do
    write_config("projects" => {})
    allow(File).to receive(:rename).and_wrap_original do |orig, from, to|
      orig.call(from, to)
      File.write(to, JSON.pretty_generate("projects" => {}) + "\n")
    end

    expect(trust.trust(checkout)).to eq(:unwritten)
    expect(error_output.string).to include(config, "not marked trusted")
  end

  it "writes through a symlinked config file to its target and keeps the link" do
    target_dir = File.realpath(Dir.mktmpdir)
    target = File.join(target_dir, "claude.json")
    File.write(target, JSON.pretty_generate("projects" => {}))
    File.symlink(target, config)

    expect(trust.trust(checkout)).to eq(:trusted)
    expect(File.symlink?(config)).to be(true)
    expect(JSON.parse(File.read(target))["projects"][checkout]["hasTrustDialogAccepted"]).to be(true)
  ensure
    FileUtils.rm_rf(target_dir) if target_dir
  end

  it "returns :unwritten with a warning instead of raising when the file can not be replaced" do
    write_config("projects" => {})
    before = File.read(config)
    File.chmod(0o555, home)

    expect(trust.trust(checkout)).to eq(:unwritten)
    expect(error_output.string).to include("not marked trusted")
    expect(File.read(config)).to eq(before)
  ensure
    File.chmod(0o755, home)
  end

  describe "#trust_checkout" do
    let(:trust_config) { instance_double(Workspace::ClaudeTrustConfig, enabled?: true) }
    let(:main_agent) { instance_double(Workspace::MainAgent, kind: "claude") }
    let(:gated) { described_class.new(env: {}, home: home, trust_config: trust_config, main_agent: main_agent, error_output: error_output) }

    before { write_config("projects" => {}) }

    it "trusts the root when the key is on and the agent is Claude Code" do
      expect(gated.trust_checkout("proj", checkout)).to eq(:trusted)
      expect(trust_config).to have_received(:enabled?).with("proj")
      expect(main_agent).to have_received(:kind).with("proj")
      expect(projects[checkout]["hasTrustDialogAccepted"]).to be(true)
    end

    it "writes nothing when the key is off" do
      allow(trust_config).to receive(:enabled?).and_return(false)

      expect(gated.trust_checkout("proj", checkout)).to be_nil
      expect(projects).to eq({})
    end

    it "writes nothing when the main agent is not Claude Code" do
      %w[codex none].each do |kind|
        allow(main_agent).to receive(:kind).and_return(kind)

        expect(gated.trust_checkout("proj", checkout)).to be_nil
      end
      expect(projects).to eq({})
    end

    it "writes nothing without a root or without its collaborators" do
      expect(gated.trust_checkout("proj", nil)).to be_nil
      expect(trust.trust_checkout("proj", checkout)).to be_nil
      expect(projects).to eq({})
    end
  end
end
