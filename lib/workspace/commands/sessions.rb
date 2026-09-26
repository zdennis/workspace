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
      # @param config [Workspace::Config] socket path lookups
      # @param output [IO] stream for the rendered table or JSON
      # @param error_output [IO] stream for the no-daemon message
      # @param clock [#now] time source, injected for deterministic tests
      # @param sleeper [#call] delay between refreshes, injected for tests
      def initialize(config:, output: $stdout, error_output: $stderr,
        clock: Time, sleeper: ->(seconds) { sleep(seconds) })
        @config = config
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
        return @output.puts(JSON.pretty_generate(snapshot)) if json

        @output.puts "workspace: #{snapshot["workspace"]}"
        @output.puts ""
        panes = snapshot["panes"] || []
        return @output.puts "  no panes" if panes.empty?

        @output.puts format_row("PANE", "KIND", "TITLE", "STATE", "IDLE")
        panes.each { |pane| render_pane(pane) }
      end

      def render_pane(pane)
        @output.puts format_row(
          "0.#{pane["index"]}",
          pane["kind"],
          truncate(pane["label"] || pane["title"], 22),
          pane["state"],
          duration(pane["idle_seconds"])
        )
        Array(pane["agents"]).each { |agent| render_agent(agent) }
      end

      # Indented to start under the TITLE column so a sub-agent reads as
      # belonging to the pane above it.
      def render_agent(agent)
        @output.puts format("%-16s%-24s%-10s", "",
          "└─ #{truncate(agent["name"], 20)}", agent["state"]).rstrip
      end

      def format_row(pane, kind, title, state, idle)
        format("%-6s%-10s%-24s%-10s%s", pane, kind, title, state, idle).rstrip
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
