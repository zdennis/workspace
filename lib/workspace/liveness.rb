module Workspace
  # Answers "is this workspace's tmux session still there?" for tracked
  # projects, so `list` and `status` can tell a running workspace from a stale
  # state-file entry.
  #
  # A project is alive when its tmux session exists. The iTerm window is not
  # consulted: asking iTerm costs an AppleScript round trip, and a headless
  # project has no window.
  class Liveness
    # @param tmux [Workspace::Tmux] source of session names
    def initialize(tmux:)
      @tmux = tmux
    end

    # Lists tmux sessions once and checks every project against that list.
    #
    # @param projects [Array<String>] project names from the state file
    # @return [Hash{String => Boolean, nil}] true when the session exists,
    #   false when it does not, nil when that can't be told: tmux didn't
    #   answer, or the project's tmux_options select a custom socket that
    #   {Workspace::Tmux#sessions} never sees
    def call(projects)
      return {} if projects.empty?

      sessions = list_sessions
      projects.to_h do |project|
        [project, status_for(project, sessions)]
      end
    end

    private

    def list_sessions
      @tmux.sessions(strict: true)
    rescue Workspace::Error
      nil
    end

    def status_for(project, sessions)
      return nil if sessions.nil? || @tmux.custom_socket_option(project)

      sessions.include?(@tmux.session_name_for(project))
    end
  end
end
