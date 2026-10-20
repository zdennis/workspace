module Workspace
  # Names the coding agent each tmux pane runs, by the label `workspace sessions`
  # shows in its TITLE column ("Claude Code", "Codex"). Agents are recognized the
  # way {SessionMonitor} and {AgentReadiness} do, from a pane's command and the
  # process table, over the same configured providers.
  class AgentLabels
    # @param process_tree [Workspace::ProcessTree] read once per lookup
    # @param providers [Array<Workspace::AgentProvider>] agents to recognize
    def initialize(process_tree:, providers: AgentProvider.all)
      @process_tree = process_tree
      @providers = providers
    end

    # @param details [Array<Hash>] panes as {Tmux#pane_details} returns them
    # @return [Hash{Integer => String}] label by pane index, for panes running an agent;
    #   empty when there are no panes (the process table is not read) or it cannot be read
    def by_index(details)
      return {} if details.empty?

      tree = @process_tree.snapshot
      details.each_with_object({}) do |detail, labels|
        agent = AgentProvider.detect(command: detail[:command], pid: detail[:pid], tree: tree, providers: @providers)
        labels[detail[:index]] = agent[:provider].label if agent
      end
    rescue Workspace::Error
      {}
    end
  end
end
