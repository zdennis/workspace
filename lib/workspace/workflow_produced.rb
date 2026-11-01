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
      rule = if stat.symlink? then "symlink"
      elsif !stat.file? then "not_regular_file"
      elsif stat.size.zero? then "empty"
      end
      Result.new(true, rule, stat.mtime)
    rescue SystemCallError
      Result.new(false, nil, nil)
    end

    def self.legacy(path)
      return Result.new(false, nil, nil) unless File.exist?(path)
      Result.new(true, nil, File.mtime(path))
    rescue SystemCallError
      Result.new(false, nil, nil)
    end
    private_class_method :legacy
  end
end
