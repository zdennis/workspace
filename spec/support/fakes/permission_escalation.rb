class FakeEscalationInbox
  attr_reader :upserts, :transitions

  def initialize(opened_at:)
    @opened_at = opened_at
    @upserts = []
    @transitions = []
    @items = []
  end

  def upsert(record, reopen: false)
    @upserts << [record, reopen]
    @items.reject! { |i| i["dedupe_key"] == record["dedupe_key"] }
    @items << record.merge("state" => "open", "updated_at" => @opened_at.iso8601)
  end

  def transition_by_key(key, to:, by: nil, snooze_until: nil)
    @transitions << [key, to, by]
    @items.each { |i| i["state"] = to if i["dedupe_key"] == key }
  end

  def list = @items.map(&:dup)
end

class FakeEscalationConfig
  attr_accessor :value
  attr_reader :calls

  def initialize(value) = (@value = value
                           @calls = 0)

  def configured?(workspace:, project:)
    @calls += 1
    raise "boom" if @value == :raise
    @value
  end
end

class FakeEscalationMonitor
  attr_accessor :panes

  def initialize = @panes = []

  def snapshot = {"panes" => @panes}
end
