require "json"

module Workspace
  # Wraps JSON-persisted workspace state for tracked sessions.
  class State
    # @param config [Workspace::Config] configuration providing state_file path
    # @param logger [Workspace::Logger] debug logger
    def initialize(config:, logger: Workspace::Logger.new)
      @config = config
      @logger = logger
      @data = {}
    end

    # @return [State] self, after loading state from disk (empty if missing or corrupt)
    def load
      @logger.debug { "state: loading from #{@config.state_file}" }
      @data = if File.exist?(@config.state_file)
        JSON.parse(File.read(@config.state_file))
      else
        @logger.debug { "state: file not found, starting empty" }
        {}
      end
      @logger.debug { "state: loaded #{@data.keys.size} project(s): #{@data.keys.join(", ")}" }
      self
    rescue JSON::ParserError
      @logger.debug { "state: corrupt JSON, resetting to empty" }
      @data = {}
      self
    end

    # @return [void]
    def save
      @logger.debug { "state: saving #{@data.keys.size} project(s) to #{@config.state_file}" }
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

    # Removes entries whose iterm_window_id is not in the given set of live IDs.
    # Does not call save; the caller is responsible for persisting changes.
    #
    # @param live_ids [Set<Integer>] set of currently live window IDs
    # @return [Array<String>] names of pruned projects
    def prune(live_ids)
      pruned = []
      @data.each_key do |project|
        wid = @data[project]["iterm_window_id"]
        unless wid && live_ids.include?(wid.to_i)
          pruned << project
        end
      end
      pruned.each { |p| @data.delete(p) }
      pruned
    end

    # @return [Hash]
    def to_h
      @data.dup
    end
  end
end
