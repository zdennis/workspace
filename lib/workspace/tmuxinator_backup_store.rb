require "digest"
require "fileutils"
require "json"
require "securerandom"
require "time"

module Workspace
  # The batches of tmuxinator config copies kept under `Config#tmuxinator_backups_dir`, one directory per batch
  # with a `manifest.json` beside the copies. `template apply`, `template restore` and `template backup` each
  # take a batch; a batch holds, per workspace, its config and its render record as they were before the write.
  #
  # The manifest is rewritten through {AtomicFile} on every {#add}, so an entry is in it before its workspace's
  # config is written: a crash leaves a manifest naming files that were not yet changed, never a change with
  # no entry. An entry with no `sha_before` means the batch created that file; undoing the batch deletes it.
  class TmuxinatorBackupStore
    SCHEMA = 1
    ID_PATTERN = /\A\d{8}T\d{12}Z-[0-9a-f]{6}\z/
    ORPHAN_AGE = 3600
    ATTEMPTS = 5
    private_constant :ORPHAN_AGE, :ATTEMPTS
    private_constant :ID_PATTERN

    # An open batch: its id and directory.
    Batch = Data.define(:id, :dir)

    # @param config [Workspace::Config] for `tmuxinator_backups_dir`
    # @param writer [Workspace::TmuxinatorConfigWriter] for `record_path(name)`, where a workspace's render record is
    # @param clock [#now] time source
    # @param id_suffix [#call] answers six lowercase hex digits, to keep two batches in one second apart
    def initialize(config:, writer:, clock: Time, id_suffix: -> { SecureRandom.hex(3) })
      @config = config
      @writer = writer
      @clock = clock
      @id_suffix = id_suffix
    end

    # Makes a batch directory and its manifest, with no entries.
    #
    # @param reason [String] `apply`, `restore`, `import` or `manual`
    # @param templates [Hash{String => String}] the sha256 of each template text in play, by file name
    # @return [Batch]
    # @raise [SystemCallError] when the directory or manifest can't be written, or a free id can't be found
    def open(reason:, templates: {})
      now = @clock.now.utc
      FileUtils.mkdir_p(@config.tmuxinator_backups_dir, mode: 0o700)
      attempts = 0
      begin
        id = "#{now.strftime("%Y%m%dT%H%M%S%6N")}Z-#{@id_suffix.call}"
        dir = File.join(@config.tmuxinator_backups_dir, id)
        Dir.mkdir(dir, 0o700)
      rescue Errno::EEXIST
        attempts += 1
        retry if attempts < ATTEMPTS
        raise
      end
      batch = Batch.new(id: id, dir: dir)
      write_manifest(batch, {
        "schema" => SCHEMA, "id" => id, "created_at" => now.iso8601(6), "reason" => reason,
        "templates" => templates, "entries" => [], "sets" => []
      })
      batch
    end

    # Copies one workspace's config and render record into the batch and lists them in its manifest. Call it
    # before the config is written.
    #
    # @param batch [Batch]
    # @param name [String] the workspace name
    # @param path [String] its tmuxinator config
    # @return [Hash] the manifest entry: `name`, `path`, `sha_before` (nil when the config did not exist),
    #   `record_path`, `record_sha_before` (nil when there was no render record)
    # @return [Hash] the manifest entry; a workspace already in the batch keeps its first entry and copies, so
    #   its `sha_before` is what it was before the batch's first write
    # @raise [ArgumentError] when +name+ is not a plain file name
    # @raise [Workspace::Error] `backup_symlink` when the config or its render record is a symbolic link
    # @raise [SystemCallError] when a copy or the manifest write fails; nothing is listed then
    def add(batch, name:, path:)
      plain_name!(name)
      manifest = read_manifest(batch.dir)
      existing = manifest["entries"].find { |listed| listed["name"] == name }
      return existing if existing
      record = @writer.record_path(name)
      entry = {
        "name" => name, "path" => path, "sha_before" => copy(path, batch, "#{name}.yml"),
        "record_path" => record, "record_sha_before" => copy(record, batch, "#{name}.record.json")
      }
      manifest["entries"] += [entry]
      write_manifest(batch, manifest)
      entry
    end

    # Copies a tmuxinator template set into the batch (under `templates/NAME`, regular non-dot files only) and lists it
    # under the manifest's `sets` before the set is replaced. A set already in the batch keeps its first entry.
    #
    # @param batch [Batch]
    # @param name [String] the set's name (a plain file name)
    # @param scope [String] the library scope it is in, `global` or `project`
    # @param project [String, nil] the project of a `project` scope
    # @param path [String] the set's folder now; one that does not exist is listed as a set the batch created
    # @return [Hash] the entry: `name`, `scope`, `project`, `sha_before` (nil when there was no set)
    # @raise [ArgumentError] when +name+ is not a plain file name
    # @raise [SystemCallError] when a copy or the manifest write fails; nothing is listed then
    def add_set(batch, name:, scope:, path:, project: nil)
      plain_name!(name)
      manifest = read_manifest(batch.dir)
      existing = manifest["sets"].find { |set| set["name"] == name && set["scope"] == scope && set["project"] == project }
      return existing if existing
      sha = nil
      if File.directory?(path)
        dest = File.join(batch.dir, "templates", scope, project.to_s, name)
        FileUtils.rm_rf(dest)
        root = File.realpath(path)
        LibraryStore.files_of(path).each do |rel|
          FileUtils.mkdir_p(File.dirname(File.join(dest, rel)))
          FileUtils.cp(File.join(root, rel), File.join(dest, rel))
        end
        FileUtils.mkdir_p(dest)
        sha = LibraryStore.tree_sha(dest)
      end
      entry = {"name" => name, "scope" => scope, "project" => project, "sha_before" => sha}
      manifest["sets"] += [entry]
      write_manifest(batch, manifest)
      entry
    end

    # Records what a set is after the batch wrote it, so a restore can tell an edit made since.
    #
    # @param batch [Batch]
    # @param name [String]
    # @param scope [String]
    # @param project [String, nil]
    # @param sha_after [String, nil] {LibraryStore.tree_sha} of the set as written; nil for one the batch deleted
    # @return [Hash, nil] the entry
    def finish_set(batch, name:, scope:, sha_after:, project: nil)
      manifest = read_manifest(batch.dir)
      entry = manifest["sets"].find { |set| set["name"] == name && set["scope"] == scope && set["project"] == project }
      return unless entry
      entry["sha_after"] = sha_after
      write_manifest(batch, manifest)
      entry
    end

    # @param manifest [Hash] from {#find} or {#list}
    # @param set [Hash] one of its `sets`
    # @return [String, nil] the folder holding the batch's copy of the set, nil when it held none
    def set_copy_path(manifest, set)
      plain_name!(set["name"])
      path = File.join(@config.tmuxinator_backups_dir, manifest["id"], "templates", set["scope"].to_s, set["project"].to_s, set["name"])
      path if File.directory?(path)
    end

    # Records what a workspace's files are after the batch wrote them, so a restore can tell an edit made
    # since from the batch's own write. An entry with no `sha_after` key was never written (the batch stopped
    # before it, or {#finish} was not reached); `sha_after: nil` means the batch deleted the file.
    #
    # @param batch [Batch]
    # @param name [String]
    # @param sha_after [String, nil] sha256 of the config as written; nil for one the batch deleted
    # @param record_sha_after [String, nil] sha256 of the render record as written
    # @return [Hash, nil] the entry, nil when the batch has none for +name+
    def finish(batch, name:, sha_after:, record_sha_after: nil)
      manifest = read_manifest(batch.dir)
      entry = manifest["entries"].find { |existing| existing["name"] == name }
      return unless entry
      entry["sha_after"] = sha_after
      entry["record_sha_after"] = record_sha_after
      write_manifest(batch, manifest)
      entry
    end

    # A batch of every entry at once, for `template backup`.
    #
    # @param entries [Array<Hash>] each `{name:, path:}`
    # @param reason [String]
    # @param templates [Hash{String => String}]
    # @return [Batch]
    def create(entries, reason:, templates: {})
      batch = self.open(reason: reason, templates: templates)
      entries.each { |entry| add(batch, name: entry.fetch(:name), path: entry.fetch(:path)) }
      batch
    end

    # Removes a batch that holds no entries (every row was skipped), so apply leaves nothing behind.
    #
    # @param batch [Batch]
    # @return [Boolean] whether it was removed
    def discard_if_empty(batch)
      manifest = read_manifest(batch.dir)
      return false unless manifest && manifest["entries"].empty? && manifest["sets"].empty?
      FileUtils.rm_rf(batch.dir)
      true
    end

    # @return [Array<Hash>] every readable manifest, newest first (an unreadable batch directory is left out)
    def list
      return [] unless Dir.exist?(@config.tmuxinator_backups_dir)
      Dir.children(@config.tmuxinator_backups_dir).select { |id| id.match?(ID_PATTERN) }.filter_map { |id|
        read_manifest(File.join(@config.tmuxinator_backups_dir, id))
      }.sort_by { |manifest| [created_at(manifest) || Time.at(0), manifest["id"]] }.reverse
    end

    # @param id [String] a batch id
    # @return [Hash] its manifest, with `dir`
    # @raise [Workspace::Error] `backup_not_found` for an id no readable batch has, or one that is not shaped like an id
    def find(id)
      dir = File.join(@config.tmuxinator_backups_dir, id.to_s)
      manifest = id.to_s.match?(ID_PATTERN) ? read_manifest(dir) : nil
      unless manifest && manifest["id"] == id
        raise Workspace::Error.new("No tmuxinator backup #{id.to_s[0, 60].inspect}. List them with: workspace template backups list",
          code: "backup_not_found", details: {"id" => id.to_s[0, 60]})
      end
      manifest
    end

    # @param batch_or_manifest [Batch, Hash] a batch, or a manifest from {#find} or {#list}
    # @param name [String]
    # @param kind [Symbol] `:config` or `:record`
    # @raise [ArgumentError] when +name+ is not a plain file name
    # @return [String, nil] the path of the copy of that file in the batch, nil when the batch holds none
    def copy_path(batch_or_manifest, name, kind: :config)
      plain_name!(name)
      dir = batch_or_manifest.is_a?(Batch) ? batch_or_manifest.dir : File.join(@config.tmuxinator_backups_dir, batch_or_manifest["id"])
      path = File.join(dir, (kind == :config) ? "#{name}.yml" : "#{name}.record.json")
      path if File.file?(path)
    end

    # Removes the batches past the limits. A workspace's newest batch is never removed, so its last backup
    # outlives both limits; a batch whose `created_at` can't be read is never removed by +max_age+. An id-shaped
    # directory with no readable manifest, more than an hour old (an `open` that died), is swept too.
    #
    # @param keep [Integer, nil] how many of the newest batches stay; nil sets no count limit
    # @param max_age [Numeric, nil] seconds; an older batch goes; nil sets no age limit
    # @return [Array<String>] the ids removed
    def prune(keep: nil, max_age: nil)
      batches = list
      newest_for = {}
      batches.each { |manifest| manifest["entries"].each { |entry| newest_for[entry["name"]] ||= manifest["id"] } }
      protected_ids = newest_for.values.uniq
      cutoff = max_age && (@clock.now.utc - max_age)
      removed = []
      batches.each_with_index do |manifest, index|
        next if protected_ids.include?(manifest["id"])
        made = created_at(manifest)
        too_many = keep && index >= keep
        too_old = cutoff && made && made < cutoff
        next unless too_many || too_old
        FileUtils.rm_rf(File.join(@config.tmuxinator_backups_dir, manifest["id"]))
        removed << manifest["id"]
      end
      removed + sweep_orphans(batches)
    end

    private

    def plain_name!(name)
      return if name.is_a?(String) && !name.empty? && name == File.basename(name) && !%w[. ..].include?(name) && !name.include?("\0")
      raise ArgumentError, "not a plain workspace name: #{name.to_s[0, 60].inspect}"
    end

    def sweep_orphans(batches)
      known = batches.map { |manifest| manifest["id"] }
      return [] unless Dir.exist?(@config.tmuxinator_backups_dir)
      Dir.children(@config.tmuxinator_backups_dir).select { |id| id.match?(ID_PATTERN) && !known.include?(id) }.select { |id|
        dir = File.join(@config.tmuxinator_backups_dir, id)
        File.directory?(dir) && File.mtime(dir) < @clock.now - ORPHAN_AGE
      }.each { |id| FileUtils.rm_rf(File.join(@config.tmuxinator_backups_dir, id)) }
    rescue SystemCallError
      []
    end

    # Copies +source+ into the batch as +as+, writing the bytes it hashes, and answers their sha256; nil when the
    # source does not exist. Only a missing source is nil: a failed write raises, so a real file is never
    # recorded as one the batch created.
    def copy(source, batch, as)
      bytes = begin
        File.open(source, File::RDONLY | File::NOFOLLOW) { |file| file.binmode.read }
      rescue Errno::ENOENT
        return nil
      rescue Errno::ELOOP
        raise Workspace::Error.new("#{source} is a symbolic link; a backup cannot put a link back, so it is not copied.",
          code: "backup_symlink", details: {"path" => source})
      end
      AtomicFile.write(File.join(batch.dir, as), bytes)
      Digest::SHA256.hexdigest(bytes)
    end

    def created_at(manifest)
      Time.iso8601(manifest["created_at"])
    rescue ArgumentError, TypeError
      nil
    end

    def read_manifest(dir)
      data = JSON.parse(File.read(File.join(dir, "manifest.json")))
      return unless data.is_a?(Hash) && data["schema"] == SCHEMA && data["entries"].is_a?(Array) && data["entries"].all?(Hash) && data["id"].is_a?(String)
      data["sets"] = [] unless data["sets"].is_a?(Array) && data["sets"].all?(Hash)
      data
    rescue SystemCallError, IOError, JSON::ParserError
      nil
    end

    def write_manifest(batch, data)
      AtomicFile.write(File.join(batch.dir, "manifest.json"), "#{JSON.pretty_generate(data)}\n")
    end
  end
end
