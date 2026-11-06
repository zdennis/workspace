# frozen_string_literal: true

# An event log whose +record+ hands its keywords to the given block, so a spec
# collects the events in whatever shape it asserts on.
class BlockEventLog
  def initialize(&on_record)
    @on_record = on_record
  end

  def record(type:, project:, data: {})
    @on_record.call(type: type, project: project, data: data)
  end
end
