module Workspace
  # Reads the `locks:` block from a project's YAML config, as written by
  # `workspace config set locks.idle_grace <duration>`.
  #
  # A bad stored value never stops a lock command: it falls back to the
  # default with a warning, since `config set` already rejects bad input and
  # a hand-edited typo should not wedge every agent waiting on a lock.
  class LockConfig
    # Smallest accepted `locks.ps_timeout`, in seconds. Below this, `ps`
    # times out on nearly every call, so liveness checks come back unknown
    # (treated as alive) and a lock queue can stall behind a clearing
    # marker that never gets to show dead.
    MIN_PS_TIMEOUT = ConfigSchema::MIN_PS_TIMEOUT

    # Largest accepted `locks.ps_timeout`, in seconds.
    MAX_PS_TIMEOUT = ConfigSchema::MAX_PS_TIMEOUT

    # @param project_settings [Workspace::ProjectSettings]
    # @param error_output [IO] where a warning about an invalid value goes
    def initialize(project_settings:, error_output: $stderr)
      @project_settings = project_settings
      @error_output = error_output
    end

    # Parses and validates an idle grace period.
    #
    # @param value [String, Numeric] seconds, or a duration like "5m"
    # @return [Numeric] seconds, always greater than 0
    # @raise [ArgumentError] if value isn't a positive duration
    def self.parse_idle_grace(value)
      ConfigSchema.parse("locks.idle_grace", value)
    end

    # @param name [String] project name (already resolved to its parent, if a worktree)
    # @return [Numeric] seconds an idle agent may keep a lock before the head
    #   waiter may take it over; {LockStore::DEFAULT_IDLE_GRACE} when unset or invalid
    def idle_grace_for(name)
      setting(name, "idle_grace")
    end

    # Parses and validates a `ps` timeout.
    #
    # @param value [String, Numeric] seconds, or a duration like "5m"
    # @return [Numeric] seconds, always in [{MIN_PS_TIMEOUT}, {MAX_PS_TIMEOUT}]
    # @raise [ArgumentError] if value isn't a duration in that range
    def self.parse_ps_timeout(value)
      ConfigSchema.parse("locks.ps_timeout", value)
    end

    # @param name [String] project name (already resolved to its parent, if a worktree)
    # @return [Numeric] seconds to wait for `ps` before killing it;
    #   {ProcessTree::DEFAULT_TIMEOUT} when unset or invalid
    def ps_timeout_for(name)
      setting(name, "ps_timeout")
    end

    # Parses and validates a stale-lock reap interval.
    #
    # @param value [String, Numeric] seconds, or a duration like "5m"
    # @return [Numeric] seconds, always greater than 0
    # @raise [ArgumentError] if value isn't a positive duration
    def self.parse_reap_interval(value)
      ConfigSchema.parse("locks.reap_interval", value)
    end

    # @param name [String] project name (already resolved to its parent, if a worktree)
    # @return [Numeric] seconds between the session-monitor daemon's stale-lock
    #   sweeps; {LockReaper::DEFAULT_INTERVAL} when unset or invalid
    def reap_interval_for(name)
      setting(name, "reap_interval")
    end

    private

    def setting(name, key)
      schema_key = "locks.#{key}"
      default = ConfigSchema.default(schema_key)
      settings = @project_settings.load(name)
      locks = settings.is_a?(Hash) ? settings["locks"] : nil
      return default unless locks.is_a?(Hash) && locks.key?(key)
      ConfigSchema.parse(schema_key, locks[key])
    rescue Workspace::ConfigParseError => e
      @error_output.puts "Warning: #{e.message} Using #{default}s for locks.#{key}."
      default
    rescue ArgumentError => e
      @error_output.puts "Warning: invalid locks.#{key} for '#{name}' (#{e.message}); using #{default}s."
      default
    end
  end
end
