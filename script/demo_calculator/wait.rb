require "time"

module DemoCalculator
  # The pure rules of `run --wait`: when to stop watching the queue, when to advance it by hand and how long
  # an item has been held.
  module Wait
    # @param text [String] `Ns`, `Nm` or `Nh`
    # @return [Integer] seconds
    # @raise [ArgumentError] when text is not a duration
    def self.parse_duration(text)
      match = /\A(\d+)([smh])\z/.match(text.to_s)
      raise ArgumentError, "not a duration (use Ns, Nm or Nh): #{text}" unless match
      match[1].to_i * {"s" => 1, "m" => 60, "h" => 3600}.fetch(match[2])
    end

    # Why the loop should stop, checked in this order: timeout, paused, disabled, held, empty.
    #
    # @param queue_row [Hash] one queue of `work-queue list --json`
    # @param now [Time]
    # @param started_at [Time] when the loop began
    # @param held_since [Hash{String => Time}] item id => when it was held
    # @param held_limit [Numeric] seconds an item may stay held
    # @param timeout [Numeric] seconds the loop may run
    # @return [Hash, nil] `{"reason" => "empty|paused|disabled|held|timeout", "item" => id or nil}`; nil to keep waiting
    def self.stop_reason(queue_row, now:, started_at:, held_since:, held_limit:, timeout:)
      items = queue_row["items"] || []
      held = items.select { |item| item["state"] == "held" }
      return {"reason" => "timeout", "item" => nil} if now - started_at >= timeout
      return {"reason" => "paused", "item" => held.first&.fetch("id")} if queue_row["state"] == "paused"
      return {"reason" => "disabled", "item" => nil} if queue_row["state"] == "off" && !items.empty?
      over = held.find { |item| held_since[item["id"]] && now - held_since[item["id"]] >= held_limit }
      return {"reason" => "held", "item" => over["id"]} if over
      return {"reason" => "empty", "item" => nil} if items.empty?
      nil
    end

    # Whether a poll should call `work-queue advance`: the queue cannot advance itself (no auto-advance feature
    # or no daemon), nothing is starting or active, and an item waits.
    #
    # @param queue_row [Hash]
    # @param work_queue_feature [Integer, nil] `capabilities.features.work_queue`
    # @return [Boolean]
    def self.advance?(queue_row, work_queue_feature:)
      return false if work_queue_feature.to_i >= 2 && queue_row["daemon_running"]
      items = queue_row["items"] || []
      return false if items.any? { |item| %w[starting active].include?(item["state"]) }
      items.any? { |item| item["state"] == "queued" }
    end

    # When each held item was held: its newest `work_queue_item_held` event, else the time the loop first saw it.
    #
    # @param events [Array<Hash>] lifecycle event log lines (`timestamp`, `type`, `data`)
    # @param items [Array<Hash>] queue items
    # @param first_seen [Hash{String => Time}] item id => first poll that saw it held
    # @return [Hash{String => Time}]
    def self.held_since(events:, items:, first_seen:)
      held_ids = items.select { |item| item["state"] == "held" }.map { |item| item["id"] }
      held_ids.to_h do |id|
        times = events.filter_map do |event|
          next unless event["type"] == "work_queue_item_held" && event.dig("data", "id") == id
          Time.parse(event["timestamp"].to_s)
        rescue ArgumentError
          nil
        end
        [id, times.max || first_seen[id]]
      end.compact
    end
  end
end
