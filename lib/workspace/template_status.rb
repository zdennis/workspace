require "digest"

module Workspace
  # Where a workspace's tmuxinator config stands against what a render would write today, from its
  # render record (the sidecar). Today's render fills the selected tmuxinator template's text with the
  # record's inputs (the agent command worked out from the current agent settings, as `template render
  # --name` does) and is compared byte for byte with the file.
  #
  # * `current`: the file is what a render writes today, and the record names the selected set.
  # * `stale`: the file is what was last rendered (its sha256 is the record's `rendered_sha`), but a render
  #   today would write something else, or from another set.
  # * `modified`: the file is not what was last rendered (edited by hand or by another tool) and is not what
  #   a render writes today either; `stale` and `reasons` still say whether a render would differ.
  # * `untracked`: no usable record, or no config, so there are no inputs to render from.
  #
  # `reasons` are labels for why a render differs: `template_switched` (the record's set is not the selected
  # one, reported even when the text matches, so apply rewrites the record), `template_changed` (the selected
  # set's text is not what was rendered), `agent_changed` (same text, but the agent settings or inputs give
  # another config), `template_unavailable` (the selected set can't be read) and `render_failed` (it can't be
  # filled with today's inputs).
  class TemplateStatus
    STATES = %w[current stale modified untracked].freeze

    # @!attribute workspace [String]
    # @!attribute state [String] one of {STATES}
    # @!attribute kind [String, nil] `project` or `worktree`, from the record
    # @!attribute template [String, nil] the tmuxinator template the record says it was rendered from
    # @!attribute selected [String, nil] the one a new config of that kind renders from now (nil when it can't be resolved)
    # @!attribute stale [Boolean] whether a render today would differ from the last one (or name another set)
    # @!attribute reasons [Array<String>] why, see the class description
    Row = Data.define(:workspace, :state, :kind, :template, :selected, :stale, :reasons) do
      # @return [Hash] the `--json` row, string keys
      def to_h
        {"workspace" => workspace, "state" => state, "kind" => kind, "template" => template, "selected" => selected,
         "stale" => stale, "reasons" => reasons}
      end
    end

    # The inputs a record is rendered with today: its own, with the agent command worked out from the
    # current agent settings (the recorded one is the pane text written then). Left out when the renderer
    # would refuse it, so rendering reports why.
    #
    # @param record [TmuxinatorConfigWriter::Record]
    # @param project_config [Workspace::ProjectConfig]
    # @return [Hash] symbol-keyed render inputs
    def self.record_inputs(record, project_config)
      inputs = record.inputs.except(:agent_command)
      value = project_config.agent_pane_value(inputs[:agent_kind], inputs[:workspace_name])
      value ? inputs.merge(agent_command: ProjectConfig.yaml_item(value)) : inputs
    rescue Error
      inputs
    end

    # @param library [Workspace::Library] resolves the template a kind selects
    # @param project_config [Workspace::ProjectConfig] renders, and finds a config
    # @param writer [Workspace::TmuxinatorConfigWriter] reads a workspace's render record
    def initialize(library:, project_config:, writer:)
      @library = library
      @project_config = project_config
      @writer = writer
    end

    # @param names [Array<String>] workspaces
    # @return [Array<Row>] one row each, in order
    def call(names)
      names.map { |name| row(name) }
    end

    # @param name [String] a workspace
    # @return [Row]
    def row(name)
      record = @writer.record(name)
      text = read_config(name)
      if record.nil? || text.nil?
        return Row.new(workspace: name, state: "untracked", kind: record&.kind&.to_s, template: record&.template, selected: nil, stale: false, reasons: [])
      end

      selected, rendered, reasons = render_today(name, record)
      state = if rendered && text == rendered && !reasons.include?("template_switched")
        "current"
      elsif sha(text) != record.rendered_sha
        "modified"
      else
        "stale"
      end
      reasons = [] if state == "current"
      Row.new(workspace: name, state: state, kind: record.kind.to_s, template: record.template, selected: selected, stale: !reasons.empty?, reasons: reasons)
    end

    # Whether a render today, with the workspace's record, writes exactly +text+: what a patch must satisfy
    # for the config to still read as rendered. False with no record or no way to render.
    #
    # @param name [String] a workspace
    # @param text [String] a config's text
    # @return [Boolean]
    def reproduces?(name, text)
      record = @writer.record(name)
      return false unless record

      _selected, rendered, = render_today(name, record)
      !rendered.nil? && rendered == text
    end

    private

    def read_config(name)
      File.read(@project_config.config_path_for(name))
    rescue SystemCallError, IOError
      nil
    end

    def sha(text)
      Digest::SHA256.hexdigest(text)
    end

    # The selected set's name, what a render writes today (nil when it can't be made) and the labels for why
    # a render differs from the last one.
    def render_today(name, record)
      chosen, template_text = selected_template(name, record)
      return [nil, nil, ["template_unavailable"]] unless chosen

      reasons = []
      reasons << "template_switched" if chosen["name"] != record.template
      reasons << "template_changed" if sha(template_text) != record.template_sha
      rendered = begin
        @project_config.render(record.kind, self.class.record_inputs(record, @project_config), template_text)
      rescue Error
        reasons << "render_failed"
        nil
      end
      reasons << "agent_changed" if rendered && !reasons.include?("template_changed") && sha(rendered) != record.rendered_sha
      [chosen["name"], rendered, reasons]
    end

    # The set a render would use and its text; nil when it can't be resolved or read.
    def selected_template(name, record)
      chosen = @library.tmuxinator_template(record.kind, workspace: name)
      [chosen, File.read(chosen["path"])]
    rescue Error, SystemCallError, IOError
      nil
    end
  end
end
