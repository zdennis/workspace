require "digest"
require "fileutils"
require "socket"

module Workspace
  # Centralizes all path constants and configuration for the workspace CLI.
  class Config
    # Cap for socket paths: macOS sockaddr_un allows 104 bytes for the full
    # expanded path, so agent socket paths are kept under this with headroom.
    MAX_SOCKET_PATH_BYTES = 100

    # Cap for the log filename component: macOS NAME_MAX allows 255 bytes per
    # path component (the log path itself is not length-limited).
    MAX_LOG_PATH_BYTES = 250

    # @param workspace_dir [String] override for the workspace installation directory
    def initialize(workspace_dir: nil)
      @workspace_dir = workspace_dir || File.expand_path("../..", __dir__)
    end

    # @return [String] the workspace installation directory
    attr_reader :workspace_dir

    # @return [String] path to the tmuxinator config directory
    def tmuxinator_dir
      File.expand_path("~/.config/tmuxinator")
    end

    # @return [String] path to the JSON state file
    def state_file
      File.expand_path("~/.workspace-state.json")
    end

    # @return [String] path to the event log file
    def event_log_file
      File.expand_path("~/.workspace-events.jsonl")
    end

    # @return [String] path to the source templates directory
    def templates_dir
      File.join(workspace_dir, "lib", "templates")
    end

    # @return [String] path to the installed project template
    def project_template_path
      File.join(tmuxinator_dir, "workspace.project-template.yml")
    end

    # @return [String] path to the installed worktree project template
    def worktree_template_path
      File.join(tmuxinator_dir, "workspace.project-worktree-template.yml")
    end

    # @return [String] path to the workspace config directory
    def workspace_config_dir
      File.expand_path("~/.config/workspace")
    end

    # @return [String] path to the per-project workspace config directory
    def workspace_projects_dir
      File.join(workspace_config_dir, "projects")
    end

    # @param name [String] the workspace name
    # @return [String] path to the project's workspace config file
    def project_config_path(name)
      File.join(workspace_projects_dir, "#{name}.yml")
    end

    # Handoff files carry one pipeline stage's output to the next, so they live
    # under the user's own config directory rather than in shared /tmp.
    #
    # @return [String] path to the directory holding pipeline handoff files
    def handoff_dir
      File.join(workspace_config_dir, "handoffs")
    end

    # Socket files live outside /tmp so they are never touched by OS temp-file
    # sweeps (macOS clears /tmp files older than 3 days; a reboot wipes it).
    #
    # @return [String] path to the directory holding the agent's runtime socket files
    def socket_dir
      dir = File.expand_path("~/.local/workspace/run")
      FileUtils.mkdir_p(dir)
      dir
    end

    # @return [String] path to the directory where work-coordinator stores its sockets
    def work_coordinator_run_dir
      File.expand_path("~/.local/run/work-coordinator")
    end

    # @param name [String] the workspace name
    # @return [String] path to the agent's own Unix socket
    def agent_socket_path(name)
      agent_file_path(name, ".sock", MAX_SOCKET_PATH_BYTES)
    end

    # @param name [String] the workspace name
    # @return [String] path to the agent's daemon log file, when launched in the background
    def agent_log_path(name)
      agent_file_path(name, ".log", MAX_LOG_PATH_BYTES, component_only: true)
    end

    # @param name [String] the workspace name
    # @return [Boolean] whether an agent is currently listening on this workspace's socket
    def agent_running?(name)
      UNIXSocket.open(agent_socket_path(name), &:close)
      true
    rescue SystemCallError, ArgumentError
      false
    end

    # State that outlives the agent process lives under the XDG state
    # directory rather than in /tmp, where a reboot would take it.
    #
    # @return [String] path to workspace's own XDG state directory
    def state_dir
      File.join(File.expand_path(ENV.fetch("XDG_STATE_HOME", "~/.local/state")), "workspace")
    end

    # @param name [String] the workspace name
    # @return [String] path to the project's pipeline state directory
    def pipeline_state_dir(name)
      File.join(state_dir, name)
    end

    # Lock files are shared across every worktree of a repository, so they are
    # keyed by namespace rather than by workspace name.
    #
    # @return [String] path to the directory holding per-namespace lock stores
    def lock_dir
      File.join(state_dir, "locks")
    end

    # @param name [String] the workspace name
    # @return [String] path to the project's persisted pipeline state file
    def pipeline_state_path(name)
      File.join(pipeline_state_dir(name), "pipeline.json")
    end

    # @return [String] path to the JSON store of per-pane context-window readings
    def context_store_path
      File.join(state_dir, "context.json")
    end

    # @param name [String] the workspace name
    # @return [String] path to the workspace's recorded-question store
    def ask_state_path(name)
      File.join(pipeline_state_dir(name), "asks.json")
    end

    # @return [String] path to the work-coordinator main socket
    def work_coordinator_socket
      File.join(work_coordinator_run_dir, "work-coordinator.sock")
    end

    # @return [String] path to the work-coordinator status socket
    def work_coordinator_status_socket
      File.join(work_coordinator_run_dir, "work-coordinator-status.sock")
    end

    # @return [String] the window-tool binary name
    def window_tool
      "window-tool"
    end

    # @param name [String] the project name
    # @return [String] path to the tmuxinator config file for the given project
    def config_path_for(name)
      File.join(tmuxinator_dir, "workspace.#{name}.yml")
    end

    # @return [String] path to the directory that stores run-result files
    def run_results_dir
      File.expand_path("~/.workspace-runs")
    end

    # @param uuid [String]
    # @return [String]
    def run_result_path(uuid)
      File.join(run_results_dir, "#{uuid}.json")
    end

    # @param uuid [String]
    # @return [String]
    def run_stdout_path(uuid)
      File.join(run_results_dir, "#{uuid}.stdout")
    end

    # @param uuid [String]
    # @return [String]
    def run_stderr_path(uuid)
      File.join(run_results_dir, "#{uuid}.stderr")
    end

    private

    # Builds the agent's per-name runtime file path ("workspace-<name><ext>")
    # under the socket directory. Short names keep their literal path; long
    # names are truncated and suffixed with a deterministic SHA-256 prefix so
    # distinct names still map to distinct files.
    #
    # Length caps keep the path within what the OS accepts: macOS caps unix
    # socket paths at 104 bytes (sockaddr_un, a full-path limit) and file
    # names at 255 bytes (NAME_MAX, a per-component limit). When +component_only+
    # is false the cap applies to the full expanded path, otherwise only to
    # the filename component.
    #
    # @param name [String] the workspace name
    # @param ext [String] the file extension, including the leading dot
    # @param limit [Integer] maximum byte length of the capped portion
    # @param component_only [Boolean] cap the filename component rather than
    #   the full path
    # @raise [Workspace::Error] when the socket directory is too deep for
    #   even the minimal hashed path to fit within +limit+
    # @return [String] the length-capped file path
    def agent_file_path(name, ext, limit, component_only: false)
      dir = socket_dir
      filename = "workspace-#{name}#{ext}"
      path = File.join(dir, filename)
      return path if capped_bytesize(path, filename, component_only) <= limit

      hash = Digest::SHA256.hexdigest(name)[0, 10]
      min_filename = "workspace-#{hash}#{ext}"
      min_path = File.join(dir, min_filename)
      min_bytesize = capped_bytesize(min_path, min_filename, component_only)
      if min_bytesize > limit
        raise Workspace::Error,
          "socket dir is too deep for an agent file to fit within #{limit} bytes: #{dir}"
      end

      name_budget = limit - min_bytesize - 1
      return min_path if name_budget < 1

      truncated = truncate_to_bytes(name, name_budget)
      File.join(dir, "workspace-#{truncated}-#{hash}#{ext}")
    end

    # Returns the byte size the length cap applies to: the full path, or just
    # its filename component.
    def capped_bytesize(path, filename, component_only)
      component_only ? filename.bytesize : path.bytesize
    end

    # Truncates +string+ to at most +budget+ bytes without splitting a
    # multibyte character (an invalid-encoding filename would fail to create).
    def truncate_to_bytes(string, budget)
      truncated = +""
      string.each_char do |char|
        break if truncated.bytesize + char.bytesize > budget

        truncated << char
      end
      truncated
    end
  end
end
