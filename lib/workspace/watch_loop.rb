require "stringio"

module Workspace
  # Redraws a frame on an interval until told to stop, for the `--watch` flags.
  class WatchLoop
    CLEAR = "\e[H\e[2J".freeze

    # @param output [#print, #puts] where frames are written; a TTY gets a clear before each frame
    # @param sleeper [#call] called with the interval between frames
    def initialize(output:, sleeper:)
      @output = output
      @sleeper = sleeper
    end

    # Runs the block once per tick and prints its frame when the text changed.
    #
    # @param interval [Numeric] seconds between frames
    # @yieldparam io [StringIO] a fresh buffer the block writes the frame into
    # @yieldreturn [Boolean] truthy to stop after this frame, without sleeping
    # @return [Hash] `{exit_code: 0}`, also after Ctrl-C or a closed pipe
    # @raise [Workspace::Error] when the block raises one
    def run(interval:)
      last = nil
      loop do
        io = StringIO.new
        stop = yield(io)
        frame = io.string
        if frame != last
          @output.print(CLEAR) if tty?
          @output.print(frame)
          @output.flush if @output.respond_to?(:flush)
          last = frame
        end
        break if stop
        @sleeper.call(interval)
      end
      {exit_code: 0}
    rescue Interrupt
      @output.puts if tty?
      {exit_code: 0}
    rescue Errno::EPIPE
      {exit_code: 0}
    end

    private

    def tty?
      @output.respond_to?(:tty?) && @output.tty?
    end
  end
end
