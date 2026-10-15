require "yaml"
require "fileutils"

module Workspace
  module Commands
    # Sets, reads, and unsets a project's config by dotted key
    # (`workspace config set/get/unset`), so callers don't need to hand-edit
    # YAML. Restricted to an allowlist, so a typo doesn't silently create
    # unused config. The allowlist, value checks and restart notes come from
    # {Workspace::ConfigSchema}.
    class Config
      # What the last {#set} or {#unset} did to the file, for the CLI's JSON row.
      #
      # @!attribute comments_preserved
      #   @return [Boolean] false when the old text had a comment the rewrite dropped
      # @!attribute backup
      #   @return [String, nil] where the old file was copied, nil when there was none
      Write = Struct.new(:comments_preserved, :backup)

      # TODO(phase 5): replace last_write with the return value
      # @return [Write, nil] the outcome of the last write; nil before any
      attr_reader :last_write

      # @param project_settings [Workspace::ProjectSettings] reads/writes project YAML
      # @param lineage [Workspace::WorkspaceLineage] resolves a project from cwd (worktree -> parent)
      # @param file_backup [Workspace::FileBackup] backs up the config file before it's rewritten
      # @param event_log [Workspace::EventLog, nil] records `config_changed` after each
      #   write (key names only, never values); nil records nothing
      # @param output [IO] output stream for user-facing messages
      # @param error_output [IO] output stream for user-facing errors
      def initialize(project_settings:, lineage:, file_backup:, event_log: nil, output: $stdout, error_output: $stderr)
        @project_settings = project_settings
        @lineage = lineage
        @file_backup = file_backup
        @event_log = event_log
        @output = output
        @error_output = error_output
      end

      # @param key [String] a dotted key from {Workspace::ConfigSchema}
      # @param value [String] the value to store
      # @param project [String, nil] project to configure; defaults to the one inferred from cwd
      # @param cwd [String] directory to infer the project from, when project is nil
      # @return [String, nil] the project the key was set for; nil for a global key
      # @raise [Workspace::UsageError] for an unknown key or an invalid value
      def set(key, value, project: nil, cwd: Dir.pwd)
        validate_key!(key)
        validate_value!(key, value)

        if ConfigSchema.key(key).global?
          set_global(key, value)
          record_change("global", "set", key, nil)
          return
        end

        lineage = @lineage.resolve(cwd: cwd)
        name = config_name(key, project, lineage)
        path = @project_settings.project_config_path(name)
        with_config_lock(path) do
          old_text = read_text(path)
          data = load_for_edit(name)
          backup = @file_backup.backup(path)
          segments = key.split(".")
          cursor = data
          segments[0..-2].each do |segment|
            cursor[segment] = {} unless cursor[segment].is_a?(Hash)
            cursor = cursor[segment]
          end
          cursor[segments.last] = value
          write(path, data)
          note_write(path, old_text, backup)
        end
        record_change("project", "set", key, name)
        @output.puts "Set #{key} = #{value} for '#{name}'."
        if ConfigSchema.key(key).restart_required?
          daemon_name = (project.nil? && lineage.worktree) ? lineage.worktree : name
          @output.puts "Takes effect the next time the session monitor starts (workspace agentd #{daemon_name} --force, or relaunch)."
        end
        name
      end

      # @param key [String] a dotted key from {Workspace::ConfigSchema}
      # @param project [String, nil] project to read; defaults to the one inferred from cwd
      # @param cwd [String] directory to infer the project from, when project is nil
      # @return [Boolean] true if the key had a value, false if unset
      # @raise [Workspace::UsageError] for an unknown key
      def get(key, project: nil, cwd: Dir.pwd)
        validate_key!(key)

        if ConfigSchema.key(key).global?
          value = @project_settings.load_global.dig(*key.split("."))
          if value.nil?
            @error_output.puts "#{key} is not set."
            return false
          end
          @output.puts value
          return true
        end

        name = config_name(key, project, @lineage.resolve(cwd: cwd))
        data = @project_settings.load(name)
        value = data.dig(*key.split("."))
        if value.nil?
          @error_output.puts "#{key} is not set for '#{name}'."
          false
        else
          @output.puts value
          true
        end
      end

      # @param key [String] a dotted key from {Workspace::ConfigSchema}
      # @param project [String, nil] project to configure; defaults to the one inferred from cwd
      # @param cwd [String] directory to infer the project from, when project is nil
      # @return [void]
      # @raise [Workspace::UsageError] for an unknown key
      def unset(key, project: nil, cwd: Dir.pwd)
        validate_key!(key)

        if ConfigSchema.key(key).global?
          with_global_backup do |data|
            segments = key.split(".")
            cursor = segments[0..-2].reduce(data) { |node, segment| node.is_a?(Hash) ? node[segment] : nil }
            cursor.delete(segments.last) if cursor.is_a?(Hash)
            data
          end
          record_change("global", "unset", key, nil)
          @output.puts "Unset #{key}."
          return
        end

        name = config_name(key, project, @lineage.resolve(cwd: cwd))
        path = @project_settings.project_config_path(name)
        with_config_lock(path) do
          old_text = read_text(path)
          data = load_for_edit(name)
          backup = @file_backup.backup(path)
          segments = key.split(".")
          cursor = segments[0..-2].reduce(data) { |node, segment| node.is_a?(Hash) ? node[segment] : nil }
          cursor.delete(segments.last) if cursor.is_a?(Hash)
          write(path, data)
          note_write(path, old_text, backup)
        end
        record_change("project", "unset", key, name)
        @output.puts "Unset #{key} for '#{name}'."
      end

      private

      # The config file a key is written to and read from: the layer
      # {ConfigLayering.default_layer} gives, which is also the `target_layer`
      # `config show` reports. A worktree's own file for a key it may override
      # (`dev.ready_timeout`, `notes.dir`), else the parent project's file. The
      # workspace is the named one, else the one cwd is in.
      def config_name(key, project, lineage)
        schema_key = ConfigSchema.key(key)
        if project
          split = WorkspaceLineage.split_worktree_name(project)
          layer = ConfigLayering.default_layer(schema_key, worktree: !split.nil?)
          return (layer == "worktree") ? project : (split&.first || project)
        end
        if schema_key.resolve == :own_then_parent && lineage.is_worktree && !lineage.worktree
          raise Workspace::UsageError, "This worktree has no workspace name (no .workspace-project marker), so #{key} can't tell which file is its own. Pass --name <project>.worktree-<name>."
        end
        layer = ConfigLayering.default_layer(schema_key, worktree: !lineage.worktree.nil?)
        (layer == "worktree") ? lineage.worktree : lineage.name
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

      def set_global(key, value)
        with_global_backup do |data|
          segments = key.split(".")
          cursor = data
          segments[0..-2].each do |segment|
            cursor[segment] = {} unless cursor[segment].is_a?(Hash)
            cursor = cursor[segment]
          end
          cursor[segments.last] = value
          data
        end
        @output.puts "Set #{key} = #{value}."
      end

      # Runs a global edit under {ProjectSettings#with_global_lock}, backing the
      # file up first (after it parsed, so a broken file is refused untouched).
      def with_global_backup
        path = @project_settings.global_config_path
        @project_settings.with_global_lock do |data|
          old_text = read_text(path)
          backup = @file_backup.backup(path)
          result = yield(data)
          # with_global_lock saves result right after this block returns.
          note_write(path, old_text, backup)
          result
        end
      end

      def read_text(path)
        File.exist?(path) ? File.read(path) : ""
      end

      # Records the write's outcome and, when a comment was dropped, says so on
      # stderr (never stdout, which `--json` keeps for its one document).
      def note_write(path, old_text, backup)
        preserved = !comments?(old_text)
        @last_write = Write.new(preserved, backup)
        return if preserved
        @error_output.puts "Note: comments in #{path} were not kept; backup at #{backup}"
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

      def validate_key!(key)
        return if ConfigSchema.settable?(key)
        raise Workspace::UsageError, "Unknown config key '#{key}'. Allowed keys: #{ConfigSchema.settable_names.join(", ")}"
      end

      def validate_value!(key, value)
        ConfigSchema.parse(key, value)
      rescue ArgumentError, RegexpError => e
        raise Workspace::UsageError, "Invalid #{key}: #{e.message}"
      end

      def write(path, data)
        FileUtils.mkdir_p(File.dirname(path))
        tmp_path = "#{path}.tmp#{Process.pid}"
        File.write(tmp_path, YAML.dump(data))
        File.rename(tmp_path, path)
      end
    end
  end
end
