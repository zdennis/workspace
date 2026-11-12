require "digest"

module Workspace
  # The file-level steps `template apply --rollback-all-on-error` and `template restore` share when they put a
  # backup batch's files back: reading a file's sha256, reading a file's bytes as the batch has them, and writing
  # a file's bytes (or deleting it) through the {TmuxinatorConfigWriter}'s own rules for modes. Deciding whether a
  # file may be touched is each caller's own: a roll back leaves a changed file with a warning, `restore` refuses
  # it unless forced.
  class TemplateBatchFiles
    # @param backups [Workspace::TmuxinatorBackupStore] finds the copies in a batch
    # @param writer [Workspace::TmuxinatorConfigWriter] writes a config or record by its mode rules
    def initialize(backups:, writer:)
      @backups = backups
      @writer = writer
    end

    # @param path [String]
    # @return [String, nil] the file's sha256, nil when it does not exist
    def sha(path)
      Digest::SHA256.file(path).hexdigest
    rescue Errno::ENOENT
      nil
    end

    # @param path [String]
    # @return [String, nil] the file's bytes, nil when it does not exist
    def read(path)
      File.binread(path)
    rescue Errno::ENOENT
      nil
    end

    # @param entry [Hash] a manifest entry
    # @param kind [Symbol] `:config` or `:record`
    # @return [Array(String, String, Object)] the file's path, its sha256 before the batch and its sha256 after
    #   (`:unknown` for an entry the batch never finished)
    def facts(entry, kind)
      if kind == :record
        [entry["record_path"], entry["record_sha_before"], entry.fetch("record_sha_after", :unknown)]
      else
        [entry["path"], entry["sha_before"], entry.fetch("sha_after", :unknown)]
      end
    end

    # @param manifest [Hash] the batch's manifest, from {TmuxinatorBackupStore#find}
    # @param entry [Hash] one of its entries
    # @param kind [Symbol] `:config` or `:record`
    # @return [String, nil] the file's bytes as they were before the batch; nil when the batch created it
    # @raise [Workspace::Error] when the batch holds no copy of a file it says it had
    def before_bytes(manifest, entry, kind)
      path, before, = facts(entry, kind)
      return nil if before.nil?
      copy = @backups.copy_path(manifest, entry["name"], kind: kind)
      raise Error, "The backup #{manifest["id"]} holds no copy of #{path}." unless copy
      File.binread(copy)
    end

    # Writes a file's bytes, or deletes it for nil. An existing file keeps its own mode; a new config gets the
    # umask's and a new record 0600, as the writer makes them.
    #
    # @param entry [Hash] a manifest entry
    # @param kind [Symbol] `:config` or `:record`
    # @param bytes [String, nil]
    # @return [void]
    # @raise [SystemCallError] when the file can't be written or deleted
    def write(entry, kind, bytes)
      path = facts(entry, kind).first
      if bytes.nil?
        File.delete(path) if File.exist?(path)
      elsif kind == :record
        @writer.put_record(entry["name"], bytes)
      else
        @writer.put_config(entry["name"], bytes)
      end
    end

    # Puts one file of the entry back as it was before the batch.
    #
    # @param manifest [Hash]
    # @param entry [Hash]
    # @param kind [Symbol]
    # @return [void]
    def put(manifest, entry, kind)
      write(entry, kind, before_bytes(manifest, entry, kind))
    end
  end
end
