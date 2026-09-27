require "json"
require "shellwords"

module Workspace
  module Commands
    # `workspace statusline` — installed as Claude Code's `statusLine`
    # command. Claude pipes one JSON payload on stdin every render and prints
    # whatever this writes to stdout.
    #
    # Two jobs, always in this order:
    #
    # 1. Record the reading: `context_window.used_percentage`, keyed on
    #    `$TMUX_PANE` (falling back to `$CLAUDE_PID` when TMUX_PANE isn't
    #    set), so `sessions --json` and `workspace handoff check` can see it
    #    later without Claude having to render again. Recorded even if
    #    rendering itself then fails.
    # 2. Print a line: a `statusline.command` in the global config gets the
    #    same stdin and its stdout is printed as-is, time-bounded so a slow
    #    or hung delegate can't freeze Claude's status bar; otherwise (or on
    #    delegate failure/timeout) the built-in {Workspace::StatuslineRenderer}
    #    runs instead.
    #
    # This runs on every render of every pane, so it must never crash the
    # status bar: bad or empty JSON, a storage error, or a delegate failure
    # all still print *something* and exit 0.
    class Statusline
      DEFAULT_DELEGATE_TIMEOUT = 5

      # @param context_store [Workspace::ContextStore] records the reading
      # @param renderer [Workspace::StatuslineRenderer] built-in fallback renderer
      # @param project_settings [Workspace::ProjectSettings] reads `statusline.command`
      # @param env [Hash] process environment, for TMUX_PANE/CLAUDE_PID
      # @param input [IO] stream Claude's JSON arrives on
      # @param output [IO] stream the rendered line is written to
      # @param logger [Workspace::Logger] debug logger
      # @param delegate_timeout [Numeric] seconds to wait for `statusline.command`
      def initialize(context_store:, renderer:, project_settings:, env: ENV, input: $stdin, output: $stdout,
        logger: Workspace::Logger.new, delegate_timeout: DEFAULT_DELEGATE_TIMEOUT)
        @context_store = context_store
        @renderer = renderer
        @project_settings = project_settings
        @env = env
        @input = input
        @output = output
        @logger = logger
        @delegate_timeout = delegate_timeout
      end

      # @return [Hash] {exit_code: 0} — always; see class docs
      def call
        raw = safe_read
        payload = parse(raw)

        record_reading(payload)
        @output.print(rendered_line(raw, payload))
        {exit_code: 0}
      rescue => e
        @logger.debug { "statusline: unexpected failure (#{e.class}: #{e.message})" }
        @output.print("workspace statusline: unavailable")
        {exit_code: 0}
      end

      private

      def safe_read
        @input.read.to_s
      rescue IOError, Errno::EBADF => e
        @logger.debug { "statusline: could not read stdin (#{e.message})" }
        ""
      end

      def parse(raw)
        return {} if raw.nil? || raw.strip.empty?
        result = JSON.parse(raw)
        result.is_a?(Hash) ? result : {}
      rescue JSON::ParserError => e
        @logger.debug { "statusline: unparseable payload (#{e.message})" }
        {}
      end

      def record_reading(payload)
        pct = payload.dig("context_window", "used_percentage")
        return if pct.nil?

        pane_id = presence(@env["TMUX_PANE"])
        pid = presence(@env["CLAUDE_PID"])
        @context_store.record(
          pct: pct,
          pane_id: pane_id,
          pid: pid,
          session_id: payload["session_id"],
          cwd: payload["cwd"]
        )
      rescue => e
        @logger.debug { "statusline: recording reading failed (#{e.class}: #{e.message})" }
      end

      def rendered_line(raw, payload)
        command = delegate_command
        if command
          delegated = run_delegate(command, raw)
          return delegated if delegated
        end
        @renderer.render(payload)
      end

      def delegate_command
        global = @project_settings.load_global
        presence(global.dig("statusline", "command"))
      rescue => e
        @logger.debug { "statusline: could not read global config (#{e.message})" }
        nil
      end

      # Runs `statusline.command` with the same stdin Claude gave us, timed
      # out so a hung or slow delegate can never freeze the status bar. Kills
      # and reaps the child on timeout, matching {Workspace::ProcessTree}'s
      # approach — no Signal.trap, just spawn/wait/kill.
      #
      # @return [String, nil] the delegate's stdout, or nil to fall back to
      #   the built-in renderer (non-zero exit, timeout, or spawn failure)
      def run_delegate(command, stdin_data)
        in_r, in_w = IO.pipe
        out_r, out_w = IO.pipe
        pid = Process.spawn(command, in: in_r, out: out_w, err: File::NULL)
        in_r.close
        out_w.close
        waiter = Process.detach(pid)

        writer = Thread.new do
          in_w.write(stdin_data)
        rescue Errno::EPIPE
          nil
        ensure
          in_w.close unless in_w.closed?
        end
        reader = Thread.new { out_r.read }
        reader.report_on_exception = false

        unless waiter.join(@delegate_timeout)
          @logger.debug { "statusline: delegate timed out after #{@delegate_timeout}s" }
          kill_and_reap(pid, waiter)
          return nil
        end

        writer.join(1)
        output = reader.value
        waiter.value.success? ? output : nil
      rescue SystemCallError, IOError => e
        @logger.debug { "statusline: delegate failed (#{e.class}: #{e.message})" }
        nil
      ensure
        [in_w, out_r].each { |io| io.close if io && !io.closed? }
      end

      def kill_and_reap(pid, waiter)
        Process.kill(:TERM, pid)
        waiter.join(1) || Process.kill(:KILL, pid)
      rescue Errno::ESRCH
        nil
      ensure
        waiter.join
      end

      def presence(value)
        return nil if value.nil? || value.to_s.empty?
        value
      end
    end
  end
end
