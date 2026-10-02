require "json"
require "fileutils"

module Workspace
  # Removes old run files from `~/.workspace-runs` so the directory stays
  # bounded. Run from {RunResultStore#write}, so it never raises: a sweep that
  # can't finish leaves the rest for the next one.
  #
  # Files are grouped by run (the uuid before the first dot: `.cmd` and `.sh`
  # written by `run --wait`, `.stdout`, `.stderr`, `.json`, and a leftover `.tmp`). A run is removed when its
  # newest file is older than the retention (7 days) and:
  #
  # - it is not in progress: a run with no `.json` yet is in progress while
  #   any of its files is being written, so only one that has been silent
  #   for the whole retention counts as abandoned; and
  # - its project has no live session, as reported by the `live_projects`
  #   callable. If that can't be asked, nothing is removed.
  #
  # Files that are not run files are never touched. A sweep runs at most once
  # per interval, tracked by the mtime of a stamp file in the directory.
  class RunResultCleaner
    RETENTION = 7 * 24 * 60 * 60
    INTERVAL = 60 * 60
    STAMP = ".last-cleanup"
    RUN_FILE = /\A(?<uuid>[^.]+)\.(?<kind>json|stdout|stderr|sh|cmd)(?<tmp>\.tmp)?\z/

    # @param dir [String] the run results directory
    # @param clock [#call] returns the current Time, injected for specs
    # @param live_projects [#call] returns the names of projects whose runs
    #   must be kept (live or unknown), asked only when a sweep is due
    # @param retention [Numeric] seconds a run is kept after its last write
    # @param interval [Numeric] minimum seconds between sweeps
    # @param logger [Workspace::Logger] debug logger
    def initialize(dir:, clock: -> { Time.now }, live_projects: -> { [] }, retention: RETENTION, interval: INTERVAL,
      logger: Workspace::Logger.new)
      @dir = dir
      @clock = clock
      @live_projects = live_projects
      @retention = retention
      @interval = interval
      @logger = logger
    end

    # @return [Integer] how many files were removed
    def call
      now = @clock.call
      return 0 unless due?(now)
      touch_stamp(now)
      runs = group_runs
      cutoff = now - @retention
      expired = runs.select { |_, files| files.map { |f| File.mtime(f) }.max < cutoff }
      return 0 if expired.empty?
      live = Array(@live_projects.call)
      expired.sum do |_, files|
        next 0 if live.include?(project_of(files))
        files.count { |file| remove(file) }
      end
    rescue => e
      @logger.debug { "run_result_cleaner: sweep failed (#{e.class}: #{e.message})" }
      0
    end

    private

    def due?(now)
      return false unless File.directory?(@dir)
      now - File.mtime(File.join(@dir, STAMP)) >= @interval
    rescue Errno::ENOENT
      true
    end

    def touch_stamp(now)
      stamp = File.join(@dir, STAMP)
      FileUtils.touch(stamp)
      File.utime(now, now, stamp)
    end

    def group_runs
      Dir.children(@dir).each_with_object({}) do |name, runs|
        match = RUN_FILE.match(name) or next
        (runs[match[:uuid]] ||= []) << File.join(@dir, name)
      end
    end

    # The project a finished run belongs to, nil when it has no readable result.
    def project_of(files)
      json = files.find { |f| f.end_with?(".json") }
      json && JSON.parse(File.read(json))["project"]
    rescue SystemCallError, JSON::ParserError, TypeError
      nil
    end

    def remove(file)
      File.delete(file)
      true
    rescue SystemCallError
      false
    end
  end
end
