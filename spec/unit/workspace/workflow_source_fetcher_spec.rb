require "tmpdir"
require "json"

RSpec.describe Workspace::WorkflowSourceFetcher do
  let(:state) { Dir.mktmpdir }
  let(:calls) { [] }
  let(:now) { Time.utc(2026, 11, 9, 12, 0, 0) }
  let(:listing) do
    [{"type" => "file", "name" => "b.yml", "path" => "wf/b.yml", "sha" => "sha-b"},
      {"type" => "file", "name" => "a.yml", "path" => "wf/a.yml", "sha" => "sha-a"},
      {"type" => "file", "name" => "README.md", "path" => "wf/README.md", "sha" => "sha-r"},
      {"type" => "dir", "name" => "sub.yml", "path" => "wf/sub.yml", "sha" => "sha-d"}]
  end
  let(:responses) { {} }
  let(:runner) do
    ->(argv, chdir:, timeout:) do
      calls << argv
      key = argv.last
      next responses.fetch(key) if responses.key?(key)
      next [JSON.generate(listing), "", true] unless argv.include?("-H")
      ["body of #{key}\n", "", true]
    end
  end
  let(:entry) { "acme/widgets/wf" }
  subject(:fetcher) { described_class.new(state_dir: state, runner: runner, clock: -> { now }) }

  after { FileUtils.rm_rf(state) }

  def cache(entry)
    Workspace::WorkflowSourceDirs.cache_dir(state, entry)
  end

  describe "a GitHub source" do
    it "writes the yml files and a manifest into the cache dir named for the entry" do
      result = fetcher.fetch(entry)

      expect(result.dir).to eq(cache(entry))
      expect(result.local).to be(false)
      expect(Dir.children(result.dir).sort).to eq(%w[a.yml b.yml manifest.json])
      expect(File.read(File.join(result.dir, "a.yml"))).to eq("body of repos/acme/widgets/contents/wf/a.yml\n")
    end

    it "records the source, ref, per-file shas and install time" do
      url = "https://github.com/acme/widgets/tree/v2/wf"
      fetcher.fetch(url)

      manifest = JSON.parse(File.read(File.join(cache(url), "manifest.json")))
      expect(manifest).to eq("source" => url, "ref" => "v2", "files" => {"a.yml" => "sha-a", "b.yml" => "sha-b"},
        "installed_at" => "2026-11-09T12:00:00Z")
    end

    it "asks for the raw body with the Accept header on every file" do
      fetcher.fetch(entry)

      raw = calls.select { |argv| argv.include?("-H") }
      expect(raw.size).to eq(2)
      expect(raw).to all(include("Accept: application/vnd.github.raw"))
    end

    it "writes into a given directory and leaves the cache alone" do
      stage = File.join(state, "stage")

      result = fetcher.fetch(entry, into: stage)

      expect(result.dir).to eq(stage)
      expect(File.exist?(File.join(stage, "manifest.json"))).to be(true)
      expect(File.exist?(cache(entry))).to be(false)
    end

    it "keeps the old cache when a later file fails" do
      fetcher.fetch(entry)
      responses["repos/acme/widgets/contents/wf/b.yml"] = ["", "HTTP 404", false]

      expect { fetcher.fetch(entry) }.to raise_error(Workspace::Error) { |e| expect(e.code).to eq("workflow_source_failed") }

      expect(File.read(File.join(cache(entry), "b.yml"))).to eq("body of repos/acme/widgets/contents/wf/b.yml\n")
      expect(Dir.children(File.dirname(cache(entry))).grep(/staging/)).to be_empty
    end

    it "passes gh's stderr through on failure" do
      responses["repos/acme/widgets/contents/wf"] = ["", "gh: Not Found (HTTP 404)", false]

      expect { fetcher.fetch(entry) }.to raise_error(Workspace::Error) { |e|
        expect(e.code).to eq("workflow_source_failed")
        expect(e.message).to include("Not Found (HTTP 404)")
        expect(e.details["stderr"]).to eq("gh: Not Found (HTTP 404)")
      }
    end

    it "refuses a path that is a file, not a directory" do
      responses["repos/acme/widgets/contents/wf"] = ['{"type":"file"}', "", true]

      expect { fetcher.fetch(entry) }.to raise_error(Workspace::Error) { |e| expect(e.code).to eq("workflow_source_failed") }
    end

    it "names the install command when gh is missing" do
      missing = ->(_argv, chdir:, timeout:) { raise Errno::ENOENT }

      expect { described_class.new(state_dir: state, runner: missing).fetch(entry) }.to raise_error(Workspace::Error) { |e|
        expect(e.code).to eq("workflow_source_gh_missing")
        expect(e.message).to include("brew install gh")
      }
    end

    it "reports a timeout" do
      slow = ->(_argv, chdir:, timeout:) { raise Timeout::Error }

      expect { described_class.new(state_dir: state, runner: slow).fetch(entry) }.to raise_error(Workspace::Error) { |e|
        expect(e.code).to eq("workflow_source_failed")
        expect(e.details["timed_out"]).to be(true)
      }
    end

    it "refuses a non-github URL without running anything" do
      expect { fetcher.fetch("https://gitlab.com/acme/widgets/wf") }.to raise_error(Workspace::Error) { |e| expect(e.code).to eq("workflow_source_invalid") }
      expect(calls).to be_empty
    end
  end

  describe "a local source" do
    it "answers the directory in place and writes no cache" do
      Dir.mktmpdir do |src|
        result = fetcher.fetch(src)

        expect(result.dir).to eq(src)
        expect(result.local).to be(true)
        expect(result.manifest).to be_nil
        expect(calls).to be_empty
        expect(Dir.exist?(File.join(state, ".workflows-sources"))).to be(false)
      end
    end

    it "refuses a directory that is not there" do
      expect { fetcher.fetch("/no/such/workflows-dir") }.to raise_error(Workspace::Error) { |e| expect(e.code).to eq("workflow_source_local_missing") }
    end
  end
end
