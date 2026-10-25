require "digest"
require "fileutils"
require "time"

module Workspace
  # The file hook events the daemon never got are recorded in: one line each,
  # newest last, so a hook that reaches no daemon is findable without --debug.
  #
  # Hooks run in separate processes, so everything here goes through the file
  # system: one write per line under an exclusive lock, the size checked inside
  # that lock (a separate lock file, as rotation replaces the log), a file past {LIMIT} moved to `<path>.1` (the one older copy kept),
  # and repeats of a key held back by a marker file's age. Never raises: a hook
  # must not fail over its own log.
  class DeliveryLog
    # Bytes after which the log is rotated.
    LIMIT = 256 * 1024
    # Seconds a repeat of the same key is held back.
    THROTTLE = 300

    # @param path [String] the log file
    # @param clock [#call] returns the current time
    def initialize(path:, clock: -> { Time.now })
      @path = path
      @clock = clock
    end

    # @param message [String] one line; newlines are replaced by spaces
    # @param key [String, nil] a repeat of this key within {THROTTLE} seconds is not written
    # @return [Boolean] whether a line was written
    def record(message, key: nil)
      FileUtils.mkdir_p(File.dirname(@path))
      File.open("#{@path}.lock", File::WRONLY | File::CREAT, 0o644) do |lock|
        lock.flock(File::LOCK_EX)
        return false if key && throttled?(key)

        File.rename(@path, "#{@path}.1") if File.size?(@path).to_i > LIMIT
        File.open(@path, File::WRONLY | File::APPEND | File::CREAT, 0o644) do |f|
          f.write("#{@clock.call.utc.iso8601} #{clean(message)}\n")
        end
      end
      true
    rescue SystemCallError, IOError
      false
    end

    private

    # Called under the log's lock, so two hooks cannot both pass.
    def throttled?(key)
      marker = "#{@path}.#{Digest::SHA256.hexdigest(key)[0, 16]}.throttle"
      now = @clock.call
      return true if File.exist?(marker) && now - File.mtime(marker) < THROTTLE

      FileUtils.touch(marker, mtime: now)
      false
    end

    def clean(text)
      text.to_s.gsub(/[\r\n]+/, " ")
    end
  end
end
