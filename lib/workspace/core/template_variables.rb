# frozen_string_literal: true

module Workspace
  # The one table of the placeholders a tmuxinator template may hold. `ProjectConfig#render` fills each
  # row from the input named by `input`; docs and specs read the same rows.
  module TemplateVariables
    # @!attribute name [String] the placeholder text between the braces
    # @!attribute kinds [Array<Symbol>] the config kinds (`:project`, `:worktree`) the renderer fills it for
    # @!attribute required [Hash{Symbol=>Boolean}] per kind, whether a template holding it needs a value
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

    ROWS = [
      Row.new(name: "PROJECT_NAME", kinds: BOTH, required: ALWAYS, input: :project_name,
        description: "The project's name (a worktree's parent project).", source: "the project", sample: "myapp"),
      Row.new(name: "WORKSPACE_NAME", kinds: BOTH, required: ALWAYS, input: :workspace_name,
        description: "The workspace's name, which is its config's name.", source: "the workspace",
        sample: "myapp.worktree-proj-123"),
      Row.new(name: "PROJECT_ROOT", kinds: %i[project], required: {project: true, worktree: false}, input: :project_root,
        description: "The project's checkout directory.", source: "the project", sample: "/Users/me/src/myapp"),
      Row.new(name: "DISPLAY_NAME", kinds: BOTH, required: ALWAYS, input: :display_name,
        description: "The text of the launcher pane's banner.", source: "the workspace name", sample: "myapp"),
      Row.new(name: "CONFIG_PATH", kinds: BOTH, required: ALWAYS, input: :config_path,
        description: "The path of the config being written.", source: "the config directory",
        sample: "/Users/me/.config/tmuxinator/myapp.yml"),
      Row.new(name: "TMUX_SESSION_NAME", kinds: %i[worktree], required: WORKTREE_ONLY, input: :tmux_session_name,
        description: "The tmux session name of the worktree.", source: "the worktree", sample: "myapp-wt-proj-123"),
      Row.new(name: "WORKTREE_PATH", kinds: %i[worktree], required: WORKTREE_ONLY, input: :worktree_path,
        description: "The worktree's directory.", source: "the worktree",
        sample: "/Users/me/src/myapp/.worktrees/proj-123"),
      Row.new(name: "WORKTREE_BRANCH", kinds: %i[worktree], required: WORKTREE_ONLY, input: :worktree_branch,
        description: "The worktree's git branch.", source: "the worktree", sample: "proj-123"),
      Row.new(name: "PRE_WINDOW", kinds: %i[worktree], required: {project: false, worktree: false}, input: :task_id, fill: :line,
        description: "A whole line: `pre_window: export WORKSPACE_TASK=ID` with a task id, dropped without one.",
        source: "the workspace's task", sample: "t_abc123")
    ].each(&:freeze).freeze

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
