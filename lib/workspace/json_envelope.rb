module Workspace
  # Builds the `--json` failure document, `{schema_version, ok: false, error,
  # code, details?, retry?}` with `code` from {ErrorCodes}. Successes are
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
