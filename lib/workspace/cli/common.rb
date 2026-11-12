require "json"

module Workspace
  class CLI
    # The output, exit and help helpers every command family calls. It holds no state: a method
    # that writes or exits takes the {Invocation}, so it uses the streams of the run in progress
    # (the buffers, inside `--help --json`).
    class Common
      # Schema version of the action documents the mutating commands print with `--json`.
      ACTION_JSON_SCHEMA_VERSION = 1

      # Runs a mutating command's work and reports it. Without `--json` the
      # command's text is untouched and a non-zero `exit_code` from the block
      # exits. With it, the text goes to stderr, stdout gets one action document
      # ({JsonEnvelope.action}), and the exit code follows its `status`: 0, 3 for
      # partial, and for failed the block's own non-zero code (else 1). A raised
      # {Workspace::Error} still becomes the error envelope in the rescue funnel.
      #
      # @param invocation [Invocation]
      # @param action [String] the verb in the document, e.g. "stop"
      # @param json [Boolean] whether `--json` was given
      # @yieldreturn [Hash, nil] `:exit_code`; with `json` also `:results` (rows
      #   with an `"outcome"`), and optionally `:warnings`, `:extra` and `:status`
      #   (else derived from the rows); build rows only when `json`, as text mode ignores them
      # @return [void]
      def run_action(invocation, action, json:)
        unless json
          outcome = yield
          code = outcome && outcome[:exit_code]
          invocation.exit_handler.exit(code) if code && !code.zero?
          return
        end

        outcome = divert_output(invocation) { yield }
        results = outcome.fetch(:results)
        code = outcome[:exit_code]
        status = outcome[:status] || JsonEnvelope.action_status(results)
        status = "failed" if status == "ok" && code && !code.zero?
        invocation.output.puts JSON.generate(JsonEnvelope.action(ACTION_JSON_SCHEMA_VERSION, action,
          results: results, status: status, warnings: outcome[:warnings] || [], extra: outcome[:extra] || {}))
        exit_code = JsonEnvelope::ACTION_EXIT_CODES.fetch(status)
        exit_code = code if exit_code == 1 && code && !code.zero?
        invocation.exit_handler.exit(exit_code) unless exit_code.zero?
      end

      # Sends what collaborators print to stderr while the block runs, so stdout
      # stays free for one JSON document. A plain stream (a test double) is left alone.
      #
      # @param invocation [Invocation]
      def divert_output(invocation, &block)
        return yield unless invocation.output.respond_to?(:divert_to)
        invocation.output.divert_to(invocation.error_output, &block)
      end

      # One row of an action document's `results`.
      #
      # @param workspace [String, nil]
      # @param outcome [String] e.g. "stopped", "failed"
      # @param reason [String, nil] a short machine-readable cause
      # @param message [String, nil] what a person would read
      # @param extra [Hash] more keys for the row
      # @return [Hash]
      def action_row(workspace, outcome, reason: nil, message: nil, **extra)
        {"workspace" => workspace, "outcome" => outcome, "reason" => reason, "message" => message}.merge(extra.transform_keys(&:to_s))
      end

      # One `results` row for a command that reports only an exit code: `ok_outcome`
      # on 0, else `failed` with the code (the details went to stderr).
      #
      # @param workspace [String, nil]
      # @param ok_outcome [String]
      # @param code [Integer]
      # @return [Hash]
      def exit_code_row(workspace, ok_outcome, code, **extra)
        return action_row(workspace, ok_outcome, **extra) if code.zero?
        action_row(workspace, "failed", reason: "exit_code", message: "Exited #{code}; the details are on stderr.", exit_code: code, **extra)
      end

      # Emits a caught failure as the `--json` error envelope (code, details and
      # retry from the exception) to stdout and exits 1.
      #
      # @param invocation [Invocation]
      # @param schema_version [Integer] the command's JSON schema version
      # @param error [Exception] the failure
      # @param message [String, nil] replaces the exception's message (e.g. its first line)
      def emit_json_error(invocation, schema_version, error, message: nil)
        invocation.output.puts JSON.generate(JsonEnvelope.from_exception(schema_version, error, message: message))
        invocation.exit_handler.exit(1)
      end

      # Emits the documented `--json` error contract (see docs/README.lock.md,
      # docs/README.dev.md) to stdout and exits, for usage/validation errors
      # raised before a command's own `status_json` branch is reached (e.g. bad
      # option, extra argument, invalid lock name).
      #
      # @param invocation [Invocation]
      # @param schema_version [Integer] the command's JSON schema version
      # @param message [String] error message (single line; not the full help text)
      def emit_json_usage_error(invocation, schema_version, message)
        invocation.output.puts JSON.generate(JsonEnvelope.error(schema_version, message, code: "usage"))
        invocation.exit_handler.exit(1)
      end

      # Whether +args+ ask for help, so a verb shows its page before it parses or acts.
      # Only the words before a `--` count, and with a +page+ the word after a flag
      # that takes a value is that value, so `--note --help` stays literal.
      #
      # @param args [Array<String>]
      # @param page [Hash, nil] a {HelpPages} page
      # @return [Boolean]
      def help_requested?(args, page = nil)
        value_flags = page ? HelpPages.value_flags(page) : []
        skip = false
        args.each do |arg|
          break if arg == "--"
          if skip
            skip = false
          elsif ["--help", "-h"].include?(arg)
            return true
          else
            skip = value_flags.include?(arg)
          end
        end
        false
      end

      # Prints the page of the verb that leads +args+ when help is asked for, before
      # anything is parsed or acted on. False when there is no verb or no request,
      # so the bare command keeps its overview.
      #
      # @param invocation [Invocation]
      # @param table [Hash] one command's {HelpPages} table
      # @param args [Array<String>]
      # @return [Boolean]
      def verb_help_shown?(invocation, table, args)
        _key, page = HelpPages.lookup(table, args)
        return false unless page && help_requested?(args, page)

        invocation.output.puts HelpPages.render(page)
        true
      end

      # Whether --json was requested, even when the parse error happened before
      # OptionParser reached the --json flag (e.g. an unknown option listed
      # first). The JSON error contract must not depend on flag order.
      #
      # @param json [Boolean] the flag as set by OptionParser so far
      # @param args [Array<String>] the raw, unparsed argv for this subcommand
      # @return [Boolean]
      def json_requested?(json, args)
        json || args.include?("--json")
      end

      # Parses a duration option such as `--poll` or `--max-wait` (e.g. "9m", "5s", or
      # a plain number of seconds), raising a usage error instead of a
      # backtrace on unparsable input.
      #
      # @param flag [String] option name, for the error message
      # @param value [String] raw option value
      # @param positive [Boolean] require the duration be greater than 0
      # @return [Numeric] seconds
      # @raise [Workspace::UsageError]
      def parse_duration_option(flag, value, positive: false)
        positive ? Workspace::Duration.parse_positive(value) : Workspace::Duration.parse(value)
      rescue ArgumentError => e
        raise UsageError, "#{flag}: #{e.message}"
      end
    end
  end
end
