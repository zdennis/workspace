require "shellwords"

module Workspace
  # Builds the shell line that resumes a Claude Code session in its directory:
  # the one place `restore` and the API-error recovery get that line from.
  class AgentResumeCommand
    # A Claude Code session id. Anything else is never put on a command line:
    # `claude --resume` reads a value that is not an id as a search term.
    SESSION_ID = /\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/

    # Flags a resumed session is started with too. Claude Code does not restore
    # the permission mode of a session that ran with it.
    CARRIED_FLAGS = %w[--dangerously-skip-permissions].freeze

    # Common Claude Code options that take one value, so the bare word after
    # them isn't the prompt. Free-text ones (`--append-system-prompt`, `--name`)
    # stay out: a prompt-like word after them can't be told from their value.
    VALUE_OPTIONS = %w[--resume -r --session-id --model --fallback-model --settings --permission-mode --agent --effort
      --mcp-config --add-dir --allowedTools --allowed-tools].freeze

    # The carried flags a running agent was started with, from its `ps` args.
    #
    # `ps` joins argv with spaces, so a prompt on the command line can't be told
    # from flags by quoting, and Shellwords would raise on an apostrophe in one.
    # A word counts only among the options, which end at `--` or at a bare word
    # that isn't the value of a {VALUE_OPTIONS} option. So a second value of a
    # multi-value option ends them too. Reading a flag as absent costs a
    # permission prompt, where reading it as present would bypass them all.
    #
    # @param args [String, nil] the process's `args` from {ProcessTree}
    # @return [Array<String>, nil] the flags (empty when it has none); nil when
    #   `ps` gave no arguments for the process, which says nothing either way
    def self.carried_flags(args)
      program, *words = args.to_s.split
      return nil if program.nil? || program.start_with?("(")

      takes_value = false
      options = words.take_while do |word|
        next false if word == "--"
        option = word.start_with?("-")
        keep = option || takes_value
        takes_value = option && VALUE_OPTIONS.include?(word)
        keep
      end
      options & CARRIED_FLAGS
    end

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
    # @param flags [Array<String>, nil] the flags to carry: {#flags_for}'s or {.carried_flags}' answer
    # @return [String, nil] the line to type, or nil for a session id that isn't one or nil +flags+
    def call(workspace:, cwd:, session_id:, flags:)
      return nil if flags.nil? || !session_id.to_s.match?(SESSION_ID)

      program = @agent_commands ? @agent_commands.command_for(workspace, "claude") : "claude"
      "cd -- #{Shellwords.escape(cwd)} && #{[program, *flags, "--resume", session_id].join(" ")}"
    end
  end
end
