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

    # A {Row} with what it was worked out from.
    #
    # @!attribute row [Row]
    # @!attribute record [TmuxinatorConfigWriter::Record, nil] the render record read
    # @!attribute text [String, nil] the config as read
    # @!attribute rendered [String, nil] what a render writes today; nil when it can't be made
    # @!attribute inputs [Hash, nil] the inputs it was rendered with ({.record_inputs})
    # @!attribute template_sha [String, nil] sha256 of the selected set's text
    # @!attribute error [Workspace::Error, nil] what stopped the render
    Assessment = Data.define(:row, :record, :text, :rendered, :inputs, :template_sha, :error)

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
      assess(name).row
    end

    # {#row} with what it was worked out from, for a caller that writes the render: `template apply`.
    #
    # @param name [String] a workspace
    # @return [Assessment]
    def assess(name)
      record = @writer.record(name)
      text = read_config(name)
      if record.nil? || text.nil?
        row = Row.new(workspace: name, state: "untracked", kind: record&.kind&.to_s, template: record&.template, selected: nil, stale: false, reasons: [])
        return Assessment.new(row: row, record: record, text: text, rendered: nil, inputs: nil, template_sha: nil, error: nil)
      end

      today = render_today(name, record)
      reasons = today[:reasons]
      state = if today[:rendered] && text == today[:rendered] && !reasons.include?("template_switched")
        "current"
      elsif sha(text) != record.rendered_sha
        "modified"
      else
        "stale"
      end
      reasons = [] if state == "current"
      row = Row.new(workspace: name, state: state, kind: record.kind.to_s, template: record.template, selected: today[:selected], stale: !reasons.empty?, reasons: reasons)
      Assessment.new(row: row, record: record, text: text, rendered: today[:rendered], inputs: today[:inputs], template_sha: today[:template_sha], error: today[:error])
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

      rendered = render_today(name, record)[:rendered]
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

    # The selected set's name and text sha, the inputs and what a render writes today with them (nil when it
    # can't be made, with the error that stopped it) and the labels for why a render differs from the last one.
    def render_today(name, record)
      chosen, template_text = selected_template(name, record)
      return {selected: nil, rendered: nil, reasons: ["template_unavailable"]} unless chosen

      reasons = []
      reasons << "template_switched" if chosen["name"] != record.template
      reasons << "template_changed" if sha(template_text) != record.template_sha
      inputs = self.class.record_inputs(record, @project_config)
      error = nil
      rendered = begin
        @project_config.render(record.kind, inputs, template_text)
      rescue Error => e
        error = e
        reasons << "render_failed"
        nil
      end
      reasons << "agent_changed" if rendered && !reasons.include?("template_changed") && sha(rendered) != record.rendered_sha
      {selected: chosen["name"], template_sha: sha(template_text), inputs: inputs, rendered: rendered, reasons: reasons, error: error}
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
