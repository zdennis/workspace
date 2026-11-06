# A lock namespace that answers one fixed directory and counts each `resolve`.
class CountingLockNamespace
  attr_reader :resolves

  def initialize(dir:)
    @dir = dir
    @resolves = 0
  end

  def resolve(cwd:)
    @resolves += 1
    {key: "ns", display: "app", dir: @dir}
  end
end
