require "digest"
require "yaml"

module Workspace
  # Reads one config YAML file for `config show/validate --json`, reporting a
  # file that can't be parsed as data (message, line, column) instead of
  # raising, and recording where each key sits so a problem can point at it.
  #
  # Unlike {ProjectSettings#load}, which refuses a bad file, this is for
  # callers that report on the file rather than act on it.
  class ConfigFile
    # What one read found.
    #
    # @!attribute layer [String] "worktree", "project" or "global"
    # @!attribute path [String]
    # @!attribute exists [Boolean]
    # @!attribute etag [String, nil] "sha256:" and the hash of the file's bytes
    # @!attribute data [Hash] the parsed mapping; empty for a missing, empty or unparsable file
    # @!attribute parse_error [Hash, nil] "message", and 1-based "line" and "column" when known
    # @!attribute locations [Hash{String => Array(Integer, Integer)}] dotted key path to its 1-based [line, column]
    Result = Struct.new(:layer, :path, :exists, :etag, :data, :parse_error, :locations, keyword_init: true) do
      # @return [Boolean] whether the file's contents are usable
      def readable? = parse_error.nil?
    end

    # @param layer [String] which layer the file is, for the report
    # @param path [String] the file to read
    # @return [Result]
    def self.read(layer, path)
      return Result.new(layer: layer, path: path, exists: false, etag: nil, data: {}, parse_error: nil, locations: {}) unless File.exist?(path)

      text = File.read(path)
      etag = "sha256:#{Digest::SHA256.hexdigest(text)}"
      result = Result.new(layer: layer, path: path, exists: true, etag: etag, data: {}, parse_error: nil, locations: {})
      parse(text, result)
    rescue SystemCallError => e
      Result.new(layer: layer, path: path, exists: true, etag: nil, data: {}, parse_error: {"message" => e.message}, locations: {})
    end

    def self.parse(text, result)
      data = YAML.safe_load(text)
      if data.is_a?(Hash)
        result.data = data
        result.locations = locate(text)
      elsif !data.nil?
        result.parse_error = {"message" => "expected a mapping at the top level, got #{data.class.name.downcase}", "line" => 1, "column" => 1}
      end
      result
    rescue Psych::SyntaxError => e
      result.parse_error = {"message" => [e.problem, e.context].compact.join(" "), "line" => e.line, "column" => e.column}
      result
    rescue Psych::Exception => e
      result.parse_error = {"message" => e.message.delete_prefix("(<unknown>): ")}
      result
    end
    private_class_method :parse

    # Walks the document's mappings, recording each key's position.
    def self.locate(text)
      root = Psych.parse(text)&.root
      locations = {}
      walk(root, [], locations) if root.is_a?(Psych::Nodes::Mapping)
      locations
    end
    private_class_method :locate

    def self.walk(mapping, prefix, locations)
      mapping.children.each_slice(2) do |key, value|
        next unless key.is_a?(Psych::Nodes::Scalar)
        path = prefix + [key.value]
        locations[path.join(".")] = [key.start_line + 1, key.start_column + 1]
        walk(value, path, locations) if value.is_a?(Psych::Nodes::Mapping)
      end
    end
    private_class_method :walk
  end
end
