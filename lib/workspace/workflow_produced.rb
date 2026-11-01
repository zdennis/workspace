require "digest"

module Workspace
  # The one check of a file a workflow step `produces`, shared by the engine's
  # decision at a turn's end, `step status` and anything else that asks whether
  # the file is there.
  #
  # A run started with the marker `"produces_check" => "strict"` in its stored
  # definition snapshot needs a regular file that is not a symlink and is not
  # empty; the file is read with `File.lstat`, so a link is never followed. A
  # run stored without the marker keeps the check it was started under: the
  # path exists (a link or directory counts) and its mtime is read as before.
  module WorkflowProduced
    MARKER_KEY = "produces_check".freeze
    STRICT = "strict".freeze

    # What the check found. `rule` is nil for a file that passes, else
    # `symlink`, `not_regular_file` or `empty`; `exists` is false when nothing
    # is at the path (a link to nothing is a `symlink`, not missing).
    Result = Struct.new(:exists, :rule, :mtime) do
      # @param started [Time, nil] when the attempt began
      # @return [Boolean] whether the file was written during this attempt
      def current?(started)
        exists && rule.nil? && (started.nil? || mtime >= started)
      end
    end

    # @param definition [Hash] a run's stored definition snapshot
    # @return [Boolean] whether the run was started under the strict rules
    def self.strict?(definition)
      definition.is_a?(Hash) && definition[MARKER_KEY] == STRICT
    end

    # @param path [String]
    # @param strict [Boolean]
    # @return [Result]
    def self.inspect_file(path, strict:)
      return legacy(path) unless strict
      stat = File.lstat(path)
      rule = link_rule(stat) || (stat.size.zero? ? "empty" : nil)
      Result.new(true, rule, stat.mtime)
    rescue SystemCallError
      Result.new(false, nil, nil)
    end

    # What a file's content is when recorded: `sha256` is nil for a file past the size cap.
    Content = Struct.new(:sha256, :bytes, :too_large)

    # Hashes a file under the same rule as {.inspect_file}: a regular file, never a link as the last part
    # of the path (a linked parent directory is followed). Stats first; a file above `max_bytes` is not read.
    # At most the stat'd size is read, so a file still being written cannot keep it going.
    #
    # @param path [String]
    # @param max_bytes [Integer]
    # @param sink [#<<, nil] given every chunk hashed, so a copy holds the bytes the hash covers
    # @param check [#call, nil] given the opened handle before anything is read; a falsy answer reads nothing and gives nil
    # @return [Content, nil] nil when the file is missing, a link, not a regular file or unreadable
    def self.digest(path, max_bytes:, sink: nil, check: nil)
      return nil if link_rule(File.lstat(path))
      File.open(path, File::RDONLY | File::NOFOLLOW | File::NONBLOCK) do |io|
        stat = io.stat
        return nil unless stat.file?
        return nil if check && !check.call(io)
        return Content.new(nil, stat.size, true) if stat.size > max_bytes
        digest = Digest::SHA256.new
        remaining = stat.size
        read = 0
        while remaining > 0 && (chunk = io.read([65_536, remaining].min))
          digest << chunk
          sink&.<<(chunk)
          read += chunk.bytesize
          remaining -= chunk.bytesize
        end
        Content.new(digest.hexdigest, read, false)
      end
    rescue SystemCallError, IOError
      nil
    end

    # @return [String, nil] `symlink` or `not_regular_file`, the rules of an lstat that need no size
    def self.link_rule(stat)
      if stat.symlink? then "symlink"
      elsif !stat.file? then "not_regular_file"
      end
    end
    private_class_method :link_rule

    def self.legacy(path)
      return Result.new(false, nil, nil) unless File.exist?(path)
      Result.new(true, nil, File.mtime(path))
    rescue SystemCallError
      Result.new(false, nil, nil)
    end
    private_class_method :legacy
  end
end
