require "digest"
require "fileutils"
require "securerandom"

module Workspace
  # The one writer of a user's workflow definitions, `config.workflows_dir/ID.yml`.
  # Every change to an id's file holds an exclusive flock on `.ID.yml.lock` beside
  # it from the check (does the file exist, does its sha match) to the write, so two
  # saves of one id can't both pass the check. A write goes to a temp file in the
  # same directory and is renamed over `ID.yml`. A preset is never written: a
  # user's file of the same id shadows it.
  class WorkflowFiles
    # @param config [Workspace::Config] names the directory
    # @param catalog [Workspace::WorkflowCatalog] checks an id and names its file
    def initialize(config:, catalog:)
      @config = config
      @catalog = catalog
    end

    # The directory the files are written to; a relative `prompt_file:` in one is read from here.
    #
    # @return [String]
    def dir
      @config.workflows_dir
    end

    # Where a user's file of this id is (or would be) written.
    #
    # @param id [String]
    # @return [String]
    # @raise [Workspace::Error] code `invalid_workflow` when the id could not be a file name
    def path(id)
      @catalog.global_path(id)
    end

    # Writes a new user's file for +id+, refused when one is already there (a link to
    # a file that is gone counts). The text is written as given; check it first.
    #
    # @param id [String]
    # @param text [String] the definition's text
    # @param dry_run [Boolean] check, under the lock, and write no definition (the directory and lock file may be created)
    # @return [Hash{String=>Object}] "path" and "sha256" (of the text's bytes)
    # @raise [Workspace::Error] code `invalid_workflow` for a bad id, `workflow_exists`
    def add(id, text, dry_run: false)
      target = path(id)
      with_lock(id) do
        if File.exist?(target) || File.symlink?(target)
          raise Workspace::Error.new("A workflow file for #{id} already exists at #{target}; change it with `workflow update` instead.",
            code: "workflow_exists", details: {"workflow" => id, "path" => target})
        end
        write(id, target, text) unless dry_run
        {"path" => target, "sha256" => Digest::SHA256.hexdigest(text.b)}
      end
    end

    private

    # Holds the id's lock for the whole check-and-write. The lock file stays.
    def with_lock(id)
      FileUtils.mkdir_p(dir)
      File.open(File.join(dir, ".#{id}.yml.lock"), File::RDWR | File::CREAT, 0o600) do |lock|
        lock.flock(File::LOCK_EX)
        yield
      end
    end

    def write(id, target, text)
      # A new name each time, created exclusively: a link or leftover file there is never followed or reused.
      tmp_path = File.join(dir, ".#{id}.yml.#{SecureRandom.hex(8)}.tmp")
      created = false
      File.open(tmp_path, File::WRONLY | File::CREAT | File::EXCL | File::BINARY, 0o644) do |file|
        created = true
        file.write(text)
      end
      File.rename(tmp_path, target)
      created = false
    ensure
      File.unlink(tmp_path) if created && File.exist?(tmp_path)
    end
  end
end
