module Workspace
  # Turns an agent daemon's session snapshot into the compact per-workspace
  # agent facts `workspace projects show` reports. A daemon that is down or
  # too slow is a fact ("available": false), never an error.
  class ProjectAgents
    # Pane states the counts report, in display order.
    STATES = %w[working idle waiting done].freeze

    # @param client [Workspace::AgentSnapshotClient] fetches the snapshot
    def initialize(client:)
      @client = client
    end

    # @param workspace [String] workspace name
    # @param timeout [Numeric, nil] seconds to wait for the daemon
    # @return [Hash] `{"available" => true, "panes" => [...], "counts" => {...}}`, or
    #   `{"available" => false, "reason" => "no_daemon" | "timeout" | "error", "detail" => message}` (`detail` only with "error")
    def facts(workspace, timeout: nil)
      snapshot = @client.fetch(workspace, timeout: timeout)
      panes = Array(snapshot["panes"]).map { |pane| pane_facts(pane) }
      counts = STATES.to_h { |state| [state, panes.count { |pane| pane["state"] == state }] }
      {"available" => true, "panes" => panes, "counts" => counts}
    rescue AgentSnapshotClient::Unavailable => e
      unavailable(e.reason.to_s)
    rescue Workspace::Error => e
      unavailable("error").merge("detail" => e.message)
    end

    private

    def unavailable(reason)
      {"available" => false, "reason" => reason}
    end

    def pane_facts(pane)
      {
        "pane_id" => pane["pane_id"],
        "kind" => pane["kind"],
        "state" => pane["state"],
        "idle_seconds" => pane["idle_seconds"],
        "agents" => Array(pane["agents"]).map { |agent| {"name" => agent["name"], "state" => agent["state"]} }
      }
    end
  end
end
