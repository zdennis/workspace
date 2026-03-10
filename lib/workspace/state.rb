require "fileutils"
require "json"

module Workspace
  # Wraps JSON-persisted workspace state for tracked sessions.
  # The event log is the source of truth; the state file is a materialized view.
  class State
    # @param config [Workspace::Config] configuration providing state_file path
    # @param event_log [Workspace::EventLog] append-only event log
    # @param logger [Workspace::Logger] debug logger
    def initialize(config:, event_log:, logger: Workspace::Logger.new)
      @config = config
      @event_log = event_log
      @logger = logger
      @data = {}
    end

    # @return [Workspace::EventLog] the event log backing this state
    attr_reader :event_log

    # Loads state by replaying the event log. Falls back to the state file
    # for migration if no event log exists yet.
    #
    # @return [State] self
    def load
      if @event_log.exists?
        @logger.debug { "state: reconstructing from event log" }
        @data = @event_log.reconstruct
        @logger.debug { "state: reconstructed #{@data.keys.size} project(s): #{@data.keys.join(", ")}" }
        @event_log.warn_if_large
      elsif File.exist?(@config.state_file)
        @logger.debug { "state: migrating from state file to event log" }
        @data = JSON.parse(File.read(@config.state_file))
        @data.each do |project, info|
          @event_log.append(type: "migrated", project: project, data: info)
        end
        @logger.debug { "state: migrated #{@data.keys.size} project(s)" }
      else
        @logger.debug { "state: no event log or state file, starting empty" }
        @data = {}
      end
      self
    rescue JSON::ParserError
      @logger.debug { "state: corrupt state file, starting empty" }
      @data = {}
      self
    end

    # Reconstructs state from the event log and writes the state file.
    #
    # @return [void]
    def save
      @data = @event_log.reconstruct
      @logger.debug { "state: saving #{@data.keys.size} project(s) to #{@config.state_file}" }
      backup_state_file
      tmp = "#{@config.state_file}.tmp"
      File.write(tmp, JSON.pretty_generate(@data))
      File.rename(tmp, @config.state_file)
    end

    # @param key [String]
    # @return [Object, nil]
    def [](key)
      @data[key]
    end

    # Sets a project's state and appends a state_set event to the log.
    #
    # @param key [String]
    # @param value [Object]
    # @return [Object]
    def []=(key, value)
      @event_log.append(type: "state_set", project: key, data: value)
      @data[key] = value
    end

    # Removes a project from state and appends a state_removed event to the log.
    #
    # @param key [String]
    # @return [Object, nil]
    def delete(key)
      @event_log.append(type: "state_removed", project: key)
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
      pruned.each { |p| delete(p) }
      pruned
    end

    # @return [Hash]
    def to_h
      @data.dup
    end

    private

    def backup_state_file
      src = @config.state_file
      return unless File.exist?(src)
      FileUtils.cp(src, "#{src}.bak")
    rescue => e
      @logger.debug { "state: backup failed: #{e.message}" }
    end
  end
end
