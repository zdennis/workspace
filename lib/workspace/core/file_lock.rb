require "fileutils"

module Workspace
  # An advisory `flock` on a sidecar lock file, held for the length of a block.
  # The lock file is made on first use; its directory is made too.
  class FileLock
    # @param path [String] the lock file
    # @param dir_mode [Integer, nil] mode for the lock file's directory when it is made
    #   (every store but ContextStore, which passes nil for the umask default)
    # @param chmod_dir [Boolean] set `dir_mode` on the directory even when it exists (LockStore only)
    # @param open_readonly [Boolean] open the lock file read-only for a shared hold (LockStore only)
    # @param make_dir [Boolean] make the lock file's directory; false leaves a missing one to fail the
    #   open (State, which must still save without the lock)
    # @param on_unavailable [#call, nil] `(step, error)` called with `:open` or `:lock` and the
    #   SystemCallError when a `wait:` hold goes on without the lock (State logs both)
    # @param opener [#call] `(path, flags, perm) { |file| }`, the seam for opening the lock file
    # @param sleeper [#call] `(seconds)`, the seam State's wait polls through
    # @param clock [#call] monotonic seconds, the seam for the `wait:` deadline
    def initialize(path, dir_mode: 0o700, chmod_dir: false, open_readonly: false,
      make_dir: true, on_unavailable: nil, opener: File.method(:open), sleeper: Kernel.method(:sleep),
      clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) })
      @path = path
      @dir_mode = dir_mode
      @chmod_dir = chmod_dir
      @open_readonly = open_readonly
      @make_dir = make_dir
      @on_unavailable = on_unavailable
      @opener = opener
      @sleeper = sleeper
      @clock = clock
    end

    # Holds the lock while the block runs.
    #
    # @param shared [Boolean] a shared lock, many readers at once (every store's read path)
    # @param nonblocking [Boolean] return nil at once, without yielding, when the lock is
    #   taken (LockStore's `nonblocking:` and WorkflowRunStore#update)
    # @param wait [Numeric, nil] seconds to keep trying; when they pass, or the lock file
    #   can't be opened or locked, the block still runs with `held` false (State, which
    #   writes without the lock rather than not at all)
    # @yieldparam held [Boolean] whether the lock is held; always true without `wait:`
    # @return [Object, nil] the block's result; nil when `nonblocking` and the lock is taken
    # @raise [SystemCallError] when the lock file or its directory can't be made (without `wait:`)
    def hold(shared: false, nonblocking: false, wait: nil, &block)
      prepare_dir if @make_dir
      return hold_waiting(shared, wait, &block) if wait
      open_lock(shared) do |file|
        return nil unless file.flock(flock_mode(shared, nonblocking))
        yield true
      end
    end

    private

    def prepare_dir
      dir = File.dirname(@path)
      @dir_mode ? FileUtils.mkdir_p(dir, mode: @dir_mode) : FileUtils.mkdir_p(dir)
      File.chmod(@dir_mode, dir) if @chmod_dir && @dir_mode
    end

    def open_lock(shared, &block)
      flags = (shared && @open_readonly) ? File::RDONLY : File::RDWR
      @opener.call(@path, flags | File::CREAT, 0o600, &block)
    end

    def flock_mode(shared, nonblocking)
      mode = shared ? File::LOCK_SH : File::LOCK_EX
      nonblocking ? mode | File::LOCK_NB : mode
    end

    def hold_waiting(shared, seconds)
      file = begin
        open_lock(shared)
      rescue SystemCallError => e
        @on_unavailable&.call(:open, e)
        return yield(false)
      end
      begin
        yield acquire(file, shared, seconds)
      ensure
        file.close
      end
    end

    def acquire(file, shared, seconds)
      deadline = @clock.call + seconds
      until file.flock(flock_mode(shared, true))
        return false if @clock.call >= deadline
        @sleeper.call(0.01)
      end
      true
    rescue SystemCallError => e
      @on_unavailable&.call(:lock, e)
      false
    end
  end
end
