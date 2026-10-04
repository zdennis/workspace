require "fileutils"

module Workspace
  # Bounds how many session monitors scan at once, machine-wide.
  #
  # Every running `workspace agentd` daemon polls its tmux session on a fixed
  # interval, and each poll spawns a handful of processes (`tmux list-panes`,
  # one `ps` snapshot, one `tmux capture-pane` per pane). With many daemons on
  # one machine those spawns stack up around the clock, so scans take turns
  # instead: a monitor holds one of N slot files for the duration of a scan,
  # and one that can't take a slot skips that tick — it never waits. Under
  # load the effective per-daemon interval becomes roughly
  # `interval × ceil(daemons / limit)`.
  #
  # A slot is a plain file taken with a non-blocking exclusive flock, which
  # the kernel releases when the fd closes or the holder dies, so a crashed
  # daemon never strands a slot.
  class ScanSlotLimiter
    # Concurrent scans allowed when +limit+ is not given and
    # WORKSPACE_SCAN_CONCURRENCY is unset or not a positive integer.
    DEFAULT_LIMIT = 4

    # @param dir [String] shared directory holding the slot files
    # @param limit [Integer, nil] how many scans may run at once. A positive
    #   integer wins; otherwise WORKSPACE_SCAN_CONCURRENCY is read (a positive
    #   integer there wins too), falling back to {DEFAULT_LIMIT}.
    # @param logger [Workspace::Logger] debug logger
    def initialize(dir:, limit: nil, logger: Workspace::Logger.new)
      @dir = dir
      @limit = self.class.parse_limit(limit) ||
        self.class.parse_limit(ENV["WORKSPACE_SCAN_CONCURRENCY"]) || DEFAULT_LIMIT
      @logger = logger
    end

    # @return [Integer] how many scans may run at once
    attr_reader :limit

    # Parses a scan concurrency limit. Anything that is not a positive
    # integer reads as nil, so its caller falls back to the default.
    #
    # @param value [String, Integer, nil] the limit to parse
    # @return [Integer, nil] the limit, or nil when it is not usable
    def self.parse_limit(value)
      return nil if value.nil? || value.to_s.strip.empty?
      parsed = Integer(value.to_s)
      parsed if parsed.positive?
    rescue ArgumentError, TypeError
      nil
    end

    # Runs the block while holding one of the limiter's slots. Every slot
    # busy means other monitors are scanning, so the caller skips this tick
    # rather than waiting one out. A limiter that can't even open a slot
    # file fails open and runs the block anyway: monitoring must never stop
    # over the limiter itself.
    #
    # @yield [] the scan to run under a slot
    # @return [Object, nil] the block's value when a slot was held (or the
    #   limiter failed open), nil when every slot was busy
    def with_scan_slot
      slot = take_slot
    rescue SystemCallError, IOError => e
      @logger.debug { "scan slot limiter: could not take a slot in #{@dir} (#{e.class}: #{e.message}); scanning without one" }
      yield
    else
      return @logger.debug { "scan slot limiter: every slot is busy; skipping this scan" } unless slot

      begin
        yield
      ensure
        begin
          slot.close
        rescue IOError, SystemCallError
          nil
        end
      end
    end

    private

    # Tries each slot file in turn and returns the first one taken, or nil
    # when every slot is held. The shared directory is created on first use.
    # flock is non-blocking, so a busy slot is passed over at once.
    #
    # @return [File, nil] the fd of the slot taken, whose flock is held until
    #   it is closed, or nil when no slot was free
    def take_slot
      FileUtils.mkdir_p(@dir, mode: 0o700)
      @limit.times do |index|
        file = File.open(File.join(@dir, "slot-#{index}"), File::RDWR | File::CREAT, 0o600)
        return file if file.flock(File::LOCK_EX | File::LOCK_NB)

        file.close
      end
      nil
    end
  end
end
