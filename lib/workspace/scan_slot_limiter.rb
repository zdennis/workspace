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
  #
  # The slot is re-entrant per thread and directory: a call made while this
  # thread already holds a slot for this limiter's directory runs under the
  # hold it already has. flock is held per open fd, and a second
  # non-blocking lock on another fd of the same file fails even from the
  # process holding the first one, so a nested call — a monitor's scan
  # reading a pane through a context reader whose own limiter works the
  # same directory — would always read every slot as busy without it.
  class ScanSlotLimiter
    # Concurrent scans allowed when +limit+ is not given and
    # WORKSPACE_SCAN_CONCURRENCY is unset or not a positive integer. One at a
    # time by default: a scan is several spawned processes, and with many
    # daemons polling, one scan at a time keeps their spawn pressure flat.
    DEFAULT_LIMIT = 1

    # Largest limit honored, however the limit was given. A mistyped value
    # must not materialize thousands of slot files in the shared state dir,
    # opened and closed by every daemon on every tick.
    MAX_LIMIT = 64

    # @param dir [String] shared directory holding the slot files
    # @param limit [Integer, nil] how many scans may run at once. A positive
    #   integer wins (values above {MAX_LIMIT} are clamped); otherwise
    #   WORKSPACE_SCAN_CONCURRENCY is read, falling back to {DEFAULT_LIMIT}.
    # @param logger [Workspace::Logger] debug logger
    def initialize(dir:, limit: nil, logger: Workspace::Logger.new)
      @dir = dir
      @limit = self.class.parse_limit(limit) ||
        self.class.parse_limit(ENV["WORKSPACE_SCAN_CONCURRENCY"]) || DEFAULT_LIMIT
      @logger = logger
    end

    # @return [Integer] how many scans may run at once
    attr_reader :limit

    # Parses a scan concurrency limit. Positive integers are capped at
    # {MAX_LIMIT}; anything else reads as nil, so its caller falls back to the
    # default.
    #
    # @param value [String, Integer, nil] the limit to parse
    # @return [Integer, nil] the limit, or nil when it is not usable
    def self.parse_limit(value)
      return nil if value.nil? || value.to_s.strip.empty?
      parsed = Integer(value.to_s)
      parsed.clamp(1, MAX_LIMIT) if parsed.positive?
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
      depth = holds[@dir]
      return run_nested(depth) { yield } if depth&.positive?

      slot = take_slot
    rescue SystemCallError, IOError => e
      @logger.debug { "scan slot limiter: could not take a slot in #{@dir} (#{e.class}: #{e.message}); scanning without one" }
      yield
    else
      return @logger.debug { "scan slot limiter: every slot is busy; skipping this scan" } unless slot

      begin
        holds[@dir] = 1
        yield
      ensure
        holds.delete(@dir)
        begin
          slot.close
        rescue IOError, SystemCallError
          nil
        end
      end
    end

    private

    # Runs a scan nested inside a slot this thread already holds for this
    # directory. The nested caller is in the same process as the holder, so
    # the hold already covers it: no second slot is taken or closed, and the
    # depth is restored to what the enclosing scan leaves behind, whatever
    # the nested scan does.
    #
    # @yield [] the nested scan
    # @return [Object] the block's value
    def run_nested(depth)
      holds[@dir] = depth + 1
      begin
        yield
      ensure
        holds[@dir] = depth
      end
    end

    # The per-thread slot hold depths, keyed on the slot directory. A nested
    # call is in the calling thread's own process whatever limiter instance
    # it went through — every limiter over a directory contends for that
    # directory's same slot files — so the hold is tracked in the thread,
    # not the instance.
    #
    # @return [Hash] slot directory to hold depth for this thread
    def holds
      Thread.current[:workspace_scan_slot_holds] ||= {}
    end

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
