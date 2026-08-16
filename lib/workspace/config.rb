module Workspace
  # Centralizes all path constants and configuration for the workspace CLI.
  class Config
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

    # @param name [String] the workspace name
    # @return [String] path to the agent's own Unix socket
    def agent_socket_path(name)
      "/tmp/workspace-#{name}.sock"
    end

    # @return [String] path to the work-coordinator main socket
    def work_coordinator_socket
      "/tmp/work-coordinator.sock"
    end

    # @return [String] path to the work-coordinator status socket
    def work_coordinator_status_socket
      "/tmp/work-coordinator-status.sock"
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
  end
end
