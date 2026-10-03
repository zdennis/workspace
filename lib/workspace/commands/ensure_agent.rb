require "fileutils"

module Workspace
  module Commands
    # Makes sure a workspace has an agent daemon (`agentd`) answering on its
    # socket, starting one detached when it doesn't. Safe to call from any
    # number of places at once, which is why `launch` and `agentd --ensure`
    # share it: a per-workspace file lock covers the check, the spawn and the
    # wait for the new daemon's socket, so a second caller finds the daemon
    # the first one started instead of starting another.
    #
    # A socket file left behind by a dead daemon doesn't answer, so it counts
    # as "not running"; the new daemon removes it when it binds.
    class EnsureAgent
      # How long to wait for a freshly spawned daemon to answer on its socket.
      DEFAULT_TIMEOUT = 5

      # @return [Symbol] :running (already up), :started (spawned and
      #   answering), :invalid_config (pipeline config unusable, nothing
      #   spawned), or :failed (spawn error or no answer in time)
      # @return [String, nil] detail for :failed, suitable after "Could not
      #   start the agent daemon for <name>: "
      Result = Struct.new(:status, :detail) do
        # @return [Boolean] whether a daemon is answering after the call
        def ok?
          status == :running || status == :started
        end
      end

      # @param config [Workspace::Config]
      # @param pipeline_config [Workspace::PipelineConfig]
      # @param spawner [#call] `(name, wc_socket, log_path)`; starts a detached
      #   `agentd` and returns immediately. Raises SystemCallError on failure.
      # @param sleeper [#call] sleeps for the given seconds
      # @param clock [#call] monotonic seconds
      # @param timeout [Numeric] seconds to wait for the daemon's socket
      # @param error_output [IO]
      def initialize(config:, pipeline_config:, spawner: method(:spawn_agentd), sleeper: ->(seconds) { sleep(seconds) },
        clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) }, timeout: DEFAULT_TIMEOUT, error_output: $stderr)
        @config = config
        @pipeline_config = pipeline_config
        @spawner = spawner
        @sleeper = sleeper
        @clock = clock
        @timeout = timeout
        @error_output = error_output
      end

      # @param name [String] the workspace name
      # @param wc_socket [String, nil] work-coordinator socket for the daemon
      # @return [Result]
      def call(name:, wc_socket: nil)
        return Result.new(:running) if @config.agent_running?(name)

        with_lock(name) do
          # Another caller may have started it while we waited for the lock.
          next Result.new(:running) if @config.agent_running?(name)

          log_path = @config.agent_log_path(name)
          next Result.new(:invalid_config) unless pipeline_usable?(name, log_path)

          @spawner.call(name, wc_socket, log_path)
          wait_for_socket(name, log_path)
        end
      rescue SystemCallError, Workspace::Error => e
        Result.new(:failed, e.message)
      end

      private

      def pipeline_usable?(name, log_path)
        @pipeline_config.stages_for(name)
        @pipeline_config.literal_sentinel_warnings(name).each { |warning| @error_output.puts "Warning: #{warning}" }
        true
      rescue Workspace::Error => e
        @error_output.puts "Warning: #{name}'s pipeline config is invalid (#{e.message}); " \
          "not starting its session monitor. See #{log_path} once fixed."
        false
      end

      def wait_for_socket(name, log_path)
        deadline = @clock.call + @timeout
        loop do
          return Result.new(:started) if @config.agent_running?(name)
          break if @clock.call >= deadline

          @sleeper.call(0.1)
        end
        Result.new(:failed, "it did not answer within #{@timeout}s; see #{log_path}")
      end

      def with_lock(name)
        File.open(@config.agent_lock_path(name), File::RDWR | File::CREAT, 0o600) do |file|
          file.flock(File::LOCK_EX)
          yield
        end
      end

      # Appends to the log so a restart keeps what the previous daemon wrote.
      def spawn_agentd(name, wc_socket, log_path)
        args = ["agentd", "--name", name]
        args += ["--wc-socket", wc_socket] if wc_socket
        pid = Process.spawn($PROGRAM_NAME, *args, out: [log_path, "a"], err: [log_path, "a"], in: File::NULL)
        Process.detach(pid)
      end
    end
  end
end
