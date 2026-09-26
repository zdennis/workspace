module Workspace
  # Reads the `locks:` block from a project's YAML config, as written by
  # `workspace config set locks.idle_grace <duration>`.
  #
  # A bad stored value never stops a lock command: it falls back to the
  # default with a warning, since `config set` already rejects bad input and
  # a hand-edited typo should not wedge every agent waiting on a lock.
  class LockConfig
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
      seconds = DevConfig.parse_duration(value)
      raise ArgumentError, "must be greater than 0, got #{value.inspect}" unless seconds.positive?
      seconds
    end

    # @param name [String] project name (already resolved to its parent, if a worktree)
    # @return [Numeric] seconds an idle agent may keep a lock before the head
    #   waiter may take it over; {LockStore::DEFAULT_IDLE_GRACE} when unset or invalid
    def idle_grace_for(name)
      settings = @project_settings.load(name)
      locks = settings.is_a?(Hash) ? settings["locks"] : nil
      return LockStore::DEFAULT_IDLE_GRACE unless locks.is_a?(Hash) && locks.key?("idle_grace")
      self.class.parse_idle_grace(locks["idle_grace"])
    rescue ArgumentError => e
      @error_output.puts "Warning: invalid locks.idle_grace for '#{name}' (#{e.message}); using #{LockStore::DEFAULT_IDLE_GRACE}s."
      LockStore::DEFAULT_IDLE_GRACE
    end
  end
end
