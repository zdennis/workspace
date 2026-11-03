module Workspace
  # Holds INT, TERM and HUP while a run of steps goes on, so a signal waits for the step under way to
  # end. The caller asks {#caught} between steps and stops there. A signal it never reported through
  # {#report} is sent again once the old handlers are back.
  class DeferredSignals
    # The signals held.
    NAMES = %w[INT TERM HUP].freeze

    # @return [String, nil] the first signal that came, without its `SIG`
    attr_reader :caught

    # Runs the block with the signals held. A signal the process ignores (nohup's SIGHUP) stays ignored.
    #
    # @yield the steps
    # @return [Object] the block's value
    def hold
      previous = {}
      NAMES.each do |name|
        handler = Signal.trap(name) { @caught ||= name }
        ignored = handler.nil? || handler == "IGNORE"
        ignored ? Signal.trap(name, handler) : previous[name] = handler
      end
      yield
    ensure
      previous.each { |name, handler| Signal.trap(name, handler) }
      Process.kill(@caught, Process.pid) if @caught && !@reported
    end

    # Takes a signal that reached the caller some other way, as an exception.
    #
    # @param name [String] the signal, without its `SIG`
    # @return [void]
    def note(name)
      @caught ||= name
    end

    # Says the signal is named in the error being raised, so {#hold} does not send it again.
    #
    # @return [Hash] `{"signal" => "SIGINT"}`, or empty when none came
    def report
      return {} unless @caught
      @reported = true
      {"signal" => "SIG#{@caught}"}
    end
  end
end
