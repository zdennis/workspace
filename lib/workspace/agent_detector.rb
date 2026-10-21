module Workspace
  # Finds the coding agent in a pane the way {AgentProvider.detect} does, for one workspace's configured
  # program names (see {AgentCommands#detector}). With no aliases it is {AgentProvider.detect} as it was.
  AgentDetector = Struct.new(:aliases, keyword_init: true) do
    def initialize(aliases: {})
      super
    end

    # @param command [String] the pane's current command
    # @param pid [Integer] the pane's process id
    # @param tree [Workspace::ProcessTree::Snapshot]
    # @param providers [Array<AgentProvider>] agents to recognize
    # @return [Hash, nil] +{provider:, pid:}+ for the agent found, or nil
    def call(command:, pid:, tree:, providers: AgentProvider.all)
      AgentProvider.detect(command: command, pid: pid, tree: tree, providers: providers, aliases: aliases)
    end

    # @return [Boolean] whether any extra program name is configured
    def aliases?
      !aliases.empty?
    end
  end
end
