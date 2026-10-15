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

    # Keys whose row carries an `effective_path`.
    NOTES_KEYS = %w[notes.dir notes.default_dir].freeze

    # A `{workspace}` or `{branch}` placeholder in a notes path.
    NOTES_PLACEHOLDER = /\{(?:workspace|branch)\}/

    # The derived, read-only row: whether the project's `dev.up` is set.
    DEV_CONFIGURED = "dev.configured".freeze

    # A backslash before a space or "~".
    ESCAPED_PATH = /\\[ ~]/

    # Problem severities that make a config invalid.
    ERROR = "error".freeze

    # @param project_settings [Workspace::ProjectSettings] where each layer's file lives
    # @param project_config [Workspace::ProjectConfig] lists the workspaces a change reaches and finds a checkout's root
    # @param notes_dir [Workspace::NotesDir] computes the `effective_path` of the notes keys
    def initialize(project_settings:, project_config:, notes_dir:)
      @project_settings = project_settings
      @project_config = project_config
      @notes_dir = notes_dir
    end

    # @param workspace [String] workspace name; a worktree reads its parent project's file too
    # @param key [String, nil] one key to report instead of every key
    # @return [Hash] the `config show --json` document; with `key`, `keys` holds just that key's row
    # @raise [Workspace::Error] code `unknown_workspace` when nothing is known about the name,
    #   code `unknown_config_key` when `key` names no key
    def show(workspace, key: nil)
      keys = key ? [ConfigSchema.key(key)] : ConfigSchema.all
      raise Workspace::Error.new("Unknown config key '#{key}'. Keys: #{ConfigSchema.all.map(&:name).join(", ")}", code: "unknown_config_key", details: {"key" => key}) if keys.first.nil?

      scan = scan(workspace)
      problems = problems_for(scan)
      {
        "schema_version" => JSON_SCHEMA_VERSION,
        "ok" => true,
        "workspace" => workspace,
        "parent" => scan.parent,
        "files" => scan.files.map { |file| file_row(file) },
        "keys" => keys.map { |k| key_row(k, scan, problems) },
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

    # The layers a reader of this key consults, highest precedence first, from {ConfigLayering}.
    # A key with no read order (`:own`, `:merge`, `:none`, and the derived `dev.configured`) is
    # reported from the one file its scope and the workspace point at, as before.
    def read_layers(key, scan)
      order = ConfigLayering.read_order(key, worktree: scan.worktree?)
      return order unless order.empty?
      return ["global"] if key.global?
      return ["project"] if key.name == DEV_CONFIGURED
      [scan.worktree? ? "worktree" : "project"]
    end

    # The layer of the file that holds the key's own value (the first one a reader consults).
    def read_layer(key, scan)
      read_layers(key, scan).first
    end

    # Every layer that holds a value for the key, highest precedence first, as {ConfigLayering::Hit}s.
    # A key with no read order keeps the one-file branch of {#read_layers}.
    def hits(key, scan)
      data = scan.files.to_h { |f| [f.layer, f.data] }
      order = ConfigLayering.read_order(key, worktree: scan.worktree?)
      return ConfigLayering.hits(key, data, worktree: scan.worktree?) unless order.empty?
      return [] if key.name == DEV_CONFIGURED
      layer = read_layer(key, scan)
      value = dig(scan.file(layer).data, key.name.split("."))
      value.nil? ? [] : [ConfigLayering::Hit.new(layer: layer, value: value)]
    end

    # The winning layer and stored value for a key, or [nil, nil] when no layer holds one.
    # The first of {#hits} wins, as for the readers.
    def winner(key, scan)
      hit = hits(key, scan).first
      hit ? [hit.layer, hit.value] : [nil, nil]
    end

    # The `layers` of a row: every layer that holds a value, lowest to highest precedence, with the winner `active`.
    # A sensitive key's value is nil and `masked` true, so no layer leaks it.
    def layer_rows(key, scan)
      hits(key, scan).each_with_index.map do |hit, index|
        file = scan.file(hit.layer)
        line, column = file.locations[key.name]
        {"layer" => hit.layer, "value" => key.sensitive ? nil : ConfigFile.json_safe(hit.value), "masked" => key.sensitive,
         "file" => file.path, "line" => line, "column" => column, "active" => index.zero?}
      end.reverse
    end

    # Problems that belong to a key's row: those in the layers it may live in, plus a `not_read` note in any other.
    # A key read by the special-cased modes (`:own`, `:merge`, `:none`) keeps the layers of its file scope.
    def row_problems(key, problems)
      layers = key.overridable_in.map(&:to_s)
      layers |= key.global? ? ["global"] : %w[worktree project] if %i[own merge none].include?(key.resolve)
      problems.select { |p| p["key"] == key.name && (layers.include?(p["layer"]) || p["code"] == "not_read") }
    end

    def key_row(key, scan, problems)
      layers = read_layers(key, scan)
      files = layers.map { |l| scan.file(l) }
      win_layer, stored = winner(key, scan)
      file = scan.file(win_layer || layers.first)
      own_problems = row_problems(key, problems)
      masked = key.sensitive && !stored.nil?
      line, column = file.locations[key.name]
      source = if files.any? { |f| !f.readable? } then "unreadable"
      elsif win_layer.nil? then "default"
      else
        win_layer
      end
      row = {
        "key" => key.name,
        "scope" => key.scope.to_s,
        "type" => key.type.to_s,
        "value" => masked ? nil : ConfigFile.json_safe(stored),
        "masked" => masked,
        "default" => key.default,
        "effective" => effective(key, stored, source, own_problems),
        "source" => source,
        "source_file" => (source == win_layer) ? file.path : nil,
        "line" => (source == win_layer) ? line : nil,
        "column" => (source == win_layer) ? column : nil,
        "resolve" => key.resolve.to_s,
        "target_layer" => target_layer(key, scan),
        "affects" => affects(key, scan),
        "applies" => key.applies.to_s,
        "settable" => key.settable?,
        "sensitive" => key.sensitive,
        "overridable_in" => key.overridable_in.map(&:to_s),
        "layers" => layer_rows(key, scan),
        "doc" => key.doc,
        "problems" => own_problems.map { |p| p.slice("severity", "code", "message", "line", "column") }
      }
      row["choices"] = key.choices if key.choices
      row["min"] = key.min unless key.min.nil?
      row["max"] = key.max unless key.max.nil?
      row["unit"] = key.unit if key.unit
      row["effective_path"] = effective_path(key, scan, problems) if NOTES_KEYS.include?(key.name)
      row["effective"] = dev_configured(scan) if key.name == DEV_CONFIGURED
      row
    end

    # Whether the project's `dev.up` holds a command, as {DevConfig#configured?} reads it: from the
    # winning layer of `dev.up`. Nil when a file it reads can't be read.
    def dev_configured(scan)
      dev_up = ConfigSchema.key("dev.up")
      return nil unless read_layers(dev_up, scan).all? { |l| scan.file(l).readable? }
      _layer, stored = winner(dev_up, scan)
      !stored.to_s.strip.empty?
    end

    # Where the workspace's notes go (`notes.dir`) or where the project's rule puts them
    # (`notes.default_dir`), as an absolute path. Nil when a config file can't be read or
    # the workspace has no known checkout (or branch, for a rule that uses it).
    def effective_path(key, scan, problems)
      dir_key = ConfigSchema.key("notes.dir")
      template_key = ConfigSchema.key("notes.default_dir")
      files = (read_layers(dir_key, scan) | read_layers(template_key, scan)).map { |l| scan.file(l) }
      return nil unless files.all?(&:readable?)
      template = valid_value(template_key, scan, problems)
      root = @project_config.project_root_for(scan.workspace)
      if key.name == "notes.default_dir"
        @notes_dir.default_path(template, root: root, workspace: scan.workspace)
      else
        stored = valid_value(key, scan, problems)
        @notes_dir.resolve(stored: stored, template: template, worktree: scan.worktree?, root: root, workspace: scan.workspace).path
      end
    end

    # The winning stored value of a key as its reader parses it, nil when unset or when it has an error (as {#effective} treats it).
    def valid_value(key, scan, problems)
      layer, stored = winner(key, scan)
      return nil if stored.nil?
      return nil if problems.any? { |p| p["key"] == key.name && p["layer"] == layer && p["severity"] == ERROR }
      key.parse(stored)
    end

    # The layer `config set` writes this key to, nil for a key edited by hand.
    def target_layer(key, scan)
      return nil unless key.settable?
      ConfigLayering.default_layer(key, worktree: scan.worktree?)
    end

    # What a reader uses: the stored value as the reader parses it, else the default.
    # Nil for a sensitive key, so its value can't leak through a parsed form.
    def effective(key, stored, source, own_problems)
      return nil if key.sensitive || source == "unreadable"
      return key.default if stored.nil? || own_problems.any? { |p| p["severity"] == ERROR }
      key.parse(stored)
    end

    # The workspaces that read the file a change to this key lands in: every workspace for the global file, the
    # project and its worktrees for the project file, the workspace alone for its own file.
    def affects(key, scan)
      return [] if key.resolve == :none
      return [scan.workspace] if %i[own merge own_then_parent].include?(key.resolve) && !key.global?
      all = @project_config.available_projects
      layer = ConfigLayering.default_layer(key, worktree: scan.worktree?)
      return (all | [scan.workspace]).sort if layer == "global"
      return [scan.workspace] if layer == "worktree"

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
      declared = declared_keys(file.layer, scope)
      read_here = declared.reject { |key| unread_here?(key, file) }
      value_problems(file, read_here) + escaped_path_problems(file, read_here) + shared_notes_problems(file, scan) + unknown_problems(file, declared, scope) + not_read_problems(file, declared, scan)
    end

    # The keys a file of this layer holds: those of its scope, plus any layered key that may be set in the layer.
    def declared_keys(layer, scope)
      ConfigSchema.all.select { |key| key.scope == scope || (key.resolve == :layered && key.overridable_in?(layer)) }
    end

    # A key whose readers look elsewhere has no effect in this file, so its value isn't checked here: a key that
    # may not be set in this file's layer.
    def unread_here?(key, file)
      %i[parent layered own_then_parent global].include?(key.resolve) && !key.overridable_in?(file.layer)
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

    # A backslash before a space or "~" is shell quoting. Config values are taken literally, so the
    # directory would be named with the backslash in it.
    def escaped_path_problems(file, declared)
      declared.select { |key| key.type == :path }.filter_map do |key|
        stored = dig(file.data, key.name.split("."))
        next unless stored.is_a?(String) && stored.match?(ESCAPED_PATH)
        located(file, "warning", "escaped_path", key.name,
          "#{key.name} has a backslash before a space or \"~\". Config values are used as written, so the directory name would contain the backslash. Remove the backslash.")
      end
    end

    # One directory for every worktree of a project means they share notes.
    def shared_notes_problems(file, scan)
      return [] unless file.layer == "project"
      stored = dig(file.data, %w[notes default_dir])
      return [] unless stored.is_a?(String) && stored.start_with?("/", "~/") && !NOTES_PLACEHOLDER.match?(stored)
      return [] unless worktrees?(scan)
      [located(file, "warning", "shared_notes_dir", "notes.default_dir",
        "notes.default_dir is an absolute path with no {workspace} or {branch}, so the worktrees of this project would all use the same notes directory. Add {workspace} or {branch} to the path.")]
    end

    def worktrees?(scan)
      root = scan.parent || scan.workspace
      @project_config.available_projects.any? { |name| name.start_with?("#{root}#{WorkspaceLineage::WORKTREE_SEPARATOR}") }
    end

    def unknown_problems(file, declared, scope)
      names = declared.map(&:name)
      tops = names.map { |name| name.split(".").first }.uniq
      other = ConfigSchema.all.map(&:name) - names
      file.data.flat_map do |top, value|
        if !tops.include?(top)
          [unknown(file, top.to_s, other, scope)]
        elsif value.is_a?(Hash) && names.any? { |name| name.start_with?("#{top}.") }
          value.keys.map { |child| "#{top}.#{child}" }.reject { |path| names.any? { |name| name == path || name.start_with?("#{path}.") } }.map { |path| unknown(file, path, other, scope) }
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
        elsif unread_here?(key, file)
          located(file, "info", "not_read", key.name, not_read_message(key, file, scan))
        end
      end
    end

    # Says where the key is read from instead. The text for a project-only key set in a worktree file is the original one.
    def not_read_message(key, file, scan)
      allowed = key.overridable_in.map(&:to_s)
      if file.layer == "worktree" && allowed == ["project"]
        "#{key.name} is read from the parent project's file (#{scan.parent}), not this worktree's."
      else
        "#{key.name} in the #{file.layer} config isn't read. It is read from the #{allowed.join(", ")} config."
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
