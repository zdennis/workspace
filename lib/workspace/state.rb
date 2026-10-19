require "fileutils"
require "json"
require "securerandom"

module Workspace
  # Wraps JSON-persisted workspace state for tracked sessions.
  # The event log is the source of truth; the state file is a materialized view.
  class State
    # Seconds a save waits for the state file's lock before writing without it.
    LOCK_WAIT = 5

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
    # for migration while the log holds no state events yet, which is also
    # the case when only activity events (a lock wait, an agent's state)
    # were written before the first load. Migrating writes state events,
    # so it happens once.
    #
    # @return [State] self
    def load
      if File.exist?(@config.state_file) && !@event_log.state_events?
        @logger.debug { "state: migrating from state file to event log" }
        @data = JSON.parse(File.read(@config.state_file))
        @data = {} unless @data.is_a?(Hash)
        @data.each do |project, info|
          @event_log.append(type: "migrated", project: project, data: info)
        end
        @logger.debug { "state: migrated #{@data.keys.size} project(s)" }
      elsif @event_log.exists?
        @logger.debug { "state: reconstructing from event log" }
        @data = @event_log.reconstruct
        @logger.debug { "state: reconstructed #{@data.keys.size} project(s): #{@data.keys.join(", ")}" }
        @event_log.warn_if_large
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

    # Reconstructs state from the event log and writes the state file. A log
    # that can't be read leaves the state file as it was, rather than
    # writing it out empty.
    #
    # The read of the log and the rename happen under an exclusive flock on
    # a sidecar lock file. Without it, a save that read the log before
    # another process's append could rename its file in after that
    # process's save, and the state file would lose the other entry. A lock
    # that can't be opened or taken within {LOCK_WAIT} seconds (a stuck
    # holder, a filesystem without flock) does not stop the save: it writes
    # anyway, as saves did before the lock.
    #
    # @return [void]
    # @raise [Workspace::Error] if the event log can't be read
    def save
      lock = open_lock
      @logger.debug { "state: saving without the state file lock" } unless lock && acquire(lock)
      write_state_file
    ensure
      lock&.close
    end

    # @param key [String]
    # @return [Object, nil]
    def [](key)
      @data[key]
    end

    # Sets a project's state and appends a state_set event to the log. This
    # merges +value+'s keys into the project's existing entry (as does every
    # other state event type) rather than replacing it; dropping a key means
    # deleting the project first, as launch's +replace_state+ does.
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

    def open_lock
      File.open("#{@config.state_file}.lock", File::RDWR | File::CREAT, 0o600)
    rescue SystemCallError => e
      @logger.debug { "state: can't open the lock file (#{e.class}: #{e.message})" }
      nil
    end

    def acquire(lock)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + LOCK_WAIT
      until lock.flock(File::LOCK_EX | File::LOCK_NB)
        return false if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
        sleep 0.01
      end
      true
    rescue SystemCallError => e
      @logger.debug { "state: can't lock the state file (#{e.class}: #{e.message})" }
      false
    end

    def write_state_file
      @data = @event_log.reconstruct(strict: true)
      @logger.debug { "state: saving #{@data.keys.size} project(s) to #{@config.state_file}" }
      backup_state_file
      tmp = "#{@config.state_file}.#{Process.pid}.#{SecureRandom.hex(4)}.tmp"
      File.write(tmp, JSON.pretty_generate(@data))
      File.rename(tmp, @config.state_file)
    rescue
      File.delete(tmp) if tmp && File.exist?(tmp)
      raise
    end

    def backup_state_file
      src = @config.state_file
      return unless File.exist?(src)
      FileUtils.cp(src, "#{src}.bak")
    rescue => e
      @logger.debug { "state: backup failed: #{e.message}" }
    end
  end
end
