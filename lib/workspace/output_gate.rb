module Workspace
  # An output stream that can be pointed somewhere else for a while. Every
  # collaborator holds the gate rather than the stream, so a command run with
  # `--json` can send the text its collaborators print to stderr and keep
  # stdout for the one JSON document.
  class OutputGate
    # @param io [IO] where writes go until {#divert_to} is called
    def initialize(io)
      @target = io
    end

    # Sends everything written through the gate to +io+ while the block runs.
    #
    # @param io [IO] the stream to write to instead
    # @return [Object] the block's value
    def divert_to(io)
      previous = @target
      @target = io
      yield
    ensure
      @target = previous
    end

    def method_missing(name, *args, **kwargs, &block)
      if @target.respond_to?(name)
        @target.public_send(name, *args, **kwargs, &block)
      else
        super
      end
    end

    def respond_to_missing?(name, include_private = false)
      @target.respond_to?(name, include_private) || super
    end
  end
end
