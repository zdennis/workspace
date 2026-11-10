require "tmpdir"
require "json"
require "spec_helper"

RSpec.describe Workspace::WorkflowSourceFetcher do
  let(:state) { Dir.mktmpdir }
  let(:stage) { File.join(state, "stage") }
  let(:calls) { [] }
  let(:now) { Time.utc(2026, 11, 9, 12, 0, 0) }
  let(:listing) do
    [{"type" => "file", "name" => "b.yml", "path" => "wf/b.yml", "sha" => "sha-b"},
      {"type" => "file", "name" => "a.yml", "path" => "wf/a.yml", "sha" => "sha-a"},
      {"type" => "file", "name" => "README.md", "path" => "wf/README.md", "sha" => "sha-r"},
      {"type" => "file", "name" => ".hidden.yml", "path" => "wf/.hidden.yml", "sha" => "sha-h"},
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
  subject(:fetcher) { described_class.new(runner: runner, clock: -> { now }) }

  after { FileUtils.rm_rf(state) }

  describe "a GitHub source" do
    it "writes the yml files and a manifest into the given directory" do
      result = fetcher.fetch(entry, into: stage)

      expect(result.dir).to eq(stage)
      expect(result.local).to be(false)
      expect(Dir.children(stage).sort).to eq(%w[a.yml b.yml manifest.json])
      expect(File.read(File.join(stage, "a.yml"))).to eq("body of repos/acme/widgets/contents/wf/a.yml\n")
    end

    it "records the source, ref, per-file shas and install time" do
      url = "https://github.com/acme/widgets/tree/v2/wf"
      ref_stage = File.join(state, "ref-stage")
      fetcher.fetch(url, into: ref_stage)

      manifest = JSON.parse(File.read(File.join(ref_stage, "manifest.json")))
      expect(manifest).to eq("source" => url, "ref" => "v2", "files" => {"a.yml" => "sha-a", "b.yml" => "sha-b"},
        "installed_at" => "2026-11-09T12:00:00Z")
    end

    it "finds a ref holding slashes by trying longer refs while GitHub says the ref is unknown" do
      url = "https://github.com/acme/widgets/tree/me/topic/wf"
      responses["repos/acme/widgets/contents/topic/wf?ref=me"] = ["", "gh: No commit found for the ref me (HTTP 404)", false]
      result = fetcher.fetch(url, into: stage)

      manifest = JSON.parse(File.read(File.join(stage, "manifest.json")))
      expect(manifest["ref"]).to eq("me/topic")
      expect(calls.map(&:last)).to include("repos/acme/widgets/contents/wf?ref=me%2Ftopic",
        "repos/acme/widgets/contents/wf/a.yml?ref=me%2Ftopic")
      expect(result.dir).to eq(stage)
    end

    it "stops at the first split when the failure is not an unknown ref" do
      url = "https://github.com/acme/widgets/tree/me/topic/wf"
      responses["repos/acme/widgets/contents/topic/wf?ref=me"] = ["", "gh: Bad credentials (HTTP 401)", false]

      expect { fetcher.fetch(url, into: stage) }.to raise_error(Workspace::Error, /Bad credentials/)
      expect(calls.size).to eq(1)
    end

    it "reports the last split's failure when no split names a ref" do
      url = "https://github.com/acme/widgets/tree/no/such/wf"
      responses["repos/acme/widgets/contents/such/wf?ref=no"] = ["", "gh: No commit found for the ref no (HTTP 404)", false]
      responses["repos/acme/widgets/contents/wf?ref=no%2Fsuch"] = ["", "gh: No commit found for the ref no/such (HTTP 404)", false]

      expect { fetcher.fetch(url, into: stage) }.to raise_error(Workspace::Error, %r{ref no/such})
      expect(calls.size).to eq(2)
    end

    it "asks for the raw body with the Accept header on every file" do
      fetcher.fetch(entry, into: stage)

      raw = calls.select { |argv| argv.include?("-H") }
      expect(raw.size).to eq(2)
      expect(raw).to all(include("Accept: application/vnd.github.raw"))
    end

    it "skips dot-files, directories and non-yml files in the listing" do
      fetcher.fetch(entry, into: stage)

      expect(Dir.children(stage).sort).to eq(%w[a.yml b.yml manifest.json])
    end

    it "raises on a later file failure and leaves the staging directory to the caller" do
      responses["repos/acme/widgets/contents/wf/b.yml"] = ["", "HTTP 404", false]

      expect { fetcher.fetch(entry, into: stage) }.to raise_error(Workspace::Error) { |e| expect(e.code).to eq("workflow_source_failed") }

      expect(File.read(File.join(stage, "a.yml"))).to eq("body of repos/acme/widgets/contents/wf/a.yml\n")
      expect(File.exist?(File.join(stage, "manifest.json"))).to be(false)
    end

    it "passes gh's stderr through on failure" do
      responses["repos/acme/widgets/contents/wf"] = ["", "gh: Not Found (HTTP 404)", false]

      expect { fetcher.fetch(entry, into: stage) }.to raise_error(Workspace::Error) { |e|
        expect(e.code).to eq("workflow_source_failed")
        expect(e.message).to include("Not Found (HTTP 404)")
        expect(e.details["stderr"]).to eq("gh: Not Found (HTTP 404)")
      }
    end

    it "refuses a path that is a file, not a directory" do
      responses["repos/acme/widgets/contents/wf"] = ['{"type":"file"}', "", true]

      expect { fetcher.fetch(entry, into: stage) }.to raise_error(Workspace::Error) { |e| expect(e.code).to eq("workflow_source_failed") }
    end

    it "names the install command when gh is missing" do
      missing = ->(_argv, chdir:, timeout:) { raise Errno::ENOENT }

      expect { described_class.new(runner: missing).fetch(entry, into: stage) }.to raise_error(Workspace::Error) { |e|
        expect(e.code).to eq("workflow_source_gh_missing")
        expect(e.message).to include("brew install gh")
      }
    end

    it "reports a timeout" do
      slow = ->(_argv, chdir:, timeout:) { raise Timeout::Error }

      expect { described_class.new(runner: slow).fetch(entry, into: stage) }.to raise_error(Workspace::Error) { |e|
        expect(e.code).to eq("workflow_source_failed")
        expect(e.details["timed_out"]).to be(true)
      }
    end

    it "refuses a non-github URL without running anything" do
      expect { fetcher.fetch("https://gitlab.com/acme/widgets/wf", into: stage) }.to raise_error(Workspace::Error) { |e| expect(e.code).to eq("workflow_source_invalid") }
      expect(calls).to be_empty
    end
  end

  describe "a local source" do
    it "answers the directory in place and writes nothing" do
      Dir.mktmpdir do |src|
        result = fetcher.fetch(src, into: stage)

        expect(result.dir).to eq(src)
        expect(result.local).to be(true)
        expect(result.manifest).to be_nil
        expect(calls).to be_empty
        expect(File.exist?(stage)).to be(false)
      end
    end

    it "refuses a directory that is not there" do
      expect { fetcher.fetch("/no/such/workflows-dir", into: stage) }.to raise_error(Workspace::Error) { |e| expect(e.code).to eq("workflow_source_local_missing") }
    end

    it "refuses a directory that is there but not readable" do
      Dir.mktmpdir do |src|
        File.chmod(0o000, src)

        expect { fetcher.fetch(src, into: stage) }.to raise_error(Workspace::Error) { |e| expect(e.code).to eq("workflow_source_local_missing") }
      ensure
        File.chmod(0o755, src)
      end
    end
  end
end
