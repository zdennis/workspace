require "rbconfig"
require "fileutils"

module Workspace
  # The `session-event` hook's part in ending a dev environment with the agent that started it:
  # on a SessionEnd it looks for a `devenv` lock record naming that session, and if one exists
  # starts `workspace dev __release SESSION` as its own process, so the hook returns at once
  # while the environment gets its full stop timeout.
  #
  # A SessionEnd whose reason is `clear` never releases: a handoff must not stop the server.
  # The check here is a plain read of the lock files for the session id, with no subprocess, so
  # the common case (no dev environment started by this session) costs a few file reads. It never
  # raises.
  class DevSessionRelease
    # @param config [Workspace::Config] supplies the lock directory and the log path
    # @param executable [String] path to `bin/workspace`
    # @param spawner [#call] starts a detached process: `(argv, cwd, log)`
    # @param recovery_marker [Workspace::RecoveryStopMarker, nil] nil builds one from +config+
    # @param logger [Workspace::Logger] debug logger
    def initialize(config:, executable:, spawner: nil, recovery_marker: nil, logger: Workspace::Logger.new)
      @config = config
      @executable = executable
      @recovery_marker = recovery_marker || RecoveryStopMarker.new(state_dir: config.state_dir)
      @spawner = spawner || method(:spawn_detached)
      @logger = logger
    end

    # @param session_id [String, nil] the session that ended, from the hook payload
    # @param cwd [String, nil] the session's working directory, from the hook payload
    # @param reason [String, nil] why it ended, from the hook payload
    # @return [Boolean] whether a release was started
    def call(session_id:, cwd:, reason:)
      return false if reason == "clear" || session_id.to_s.empty? || @recovery_marker.marked?(session_id) || !named?(session_id)

      cwd = Dir.pwd unless cwd && File.directory?(cwd)
      @spawner.call([RbConfig.ruby, @executable, "dev", "__release", session_id], cwd, log_path)
      true
    rescue => e
      @logger.debug { "session-event: dev release failed (#{e.class}: #{e.message})" }
      false
    end

    private

    # Whether any namespace's lock file mentions the session. A false positive (the id in some
    # other field) only starts a release that finds nothing to stop.
    def named?(session_id)
      return false unless Dir.exist?(@config.lock_dir)

      Dir.children(@config.lock_dir).any? do |name|
        path = File.join(@config.lock_dir, name, "locks.json")
        File.file?(path) && File.read(path).include?(session_id)
      rescue SystemCallError
        false
      end
    end

    def log_path
      File.join(@config.state_dir, "dev-release.log")
    end

    def spawn_detached(argv, cwd, log)
      FileUtils.mkdir_p(File.dirname(log))
      Process.detach(Process.spawn(*argv, chdir: cwd, in: File::NULL, out: [log, "a"], err: [log, "a"]))
    end
  end
end
