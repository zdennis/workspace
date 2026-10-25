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

    # Replaces the user's file of this id when its raw bytes still hash to +if_sha256+. The
    # current file is read as bytes and never parsed, so a broken file can be replaced. The
    # text is written as given; check it first.
    #
    # @param id [String]
    # @param text [String] the new definition's text
    # @param if_sha256 [String] the sha256 of the raw bytes the caller last read
    # @param dry_run [Boolean] check, under the lock, and write no definition
    # @return [Hash{String=>Object}] "path" and "sha256" (of the new text's bytes)
    # @raise [Workspace::Error] code `invalid_workflow` for a bad id, `builtin_workflow` (only a preset has the id),
    #   `unknown_workflow`, `stale_workflow` (details "sha256" is the current file's)
    def update(id, text, if_sha256:, dry_run: false)
      target = path(id)
      with_lock(id) do
        raise_missing(id) unless File.exist?(target) || File.symlink?(target)
        current = current_sha256(target)
        unless current && current == if_sha256.to_s.strip.downcase
          hint = current ? "" : " The file can't be read; `workflow remove #{id}` or fixing the file by hand is the way out."
          raise Workspace::Error.new("The workflow file #{target} changed: its sha256 is #{current || "unreadable"}, not #{if_sha256}. Nothing was changed.#{hint}",
            code: "stale_workflow", details: {"workflow" => id, "path" => target, "sha256" => current})
        end
        write(id, target, text) unless dry_run
        {"path" => target, "sha256" => Digest::SHA256.hexdigest(text.b)}
      end
    end

    # Deletes the user's file of this id: the file or link itself, never what a link points to
    # (a link to a file that is gone counts). The file is not read, so a broken one can be removed.
    # The lock file stays.
    #
    # @param id [String]
    # @param dry_run [Boolean] check, under the lock, and delete nothing
    # @return [Hash{String=>Object}] "path" and "preset" (true when a preset of the id is in effect once the file is gone)
    # @raise [Workspace::Error] code `invalid_workflow` for a bad id or a directory at the path, `builtin_workflow`
    #   (only a preset has the id), `unknown_workflow`
    def remove(id, dry_run: false)
      target = path(id)
      with_lock(id) do
        raise_missing(id, "remove") unless File.exist?(target) || File.symlink?(target)
        if File.directory?(target) && !File.symlink?(target)
          raise Workspace::Error.new("#{target} is a directory, not a workflow file; nothing was removed. Remove it by hand.",
            code: "invalid_workflow", details: {"workflow" => id, "path" => target})
        end
        File.unlink(target) unless dry_run
        {"path" => target, "preset" => File.file?(File.join(@config.builtin_workflows_dir, "#{id}.yml"))}
      end
    end

    # Without the lock, refuses an id that has no file of the user's, so a caller can say so
    # before asking a person anything. `remove` still decides under the lock.
    #
    # @param id [String]
    # @return [void]
    # @raise [Workspace::Error] code `invalid_workflow`, `builtin_workflow`, `unknown_workflow`
    def ensure_present(id)
      target = path(id)
      raise_missing(id, "remove") unless File.exist?(target) || File.symlink?(target)
    end

    private

    def raise_missing(id, verb = "update")
      if @catalog.locate(id)&.first == "builtin"
        advice = (verb == "update") ? "save a copy with `workflow add #{id} PATH` instead" : "a preset can't be removed"
        raise Workspace::Error.new("#{id} is a preset and has no file of yours to #{verb}; #{advice}.",
          code: "builtin_workflow", details: {"workflow" => id})
      end
      @catalog.find(id) # raises unknown_workflow, naming the known ids
      raise Workspace::Error.new("No workflow file for #{id}.", code: "unknown_workflow", details: {"workflow" => id})
    end

    # The digest of the file's raw bytes, nil when it can't be read (a dangling link, a directory).
    def current_sha256(target)
      Digest::SHA256.hexdigest(File.binread(target))
    rescue SystemCallError
      nil
    end

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
