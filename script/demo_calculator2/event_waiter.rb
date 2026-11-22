require "json"
require "open3"

module DemoCalculator2
  # Waits for a work-queue event of the lane workspaces, with a backstop: one `workspace events --follow` child serves
  # every wait, started on the first one. When the follower cannot start or ends, each wait is a plain sleep.
  class EventWaiter
    TYPES = %w[work_queue_item_started work_queue_item_finished].freeze
    ARGS = ["events", "--follow", "--json", "--types", TYPES.join(",")].freeze
    FALLBACK_SLEEP = 3

    # @param line [String] one line of the follower's output
    # @param workspaces [Array<String>] the lane workspace names
    # @return [Boolean] whether the line is a queue start or finish of one of the workspaces
    def self.wake?(line, workspaces)
      event = JSON.parse(line)
      event.is_a?(Hash) && TYPES.include?(event["type"]) && workspaces.include?(event["workspace"])
    rescue JSON::ParserError
      false
    end

    # @param workspaces [Array<String>] the lane workspace names a line must name, unless `call` is given its own
    # @param workspace [String] the `workspace` program the follower runs
    # @param spawn [#call] `call(argv)` starts the follower and returns `[stdout, thread]`: a readable IO and the thread
    #   whose `pid` is the child and whose `join` reaps it
    # @param sleeper [#call] sleeps for the given seconds
    # @param clock [#call] returns the current Time
    def initialize(workspaces: [], workspace: "workspace", spawn: self.class.method(:popen), sleeper: ->(seconds) { sleep(seconds) }, clock: -> { Time.now })
      @workspaces = workspaces
      @workspace_bin = workspace
      @spawn = spawn
      @sleeper = sleeper
      @clock = clock
      @buffer = +""
      @fallback = false
    end

    # The default spawn: the child's stdin is closed and its errors are dropped.
    def self.popen(argv)
      stdin, stdout, thread = Open3.popen2(*argv, err: File::NULL)
      stdin.close
      [stdout, thread]
    end

    # Returns when a matching line has arrived or `timeout` seconds have passed.
    #
    # @param timeout [Numeric] seconds
    # @param workspaces [Array<String>, nil] the names a line must name for this wait; nil uses the constructor's
    # @return [void]
    def call(timeout, workspaces: nil)
      names = workspaces || @workspaces
      start unless @fallback || @stdout
      return @sleeper.call(FALLBACK_SLEEP) if @fallback
      deadline = @clock.call + timeout
      loop do
        return if next_wake?(names)
        remaining = deadline - @clock.call
        return if remaining <= 0
        return unless IO.select([@stdout], nil, nil, remaining)
        begin
          @buffer << @stdout.read_nonblock(4096)
        rescue IO::WaitReadable
          next
        rescue SystemCallError, IOError
          close
          @fallback = true
          return @sleeper.call(FALLBACK_SLEEP)
        end
      end
    end

    # Stops the follower and reaps it.
    def close
      stdout, thread = @stdout, @thread
      @stdout = @thread = nil
      return unless thread
      begin
        Process.kill("TERM", thread.pid)
      rescue SystemCallError
        nil
      end
      thread.join
      stdout.close unless stdout.closed?
    end

    private

    def start
      @stdout, @thread = @spawn.call([@workspace_bin, *ARGS])
    rescue SystemCallError
      @stdout = @thread = nil
      @fallback = true
    end

    def next_wake?(names)
      while (index = @buffer.index("\n"))
        line = @buffer.slice!(0..index)
        return true if self.class.wake?(line, names)
      end
      false
    end
  end
end
