# frozen_string_literal: true

require "json"

# An event log that appends each record as a JSON line to a file, safe to use from forked processes.
class FileAppendingEventLog
  def initialize(path)
    @path = path
  end

  def latest_agent_states(_project) = {}

  def record(type:, project:, data:)
    File.open(@path, "a") { |f| f.syswrite(JSON.generate({"type" => type, "data" => data}) + "\n") }
  end
end
