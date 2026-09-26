require "yaml"
require "fileutils"

module Workspace
  module Commands
    # Sets, reads, and unsets a project's config by dotted key
    # (`workspace config set/get/unset`), so callers don't need to hand-edit
    # YAML. Restricted to an allowlist, so a typo doesn't silently create
    # unused config.
    class Config
      # Keys `set`/`get`/`unset` allow. Unlisted dotted keys are rejected.
      ALLOWED_KEYS = %w[dev.up dev.ready dev.stop_timeout].freeze

      # @param project_settings [Workspace::ProjectSettings] reads/writes project YAML
      # @param lineage [Workspace::WorkspaceLineage] resolves a project from cwd (worktree -> parent)
      # @param file_backup [Workspace::FileBackup] backs up the config file before it's rewritten
      # @param output [IO] output stream for user-facing messages
      def initialize(project_settings:, lineage:, file_backup:, output: $stdout)
        @project_settings = project_settings
        @lineage = lineage
        @file_backup = file_backup
        @output = output
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

        name = project || @lineage.resolve(cwd: cwd).name
        path = @project_settings.project_config_path(name)
        @file_backup.backup(path)
        data = @project_settings.load(name)
        segments = key.split(".")
        cursor = data
        segments[0..-2].each do |segment|
          cursor[segment] = {} unless cursor[segment].is_a?(Hash)
          cursor = cursor[segment]
        end
        cursor[segments.last] = value
        write(path, data)
        @output.puts "Set #{key} = #{value} for '#{name}'."
      end

      # @param key [String] a dotted key from {ALLOWED_KEYS}
      # @param project [String, nil] project to read; defaults to the one inferred from cwd
      # @param cwd [String] directory to infer the project from, when project is nil
      # @return [void]
      # @raise [Workspace::UsageError] for an unknown key
      def get(key, project: nil, cwd: Dir.pwd)
        validate_key!(key)

        name = project || @lineage.resolve(cwd: cwd).name
        data = @project_settings.load(name)
        value = data.dig(*key.split("."))
        @output.puts value.nil? ? "(unset)" : value
      end

      # @param key [String] a dotted key from {ALLOWED_KEYS}
      # @param project [String, nil] project to configure; defaults to the one inferred from cwd
      # @param cwd [String] directory to infer the project from, when project is nil
      # @return [void]
      # @raise [Workspace::UsageError] for an unknown key
      def unset(key, project: nil, cwd: Dir.pwd)
        validate_key!(key)

        name = project || @lineage.resolve(cwd: cwd).name
        path = @project_settings.project_config_path(name)
        @file_backup.backup(path)
        data = @project_settings.load(name)
        segments = key.split(".")
        cursor = segments[0..-2].reduce(data) { |node, segment| node.is_a?(Hash) ? node[segment] : nil }
        cursor.delete(segments.last) if cursor.is_a?(Hash)
        write(path, data)
        @output.puts "Unset #{key} for '#{name}'."
      end

      private

      def validate_key!(key)
        return if ALLOWED_KEYS.include?(key)
        raise Workspace::UsageError, "Unknown config key '#{key}'. Allowed keys: #{ALLOWED_KEYS.join(", ")}"
      end

      def validate_value!(key, value)
        return unless key == "dev.stop_timeout"
        Workspace::DevConfig.parse_duration(value)
      rescue ArgumentError => e
        raise Workspace::UsageError, "Invalid dev.stop_timeout: #{e.message}"
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
