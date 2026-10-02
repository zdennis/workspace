require "yaml"
require "fileutils"

module Workspace
  module Commands
    # Sets, reads, and unsets a project's config by dotted key
    # (`workspace config set/get/unset`), so callers don't need to hand-edit
    # YAML. Restricted to an allowlist, so a typo doesn't silently create
    # unused config.
    class Config
      # Keys `set`/`get`/`unset` allow, written to a project's config. Unlisted
      # dotted keys are rejected.
      ALLOWED_KEYS = %w[dev.up dev.ready dev.stop_timeout dev.startup_timeout dev.ready_timeout dev.kill_grace locks.idle_grace locks.ps_timeout locks.reap_interval alerts.notify alerts.idle_after handoff.threshold handoff.check_prompt handoff.resume_prompt].freeze

      # Keys `set`/`get`/`unset` allow, written to the global config
      # (~/.config/workspace/config.yml) instead of a project's — there's one
      # status line and one context source per machine, not per project.
      GLOBAL_ALLOWED_KEYS = %w[statusline.command context.source context.pattern launch.headless].freeze

      # Keys the session-monitor daemon only reads once, at startup. Changing
      # one of these has no effect on an already-running daemon.
      RESTART_REQUIRED_KEYS = %w[locks.ps_timeout locks.reap_interval alerts.notify alerts.idle_after].freeze

      # @param project_settings [Workspace::ProjectSettings] reads/writes project YAML
      # @param lineage [Workspace::WorkspaceLineage] resolves a project from cwd (worktree -> parent)
      # @param file_backup [Workspace::FileBackup] backs up the config file before it's rewritten
      # @param output [IO] output stream for user-facing messages
      # @param error_output [IO] output stream for user-facing errors
      def initialize(project_settings:, lineage:, file_backup:, output: $stdout, error_output: $stderr)
        @project_settings = project_settings
        @lineage = lineage
        @file_backup = file_backup
        @output = output
        @error_output = error_output
      end

      # @param key [String] a dotted key from {ALLOWED_KEYS}
      # @param value [String] the value to store
      # @param project [String, nil] project to configure; defaults to the one inferred from cwd
      # @param cwd [String] directory to infer the project from, when project is nil
      # @return [void]
      # @raise [Workspace::UsageError] for an unknown key or an invalid value
      def set(key, value, project: nil, cwd: Dir.pwd)
        validate_key!(key)
        validate_value!(key, value)

        if GLOBAL_ALLOWED_KEYS.include?(key)
          set_global(key, value)
          return
        end

        lineage = @lineage.resolve(cwd: cwd)
        name = project || lineage.name
        path = @project_settings.project_config_path(name)
        with_config_lock(path) do
          @file_backup.backup(path)
          data = load_for_edit(name)
          segments = key.split(".")
          cursor = data
          segments[0..-2].each do |segment|
            cursor[segment] = {} unless cursor[segment].is_a?(Hash)
            cursor = cursor[segment]
          end
          cursor[segments.last] = value
          write(path, data)
        end
        @output.puts "Set #{key} = #{value} for '#{name}'."
        if RESTART_REQUIRED_KEYS.include?(key)
          daemon_name = (project.nil? && lineage.worktree) ? lineage.worktree : name
          @output.puts "Takes effect the next time the session monitor starts (workspace agentd #{daemon_name} --force, or relaunch)."
        end
      end

      # @param key [String] a dotted key from {ALLOWED_KEYS}
      # @param project [String, nil] project to read; defaults to the one inferred from cwd
      # @param cwd [String] directory to infer the project from, when project is nil
      # @return [Boolean] true if the key had a value, false if unset
      # @raise [Workspace::UsageError] for an unknown key
      def get(key, project: nil, cwd: Dir.pwd)
        validate_key!(key)

        if GLOBAL_ALLOWED_KEYS.include?(key)
          value = @project_settings.load_global.dig(*key.split("."))
          if value.nil?
            @error_output.puts "#{key} is not set."
            return false
          end
          @output.puts value
          return true
        end

        name = project || @lineage.resolve(cwd: cwd).name
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

      # @param key [String] a dotted key from {ALLOWED_KEYS}
      # @param project [String, nil] project to configure; defaults to the one inferred from cwd
      # @param cwd [String] directory to infer the project from, when project is nil
      # @return [void]
      # @raise [Workspace::UsageError] for an unknown key
      def unset(key, project: nil, cwd: Dir.pwd)
        validate_key!(key)

        if GLOBAL_ALLOWED_KEYS.include?(key)
          @project_settings.with_global_lock do |data|
            segments = key.split(".")
            cursor = segments[0..-2].reduce(data) { |node, segment| node.is_a?(Hash) ? node[segment] : nil }
            cursor.delete(segments.last) if cursor.is_a?(Hash)
            data
          end
          @output.puts "Unset #{key}."
          return
        end

        name = project || @lineage.resolve(cwd: cwd).name
        path = @project_settings.project_config_path(name)
        with_config_lock(path) do
          @file_backup.backup(path)
          data = load_for_edit(name)
          segments = key.split(".")
          cursor = segments[0..-2].reduce(data) { |node, segment| node.is_a?(Hash) ? node[segment] : nil }
          cursor.delete(segments.last) if cursor.is_a?(Hash)
          write(path, data)
        end
        @output.puts "Unset #{key} for '#{name}'."
      end

      private

      def load_for_edit(name)
        @project_settings.load(name)
      rescue Workspace::ConfigParseError => e
        raise Workspace::ConfigParseError.new(e.path, "#{e.reason}. Fix or remove the file, then retry")
      end

      def set_global(key, value)
        @project_settings.with_global_lock do |data|
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
        return if ALLOWED_KEYS.include?(key) || GLOBAL_ALLOWED_KEYS.include?(key)
        raise Workspace::UsageError, "Unknown config key '#{key}'. Allowed keys: #{(ALLOWED_KEYS + GLOBAL_ALLOWED_KEYS).join(", ")}"
      end

      def validate_value!(key, value)
        case key
        when "dev.stop_timeout" then Workspace::Duration.parse(value)
        when "dev.startup_timeout", "dev.ready_timeout" then Workspace::Duration.parse_positive(value)
        when "dev.kill_grace" then Workspace::Duration.parse_capped(value, max: Workspace::DevConfig::MAX_KILL_GRACE)
        when "locks.idle_grace" then Workspace::LockConfig.parse_idle_grace(value)
        when "locks.ps_timeout" then Workspace::LockConfig.parse_ps_timeout(value)
        when "locks.reap_interval" then Workspace::LockConfig.parse_reap_interval(value)
        when "alerts.notify" then Workspace::AlertConfig.parse_notify(value)
        when "alerts.idle_after" then Workspace::AlertConfig.parse_idle_after(value)
        when "launch.headless" then Workspace::LaunchMode.parse_config(value)
        when "handoff.threshold" then Workspace::HandoffConfig.parse_threshold(value)
        when "handoff.check_prompt", "handoff.resume_prompt" then Workspace::HandoffConfig.parse_prompt(value)
        when "context.source"
          raise ArgumentError, "must be \"statusline\" or \"scrape\"" unless %w[statusline scrape].include?(value)
        when "context.pattern"
          Regexp.new(value)
          raise ArgumentError, "must have exactly one capture group" unless capture_group_count(value) == 1
        end
      rescue ArgumentError, RegexpError => e
        raise Workspace::UsageError, "Invalid #{key}: #{e.message}"
      end

      # Counts capturing groups (named and unnamed) in a regex source by
      # walking it character by character, skipping escaped characters and
      # character-class bodies (`[(]` isn't a group), and recognizing named
      # groups (`(?<name>`, `(?'name'`) while excluding lookaround
      # (`(?=`, `(?!`, `(?<=`, `(?<!`) and non-capturing groups (`(?:`).
      # Good enough for validating a config value; not a full regex parser.
      def capture_group_count(pattern)
        count = 0
        in_class = false
        i = 0
        chars = pattern.chars
        while i < chars.size
          c = chars[i]
          if c == "\\"
            i += 2
            next
          end
          if in_class
            in_class = false if c == "]"
            i += 1
            next
          end
          case c
          when "["
            in_class = true
          when "("
            if chars[i + 1] == "?"
              nxt = chars[i + 2]
              if nxt == "<" && !["=", "!"].include?(chars[i + 3])
                count += 1 # named group (?<name>...)
              elsif nxt == "'"
                count += 1 # named group (?'name'...)
              end
              # else: non-capturing (?:...) or lookaround (?=/?!/?<=/?<!), not counted
            else
              count += 1 # unnamed capturing group
            end
          end
          i += 1
        end
        count
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
