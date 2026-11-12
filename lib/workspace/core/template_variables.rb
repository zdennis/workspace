# frozen_string_literal: true

module Workspace
  # The one table of the placeholders a tmuxinator template may hold. `ProjectConfig#render` fills each
  # row from the input named by `input`; docs and specs read the same rows.
  module TemplateVariables
    # @!attribute name [String] the placeholder text between the braces
    # @!attribute kinds [Array<Symbol>] the config kinds (`:project`, `:worktree`) the renderer fills it for
    # @!attribute required [Hash{Symbol=>Boolean}] per kind, whether a template of that kind must hold it (`template validate` refuses one that does not)
    # @!attribute description [String]
    # @!attribute source [String] where the value comes from
    # @!attribute sample [String] an example value
    # @!attribute input [Symbol] the render input key that holds the value
    # @!attribute fill [Symbol] `:value` replaces the placeholder text; `:line` is a whole line the renderer writes or drops
    Row = Struct.new(:name, :kinds, :required, :description, :source, :sample, :input, :fill, keyword_init: true) do
      def initialize(fill: :value, **rest) = super
    end

    BOTH = %i[project worktree].freeze
    ALWAYS = {project: true, worktree: true}.freeze
    WORKTREE_ONLY = {project: false, worktree: true}.freeze
    PROJECT_ONLY = {project: true, worktree: false}.freeze
    NEVER = {project: false, worktree: false}.freeze

    ROWS = [
      Row.new(name: "PROJECT_NAME", kinds: BOTH, required: PROJECT_ONLY, input: :project_name,
        description: "The project's name (a worktree's parent project).", source: "the project", sample: "myapp"),
      Row.new(name: "WORKSPACE_NAME", kinds: BOTH, required: ALWAYS, input: :workspace_name,
        description: "The workspace's name, which is its config's name.", source: "the workspace",
        sample: "myapp.worktree-proj-123"),
      Row.new(name: "PROJECT_ROOT", kinds: %i[project], required: PROJECT_ONLY, input: :project_root,
        description: "The project's checkout directory.", source: "the project", sample: "/Users/me/src/myapp"),
      Row.new(name: "DISPLAY_NAME", kinds: BOTH, required: NEVER, input: :display_name,
        description: "The text of the launcher pane's banner.", source: "the workspace name", sample: "myapp"),
      Row.new(name: "CONFIG_PATH", kinds: BOTH, required: NEVER, input: :config_path,
        description: "The path of the config being written.", source: "the config directory",
        sample: "/Users/me/.config/tmuxinator/myapp.yml"),
      Row.new(name: "TMUX_SESSION_NAME", kinds: %i[worktree], required: WORKTREE_ONLY, input: :tmux_session_name,
        description: "The tmux session name of the worktree.", source: "the worktree", sample: "myapp-wt-proj-123"),
      Row.new(name: "WORKTREE_PATH", kinds: %i[worktree], required: WORKTREE_ONLY, input: :worktree_path,
        description: "The worktree's directory.", source: "the worktree",
        sample: "/Users/me/src/myapp/.worktrees/proj-123"),
      Row.new(name: "WORKTREE_BRANCH", kinds: %i[worktree], required: WORKTREE_ONLY, input: :worktree_branch,
        description: "The worktree's git branch.", source: "the worktree", sample: "proj-123"),
      Row.new(name: "AGENT_COMMAND", kinds: BOTH, required: NEVER, input: :agent_command,
        description: "The agent pane's command: for Claude Code the flagged `--continue ||` line with the configured program, for another kind the bare configured command.",
        source: "`agent.kind` and `agent.commands.<kind>`",
        sample: "claude --dangerously-skip-permissions --continue || claude --dangerously-skip-permissions"),
      Row.new(name: "PRE_WINDOW", kinds: %i[worktree], required: NEVER, input: :task_id, fill: :line,
        description: "A whole line: `pre_window: export WORKSPACE_TASK=ID` with a task id, dropped without one.",
        source: "the workspace's task", sample: "t_abc123")
    ].each(&:freeze).freeze

    # The values `template render --sample` and the validator's dummy render fill: each row's sample, a Claude Code
    # agent kind and, for a worktree, a task id.
    #
    # @param kind [Symbol] `:project` or `:worktree`
    # @return [Hash{Symbol=>String}] render inputs by their key
    def self.sample_inputs(kind)
      inputs = for_kind(kind).to_h { |row| [row.input, row.sample] }
      inputs[:agent_kind] = "claude"
      inputs[:task_id] = "t_sample" if kind == :worktree
      inputs
    end

    # @param name [String]
    # @return [Row, nil]
    def self.find(name)
      ROWS.find { |row| row.name == name }
    end

    # @param kind [Symbol]
    # @return [Array<Row>] the rows the renderer fills for that kind
    def self.for_kind(kind)
      ROWS.select { |row| row.kinds.include?(kind) }
    end
  end
end
