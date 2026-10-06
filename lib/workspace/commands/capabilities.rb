require "json"

module Workspace
  module Commands
    # Prints what this CLI can do, so a caller can ask instead of comparing
    # version numbers. Cheap and offline: it reads constants, config paths and
    # the PATH, and never starts a process or touches git, tmux or a daemon.
    class Capabilities
      # Feature name to integer revision; 0 means this CLI doesn't have it. A
      # revision goes up when the feature's output changes in a way a reader
      # must handle. Names that are 0 are listed so a caller sees them
      # explicitly; the item that adds the feature raises it to 1.
      FEATURES = {
        "envelope" => 1,
        "error_codes" => 1,
        "name_scope" => 1,
        "no_input" => 1,
        "action_json" => 1,
        "sessions" => 1,
        "locks_json" => 2,
        "git_facts" => 1,
        "prune_safe" => 1,
        "snapshot" => 2,
        "events_follow" => 0,
        "actions_manifest" => 0,
        "agent_send" => 1,
        "agent_spawn" => 0,
        "focus_pane" => 1,
        "state_done" => 1,
        "doctor_json" => 0,
        "daemon_control" => 3,
        "config_json" => 1,
        "tmux_show" => 1,
        "tasks" => 1,
        "event_emitters" => 1,
        "ui_open" => 1,
        "pane_bindings" => 2,
        "library" => 3,
        "library_play" => 2,
        "library_copy" => 1,
        "instructions" => 1,
        "restore" => 1,
        "workflow" => 1
      }.freeze

      # The exit statuses commands use, by meaning.
      EXIT_CODES = {
        "ok" => 0,
        "failed" => 1,
        "not_submitted" => 2,
        "partial" => 3,
        "lock_cleared" => 4,
        "timeout" => 75
      }.freeze

      # Dependency key to the executable name looked up on the PATH.
      DEPENDENCIES = {
        "window_tool" => "window-tool",
        "gh" => "gh",
        "tmux" => "tmux"
      }.freeze

      # @param config [Workspace::Config] source of the event log and run directory paths
      # @param path_env [String, nil] the PATH to search for dependencies
      # @param output [IO] output stream
      def initialize(config:, path_env: ENV["PATH"], output: $stdout)
        @config = config
        @path_env = path_env.to_s
        @output = output
      end

      # @param json [Boolean] print one JSON document instead of text
      # @return [void]
      def call(json: false)
        json ? @output.puts(JSON.generate(document)) : print_text
      end

      private

      def document
        {
          "schema_version" => JsonEnvelope::SCHEMA_VERSION,
          "ok" => true,
          "version" => Workspace::VERSION,
          "features" => FEATURES,
          "exit_codes" => EXIT_CODES,
          "paths" => {"event_log" => @config.event_log_file, "run_dir" => @config.run_dir, "library" => @config.library_dir},
          "dependencies" => dependencies.transform_values { |path| {"path" => path} }
        }
      end

      def dependencies
        DEPENDENCIES.transform_values { |exe| find_executable(exe) }
      end

      def find_executable(exe)
        @path_env.split(File::PATH_SEPARATOR).reject(&:empty?).each do |dir|
          candidate = File.join(dir, exe)
          return candidate if File.file?(candidate) && File.executable?(candidate)
        end
        nil
      end

      def print_text
        @output.puts "workspace #{Workspace::VERSION}"
        @output.puts
        @output.puts "features (0 = not available):"
        FEATURES.each { |name, revision| @output.puts "  #{name.ljust(18)}#{revision}" }
        @output.puts
        @output.puts "dependencies:"
        dependencies.each { |name, path| @output.puts "  #{DEPENDENCIES.fetch(name).ljust(12)}#{path || "not found"}" }
      end
    end
  end
end
