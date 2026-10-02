module Workspace
  # Builds the documents behind `workspace config show --json` and
  # `workspace config validate --json`: every {ConfigSchema} key with the value
  # a workspace reads and the layer it comes from, and the problems in the
  # files that workspace reads.
  #
  # A file that can't be parsed is reported as data (message, line, column)
  # and its keys are marked unreadable, instead of raising: this is for
  # callers that report on config, not ones that act on it. Keys marked
  # `sensitive` in the schema never have their value in the output.
  class ConfigReport
    # Schema version of both documents.
    JSON_SCHEMA_VERSION = 1

    # Problem severities that make a config invalid.
    ERROR = "error".freeze

    # @param project_settings [Workspace::ProjectSettings] where each layer's file lives
    # @param project_config [Workspace::ProjectConfig] lists the workspaces a change reaches
    def initialize(project_settings:, project_config:)
      @project_settings = project_settings
      @project_config = project_config
    end

    # @param workspace [String] workspace name; a worktree reads its parent project's file too
    # @return [Hash] the `config show --json` document
    # @raise [Workspace::Error] code `unknown_workspace` when nothing is known about the name
    def show(workspace)
      scan = scan(workspace)
      problems = problems_for(scan)
      {
        "schema_version" => JSON_SCHEMA_VERSION,
        "ok" => true,
        "workspace" => workspace,
        "parent" => scan.parent,
        "files" => scan.files.map { |file| file_row(file) },
        "keys" => ConfigSchema.all.map { |key| key_row(key, scan, problems) },
        "unknown_keys" => problems.select { |p| p["code"] == "unknown_key" }
          .map { |p| p.slice("key", "layer", "line", "column") }
      }
    end

    # @param workspace [String] workspace name
    # @return [Hash] the `config validate --json` document; `valid` is false when any problem is an error
    # @raise [Workspace::Error] code `unknown_workspace` when nothing is known about the name
    def validate(workspace)
      problems = problems_for(scan(workspace))
      {
        "schema_version" => JSON_SCHEMA_VERSION,
        "ok" => true,
        "valid" => problems.none? { |p| p["severity"] == ERROR },
        "workspace" => workspace,
        "problems" => problems
      }
    end

    private

    Scan = Struct.new(:workspace, :parent, :files, keyword_init: true) do
      def file(layer) = files.find { |f| f.layer == layer }

      def worktree? = !parent.nil?
    end
    private_constant :Scan

    def scan(workspace)
      split = WorkspaceLineage.split_worktree_name(workspace)
      parent = split&.first
      files = []
      files << ConfigFile.read("worktree", @project_settings.project_config_path(workspace)) if parent
      files << ConfigFile.read("project", @project_settings.project_config_path(parent || workspace))
      files << ConfigFile.read("global", @project_settings.global_config_path)
      known = @project_config.available_projects.include?(workspace) || files.first(files.size - 1).any?(&:exists)
      raise Workspace::Error.new("Unknown project '#{workspace}'", code: "unknown_workspace", details: {"name" => workspace}) unless known
      Scan.new(workspace: workspace, parent: parent, files: files)
    end

    def file_row(file)
      {"layer" => file.layer, "path" => file.path, "exists" => file.exists, "etag" => file.etag, "parse_error" => file.parse_error}
    end

    # The layer whose file a reader of this key consults.
    def read_layer(key, scan)
      return "global" if key.global?
      return "project" if key.resolve == :parent
      scan.worktree? ? "worktree" : "project"
    end

    def key_row(key, scan, problems)
      layer = read_layer(key, scan)
      file = scan.file(layer)
      parts = key.name.split(".")
      stored = dig(file.data, parts)
      layers = key.global? ? ["global"] : %w[worktree project]
      own_problems = problems.select { |p| p["key"] == key.name && layers.include?(p["layer"]) }
      masked = key.sensitive && !stored.nil?
      line, column = file.locations[key.name]
      source = if !file.readable? then "unreadable"
      elsif stored.nil? then "default"
      else
        layer
      end
      {
        "key" => key.name,
        "scope" => key.scope.to_s,
        "type" => key.type.to_s,
        "value" => masked ? nil : ConfigFile.json_safe(stored),
        "masked" => masked,
        "default" => key.default,
        "effective" => effective(key, stored, source, own_problems),
        "source" => source,
        "source_file" => (source == layer) ? file.path : nil,
        "line" => (source == layer) ? line : nil,
        "column" => (source == layer) ? column : nil,
        "resolve" => key.resolve.to_s,
        "target_layer" => target_layer(key),
        "affects" => affects(key, scan),
        "applies" => key.applies.to_s,
        "settable" => key.settable?,
        "sensitive" => key.sensitive,
        "problems" => own_problems.map { |p| p.slice("severity", "code", "message", "line", "column") }
      }
    end

    # The layer `config set` writes this key to, nil for a key edited by hand.
    def target_layer(key)
      return nil unless key.settable?
      key.global? ? "global" : "project"
    end

    # What a reader uses: the stored value as the reader parses it, else the default.
    # Nil for a sensitive key, so its value can't leak through a parsed form.
    def effective(key, stored, source, own_problems)
      return nil if key.sensitive || source == "unreadable"
      return key.default if stored.nil? || own_problems.any? { |p| p["severity"] == ERROR }
      key.parse(stored)
    end

    # The workspaces that read the file a change to this key lands in.
    def affects(key, scan)
      return [] if key.resolve == :none
      all = @project_config.available_projects
      return (all | [scan.workspace]).sort if key.global?
      return [scan.workspace] unless key.resolve == :parent

      root = scan.parent || scan.workspace
      ([root] + all.select { |name| name.start_with?("#{root}#{WorkspaceLineage::WORKTREE_SEPARATOR}") }).uniq.sort
    end

    def dig(data, parts)
      parts.reduce(data) { |node, part| node.is_a?(Hash) ? node[part] : nil }
    end

    def problems_for(scan)
      rows = scan.files.each_with_index.flat_map do |file, order|
        layer_problems(file, scan).each_with_index.map { |p, i| [[order, p["line"] || 0, p["column"] || 0, i], p] }
      end
      rows.sort_by(&:first).map(&:last)
    end

    def layer_problems(file, scan)
      return [] unless file.exists
      return [problem("error", "yaml_syntax", file, file.parse_error["message"], line: file.parse_error["line"], column: file.parse_error["column"])] unless file.readable?

      scope = (file.layer == "global") ? :global : :project
      declared = ConfigSchema.all.select { |key| key.scope == scope }
      value_problems(file, declared.reject { |key| unread_here?(key, file) }) + unknown_problems(file, declared, scope) + not_read_problems(file, declared, scan)
    end

    # A key whose readers look elsewhere has no effect in this file, so its value isn't checked here.
    def unread_here?(key, file)
      file.layer == "worktree" && key.resolve == :parent
    end

    def value_problems(file, declared)
      sections = declared.select { |key| key.name.include?(".") }.map { |key| key.name.split(".").first }.uniq
      bad_sections = sections.select { |section| file.data.key?(section) && !file.data[section].is_a?(Hash) && !file.data[section].nil? }
      problems = bad_sections.map { |section| located(file, "error", "invalid_value", section, "#{section} must be a mapping") }
      declared.each do |key|
        next if bad_sections.include?(key.name.split(".").first)
        stored = dig(file.data, key.name.split("."))
        next if stored.nil?
        if ConfigFile.non_finite?(stored)
          problems << located(file, "error", "invalid_value", key.name, "#{key.name} must be a finite number, not .inf, -.inf or .nan")
        elsif key.type == :mapping
          problems << located(file, "error", "invalid_value", key.name, "#{key.name} must be a mapping") unless stored.is_a?(Hash)
        elsif key.parser
          begin
            key.parse(stored)
          rescue ArgumentError, RegexpError => e
            problems << located(file, "error", "invalid_value", key.name, "#{key.name}: #{e.message}")
          end
        end
      end
      problems
    end

    def unknown_problems(file, declared, scope)
      names = declared.map(&:name)
      tops = names.map { |name| name.split(".").first }.uniq
      other = ConfigSchema.all.reject { |key| key.scope == scope }.map(&:name)
      file.data.flat_map do |top, value|
        if !tops.include?(top)
          [unknown(file, top.to_s, other, scope)]
        elsif value.is_a?(Hash) && names.any? { |name| name.start_with?("#{top}.") }
          value.keys.map { |child| "#{top}.#{child}" }.reject { |path| names.include?(path) }.map { |path| unknown(file, path, other, scope) }
        else
          []
        end
      end
    end

    def unknown(file, path, other_scope_names, scope)
      other = (scope == :global) ? "project" : "global"
      related = other_scope_names.any? { |name| name == path || name.start_with?("#{path}.") }
      hint = related ? " It is a #{other} setting." : ""
      located(file, "warning", "unknown_key", path, "#{path} isn't a known #{scope} config key. Nothing reads it here.#{hint}")
    end

    def not_read_problems(file, declared, scan)
      declared.filter_map do |key|
        next if dig(file.data, key.name.split(".")).nil?
        if key.resolve == :none
          located(file, "info", "not_read", key.name, "#{key.name} in the #{file.layer} config isn't read by anything.")
        elsif file.layer == "worktree" && key.resolve == :parent
          located(file, "info", "not_read", key.name, "#{key.name} is read from the parent project's file (#{scan.parent}), not this worktree's.")
        end
      end
    end

    def located(file, severity, code, path, message)
      line, column = file.locations[path]
      problem(severity, code, file, message, key: path, line: line, column: column)
    end

    def problem(severity, code, file, message, key: nil, line: nil, column: nil)
      {"severity" => severity, "code" => code, "layer" => file.layer, "file" => file.path,
       "line" => line, "column" => column, "key" => key, "message" => message}
    end
  end
end
