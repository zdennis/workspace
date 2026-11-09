require "erb"
require "fileutils"
require "json"
require "time"
require "timeout"

module Workspace
  # Gets the files of one `workflows.sources` entry. A local entry is checked and
  # answered in place: nothing is copied. A GitHub entry is read with `gh api`
  # (one directory listing, then one raw fetch per `.yml` file) and written, with
  # a `manifest.json`, into its cache directory
  # (`<state_dir>/.workflows-sources/<sha256-of-entry>/`). Credentials stay with
  # `gh`; none is read here.
  class WorkflowSourceFetcher
    # Seconds one `gh` call may take.
    DEFAULT_TIMEOUT = 30.0

    # The manifest's file name; it is not `.yml`, so the catalog skips it.
    MANIFEST = "manifest.json".freeze

    RAW_ACCEPT = "Accept: application/vnd.github.raw".freeze

    # What a fetch answers.
    #
    # @!attribute dir [String] the directory holding the `.yml` files
    # @!attribute local [Boolean] true when +dir+ is the local source itself
    # @!attribute manifest [Hash, nil] what was written to `manifest.json`; nil for a local source
    Result = Struct.new(:dir, :local, :manifest, keyword_init: true)

    # Runs a command without a prompt, stopped when +timeout+ passes.
    #
    # @return [Array(String, String, Boolean)] stdout, stderr, success
    # @raise [Errno::ENOENT] if the command is not installed
    # @raise [Timeout::Error] if it ran past +timeout+
    def self.run(argv, chdir:, timeout:)
      TimedProcess.run(argv, chdir: chdir, timeout: timeout)
    end

    # @param state_dir [String] the state root the cache lives under
    # @param runner [#call] `(argv, chdir:, timeout:)` returning `[stdout, stderr, success]`
    # @param home [String, nil] what a leading `~` stands for
    # @param timeout [Numeric] seconds one `gh` call may take
    # @param clock [#call] returns the time `installed_at` records
    def initialize(state_dir:, runner: self.class.method(:run), home: ENV["HOME"], timeout: DEFAULT_TIMEOUT, clock: -> { Time.now })
      @state_dir = state_dir
      @runner = runner
      @home = home
      @timeout = timeout
      @clock = clock
    end

    # @param entry [String] one `workflows.sources` entry
    # @param into [String, nil] a directory to write a remote source into (the caller owns it,
    #   for staging); nil writes the source's cache directory, replacing what was there only
    #   once every file has arrived
    # @return [Result]
    # @raise [Workspace::Error] `workflow_source_invalid`, `workflow_source_local_missing`,
    #   `workflow_source_gh_missing` or `workflow_source_failed`
    def fetch(entry, into: nil)
      parsed = parse(entry)
      return local(parsed) if parsed.kind == :local

      into ? remote(entry, parsed, into) : cached(entry, parsed)
    end

    private

    def parse(entry)
      WorkflowSource.parse(entry, home: @home)
    rescue Workspace::UsageError => e
      raise Workspace::Error.new(e.message, code: "workflow_source_invalid", details: {"source" => entry})
    end

    def local(parsed)
      unless File.directory?(parsed.path) && File.readable?(parsed.path) && File.executable?(parsed.path)
        raise Workspace::Error.new("Workflow source #{parsed.path} is not a readable directory.",
          code: "workflow_source_local_missing", details: {"source" => parsed.path})
      end
      Result.new(dir: parsed.path, local: true, manifest: nil)
    end

    def cached(entry, parsed)
      target = WorkflowSourceDirs.cache_dir(@state_dir, entry)
      FileUtils.mkdir_p(File.dirname(target))
      staging = "#{target}.staging-#{Process.pid}"
      FileUtils.rm_rf(staging)
      FileUtils.mkdir_p(staging)
      begin
        result = remote(entry, parsed, staging)
        FileUtils.rm_rf(target)
        File.rename(staging, target)
        Result.new(dir: target, local: false, manifest: result.manifest)
      ensure
        FileUtils.rm_rf(staging)
      end
    end

    def remote(entry, parsed, dir)
      FileUtils.mkdir_p(dir)
      files = {}
      listing(entry, parsed).each do |item|
        text = gh(entry, ["gh", "api", "-H", RAW_ACCEPT, endpoint(parsed, item["path"])])
        AtomicFile.write(File.join(dir, item["name"]), text, perm: 0o644)
        files[item["name"]] = item["sha"]
      end
      manifest = {"source" => entry, "ref" => parsed.ref, "files" => files, "installed_at" => @clock.call.utc.iso8601}
      AtomicFile.write(File.join(dir, MANIFEST), JSON.pretty_generate(manifest) + "\n", perm: 0o644)
      Result.new(dir: dir, local: false, manifest: manifest)
    end

    def listing(entry, parsed)
      doc = JSON.parse(gh(entry, ["gh", "api", endpoint(parsed, parsed.path)]))
      unless doc.is_a?(Array)
        raise failed(entry, "#{parsed.path} is not a directory in #{parsed.owner}/#{parsed.repo}", nil)
      end
      doc.select { |item| item.is_a?(Hash) && item["type"] == "file" && item["name"].to_s.end_with?(".yml") && item["name"] !~ %r{[/\\]} && item["path"].is_a?(String) }
        .sort_by { |item| item["name"] }
    rescue JSON::ParserError
      raise failed(entry, "gh returned an unreadable directory listing", nil)
    end

    def endpoint(parsed, path)
      segments = path.split("/").map { |s| ERB::Util.url_encode(s) }.join("/")
      url = "repos/#{parsed.owner}/#{parsed.repo}/contents/#{segments}"
      parsed.ref ? "#{url}?ref=#{ERB::Util.url_encode(parsed.ref)}" : url
    end

    def gh(entry, argv)
      stdout, stderr, success = @runner.call(argv, chdir: Dir.pwd, timeout: @timeout)
      raise failed(entry, "gh failed: #{stderr.to_s.scrub.strip}", stderr) unless success
      stdout
    rescue Errno::ENOENT
      raise missing_gh(entry)
    rescue Timeout::Error
      raise Workspace::Error.new("gh did not answer in time for workflow source #{entry}.",
        code: "workflow_source_failed", details: {"source" => entry, "timed_out" => true})
    end

    def missing_gh(entry)
      Workspace::Error.new("`gh` is not installed; install it with `brew install gh` to use workflow source #{entry}.",
        code: "workflow_source_gh_missing", details: {"source" => entry, "install" => "brew install gh"})
    end

    def failed(entry, message, stderr)
      details = {"source" => entry}
      details["stderr"] = stderr.to_s.scrub if stderr
      Workspace::Error.new("#{message} (workflow source #{entry})", code: "workflow_source_failed", details: details)
    end
  end
end
