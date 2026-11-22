module Workspace
  # Stands in for an object that is costly to build, and builds it on the first
  # method call. Every call is then passed to the built object.
  #
  # The block runs at most once, also when it returns nil or false. If the block
  # raises, the error reaches the caller and nothing is kept, so the next call
  # runs the block again. Not safe to share between threads.
  #
  # A Deferred is itself always truthy and is never nil, and the methods every
  # object has (`nil?`, `==`, `is_a?`, `class`) answer for the Deferred, not for
  # the built object.
  class Deferred
    # @yieldreturn [Object] the object to build on first use
    # @raise [ArgumentError] when no block is given
    def initialize(&builder)
      raise ArgumentError, "Deferred needs a block" unless builder
      @builder = builder
      @built = false
      @target = nil
    end

    # @param name [Symbol]
    # @return [Boolean] whether the built object answers `name`; builds it
    def respond_to_missing?(name, include_private = false)
      target.respond_to?(name, include_private) || super
    end

    # Passes the call to the built object, building it first when needed.
    def method_missing(name, *args, **kwargs, &block)
      target.public_send(name, *args, **kwargs, &block)
    end

    private

    def target
      return @target if @built
      @target = @builder.call
      @built = true
      @builder = nil
      @target
    end
  end
end
