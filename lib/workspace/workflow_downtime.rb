require "json"
require "time"

module Workspace
  # Records the time the machine was off or asleep (no daemon tick and no sweep beat), so a run's clocks can
  # skip it. Every daemon tick and sweep pass calls {#beat}, which writes the
  # heartbeat; a beat that finds the old heartbeat more than +downtime_after+
  # seconds behind records the gap as a span. Paths are injected.
  #
  # +downtime_after+ must stay well above the longest tick: a tick that blocks
  # longer than it records false downtime.
  class WorkflowDowntime
    KEEP_SECONDS = 30 * 24 * 3600
    # Threshold used when +downtime_after+ cannot be read.
    DEFAULT_AFTER = 120

    # @param heartbeat_path [String] file holding the last beat's time
    # @param downtime_path [String] JSONL file of recorded +from+/+to+ spans
    # @param downtime_after [#call] returns the gap in seconds that counts as downtime
    # @param clock [#call] returns the current Time
    def initialize(heartbeat_path:, downtime_path:, downtime_after:, clock: -> { Time.now })
      @heartbeat_path = heartbeat_path
      @downtime_path = downtime_path
      @downtime_after = downtime_after
      @clock = clock
    end

    # Writes the heartbeat, recording a span first when the old one is stale.
    # Never raises.
    # @return [void]
    def beat
      now = @clock.call
      FileLock.new("#{@heartbeat_path}.lock", dir_mode: nil).hold do
        old = read_heartbeat
        record(old, now) if old && now - old > threshold
        AtomicFile.write(@heartbeat_path, now.utc.iso8601(3), fsync: false)
      end
      nil
    rescue
      nil
    end

    # @param now [Time]
    # @return [Array<Hash>] recorded spans as +since+/+until+, plus the open gap
    #   (+since+ only) when the heartbeat is older than the threshold
    def spans(now = @clock.call)
      result = read_spans.map { |from, to| {"since" => from.utc.iso8601(3), "until" => to.utc.iso8601(3)} }
      beat_time = read_heartbeat
      if beat_time && now - beat_time > threshold
        result << {"since" => beat_time.utc.iso8601(3)}
      end
      result
    rescue
      []
    end

    # @return [String] "wall" when no heartbeat exists yet, else "active"
    def clock_kind
      File.exist?(@heartbeat_path) ? "active" : "wall"
    end

    private

    def threshold
      @downtime_after.call
    rescue
      DEFAULT_AFTER
    end

    def read_heartbeat
      Time.iso8601(File.read(@heartbeat_path).strip)
    rescue
      nil
    end

    def read_spans
      File.readlines(@downtime_path).filter_map { |line| parse_span(line) }
    rescue SystemCallError
      []
    end

    def parse_span(line)
      data = JSON.parse(line)
      from = Time.iso8601(data["from"])
      to = Time.iso8601(data["to"])
      [from, to]
    rescue
      nil
    end

    def record(from, to)
      return if to <= from
      kept = read_spans.select { |_, span_to| to - span_to <= KEEP_SECONDS }
      kept << [from, to]
      lines = kept.map { |f, t| JSON.generate("from" => f.utc.iso8601(3), "to" => t.utc.iso8601(3)) }
      AtomicFile.write(@downtime_path, lines.join("\n") + "\n", fsync: false)
    end
  end
end
