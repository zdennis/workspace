# Unit and integration specs may not start a process: that is what makes a
# spec a system spec. Every spawn point checks the token the around hook puts
# in fiber storage (copied into threads the example starts). An active token
# records the spawn and raises Violation, an Exception so `rescue => e` in lib/
# can't hide it; the hook fails the example afterwards whatever was rescued.
module SpawnGuard
  Token = Struct.new(:tier, :violations, :active)

  class Violation < Exception # rubocop:disable Lint/InheritException
  end

  GUARDED_TIERS = %i[unit integration].freeze

  def self.guard(example)
    tier = example.metadata[:type]
    return example.run unless GUARDED_TIERS.include?(tier)

    token = Token.new(tier, [], true)
    previous = Fiber[:spawn_guard]
    Fiber[:spawn_guard] = token
    begin
      example.run
    ensure
      token.active = false
      Fiber[:spawn_guard] = previous
    end
    check!(token)
  end

  def self.check!(token)
    return if token.violations.empty?

    RSpec::Expectations.fail_with(
      "#{token.tier} specs may not start a process; move this spec to spec/system/:\n" +
        token.violations.map { |v| "  #{v}" }.join("\n")
    )
  end

  def self.intercept(kind, args)
    token = Fiber[:spawn_guard]
    return unless token&.active

    command = args.flatten.reject { |a| a.is_a?(Hash) }.map(&:to_s).join(" ")[0, 120]
    site = caller_locations(2).find { |l| !l.path.end_with?("spawn_guard.rb") && !l.path.start_with?(RbConfig::CONFIG["rubylibdir"]) }
    token.violations << "#{kind} #{command.inspect} (#{site})"
    raise Violation, "#{token.tier} spec tried to start a process: #{kind} #{command}"
  end

  module KernelMethods
    private

    def system(*args, **opts)
      SpawnGuard.intercept("system", args)
      super
    end

    def spawn(*args, **opts)
      SpawnGuard.intercept("spawn", args)
      super
    end

    def `(command)
      SpawnGuard.intercept("`", [command])
      super
    end

    def exec(*args, **opts)
      SpawnGuard.intercept("exec", args)
      super
    end

    def fork(&block)
      SpawnGuard.intercept("fork", [])
      super
    end
  end

  module SingletonMethods
    def system(*args, **opts)
      SpawnGuard.intercept("system", args)
      super
    end

    def spawn(*args, **opts)
      SpawnGuard.intercept("spawn", args)
      super
    end

    def `(command)
      SpawnGuard.intercept("`", [command])
      super
    end

    def exec(*args, **opts)
      SpawnGuard.intercept("exec", args)
      super
    end

    def fork(&block)
      SpawnGuard.intercept("fork", [])
      super
    end
  end

  module ProcessMethods
    def spawn(*args, **opts)
      SpawnGuard.intercept("Process.spawn", args)
      super
    end

    def exec(*args, **opts)
      SpawnGuard.intercept("Process.exec", args)
      super
    end

    def fork(&block)
      SpawnGuard.intercept("Process.fork", [])
      super
    end
  end

  module PopenMethods
    def popen(*args, **opts, &block)
      SpawnGuard.intercept("IO.popen", args)
      super
    end
  end

  module PtyMethods
    def spawn(*args, **opts, &block)
      SpawnGuard.intercept("PTY.spawn", args)
      super
    end

    def getpty(*args, **opts, &block)
      SpawnGuard.intercept("PTY.getpty", args)
      super
    end
  end

  def self.install
    Kernel.prepend(KernelMethods)
    Kernel.singleton_class.prepend(SingletonMethods)
    Process.singleton_class.prepend(ProcessMethods)
    IO.singleton_class.prepend(PopenMethods)
    require "pty"
    PTY.singleton_class.prepend(PtyMethods)
  end
end
