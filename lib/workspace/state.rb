require "json"

module Workspace
  # Wraps JSON-persisted workspace state for tracked sessions.
  class State
    # @param config [Workspace::Config] configuration providing state_file path
    def initialize(config:)
      @config = config
      @data = {}
    end

    # @return [State] self, after loading state from disk (empty if missing or corrupt)
    def load
      @data = if File.exist?(@config.state_file)
        JSON.parse(File.read(@config.state_file))
      else
        {}
      end
      self
    rescue JSON::ParserError
      @data = {}
      self
    end

    # @return [void]
    def save
      File.write(@config.state_file, JSON.pretty_generate(@data))
    end

    # @param key [String]
    # @return [Object, nil]
    def [](key)
      @data[key]
    end

    # @param key [String]
    # @param value [Object]
    # @return [Object]
    def []=(key, value)
      @data[key] = value
    end

    # @param key [String]
    # @return [Object, nil]
    def delete(key)
      @data.delete(key)
    end

    # @return [Array<String>]
    def keys
      @data.keys
    end

    # @return [Boolean]
    def empty?
      @data.empty?
    end

    # @yield [key, value]
    # @return [Enumerator, void]
    def each(&block)
      @data.each(&block)
    end

    # @param keys [Array<String>]
    # @return [Object, nil]
    def dig(*keys)
      @data.dig(*keys)
    end

    # @return [Hash]
    def to_h
      @data.dup
    end
  end
end
