# frozen_string_literal: true

require "yaml"

module Workspace
  # Checks a tmuxinator template set (`project.yml`, `worktree.yml`) without writing anything: the placeholders
  # ({TemplateVariables}), the agent pane, and a dummy render through {ProjectConfig#render} that must parse as
  # a tmuxinator config. Answers problems; raises nothing for a bad template.
  class TemplateValidator
    # @!attribute severity [String] `error` or `warning`
    # @!attribute code [String] a stable code (`unknown_placeholder`, `missing_placeholder`, `pre_window_not_alone`,
    #   `agent_command_not_alone`, `no_agent_pane`, `literal_agent_pane`, `unreadable`, `render_failed`, `invalid_yaml`,
    #   `unresolved_placeholder`)
    # @!attribute kind [Symbol] `:project` or `:worktree`
    # @!attribute message [String]
    Problem = Struct.new(:severity, :code, :kind, :message, keyword_init: true) do
      # @return [Hash{String=>String}]
      def to_h = {"severity" => severity, "code" => code, "kind" => kind.to_s, "message" => message}

      # @return [String] `project.yml: message`
      def to_s = "#{kind}.yml: #{message}"
    end

    # @!attribute errors [Array<Problem>]
    # @!attribute warnings [Array<Problem>]
    Result = Struct.new(:errors, :warnings, keyword_init: true) do
      # @return [Boolean] true when there is no error (warnings allowed)
      def valid? = errors.empty?
    end

    # An agent command that needs YAML quoting, so the dummy render proves the quoting.
    SAMPLE_AGENT_COMMAND = "claude-dev --x: y #z"

    # The file of each kind in a set.
    TEMPLATE_FILES = {project: "project.yml", worktree: "worktree.yml"}.freeze

    AGENT_ITEM = /\A\s*- \{\{AGENT_COMMAND\}\}\s*\z/

    # @param project_config [Workspace::ProjectConfig] its {ProjectConfig#render} fills the dummy render and
    #   {ProjectConfig#agent_pane_in_template?} finds a literal agent pane
    def initialize(project_config:)
      @project_config = project_config
    end

    # @param dir [String] a set's directory, holding `project.yml` and `worktree.yml`
    # @return [Result]
    def call_set(dir)
      problems = TEMPLATE_FILES.flat_map { |kind, name| file(kind, File.join(dir, name)) }
      Result.new(errors: problems.select { |p| p.severity == "error" }, warnings: problems.select { |p| p.severity == "warning" })
    end

    # @param kind [Symbol] `:project` or `:worktree`
    # @param path [String] one tmuxinator template file, saved or not
    # @return [Array<Problem>] its errors and warnings, errors first
    def call_file(kind, path)
      file(kind, path).sort_by { |p| (p.severity == "error") ? 0 : 1 }
    end

    private

    def file(kind, path)
      text = begin
        File.read(path)
      rescue SystemCallError => e
        return [problem("error", "unreadable", kind, "can't read #{path}: #{e.message}")]
      end
      found = placeholder_problems(kind, text) + pre_window_problems(kind, text) + agent_problems(kind, text, path)
      found + render_problems(kind, text, found)
    end

    def placeholder_problems(kind, text)
      names = text.scan(/\{\{([A-Z0-9_]+)\}\}/).flatten.uniq
      unknown = names.reject { |name| TemplateVariables.find(name)&.kinds&.include?(kind) }.map do |name|
        known = TemplateVariables.find(name) ? "is not filled in a #{kind} template" : "is not a placeholder"
        problem("error", "unknown_placeholder", kind, "{{#{name}}} #{known}. See: workspace template variables")
      end
      required = TemplateVariables.for_kind(kind).select { |row| row.required[kind] }.map(&:name)
      missing = required.reject { |name| names.include?(name) }.map do |name|
        problem("error", "missing_placeholder", kind, "{{#{name}}} is required and does not appear.")
      end
      unknown + missing
    end

    def pre_window_problems(kind, text)
      return [] unless text.include?("{{PRE_WINDOW}}")
      return [] if text.lines.grep(/\{\{PRE_WINDOW\}\}/).all? { |line| line.chomp == "{{PRE_WINDOW}}" }
      [problem("error", "pre_window_not_alone", kind, "{{PRE_WINDOW}} must be alone on its line, with nothing before or after it.")]
    end

    # The agent pane: `- {{AGENT_COMMAND}}` alone, else a literal line the renderer can find (a warning). A
    # worktree needs one of them; a project template without one is a warning.
    def agent_problems(kind, text, path)
      severity = (kind == :worktree) ? "error" : "warning"
      lines = text.lines
      uses = lines.select { |line| line.include?("{{AGENT_COMMAND}}") }
      if uses.any?
        return [] if uses.all? { |line| line.match?(AGENT_ITEM) }
        return [problem(severity, "agent_command_not_alone", kind,
          "{{AGENT_COMMAND}} must be the whole unquoted list item (- {{AGENT_COMMAND}}); a value that needs quoting breaks inside quotes or other text.")]
      end
      if @project_config.agent_pane_in_template?(path)
        [problem("warning", "literal_agent_pane", kind,
          "The agent pane is a literal claude line, so agent.kind and agent.commands apply only through the rewrite. Use - {{AGENT_COMMAND}}, which follows them.")]
      else
        [problem(severity, "no_agent_pane", kind, "No agent pane found: add - {{AGENT_COMMAND}} as a pane item.")]
      end
    end

    def render_problems(kind, text, found)
      return [] if found.any? { |p| p.severity == "error" || p.code == "agent_command_not_alone" }
      content = begin
        @project_config.render(kind, sample_inputs(kind), text)
      rescue Workspace::Error => e
        return [problem("error", "render_failed", kind, "the dummy render failed: #{e.message}")]
      end
      return [problem("error", "unresolved_placeholder", kind, "a {{ is left after the dummy render.")] if content.include?("{{")
      parsed = begin
        YAML.safe_load(content)
      rescue Psych::Exception => e
        return [problem("error", "invalid_yaml", kind, "the dummy render is not valid YAML: #{e.message}")]
      end
      missing = %w[name root windows].reject { |key| parsed.is_a?(Hash) && parsed.key?(key) }
      return [] if missing.empty?
      [problem("error", "invalid_yaml", kind, "the dummy render has no #{missing.join(", ")} key.")]
    end

    def sample_inputs(kind)
      TemplateVariables.sample_inputs(kind).merge(agent_command: ProjectConfig.yaml_item(SAMPLE_AGENT_COMMAND))
    end

    def problem(severity, code, kind, message)
      Problem.new(severity: severity, code: code, kind: kind, message: message)
    end
  end
end
