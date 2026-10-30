module Workspace
  # Checks a note path (a relative path inside a workspace's notes
  # directory). The rules are a deliberate, ASCII-only subset of
  # workspace-ui's +noteSegments+. The check is advisory: workspace-ui
  # checks again when it opens the note.
  module NotePath
    MAX_SEGMENTS = 4
    MAX_SEGMENT_BYTES = 255
    SEGMENT = /\A[A-Za-z0-9._-]+\z/
    EXTENSIONS = %w[.md .markdown].freeze
    private_constant :MAX_SEGMENTS, :MAX_SEGMENT_BYTES, :SEGMENT, :EXTENSIONS

    # Raised for a path that is not an acceptable note path.
    class Refused < Error
      # @return [String] why the path was refused
      attr_reader :reason

      # @param reason [String] why the path was refused
      def initialize(reason)
        @reason = reason
        super
      end
    end

    # Checks the shape of +rel+ without touching the filesystem.
    #
    # @param rel [String] a path relative to the notes directory
    # @return [Array<String>] the path's segments
    # @raise [Refused] if the shape is not acceptable
    def self.segments(rel)
      raise Refused, "must be a string" unless rel.is_a?(String)
      unless [Encoding::UTF_8, Encoding::US_ASCII, Encoding::BINARY].include?(rel.encoding) &&
          rel.dup.force_encoding(Encoding::UTF_8).valid_encoding?
        raise Refused, "must be valid UTF-8"
      end
      raise Refused, "must not be empty" if rel.empty?
      raise Refused, "must be relative" if rel.start_with?("/")

      parts = rel.split("/", -1)
      raise Refused, "must not have an empty segment" if parts.any?(&:empty?)
      raise Refused, "must have at most #{MAX_SEGMENTS} segments" if parts.size > MAX_SEGMENTS
      parts.each { |part| check_segment(part) }
      raise Refused, "must end in .md or .markdown" unless EXTENSIONS.include?(File.extname(parts.last))
      parts
    end

    # Checks +rel+ against the files in +dir+: the shape, then that the
    # note is a regular file whose real path is exactly the real path of
    # +dir+ plus +rel+. That refuses any symlink inside +dir+ (only +dir+
    # itself may be a link) and any case mismatch, since the real path
    # carries the on-disk case.
    #
    # @param rel [String] a path relative to the notes directory
    # @param dir [String] the notes directory
    # @return [String] +rel+ exactly as given
    # @raise [Refused] if the path is not an acceptable existing note
    def self.resolve(rel, dir)
      segments(rel)
      raise Refused, "the notes directory does not exist" unless File.directory?(dir.to_s)
      real_dir = File.realpath(dir)
      real = File.realpath(File.join(dir, rel))
      raise Refused, "must not go through a symlink or differ in case from the file on disk" unless real == "#{real_dir}/#{rel}"
      raise Refused, "not a file" unless File.file?(real)
      rel
    rescue Errno::ENOENT
      raise Refused, "no such file in the notes directory"
    rescue Errno::ELOOP
      raise Refused, "too many levels of symbolic links"
    rescue Errno::EACCES, Errno::EPERM
      raise Refused, "permission denied in the notes directory"
    rescue Errno::ENOTDIR
      raise Refused, "a part of the path is not a directory"
    rescue Errno::ENAMETOOLONG
      raise Refused, "a name in the path is too long"
    rescue SystemCallError => e
      raise Refused, "cannot read the note: #{e.class.name.split("::").last}"
    end

    # Joins checked segments into the path of a link. With the segment
    # charset every character is unreserved, so nothing is encoded.
    #
    # @param segments [Array<String>] segments from {.segments}
    # @return [String]
    def self.url_path(segments)
      segments.join("/")
    end

    def self.check_segment(part)
      raise Refused, "a name must not start with a dot" if part.start_with?(".")
      raise Refused, "node_modules is not allowed" if part == "node_modules"
      raise Refused, "a name may use only letters, digits, dot, hyphen and underscore" unless SEGMENT.match?(part)
      raise Refused, "a name must be at most #{MAX_SEGMENT_BYTES} characters" if part.bytesize > MAX_SEGMENT_BYTES
    end
    private_class_method :check_segment
  end
end
