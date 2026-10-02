module Workspace
  # Builds the `--json` failure document, `{schema_version, ok: false, error,
  # code, details?, retry?}` with `code` from {ErrorCodes}, and the action
  # document that a mutating command prints with `--json`. Other successes are
  # written by each command with `"ok" => true` right after `schema_version`.
  module JsonEnvelope
    # The envelope version used when the caller has no command-specific one.
    SCHEMA_VERSION = 1

    # @param schema_version [Integer]
    # @param message [String] what a person would read
    # @param code [String] a key of {ErrorCodes::REGISTRY}
    # @param details [Hash, nil] machine data; omitted when nil or empty
    # @param retry_with [Hash, nil] the `retry` hint; omitted when nil
    # @return [Hash] the failure document
    def self.error(schema_version, message, code: "error", details: nil, retry_with: nil)
      doc = {"schema_version" => schema_version, "ok" => false, "error" => message, "code" => code}
      doc["details"] = details if details && !details.empty?
      doc["retry"] = retry_with if retry_with
      doc
    end

    # Outcomes that make a result row count as a failure when deriving a status.
    FAILED_OUTCOMES = %w[failed refused].freeze

    # Exit code for each action `status`: partial is 3, failed 1.
    ACTION_EXIT_CODES = {"ok" => 0, "dry_run" => 0, "cancelled" => 0, "partial" => 3, "failed" => 1, "refused" => 1}.freeze

    # The status of an action from its result rows: `ok` when none failed,
    # `failed` when all did, `partial` when some did. No rows is `ok`.
    #
    # @param results [Array<Hash>] rows with an `"outcome"`
    # @return [String]
    def self.action_status(results)
      failed = results.count { |r| FAILED_OUTCOMES.include?(r["outcome"]) }
      if failed.zero? then "ok"
      elsif failed == results.size then "failed"
      else
        "partial"
      end
    end

    # The document a mutating command prints with `--json`. `ok` is true even
    # for a `failed` status: it means the command ran and reports per-row
    # outcomes; the exit code follows `status`. Exceptions use {.error} instead.
    #
    # @param schema_version [Integer]
    # @param action [String] the verb, e.g. "stop"
    # @param results [Array<Hash>] one row per target, each with an `"outcome"`
    # @param status [String] a key of {ACTION_EXIT_CODES}
    # @param warnings [Array<Hash>] `{code, message}` entries
    # @param summary [Hash, nil] outcome counts; counted from `results` when nil
    # @param extra [Hash] more top-level keys, placed after `status`
    # @return [Hash] the action document
    def self.action(schema_version, action, results:, status:, warnings: [], summary: nil, extra: {})
      summary ||= results.each_with_object(Hash.new(0)) { |r, h| h[r["outcome"]] += 1 }
      {"schema_version" => schema_version, "ok" => true, "action" => action, "status" => status}
        .merge(extra)
        .merge("results" => results, "warnings" => warnings, "summary" => summary)
    end

    # @param schema_version [Integer]
    # @param exception [Exception] a {Workspace::Error}, an OptionParser error, or anything else
    # @param message [String, nil] replaces the exception's message (e.g. its first line)
    # @return [Hash] the failure document, using the exception's code, details and retry
    def self.from_exception(schema_version, exception, message: nil)
      message ||= exception.message
      case exception
      when Workspace::Error
        error(schema_version, message, code: exception.code, details: exception.details, retry_with: exception.retry)
      when OptionParser::ParseError
        error(schema_version, message, code: "usage")
      else
        error(schema_version, message)
      end
    end
  end
end
