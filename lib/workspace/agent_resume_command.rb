require "shellwords"

module Workspace
  # Builds the shell line that resumes a Claude Code session in its directory:
  # the one place `restore` and the API-error recovery get that line from.
  class AgentResumeCommand
    # A Claude Code session id. Anything else is never put on a command line:
    # `claude --resume` reads a value that is not an id as a search term.
    SESSION_ID = /\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/

    # Flags of the workspace config's own `claude` pane that a resumed
    # session is started with too. Claude Code does not restore the
    # permission mode of a session that ran with it.
    CARRIED_FLAGS = %w[--dangerously-skip-permissions].freeze

    # @param tmuxinator_report [Workspace::TmuxinatorReport] reads the panes a workspace's config defines
    # @param agent_commands [Workspace::AgentCommands, nil] the command that starts Claude Code per
    #   workspace; nil means `claude` alone
    def initialize(tmuxinator_report:, agent_commands: nil)
      @tmuxinator_report = tmuxinator_report
      @agent_commands = agent_commands
    end

    # @param workspace [String] a workspace name
    # @return [Array<String>, nil] the flags of the config's `claude` pane that a resumed session
    #   carries (empty when it has none); nil when the tmuxinator config can't be read
    def flags_for(workspace)
      windows = @tmuxinator_report.show(workspace)["windows"]
      claude = windows.flat_map { |window| window["panes"] }.find { |pane| pane["kind"] == "claude" }
      Array(claude && claude["flags"]) & CARRIED_FLAGS
    rescue Workspace::Error
      nil
    end

    # @param workspace [String] a workspace name
    # @param cwd [String] the directory the session ran in
    # @param session_id [String] the Claude Code session id
    # @param flags [Array<String>, nil] what {#flags_for} answered (or +[]+)
    # @return [String, nil] the line to type, or nil for a session id that isn't one or nil +flags+
    def call(workspace:, cwd:, session_id:, flags:)
      return nil if flags.nil? || !session_id.to_s.match?(SESSION_ID)

      program = @agent_commands ? @agent_commands.command_for(workspace, "claude") : "claude"
      "cd -- #{Shellwords.escape(cwd)} && #{[program, *flags, "--resume", session_id].join(" ")}"
    end
  end
end
