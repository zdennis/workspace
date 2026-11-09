# frozen_string_literal: true

# A subclass of a real class whose named methods can be intercepted per example.
#
#   git = Interceptable.subclass(Workspace::Git, :push).new(output: out, input: inp)
#   git.on(:push) { |original, *args, **kw| calls << args; original.call(*args, **kw) }
#
# With no hook set a method runs the real one. A hook gets a callable for the real method first, then
# the call's own arguments and block. The subclass keeps the visibility of the methods it wraps.
module Interceptable
  def self.subclass(base, *names)
    Class.new(base) do
      define_method(:on) do |name, &hook|
        raise ArgumentError, "#{name} is not intercepted by #{self.class.superclass}; declare it in Interceptable.subclass" unless names.include?(name)

        (@interceptor_hooks ||= {})[name] = hook
        self
      end

      def calls_to(name)
        (@interceptor_calls ||= Hash.new { |h, k| h[k] = [] })[name]
      end

      names.each do |name|
        define_method(name) do |*args, **kw, &block|
          calls_to(name) << [args, kw]
          hook = (@interceptor_hooks || {})[name]
          original = ->(*a, **k, &b) { super(*a, **k, &b) }
          next original.call(*args, **kw, &block) unless hook
          hook.call(original, *args, **kw, &block)
        end
        private name if base.private_method_defined?(name)
      end
    end
  end
end
