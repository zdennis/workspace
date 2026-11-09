# frozen_string_literal: true

# The accepts-every-call rule that `fake_contract_spec` holds each shared fake to: a call the real
# method accepts must not fail on the fake. For a method both define, the fake takes the same number of
# required positionals, room for every optional one, every keyword of the real method by name or by
# `**`, and requires no keyword the real method does not require. A public method of the fake that the
# real class lacks is a problem too, unless the fake lists it in CONTROL_METHODS.
module FakeContract
  def self.problems(fake, real, control: [])
    own = fake.public_instance_methods(false) - control
    own.sort.flat_map do |name|
      next ["#{fake}##{name} is not a method of #{real}"] unless real.public_method_defined?(name)

      compare(name, fake.instance_method(name).parameters, real.instance_method(name).parameters)
    end
  end

  def self.compare(name, fake, real)
    kinds = ->(params, kind) { params.select { |k, _| k == kind }.map(&:last) }
    problems = []
    required = kinds.call(real, :req).size
    optional = kinds.call(real, :opt).size
    fake_required = kinds.call(fake, :req).size
    fake_room = fake_required + kinds.call(fake, :opt).size
    problems << "#{name}: the fake requires #{fake_required} positionals, the real method #{required}" if fake_required != required
    problems << "#{name}: the fake takes #{fake_room} positionals at most, the real method #{required + optional}" if fake_room < required + optional && kinds.call(fake, :rest).empty?
    real_keys = kinds.call(real, :keyreq) + kinds.call(real, :key)
    fake_keys = kinds.call(fake, :keyreq) + kinds.call(fake, :key)
    fake_takes_any = !kinds.call(fake, :keyrest).empty?
    (real_keys - fake_keys).each { |key| problems << "#{name}: the fake does not accept #{key}:" } unless fake_takes_any
    problems << "#{name}: the real method takes any keyword, the fake does not" if !kinds.call(real, :keyrest).empty? && !fake_takes_any
    (kinds.call(fake, :keyreq) - kinds.call(real, :keyreq)).each { |key| problems << "#{name}: the fake requires #{key}:, the real method does not" }
    problems
  end
end
