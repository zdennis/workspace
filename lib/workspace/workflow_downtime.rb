require "json"
require "time"

module Workspace
  # Records the time the machine was off or asleep (no daemon tick and no sweep beat), so a run's clocks can
  # skip it. Every daemon tick and sweep pass calls {#beat}, which writes the
  # heartbeat; a beat that finds the old heartbeat more than +downtime_after+
  # seconds plus the grace that heartbeat wrote behind records the gap as a span.
  # A sweep beats every few minutes and writes that interval as its grace, so a
  # machine kept up only by the scheduled sweep is not read as down. Paths are injected.
  #
  # +downtime_after+ must stay well above the longest tick: a tick that blocks
  # longer than it records false downtime.
  class WorkflowDowntime
    KEEP_SECONDS = 30 * 24 * 3600
    # Threshold used when +downtime_after+ cannot be read.
    DEFAULT_AFTER = 120

    # @param heartbeat_path [String] file holding the last beat's time and grace
    # @param downtime_path [String] JSONL file of recorded +from+/+to+ spans
    # @param downtime_after [#call] returns the gap in seconds that counts as downtime
    # @param clock [#call] returns the current Time
    def initialize(heartbeat_path:, downtime_path:, downtime_after:, clock: -> { Time.now })
      @heartbeat_path = heartbeat_path
      @downtime_path = downtime_path
      @downtime_after = downtime_after
      @clock = clock
    end

    # Writes the heartbeat with the beater's grace, recording a span first when the old
    # beat is stale: more than +downtime_after+ plus the grace the old beat wrote behind.
    # Never raises.
    # @param grace [Numeric] seconds the beater allows before its next beat is due
    #   (a sweep beating every 5 minutes passes 300; a daemon ticking often passes 0)
    # @return [void]
    def beat(grace: 0)
      FileLock.new("#{@heartbeat_path}.lock").hold do
        now = @clock.call
        old, old_grace = read_heartbeat
        record(old, now) if old && now - old > threshold + old_grace
        AtomicFile.write(@heartbeat_path, "#{now.utc.iso8601(3)} #{grace.to_i}", fsync: false)
      end
      nil
    rescue
      nil
    end

    # @param now [Time]
    # @return [Array<Hash>] recorded spans as +since+/+until+, plus the open gap
    #   (+since+ only) when the heartbeat is older than the threshold plus its grace
    def spans(now = @clock.call)
      beat_time, grace = read_heartbeat
      result = read_spans.map { |from, to| {"since" => from.utc.iso8601(3), "until" => to.utc.iso8601(3)} }
      if beat_time && now - beat_time > threshold + grace
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
      time, grace = File.read(@heartbeat_path).split
      [Time.iso8601(time), grace.to_i]
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
