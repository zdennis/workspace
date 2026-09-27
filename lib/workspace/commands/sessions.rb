require "socket"
require "json"

module Workspace
  module Commands
    # Shows which panes in a workspace are running a coding agent, whether each
    # is working or idle, and what sub-agents they have started.
    #
    # The daemon holds the state; this command only asks for it. That keeps one
    # code path behind both the table and `--json`, so what a future UI reads is
    # exactly what the table shows.
    class Sessions
      # The lock this column shows; see {Workspace::LockEnforcer::LOCK_NAME}.
      LOCK_NAME = "edit"

      # @param config [Workspace::Config] socket path lookups
      # @param lock_namespace [Workspace::LockNamespace, nil] resolves the edit
      #   lock's store directory; nil hides the LOCK column entirely
      # @param lock_holder [Workspace::LockHolder, nil] checks holder/waiter
      #   liveness for the lock store; required together with +lock_namespace+
      # @param project_config [Workspace::ProjectConfig, nil] resolves the
      #   rendered workspace's project root, so the lock namespace matches the
      #   workspace being shown rather than the command's own Dir.pwd;
      #   required together with +lock_namespace+/+lock_holder+
      # @param output [IO] stream for the rendered table or JSON
      # @param error_output [IO] stream for the no-daemon message
      # @param clock [#now] time source, injected for deterministic tests
      # @param sleeper [#call] delay between refreshes, injected for tests
      def initialize(config:, lock_namespace: nil, lock_holder: nil, project_config: nil, output: $stdout,
        error_output: $stderr, clock: Time, sleeper: ->(seconds) { sleep(seconds) })
        @config = config
        @lock_namespace = lock_namespace
        @lock_holder = lock_holder
        @project_config = project_config
        @output = output
        @error_output = error_output
        @clock = clock
        @sleeper = sleeper
      end

      # @param name [String] workspace name
      # @param json [Boolean] emit the raw payload instead of a table
      # @param watch [Boolean] redraw until interrupted
      # @param interval [Numeric] seconds between redraws when watching
      # @return [void]
      # @raise [Workspace::Error] if no agent daemon is listening
      def call(name:, json: false, watch: false, interval: 2)
        @name = name
        return render(fetch(name), json) unless watch

        loop do
          snapshot = fetch(name)
          @output.print "\e[H\e[2J"
          render(snapshot, json)
          @sleeper.call(interval)
        end
      rescue Interrupt
        @output.puts ""
      end

      private

      def fetch(name)
        path = @config.agent_socket_path(name)
        UNIXSocket.open(path) do |socket|
          socket.puts(JSON.generate("type" => "sessions", "workspace" => name))
          reply = socket.gets
          raise Workspace::Error, "Agent for '#{name}' closed the connection." unless reply
          JSON.parse(reply)
        end
      rescue SystemCallError, IOError
        raise Workspace::Error,
          "No agent daemon for '#{name}'.\nStart one with:  workspace agent #{name}"
      end

      def render(snapshot, json)
        panes = snapshot["panes"] || []
        apply_lock_column(panes)
        return @output.puts(JSON.pretty_generate(snapshot)) if json

        @output.puts "workspace: #{snapshot["workspace"]}"
        @output.puts ""
        return @output.puts "  no panes" if panes.empty?

        @output.puts format_row("PANE", "KIND", "TITLE", "STATE", "IDLE", "LOCK")
        panes.each { |pane| render_pane(pane) }
      end

      def render_pane(pane)
        @output.puts format_row(
          "0.#{pane["index"]}",
          pane["kind"],
          truncate(pane["label"] || pane["title"], 22),
          pane["state"],
          duration(pane["idle_seconds"]),
          pane["lock"]
        )
        Array(pane["agents"]).each { |agent| render_agent(agent) }
      end

      # Loads every lock in the project's namespace once per render — never
      # per pane — and stamps each pane with both the human `"lock"` string
      # (each held/queued lock the pane is party to, joined with a space,
      # e.g. `"edit ✓ devenv #2"`) and structured fields for `--json`
      # consumers: `"lock_state"` ("held", "queued", or nil), `"lock_position"`
      # (1-based live-queue position, or nil), and `"lock_name"` (the lock's
      # name, or nil) describe the {LOCK_NAME} lock when the pane holds or
      # queues for it, else the pane's first lock (by the same edit-first,
      # alphabetical ordering as the label), for backward compatibility with
      # consumers written before multi-lock support. A `"locks"` array of
      # `{"name" => ..., "state" => ..., "position" => ...}` carries every
      # lock the pane is party to, in that same order.
      #
      # A holder or waiter flagged `"stale"` (its pid is no longer alive) is
      # treated as absent: it never renders "✓" or "held", and it is skipped
      # when numbering the queue, so `#1`/position 1 always refers to the
      # next live waiter.
      #
      # Hides the whole column — leaving `"lock"`, `"lock_state"`,
      # `"lock_position"`, `"lock_name"`, and `"locks"` all unset — when the
      # rendered workspace's project root can't be resolved, rather than
      # guessing at some other project's lock state via the command's own
      # working directory.
      def apply_lock_column(panes)
        return unless @lock_namespace && @lock_holder

        root = project_root
        return unless root

        positions = lock_positions(root)
        panes.each do |pane|
          entries = positions[pane["pane_id"]] || []
          pane["lock"] = entries.map { |e| e[:label] }.join(" ")
          pane["locks"] = entries.map { |e| {"name" => e[:name], "state" => e[:state], "position" => e[:position]} }
          primary = entries.find { |e| e[:name] == LOCK_NAME } || entries.first
          pane["lock_state"] = primary ? primary[:state] : nil
          pane["lock_position"] = primary ? primary[:position] : nil
          pane["lock_name"] = primary ? primary[:name] : nil
        end
      end

      def project_root
        return nil unless @project_config && @name
        @project_config.project_root_for(@name)
      end

      # Returns pane_id => ordered array of lock-entry hashes (`:label`,
      # `:state`, `:position`, `:name`), ordered {LOCK_NAME} first, then every
      # other lock name alphabetically, so the label and the primary
      # `--json` fields stay deterministic across renders.
      def lock_positions(root)
        namespace = @lock_namespace.resolve(cwd: root)
        store = LockStore.new(dir: namespace[:dir], liveness: @lock_holder)
        statuses = store.status
        names = statuses.keys.sort_by { |name| [(name == LOCK_NAME) ? 0 : 1, name] }

        positions = Hash.new { |h, k| h[k] = [] }
        names.each do |name|
          entry = statuses[name] || {}
          holder = entry["holder"]
          if holder && holder["pane"] && !holder["stale"]
            positions[holder["pane"]] << {label: "#{name} ✓", state: "held", position: nil, name: name}
          end
          live_waiters = (entry["queue"] || []).reject { |waiter| waiter["stale"] }
          live_waiters.each_with_index do |waiter, i|
            next unless waiter["pane"]
            positions[waiter["pane"]] << {label: "#{name} ##{i + 1}", state: "queued", position: i + 1, name: name}
          end
        end
        positions
      rescue Workspace::Error
        Hash.new { |h, k| h[k] = [] }
      end

      # Indented to start under the TITLE column so a sub-agent reads as
      # belonging to the pane above it.
      def render_agent(agent)
        @output.puts format("%-16s%-24s%-10s", "",
          "└─ #{truncate(agent["name"], 20)}", agent["state"]).rstrip
      end

      def format_row(pane, kind, title, state, idle, lock = "")
        format("%-6s%-10s%-24s%-10s%-8s%s", pane, kind, title, state, idle, lock).rstrip
      end

      def truncate(value, width)
        text = value.to_s
        (text.length > width) ? "#{text[0, width - 1]}…" : text
      end

      def duration(seconds)
        return "" if seconds.nil?
        return "#{seconds}s" if seconds < 60
        return "#{seconds / 60}m#{seconds % 60}s" if seconds < 3600
        "#{seconds / 3600}h#{(seconds % 3600) / 60}m"
      end
    end
  end
end
