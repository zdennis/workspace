require "fileutils"

module Workspace
  # Copies a file aside before it is modified, so any edit workspace makes can
  # be undone by hand.
  #
  # Backups live next to the original with a timestamp suffix rather than in a
  # central directory: a user who finds an unexpected settings.json finds the
  # backup in the same listing, without knowing workspace wrote it.
  class FileBackup
    # @param output [IO] stream for user-facing messages
    # @param clock [#now] time source, injected for deterministic tests
    def initialize(output: $stdout, clock: Time)
      @output = output
      @clock = clock
    end

    # Copies path aside and reports where the copy landed.
    #
    # @param path [String] file to back up
    # @param dry_run [Boolean] report the backup path without writing it
    # @return [String, nil] the backup path, or nil if there was nothing to back up
    def backup(path, dry_run: false)
      return nil unless File.exist?(path)

      destination = backup_path(path)
      FileUtils.cp(path, destination) unless dry_run
      @output.puts "  backup  #{destination}"
      destination
    end

    private

    # A counter suffix keeps a second backup within the same second from
    # silently overwriting the first.
    def backup_path(path)
      stamp = @clock.now.strftime("%Y%m%d%H%M%S")
      candidate = "#{path}.workspace-backup-#{stamp}"
      return candidate unless File.exist?(candidate)

      counter = 2
      counter += 1 while File.exist?("#{candidate}.#{counter}")
      "#{candidate}.#{counter}"
    end
  end
end
