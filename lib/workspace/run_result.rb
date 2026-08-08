module Workspace
  # Immutable value object representing the result of a watched or direct run.
  RunResult = Struct.new(
    :uuid,
    :project,
    :command,
    :status,
    :stdout,
    :stderr,
    :started_at,
    :finished_at,
    keyword_init: true
  ) do
    # @return [Hash]
    def to_h
      {
        "uuid" => uuid,
        "project" => project,
        "command" => command,
        "status" => status,
        "stdout" => stdout,
        "stderr" => stderr,
        "started_at" => started_at,
        "finished_at" => finished_at
      }
    end

    # @return [String]
    def to_json(*)
      JSON.generate(to_h)
    end

    # @param json [String]
    # @return [RunResult]
    def self.from_json(json)
      h = JSON.parse(json)
      new(
        uuid: h["uuid"],
        project: h["project"],
        command: h["command"],
        status: h["status"],
        stdout: h["stdout"],
        stderr: h["stderr"],
        started_at: h["started_at"],
        finished_at: h["finished_at"]
      )
    end
  end
end
