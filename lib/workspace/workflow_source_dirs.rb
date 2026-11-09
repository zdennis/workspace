require "digest"

module Workspace
  # Answers the directories the catalog reads workflow sources from: one slot per
  # entry of the global `workflows.sources`, in list order. A local entry is its own
  # directory; a remote one is its cache directory
  # (`<state_dir>/.workflows-sources/<sha256-of-entry>/`). A slot is nil when its
  # directory is not there, so the catalog's `source:N` numbers stay the 1-based
  # positions `--source N` uses. Reads only; it never fetches.
  class WorkflowSourceDirs
    CACHE_DIR = ".workflows-sources".freeze

    # @param config_resolver [Workspace::ConfigResolver]
    # @param state_dir [String] the state root the cache lives under
    # @param home [String, nil] what a leading `~` stands for
    def initialize(config_resolver:, state_dir:, home: ENV["HOME"])
      @config_resolver = config_resolver
      @state_dir = state_dir
      @home = home
    end

    # The cache directory of one source entry, existing or not.
    #
    # @param entry [String] the entry as listed in `workflows.sources`
    # @return [String]
    def self.cache_dir(state_dir, entry)
      File.join(state_dir, CACHE_DIR, Digest::SHA256.hexdigest(entry))
    end

    # @return [Array<String, nil>] a directory per listed source, nil where it does not exist or the entry can't be read
    def call
      entries.map { |entry| existing(entry) }
    rescue Workspace::ConfigParseError, ArgumentError
      []
    end

    private

    def entries
      value = @config_resolver.view(workspace: "", upto: "global").raw("workflows.sources")
      value.nil? ? [] : ConfigSchema.parse("workflows.sources", value)
    end

    def existing(entry)
      parsed = WorkflowSource.parse(entry, home: @home)
      dir = (parsed.kind == :local) ? parsed.path : self.class.cache_dir(@state_dir, entry)
      File.directory?(dir) ? dir : nil
    rescue Workspace::UsageError
      nil
    end
  end
end
