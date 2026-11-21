module Workspace
  # The one map from a tmux session to the workspace whose agentd owns it.
  #
  # A worktree workspace's session (`proj-wt-feat`) is not named like the
  # workspace (`proj.worktree-feat`) agentd binds its socket for, so the name
  # cannot be read off the session. Launch records it on the session as the
  # user option {OPTION}; this reads that back. A session started before that
  # (no option) is looked up in the tmuxinator configs, and one no config names
  # is not a workspace session at all (nil).
  class SessionWorkspace
    # The tmux session user option holding the workspace name.
    OPTION = "@workspace"

    # @param tmux [Workspace::Tmux] reads the session option and each config's session name
    # @param project_config [Workspace::ProjectConfig] lists the configs the fallback looks through
    # @param config [Workspace::Config] tells whether a daemon already listens under the session's own name
    # @param on_ambiguous [#call, nil] given the session and the config names that all claim it
    def initialize(tmux:, project_config:, config:, on_ambiguous: nil)
      @tmux = tmux
      @project_config = project_config
      @config = config
      @on_ambiguous = on_ambiguous
    end

    # @param session [String] a tmux session name
    # @return [String, nil] the workspace name in lowercase, nil for a session that is no workspace's
    def call(session)
      recorded = @tmux.session_option(session, OPTION)
      return WorkspaceName.normalize(recorded) if recorded

      matches = config_matches(session)
      @on_ambiguous&.call(session, matches) if matches.size > 1
      found = matches.first && WorkspaceName.normalize(matches.first)
      # The first hook can beat the pane that records the option; record it so later hooks skip the scan.
      # An ambiguous session is not recorded, so it stays ambiguous for every hook rather than settling on the first config.
      return found.tap { |name| @tmux.set_session_option(session, OPTION, name) if matches.size == 1 } if found

      session if File.socket?(@config.agent_socket_path(session))
    end

    # Whether more than one config claims the session, so {#call}'s answer is a guess at the first.
    # A session that records its workspace is never ambiguous. Says nothing through `on_ambiguous`.
    #
    # @param session [String] a tmux session name
    # @return [Boolean]
    def ambiguous?(session)
      return false if @tmux.session_option(session, OPTION)

      config_matches(session).size > 1
    end

    private

    # Compares unquoted and ignoring case, as the session names in the configs
    # may be quoted and a config keeps the case it was written in.
    def config_matches(session)
      @project_config.available_projects.select do |name|
        unquote(@tmux.session_name_for(name)).casecmp?(session)
      end
    end

    def unquote(value)
      value.to_s.strip.sub(/\A(["'])(.*)\1\z/, '\2')
    end
  end
end
