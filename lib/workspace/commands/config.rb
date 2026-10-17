require "yaml"
require "fileutils"
require "json"

module Workspace
  module Commands
    # Sets, reads, and unsets a config key by dotted key
    # (`workspace config set/get/unset`), so callers don't need to hand-edit
    # YAML. Restricted to an allowlist, so a typo doesn't silently create
    # unused config. The allowlist, value checks and restart notes come from
    # {Workspace::ConfigSchema}.
    #
    # Each command writes one layer's file. The user-facing scopes are `global`,
    # `project` and `workspace`; `workspace` is the `worktree` layer (the
    # `layer` value in every JSON document), and in a main checkout, which has
    # no file of its own besides the project's, it is the `project` layer.
    class Config
      # Version of the `keys --json` document.
      KEYS_JSON_SCHEMA_VERSION = 1

      # The user-facing scope names, lowest layer first.
      SCOPES = %w[global project workspace].freeze

      # `worktree` is accepted as another spelling of `workspace`.
      SCOPE_ALIASES = {"worktree" => "workspace"}.freeze

      # The scope each layer is called by in `scope_not_allowed` details and results.
      LAYER_SCOPES = {"global" => "global", "project" => "project", "worktree" => "workspace"}.freeze

      # What a {#set} or {#unset} did.
      #
      # @!attribute key
      #   @return [String] the dotted key
      # @!attribute workspace
      #   @return [String, nil] the name whose file was written (the parent project for a project-layer write); nil for the global file
      # @!attribute layer
      #   @return [String] "global", "project" or "worktree"
      # @!attribute scope
      #   @return [String] the layer as the user names it: "global", "project" or "workspace"
      # @!attribute path
      #   @return [String] the file that was written
      # @!attribute comments_preserved
      #   @return [Boolean] false when the old text had a comment the rewrite dropped
      # @!attribute backup
      #   @return [String, nil] where the old file was copied, nil when there was none
      # @!attribute affects
      #   @return [Array<String>] the workspaces whose daemons read the file
      # @!attribute changed
      #   @return [Boolean] false when nothing was written (an `unset` of a key that wasn't set)
      Result = Struct.new(:key, :workspace, :layer, :scope, :path, :comments_preserved, :backup, :affects, :changed, keyword_init: true)

      Target = Struct.new(:layer, :name, :path, :workspace)
      private_constant :Target

      # @param project_settings [Workspace::ProjectSettings] reads/writes project YAML
      # @param lineage [Workspace::WorkspaceLineage] resolves a project from cwd (worktree -> parent)
      # @param file_backup [Workspace::FileBackup] backs up the config file before it's rewritten
      # @param event_log [Workspace::EventLog, nil] records `config_changed` after each
      #   write (key names only, never values); nil records nothing
      # @param project_config [Workspace::ProjectConfig, nil] lists the known workspaces: it lets
      #   `--scope workspace` refuse an unknown one and the restart hint name every affected daemon
      # @param output [IO] output stream for user-facing messages
      # @param error_output [IO] output stream for user-facing errors
      def initialize(project_settings:, lineage:, file_backup:, event_log: nil, project_config: nil, output: $stdout, error_output: $stderr)
        @project_settings = project_settings
        @lineage = lineage
        @file_backup = file_backup
        @event_log = event_log
        @project_config = project_config
        @output = output
        @error_output = error_output
      end

      # @param key [String] a dotted key from {Workspace::ConfigSchema}
      # @param value [String] the value to store
      # @param project [String, nil] workspace to configure; defaults to the one inferred from cwd
      # @param scope [String, nil] "global", "project" or "workspace" ("worktree" is the same); nil
      #   writes the highest layer the key allows at or below the workspace ({ConfigLayering.default_layer})
      # @param cwd [String] directory to infer the workspace from, when project is nil
      # @return [Result]
      # @raise [Workspace::Error] code `unknown_config_key`, `scope_not_allowed` or `unknown_workspace`
      # @raise [Workspace::UsageError] for an invalid value or scope
      def set(key, value, project: nil, scope: nil, cwd: Dir.pwd)
        validate_key!(key)
        validate_value!(key, value)
        target = target_for(key, project, scope, cwd, "set")
        write = apply(target) { |data| store(data, key, value) }
        record_change(target.layer, "set", key, target.name)
        @output.puts target.name ? "Set #{key} = #{value} for '#{target.name}'." : "Set #{key} = #{value}."
        affects = affected_workspaces(target)
        print_restart_hint(key, affects)
        result_for(key, target, write, affects)
      end

      # @param key [String] a dotted key from {Workspace::ConfigSchema}
      # @param project [String, nil] workspace to read; defaults to the one inferred from cwd
      # @param scope [String, nil] as for {#set}; only that layer's file is read
      # @param cwd [String] directory to infer the workspace from, when project is nil
      # @return [Boolean] true if the key had a value, false if unset
      # @raise [Workspace::Error] as for {#set}
      def get(key, project: nil, scope: nil, cwd: Dir.pwd)
        validate_key!(key)
        target = target_for(key, project, scope, cwd, "read")
        data = (target.layer == "global") ? @project_settings.load_global : @project_settings.load(target.name)
        value = data.dig(*key.split("."))
        if value.nil?
          @error_output.puts target.name ? "#{key} is not set for '#{target.name}'." : "#{key} is not set."
          false
        else
          @output.puts value
          true
        end
      end

      # @param key [String] a dotted key from {Workspace::ConfigSchema}
      # @param project [String, nil] workspace to configure; defaults to the one inferred from cwd
      # @param scope [String, nil] as for {#set}
      # @param cwd [String] directory to infer the workspace from, when project is nil
      # @return [Result]
      # @raise [Workspace::Error] as for {#set}
      def unset(key, project: nil, scope: nil, cwd: Dir.pwd)
        validate_key!(key)
        target = target_for(key, project, scope, cwd, "unset")
        unless set_in?(target, key)
          @output.puts target.name ? "#{key} was not set for '#{target.name}'; nothing changed." : "#{key} was not set; nothing changed."
          return Result.new(key: key, workspace: target.name, layer: target.layer, scope: LAYER_SCOPES.fetch(target.layer), path: target.path,
            comments_preserved: true, backup: nil, affects: [], changed: false)
        end
        write = apply(target) { |data| remove(data, key) }
        record_change(target.layer, "unset", key, target.name)
        @output.puts target.name ? "Unset #{key} for '#{target.name}'." : "Unset #{key}."
        affects = affected_workspaces(target)
        print_restart_hint(key, affects)
        result_for(key, target, write, affects)
      end

      # What an {#edit} found: the file to open and whether it had to be made.
      #
      # @!attribute workspace
      #   @return [String, nil] the name whose file it is; nil for the global file
      # @!attribute layer
      #   @return [String] "global", "project" or "worktree"
      # @!attribute scope
      #   @return [String] "global", "project" or "workspace"
      # @!attribute path
      #   @return [String] the file
      # @!attribute created
      #   @return [Boolean] true when the file was absent and a stub was written
      EditResult = Struct.new(:workspace, :layer, :scope, :path, :created, keyword_init: true)

      # Finds the file of one scope for hand-editing, writing a stub (a comment header) through
      # the usual temp-file-and-rename write when it is absent. An existing file is not touched.
      # The scope is resolved as for {#set}, with no key to check; the default is the
      # workspace's own file.
      #
      # @param project [String, nil] workspace to edit; defaults to the one inferred from cwd
      # @param scope [String, nil] "global", "project" or "workspace" ("worktree" is the same); nil is "workspace"
      # @param cwd [String] directory to infer the workspace from, when project is nil
      # @return [EditResult]
      # @raise [Workspace::Error] code `unknown_workspace`
      # @raise [Workspace::UsageError] for an invalid scope or a worktree with no name
      def edit(project: nil, scope: nil, cwd: Dir.pwd)
        target = edit_target(project, scope, cwd)
        created = false
        with_config_lock(target.path) do
          unless File.exist?(target.path)
            write_text(target.path, "# workspace config (#{target.layer}). See docs/README.config.md\n")
            created = true
          end
        end
        EditResult.new(workspace: target.name, layer: target.layer, scope: LAYER_SCOPES.fetch(target.layer), path: target.path, created: created)
      end

      # Describes the keys in {Workspace::ConfigSchema}: name, type, default, doc, the layers that may hold
      # each, whether `set` accepts it and when a change applies. Reads no config file and prints no
      # stored value.
      #
      # With no query, every key is listed one to a line. A query that equals a key name prints that
      # key in full; any other query keeps the keys whose name or doc text contains it (any case).
      #
      # @param query [String, nil] a key name, or text to look for in key names and docs
      # @param settable [Boolean] true to keep only the keys `config set` accepts
      # @param json [Boolean] true to print one `{"keys": [...]}` document instead of text
      # @return [Array<ConfigSchema::Key>] the keys described
      # @raise [Workspace::Error] code `unknown_config_key` when nothing matches
      def keys(query: nil, settable: false, json: false)
        found = ConfigSchema.all.select { |key| !settable || key.settable? }
        exact = found.select { |key| key.name == query }
        found = if query.to_s.empty?
          found
        else
          (exact.any? ? exact : found.select { |key| key_matches?(key, query) })
        end
        if found.empty?
          kind = settable ? "settable config key" : "config key"
          raise Workspace::Error.new("No #{kind} matches '#{query}'. Run `workspace config keys#{" --settable" if settable}` with no query to list them.",
            code: "unknown_config_key", details: {"key" => query}.merge(settable ? {"settable" => true} : {}))
        end
        if json
          @output.puts JSON.generate({"schema_version" => KEYS_JSON_SCHEMA_VERSION, "ok" => true, "keys" => found.map { |key| key_document(key) }})
        elsif exact.any?
          @output.puts found.map { |key| key_detail(key) }.join("\n")
        else
          print_key_list(found)
        end
        found
      end

      private

      def edit_target(project, scope, cwd)
        scope = normalize_scope(scope) || "workspace"
        return Target.new("global", nil, @project_settings.global_config_path, nil) if scope == "global"
        workspace, worktree = workspace_for(project, cwd, nil, scope)
        layer = (scope == "workspace" && worktree) ? "worktree" : "project"
        check_workspace_known!(workspace) if scope == "workspace"
        name = (layer == "project") ? (WorkspaceLineage.split_worktree_name(workspace)&.first || workspace) : workspace
        Target.new(layer, name, @project_settings.project_config_path(name), workspace)
      end

      # More affected workspaces than this, and the restart hint gives a count and one command.
      MAX_LISTED_RESTARTS = 3

      def print_restart_hint(key, affects)
        return unless ConfigSchema.key(key).restart_required?
        how = if affects.size > MAX_LISTED_RESTARTS
          "#{affects.size} workspaces' session monitors read it; run `workspace daemon restart --all`, or relaunch"
        else
          "#{affects.map { |name| "workspace agentd #{name} --force" }.join(", ")}, or relaunch"
        end
        @output.puts "Takes effect the next time the session monitor starts (#{how})."
      end

      # Whether the target's file holds the key.
      def set_in?(target, key)
        data = (target.layer == "global") ? @project_settings.load_global : load_for_edit(target.name)
        !data.dig(*key.split(".")).nil?
      end

      # The file a command acts on. With no scope, the layer {ConfigLayering.default_layer}
      # gives, which is also the `target_layer` `config show` reports; with one, the layer it
      # names, refused when the key doesn't allow it. The workspace is the named one, else the
      # one cwd is in.
      def target_for(key, project, scope, cwd, action)
        schema_key = ConfigSchema.key(key)
        scope = normalize_scope(scope)
        workspace, worktree = workspace_for(project, cwd, schema_key, scope)
        layer = case scope
        when nil then ConfigLayering.default_layer(schema_key, worktree: worktree)
        when "workspace" then worktree ? "worktree" : "project"
        else scope
        end
        refuse_scope!(schema_key, layer, scope, action) if scope
        check_workspace_known!(workspace) if scope == "workspace"
        return Target.new(layer, nil, @project_settings.global_config_path, workspace) if layer == "global"
        name = (layer == "project") ? (WorkspaceLineage.split_worktree_name(workspace)&.first || workspace) : workspace
        Target.new(layer, name, @project_settings.project_config_path(name), workspace)
      end

      def normalize_scope(scope)
        return nil if scope.nil?
        scope = SCOPE_ALIASES.fetch(scope, scope)
        return scope if SCOPES.include?(scope)
        raise Workspace::UsageError, "Unknown scope '#{scope}'. Use global, project or workspace."
      end

      # @return [Array(String, Boolean)] the workspace name and whether it is a worktree
      def workspace_for(project, cwd, schema_key, scope)
        if project
          return [project, !WorkspaceLineage.split_worktree_name(project).nil?]
        end
        lineage = @lineage.resolve(cwd: cwd)
        if lineage.is_worktree && !lineage.worktree && (scope == "workspace" || (scope.nil? && schema_key.resolve == :own_then_parent))
          raise Workspace::UsageError, "This worktree has no workspace name (no .workspace-project marker), so #{schema_key ? schema_key.name : "config edit"} can't tell which file is its own. Pass --name <project>.worktree-<name>."
        end
        [lineage.worktree || lineage.name, !lineage.worktree.nil?]
      end

      def refuse_scope!(schema_key, layer, typed, action)
        return if schema_key.overridable_in?(layer)
        allowed = schema_key.overridable_in.map { |l| LAYER_SCOPES.fetch(l.to_s) }
        here = (typed == "workspace" && layer == "project") ? " (the project file here)" : ""
        use = allowed.map { |name| "--scope #{name}" }.join(" or ")
        verb = (action == "read") ? "read from" : "#{action} in"
        raise Workspace::Error.new("#{schema_key.name} is #{layer_reason(schema_key)}, so it can't be #{verb} the #{typed} scope#{here}. Use #{use}.",
          code: "scope_not_allowed", details: {"key" => schema_key.name, "scope" => typed, "allowed" => allowed})
      end

      # Why a key lives only in the layers it does, in a few words.
      def layer_reason(schema_key)
        layers = schema_key.overridable_in.map(&:to_s)
        if layers == ["global"]
          "a machine-wide setting"
        elsif layers == ["project"]
          "a project-wide setting shared by its worktrees"
        elsif !layers.include?("global")
          "a project or workspace setting, not a machine-wide one"
        else
          "a machine or project setting, not one workspace's own"
        end
      end

      def check_workspace_known!(workspace)
        return if @project_config.nil?
        return if @project_config.available_projects.any? { |known| WorkspaceName.same?(known, workspace) }
        return if File.exist?(@project_settings.project_config_path(workspace))
        raise Workspace::Error.new("Unknown workspace '#{workspace}'", code: "unknown_workspace", details: {"name" => workspace})
      end

      # The workspaces whose daemons read the file written: all for the global file, the
      # project and its worktrees for a project file, the one workspace for its own.
      def affected_workspaces(target)
        return [target.name] if target.layer == "worktree"
        known = @project_config ? @project_config.available_projects : []
        if target.layer == "global"
          return (known | [target.workspace]).sort
        end
        prefix = "#{target.name}#{WorkspaceLineage::WORKTREE_SEPARATOR}"
        siblings = known.select { |name| name.start_with?(prefix) }
        siblings |= [target.workspace] if target.workspace.start_with?(prefix)
        ([target.name] + siblings).uniq.sort
      end

      def result_for(key, target, write, affects)
        Result.new(key: key, workspace: target.name, layer: target.layer, scope: LAYER_SCOPES.fetch(target.layer), path: target.path,
          comments_preserved: write.comments_preserved, backup: write.backup, affects: affects, changed: true)
      end

      # Loads the target's file under its lock, backs it up, yields the data to change
      # and writes it back (the global file through {ProjectSettings#with_global_lock}).
      # A file that doesn't parse is refused untouched.
      #
      # @return [Struct] the outcome of the write (`comments_preserved`, `backup`)
      def apply(target)
        write = nil
        if target.layer == "global"
          @project_settings.with_global_lock do |data|
            old_text = read_text(target.path)
            backup = @file_backup.backup(target.path)
            yield data
            write = note_write(target.path, old_text, backup)
            data
          end
        else
          with_config_lock(target.path) do
            old_text = read_text(target.path)
            data = load_for_edit(target.name)
            backup = @file_backup.backup(target.path)
            yield data
            write(target.path, data)
            write = note_write(target.path, old_text, backup)
          end
        end
        write
      end

      def store(data, key, value)
        segments = key.split(".")
        cursor = data
        segments[0..-2].each do |segment|
          cursor[segment] = {} unless cursor[segment].is_a?(Hash)
          cursor = cursor[segment]
        end
        cursor[segments.last] = value
      end

      def remove(data, key)
        segments = key.split(".")
        cursor = segments[0..-2].reduce(data) { |node, segment| node.is_a?(Hash) ? node[segment] : nil }
        cursor.delete(segments.last) if cursor.is_a?(Hash)
      end

      # The key's name goes in the log, never its value: values can be commands
      # or tokens. A global change has no project: it is logged with project ""
      # (readers drop an event without a project string) and data.scope "global".
      # EventLog#record never raises.
      def record_change(layer, via, key, project)
        data = {"layer" => layer, "via" => via, "keys" => [key]}
        project ? data["workspace"] = project : data["scope"] = "global"
        @event_log&.record(type: "config_changed", project: project || "", data: data)
      end

      def load_for_edit(name)
        @project_settings.load(name)
      rescue Workspace::ConfigParseError => e
        raise Workspace::ConfigParseError.new(e.path, "#{e.reason}. Fix or remove the file, then retry")
      end

      def read_text(path)
        File.exist?(path) ? File.read(path) : ""
      end

      # The outcome of a write: whether comments survived and where the old file went.
      Write = Struct.new(:comments_preserved, :backup)
      private_constant :Write

      # Returns the write's outcome and, when a comment was dropped, says so on
      # stderr (never stdout, which `--json` keeps for its one document).
      def note_write(path, old_text, backup)
        preserved = !comments?(old_text)
        write = Write.new(preserved, backup)
        @error_output.puts "Note: comments in #{path} were not kept; backup at #{backup}" unless preserved
        write
      end

      # Whether +text+ has a YAML comment: a `#` at the start of a line or after
      # whitespace, outside a quoted scalar. A quote only opens at the start of a
      # value (after whitespace, `[`, `{` or `,`), so an apostrophe inside a plain
      # word is not one. Lines inside a block scalar (`|`, `>`) are not told
      # apart, so a `#` line in one counts: a false positive only adds a note.
      #
      # Other writers drop comments too and are out of scope here:
      # HookInstaller#preserve_existing_statusline_command, Commands::Layout and
      # the ProjectSettings#save callers (notes_setup, start's hook seeding,
      # ensure_exists).
      def comments?(text)
        text.each_line.any? do |line|
          quote = nil
          prev = nil
          escaped = false
          line.each_char.any? do |char|
            hit = false
            if escaped
              escaped = false
            elsif quote
              if quote == '"' && char == "\\"
                escaped = true
              elsif char == quote
                quote = nil
              end
            elsif ['"', "'"].include?(char) && (prev.nil? || prev =~ /[\s\[{,]/)
              quote = char
            elsif char == "#" && (prev.nil? || prev =~ /\s/)
              hit = true
            end
            prev = char
            hit
          end
        end
      end

      # Guards the load -> mutate -> write cycle with an exclusive flock on a
      # sibling lock file, so concurrent `set`/`unset` calls for the same
      # project serialize instead of clobbering each other. The lock is held
      # on a sentinel file (never on the config file itself), matching
      # {Workspace::LockStore}'s rationale: the config file is rewritten via
      # tmp-file-then-rename, which would leave a held flock pointing at a
      # deleted inode if it were locked directly.
      def with_config_lock(path)
        FileUtils.mkdir_p(File.dirname(path))
        lockfile_path = "#{path}.lock"
        File.open(lockfile_path, File::RDWR | File::CREAT, 0o600) do |f|
          f.flock(File::LOCK_EX)
          yield
        end
      end

      # Longest doc text the one-line key list shows before cutting it.
      KEY_LIST_DOC_WIDTH = 70

      def key_matches?(key, query)
        needle = query.downcase
        key.name.downcase.include?(needle) || key.doc.downcase.include?(needle)
      end

      def print_key_list(found)
        rows = found.map { |key| [key.name, key.scope.to_s, key.settable? ? "set" : "-", key.type.to_s, key_default(key), key_summary(key.doc)] }
        widths = (0..4).map { |column| rows.map { |row| row[column].length }.max }
        rows.each do |row|
          @output.puts [*row[0..4].each_with_index.map { |cell, i| cell.ljust(widths[i]) }, row[5]].join("  ").rstrip
        end
        @output.puts
        @output.puts "Columns: name, scope (the file it lives in), set (`config set` accepts it), type, default, description."
        @output.puts "Run `workspace config keys <name>` for details and examples."
      end

      def key_detail(key)
        lines = [key.name, "  #{key_summary(key.doc, width: nil)}", "",
          "  Type:     #{key_type(key)}",
          "  Default:  #{key_default(key)}",
          "  Scope:    #{key.scope}",
          "  Layers:   #{key.overridable_in.empty? ? "(none; nothing reads it from a layer)" : key.overridable_in.join(", ")}",
          "  Settable: #{key.settable? ? "yes" : "no (edit the file with `workspace config edit`)"}",
          "  Applies:  #{key.applies.to_s.tr("_", " ")}"]
        if key.settable? && key.example_values.any?
          lines << "  Examples:"
          key.example_values.each { |value| lines << "    workspace config set #{key.name} #{shell_word(value)}" }
        end
        lines.join("\n") + "\n"
      end

      def key_type(key)
        parts = [key.type.to_s]
        parts << "unit #{key.unit}" if key.unit
        parts << "min #{key.min}" if key.min
        parts << "max #{key.max}" if key.max
        parts << "choices #{key.choices.join(", ")}" if key.choices
        parts.first + ((parts.size > 1) ? " (#{parts[1..].join("; ")})" : "")
      end

      def key_default(key)
        value = key.default
        if value.nil? then "(unset)"
        elsif key.type == :duration then Duration.humanize(value)
        elsif value.is_a?(Array) then value.join(", ")
        elsif value.is_a?(String) && value.include?("\n") then "(built-in text)"
        else value.to_s
        end
      end

      # The doc as one line without Markdown links. Cut to +width+ (nil keeps it whole): at the end of
      # the first sentence when that fits, else at a word boundary with "...".
      def key_summary(doc, width: KEY_LIST_DOC_WIDTH)
        text = doc.gsub(/\[([^\]]+)\]\([^)]*\)/, "\\1").tr("\n", " ")
        return text if width.nil? || text.length <= width
        sentence = text[/\A.*?(?<!e\.g|i\.e|etc)\.(?=\s)/]
        return sentence if sentence && sentence.length <= width
        cut = text[0, width - 3].sub(/\s+\S*\z/, "")
        cut = cut[0...cut.index(/\s*\b(e\.g|i\.e)\./)] if cut.match?(/\b(e\.g|i\.e)\./)
        cut = cut[0...cut.rindex("`")] if cut.count("`").odd?
        cut = cut[0...cut.rindex("(")] if cut.count("(") > cut.count(")")
        cut.sub(/[\s,;:-]+\z/, "") + "..."
      end

      # A value as one shell word: bare when it is safe, else in single quotes.
      def shell_word(value)
        return value if value.match?(%r{\A[\w./:%@+=,~-]+\z})
        "'#{value.gsub("'", "'\\''")}'"
      end

      def key_document(key)
        {
          "name" => key.name, "scope" => key.scope.to_s, "doc" => key.doc, "type" => key.type.to_s, "default" => key.default,
          "choices" => key.choices, "min" => key.min, "max" => key.max, "unit" => key.unit,
          "layers" => key.overridable_in.map(&:to_s), "settable" => key.settable?, "applies" => key.applies.to_s,
          "restart" => !!key.restart_required?, "sensitive" => !!key.sensitive,
          "examples" => key.settable? ? key.example_values : []
        }
      end

      def validate_key!(key)
        return if ConfigSchema.settable?(key)
        raise Workspace::Error.new("Unknown config key '#{key}'. Allowed keys: #{ConfigSchema.settable_names.join(", ")}. Run `workspace config keys` to see what each does.", code: "unknown_config_key", details: {"key" => key})
      end

      def validate_value!(key, value)
        ConfigSchema.parse(key, value)
      rescue ArgumentError, RegexpError => e
        raise Workspace::UsageError.new("Invalid #{key}: #{e.message}", details: {"key" => key})
      end

      def write(path, data)
        write_text(path, YAML.dump(data))
      end

      def write_text(path, text)
        FileUtils.mkdir_p(File.dirname(path))
        tmp_path = "#{path}.tmp#{Process.pid}"
        File.write(tmp_path, text)
        File.rename(tmp_path, path)
      end
    end
  end
end
