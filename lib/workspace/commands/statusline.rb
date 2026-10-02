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
    #    set), so `sessions --json` can see it later without Claude having
    #    to render again. Recorded even if rendering itself then fails.
    #    Right after `/clear`, Claude renders with `used_percentage` as JSON
    #    null (and a new `session_id`); that's still recorded, as a reading
    #    with a nil pct, so the new session is visible to readers even
    #    before Claude reports a real percentage. Only a present-but-invalid
    #    value (a string, a negative number, one over 100) is dropped.
    #    The same call records `cost.total_cost_usd`, `cost.total_duration_ms`,
    #    and `model.display_name` (each nil when absent or the wrong type).
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
      DEFAULT_DELEGATE_TIMEOUT = 3
      KILL_GRACE = 0.5
      THREAD_JOIN_GRACE = 1
      MAX_DELEGATE_OUTPUT_BYTES = 64 * 1024

      # @param context_store [Workspace::ContextStore] records the reading
      # @param renderer [Workspace::StatuslineRenderer] built-in fallback renderer
      # @param project_settings [Workspace::ProjectSettings] reads `statusline.command`
      # @param env [Hash] process environment, for TMUX_PANE/CLAUDE_PID
      # @param input [IO] stream Claude's JSON arrives on
      # @param output [IO] stream the rendered line is written to
      # @param logger [Workspace::Logger] debug logger
      # @param delegate_timeout [Numeric] seconds to wait for `statusline.command`
      # @param terminator [Workspace::ProcessGroupTerminator] stops a timed-out delegate's process group
      # @param lock_holder [Workspace::LockHolder] looks up CLAUDE_PID's `ps`
      #   start time, so a pid-keyed reading can later be verified rather
      #   than trusted on a possibly-reused pid
      def initialize(context_store:, renderer:, project_settings:, env: ENV, input: $stdin, output: $stdout,
        logger: Workspace::Logger.new, delegate_timeout: DEFAULT_DELEGATE_TIMEOUT,
        terminator: Workspace::ProcessGroupTerminator.new, lock_holder: Workspace::LockHolder.new)
        @context_store = context_store
        @renderer = renderer
        @project_settings = project_settings
        @env = env
        @input = input
        @output = output
        @logger = logger
        @delegate_timeout = delegate_timeout
        @terminator = terminator
        @lock_holder = lock_holder
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

        pane_id = presence(@env["TMUX_PANE"])
        pid = presence(@env["CLAUDE_PID"])
        @context_store.record(
          pct: pct,
          pane_id: pane_id,
          pid: pid,
          started: pid && pid_started(pid),
          session_id: payload["session_id"],
          cwd: payload["cwd"],
          cost_usd: nested(payload, "cost", "total_cost_usd"),
          duration_ms: nested(payload, "cost", "total_duration_ms"),
          model: nested(payload, "model", "display_name")
        )
      rescue => e
        @logger.debug { "statusline: recording reading failed (#{e.class}: #{e.message})" }
      end

      def nested(payload, key, field)
        section = payload[key]
        section[field] if section.is_a?(Hash)
      end

      def pid_started(pid)
        @lock_holder.start_time(pid.to_i)
      rescue Workspace::Error => e
        @logger.debug { "statusline: could not look up start time for pid #{pid} (#{e.message})" }
        nil
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

      # Runs `statusline.command` with the same stdin Claude gave us, bounded
      # by one deadline covering both the delegate exiting and its stdout
      # reaching EOF — a delegate that exits but leaves a background child
      # holding stdout open is as stuck as one that never exits. The delegate
      # runs in its own process group so a timeout stops everything it
      # started, not just the shell; Claude renders several times a second,
      # so orphans would pile up otherwise. No Signal.trap, just
      # spawn/wait/kill.
      #
      # @return [String, nil] the delegate's stdout, or nil to fall back to
      #   the built-in renderer (non-zero exit, timeout, or spawn failure)
      def run_delegate(command, stdin_data)
        deadline = now + @delegate_timeout
        in_r, in_w = IO.pipe
        out_r, out_w = IO.pipe
        pid = Process.spawn(command, in: in_r, out: out_w, err: File::NULL, pgroup: true)
        in_r.close
        out_w.close
        waiter = Process.detach(pid)

        writer = Thread.new do
          in_w.write(stdin_data)
        rescue Errno::EPIPE, IOError
          nil
        ensure
          in_w.close unless in_w.closed?
        end
        reader = Thread.new do
          read_capped(out_r)
        rescue IOError
          nil
        end

        unless waiter.join(remaining(deadline)) && reader.join(remaining(deadline))
          @logger.debug { "statusline: delegate timed out after #{@delegate_timeout}s" }
          stop_group(pid, waiter)
          return nil
        end

        output = reader.value
        waiter.value.success? ? output : nil
      rescue SystemCallError, IOError => e
        @logger.debug { "statusline: delegate failed (#{e.class}: #{e.message})" }
        nil
      ensure
        [in_w, out_r].each { |io| io.close if io && !io.closed? }
        [writer, reader].each { |t| t&.join(THREAD_JOIN_GRACE) }
      end

      # Reads at most MAX_DELEGATE_OUTPUT_BYTES from the delegate's stdout,
      # then keeps draining (and discarding) whatever comes after so the
      # delegate never blocks on a full pipe buffer.
      def read_capped(io)
        kept = "".b
        loop do
          chunk = io.readpartial(64 * 1024)
          kept << chunk if kept.bytesize < MAX_DELEGATE_OUTPUT_BYTES
        end
      rescue EOFError
        kept.byteslice(0, MAX_DELEGATE_OUTPUT_BYTES)
      end

      def stop_group(pid, waiter)
        @terminator.terminate(pid, stop_timeout: KILL_GRACE)
      rescue Workspace::Error, SystemCallError => e
        @logger.debug { "statusline: could not stop delegate group #{pid} (#{e.message})" }
        begin
          Process.kill(:KILL, pid)
        rescue SystemCallError
          nil
        end
      ensure
        waiter.join(THREAD_JOIN_GRACE)
      end

      def remaining(deadline)
        [deadline - now, 0].max
      end

      def now
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end

      def presence(value)
        return nil if value.nil? || value.to_s.empty?
        value
      end
    end
  end
end
