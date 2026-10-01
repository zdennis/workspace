require "json"

module Workspace
  # Gathers the per-member and per-project facts `workspace projects show`
  # reports: running and headless state, open asks, pipeline entries, the
  # repo-wide locks, the dev environment and each running workspace's agent
  # states. Everything it reads is local state; a source that can't be read
  # yields nil for that field (and a message in the returned +errors+).
  class ProjectFacts
    # @param tmux [Workspace::Tmux] maps workspace names to session names
    # @param state [Workspace::State] session state, read for each workspace's headless flag
    # @param config [Workspace::Config] locates each workspace's ask and pipeline state files
    # @param lock_namespace [Workspace::LockNamespace] locates the project's lock store
    # @param lock_holder [Workspace::LockHolder] tells live lock holders from stale ones
    # @param dev [Workspace::Commands::Dev] reports the dev environment's state
    # @param agents [Workspace::ProjectAgents] reads each running workspace's agent states from its daemon
    # @param error_output [IO] stream for warnings about unreadable ask or pipeline stores
    def initialize(tmux:, state:, config:, lock_namespace:, lock_holder:, dev:, agents:, error_output: $stderr)
      @tmux = tmux
      @state = state
      @config = config
      @lock_namespace = lock_namespace
      @lock_holder = lock_holder
      @dev = dev
      @agents = agents
      @error_output = error_output
    end

    # @param project [Workspace::ProjectCatalog::Project]
    # @param sessions [Array<String>] running tmux session names
    # @param agents [Boolean] read agent states from the daemons; false skips every socket
    # @param timeout [Numeric] seconds to wait for each agent daemon
    # @return [Hash] `{members:, locks:, dev:, errors:}`; each member is the
    #   JSON-ready hash `show` prints, +errors+ maps a source name to why it was unreadable
    def for_project(project, sessions:, agents:, timeout:)
      @state.load
      members = project.members.map { |member| member_facts(member, sessions, agents: agents, timeout: timeout) }
      errors = {}
      locks = lock_facts(project, errors)
      dev = dev_facts(project, errors)
      {members: members, locks: locks, dev: dev, errors: errors}
    end

    private

    # A missing checkout has no sessions or state worth reading, so its
    # counts are nil (unknown) rather than 0.
    def member_facts(member, sessions, agents:, timeout:)
      workspace = member.workspace
      running = member.exists && sessions.include?(@tmux.session_name_for(workspace))
      entries = member.exists ? pipeline_entries(workspace) : nil
      {
        "workspace" => workspace,
        "path" => member.path,
        "kind" => member.kind,
        "configured" => member.configured,
        "exists" => member.exists,
        "running" => running ? true : false,
        "headless" => headless?(workspace),
        "open_asks" => member.exists ? open_asks(workspace) : nil,
        "pipeline" => entries && {"entries" => entries},
        "agents" => agent_facts(workspace, running, agents: agents, timeout: timeout)
      }
    end

    # nil with --no-agents; a workspace that isn't running has no daemon to ask.
    def agent_facts(workspace, running, agents:, timeout:)
      return nil unless agents
      return {"available" => false, "reason" => "not_running"} unless running
      @agents.facts(workspace, timeout: timeout)
    end

    def headless?(workspace)
      info = @state[workspace]
      (info.is_a?(Hash) && info["headless"]) ? true : false
    end

    def open_asks(workspace)
      AskStore.new(path: @config.ask_state_path(workspace), error_output: @error_output).list(open_only: true).size
    rescue Workspace::Error => e
      @error_output.puts "workspace projects: not counting open questions for #{workspace}: #{e.message}"
      nil
    end

    def pipeline_entries(workspace)
      path = @config.pipeline_state_path(workspace)
      return 0 unless File.exist?(path)
      entries = JSON.parse(File.read(path))
      entries.is_a?(Hash) ? entries.size : 0
    rescue JSON::ParserError, SystemCallError
      @error_output.puts "workspace projects: could not read #{workspace}'s pipeline state at #{path}"
      nil
    end

    # Locks and the dev environment live in the repository's shared lock
    # store, so they are read once for the project, from its main checkout.
    def lock_facts(project, errors)
      return {} unless project_dir?(project)
      store = LockStore.new(dir: @lock_namespace.resolve(cwd: project.path)[:dir], liveness: @lock_holder)
      store.status.each_with_object({}) do |(name, entry), locks|
        locks[name] = {
          "holder" => entry["holder"] && lock_record(entry["holder"], project),
          "queue" => (entry["queue"] || []).map { |waiter| lock_record(waiter, project) }
        }
      end
    rescue Workspace::Error => e
      errors["locks"] = e.message
      nil
    end

    def dev_facts(project, errors)
      return nil unless project_dir?(project)
      payload = @dev.status_payload(working_dir: project.path)
      holder = payload["holder"]
      {
        "running" => payload["running"],
        "ready" => payload["ready"],
        "holder_workspace" => payload["running"] ? workspace_at(holder["worktree"], project) : nil
      }
    rescue Workspace::Error => e
      errors["dev"] = e.message
      nil
    end

    def project_dir?(project)
      !project.path.to_s.empty? && File.directory?(project.path)
    end

    def lock_record(record, project)
      {
        "workspace" => workspace_at(record["worktree"], project),
        "path" => record["worktree"],
        "pid" => record["pid"] || record["waiter_pid"],
        "stale" => record["stale"] ? true : false
      }
    end

    # The member whose checkout contains +path+ (the deepest one wins, since
    # worktrees can sit inside the main checkout), or nil for a path that
    # belongs to no configured member.
    def workspace_at(path, project)
      return nil if path.to_s.empty?
      target = begin
        File.realpath(path)
      rescue SystemCallError
        File.expand_path(path)
      end
      member = project.members
        .select { |m| !m.path.empty? && (target == m.path || target.start_with?("#{m.path}/")) }
        .max_by { |m| m.path.length }
      member&.workspace
    end
  end
end
