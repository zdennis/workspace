require "open3"

module Workspace
  # Executes hook scripts defined in project configuration.
  # Hooks are run as shell commands with workspace-specific environment variables.
  # Automatically resolves the project root directory for the working directory.
  class HookRunner
    # @param project_settings [Workspace::ProjectSettings] project config reader
    # @param project_config [Workspace::ProjectConfig] project config for root path resolution
    # @param output [IO] output stream for user-facing messages
    # @param error_output [IO] error output stream for warnings
    # @param logger [Workspace::Logger] debug logger
    def initialize(project_settings:, project_config:, output: $stdout, error_output: $stderr, logger: Workspace::Logger.new)
      @project_settings = project_settings
      @project_config = project_config
      @output = output
      @error_output = error_output
      @logger = logger
    end

    # Runs a hook for the given project and event, if one is configured.
    # Automatically resolves the project root as the working directory.
    #
    # @param project [String] project name
    # @param event [String] hook event name (e.g. "post_launch")
    # @param env [Hash] additional environment variables
    # @return [Boolean] true if hook ran successfully or no hook defined
    def run(project, event, env: {})
      script = @project_settings.hook_for(project, event)
      unless script
        @logger.debug { "hook_runner: no #{event} hook for #{project}" }
        return true
      end
      @logger.debug { "hook_runner: running #{event} hook for #{project}: #{script}" }

      hook_env = {"WORKSPACE_PROJECT" => project}.merge(env)

      chdir = @project_config.project_root_for(project)
      capture_opts = {}
      capture_opts[:chdir] = chdir if chdir && File.directory?(chdir)

      @output.puts "Running #{event} hook..."
      stdout, stderr, status = Open3.capture3(hook_env, "sh", "-c", script, **capture_opts)
      @output.print stdout unless stdout.empty?

      unless status.success?
        @error_output.puts "Warning: #{event} hook failed (exit #{status.exitstatus})"
        @error_output.print stderr unless stderr.empty?
        return false
      end

      true
    end
  end
end
