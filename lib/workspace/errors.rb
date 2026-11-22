module Workspace
  # Raised for runtime errors in workspace operations.
  #
  # Besides the message, an error carries the machine-readable parts of the
  # `--json` error envelope (see {JsonEnvelope}): a stable {#code} from
  # {ErrorCodes}, {#details} and an optional {#retry}.
  class Error < StandardError
    # @return [Hash, nil] the flags that turn this refusal into a forced run, as
    #   `{"flags" => [...], "destructive" => bool}`
    attr_reader :retry

    # @param message [String, nil]
    # @param code [String, nil] a key of {ErrorCodes::REGISTRY}; nil uses the class's code
    # @param details [Hash, nil] machine data for the envelope's `details`
    # @param retry_with [Hash, nil] the envelope's `retry`
    def initialize(message = nil, code: nil, details: nil, retry_with: nil)
      super(message)
      @code = code
      @details = details
      @retry = retry_with
    end

    # @return [String] the stable error code; `"error"` unless a subclass or the raiser names one
    def code
      @code || "error"
    end

    # @return [Hash] machine data about the failure; `{}` when there is none
    def details
      @details || {}
    end
  end

  # Raised for invalid usage or missing required arguments.
  class UsageError < Error
    # @return [String] `"usage"`
    def code
      @code || "usage"
    end
  end

  # Raised when a config file exists but can't be parsed as a YAML mapping.
  class ConfigParseError < Error
    # @return [String] path of the file that failed to parse
    attr_reader :path

    # @return [String] why the file couldn't be used
    attr_reader :reason

    # @param path [String] the config file
    # @param reason [String] why it couldn't be used
    def initialize(path, reason)
      @path = path
      @reason = reason
      super("Cannot parse #{path}: #{reason}.")
    end

    # @return [String] `"config_parse"`
    def code
      @code || "config_parse"
    end

    # @return [Hash] the file's `path` and the parse `reason`
    def details
      {"path" => path, "reason" => reason}
    end
  end

  # Raised when a worktree can't be removed because it has unsaved work
  # (or git couldn't tell whether it does).
  class UnsavedWorkError < Error
    # @return [Hash, Symbol] the Git#unsaved_work result: a Hash, or :unknown
    attr_reader :unsaved

    # @param message [String, nil] error message
    # @param unsaved [Hash, Symbol] the Git#unsaved_work result
    def initialize(message = nil, unsaved: :unknown)
      super(message)
      @unsaved = unsaved
    end

    # @param unsaved [Hash, Symbol] a Git#unsaved_work result
    # @return [String] a one-phrase description of the unsaved work
    def self.describe(unsaved)
      return "git couldn't check it for unsaved work" if unsaved == :unknown
      "#{unsaved[:changed_files]} changed file(s) and #{unsaved[:unpushed_commits]} " \
        "unpushed commit(s) on #{unsaved[:branch] || "HEAD"}"
    end

    # @return [String] a one-phrase description of the unsaved work
    def summary
      self.class.describe(unsaved)
    end

    # @return [String] `"unsaved_unknown"` when git couldn't check, else `"unsaved_work"`
    def code
      @code || ((unsaved == :unknown) ? "unsaved_unknown" : "unsaved_work")
    end

    # @return [Hash] the counts behind the refusal; `{}` when git couldn't check
    def details
      return {} if unsaved == :unknown
      unsaved.to_h { |key, value| [key.to_s, value] }
    end

    # @return [Hash] `--force` discards the unsaved work
    def retry
      @retry || {"flags" => ["--force"], "destructive" => true}
    end
  end
end
