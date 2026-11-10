require "spec_helper"
require "tmpdir"

RSpec.describe Workspace::WorkflowSourceDirs do
  around do |example|
    Dir.mktmpdir("wf-source-dirs") do |dir|
      @dir = dir
      example.run
    end
  end

  let(:raw) { nil }
  let(:view) { double("view", raw: raw) }
  let(:resolver) { instance_double(Workspace::ConfigResolver, view: view) }
  subject(:dirs) { described_class.new(config_resolver: resolver, state_dir: File.join(@dir, "state"), home: @dir) }

  it "answers nothing when the key is unset" do
    expect(dirs.call).to eq([])
  end

  context "with local and remote entries" do
    let(:local) { File.join(@dir, "local") }
    let(:remote) { "acme/workflows/presets" }
    let(:raw) { [local, remote, "~/home-src", File.join(@dir, "gone")] }

    it "answers an existing local directory, an existing cache directory, and nil for what is not there" do
      cache = described_class.cache_dir(File.join(@dir, "state"), remote)
      FileUtils.mkdir_p([local, cache, File.join(@dir, "home-src")])

      expect(dirs.call).to eq([local, cache, File.join(@dir, "home-src"), nil])
    end

    it "keeps a slot for a remote source whose cache is missing" do
      FileUtils.mkdir_p(local)

      expect(dirs.call).to eq([local, nil, nil, nil])
    end
  end

  context "when the stored value is refused by the schema" do
    let(:raw) { "relative/dir" }

    it "answers nothing" do
      expect(dirs.call).to eq([])
    end
  end

  it "answers nothing when the global config can't be parsed" do
    allow(resolver).to receive(:view).and_raise(Workspace::ConfigParseError.new("x.yml", "bad"))

    expect(dirs.call).to eq([])
  end
end
