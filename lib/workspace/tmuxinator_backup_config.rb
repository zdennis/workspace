module Workspace
  # Reads the global `tmuxinator.backups.keep` and `tmuxinator.backups.max_age`, as written by
  # `workspace config set`: how many tmuxinator config backup batches are kept, and how old one may get.
  # A bad stored value falls back to the default with a warning, since `config set` already refuses one.
  class TmuxinatorBackupConfig
    # @param config_resolver [Workspace::ConfigResolver]
    # @param error_output [IO] where a warning about an unusable value goes
    def initialize(config_resolver:, error_output: $stderr)
      @config_resolver = config_resolver
      @error_output = error_output
    end

    # @return [Integer] how many batches stay (default 20)
    def keep
      read("tmuxinator.backups.keep")
    end

    # @return [Integer, nil] seconds a batch may age; nil sets no age limit
    def max_age
      read("tmuxinator.backups.max_age")
    end

    private

    def read(key)
      default = ConfigSchema.default(key)
      value = @config_resolver.view(workspace: "", upto: "global").raw(key)
      value.nil? ? default : ConfigSchema.parse(key, value)
    rescue Workspace::ConfigParseError, ArgumentError => e
      @error_output.puts "Warning: #{key}: #{e.message} Using #{default.nil? ? "no limit" : default}."
      default
    end
  end
end
