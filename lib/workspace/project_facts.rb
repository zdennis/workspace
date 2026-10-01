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
    # @param git [Workspace::Git] reads each checkout's branch, changes and unsaved work
    # @param error_output [IO] stream for warnings about unreadable ask or pipeline stores
    def initialize(tmux:, state:, config:, lock_namespace:, lock_holder:, dev:, agents:, git:, error_output: $stderr)
      @tmux = tmux
      @state = state
      @config = config
      @lock_namespace = lock_namespace
      @lock_holder = lock_holder
      @dev = dev
      @agents = agents
      @git = git
      @error_output = error_output
    end

    # Seconds all of a project's git facts may take unless told otherwise.
    DEFAULT_GIT_TIMEOUT = 5.0

    MISSING_GIT = {"available" => true, "branch" => nil, "changed_files" => nil, "ahead" => nil, "upstream" => nil,
                   "unpushed_commits" => nil, "unsaved" => "missing"}.freeze
    private_constant :MISSING_GIT

    # @param project [Workspace::ProjectCatalog::Project]
    # @param sessions [Array<String>] running tmux session names
    # @param agents [Boolean] read agent states from the daemons; false skips every socket
    # @param timeout [Numeric] seconds to wait for each agent daemon
    # @param git [Boolean] read each member's git facts; false leaves them nil
    # @param git_timeout [Numeric] seconds all members' git facts may take in total
    # @param members [Array<Workspace::ProjectCatalog::Member>] the members to report
    #   (defaults to the project's configured ones; may add unconfigured worktrees)
    # @return [Hash] `{members:, locks:, dev:, errors:}`; each member is the
    #   JSON-ready hash `show` prints, +errors+ maps a source name to why it was unreadable
    def for_project(project, sessions:, agents:, timeout:, git: false, git_timeout: DEFAULT_GIT_TIMEOUT, members: project.members)
      @state.load
      facts = members.map { |member| member_facts(member, sessions, agents: agents, timeout: timeout) }
      if git
        git_facts(project, members, timeout: git_timeout).each_with_index { |fact, i| facts[i]["git"] = fact }
      end
      errors = {}
      locks = lock_facts(project, errors)
      dev = dev_facts(project, errors)
      {members: facts, locks: locks, dev: dev, errors: errors}
    end

    # Git facts for each member, in order, read in parallel and bounded as a
    # whole by +timeout+. Each is a Hash with `available`, `branch`,
    # `changed_files`, `ahead`, `upstream`, `unpushed_commits` and `unsaved`
    # (`"no"`, `"yes"`, `"unknown"` or `"missing"`), plus `reason` when
    # `available` is false (`"timeout"` or `"error"`; git failing or timing
    # out means `unsaved` is `"unknown"`, never clean). A checkout that is gone
    # is `"missing"`, never clean. A member of a project that isn't a git
    # repository gets nil.
    #
    # @param project [Workspace::ProjectCatalog::Project]
    # @param members [Array<Workspace::ProjectCatalog::Member>]
    # @param timeout [Numeric] seconds all members share
    # @return [Array<Hash, nil>] one entry per member
    def git_facts(project, members, timeout: DEFAULT_GIT_TIMEOUT)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
      runs = members.map do |member|
        if !member.exists || !File.directory?(member.path)
          MISSING_GIT
        elsif project.vcs == "git"
          Thread.new do
            Thread.current.report_on_exception = false
            collect_git(member.path)
          end
        end
      end
      runs.map { |run| run.is_a?(Thread) ? await_git(run, deadline) : run }
    end

    private

    def await_git(thread, deadline)
      remaining = [deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC), 0].max
      return thread.value if thread.join(remaining)
      thread.kill
      unavailable_git("timeout")
    rescue => e
      unavailable_git("error", detail: e.message)
    end

    def unavailable_git(reason, detail: nil)
      fact = MISSING_GIT.merge("available" => false, "reason" => reason, "unsaved" => "unknown")
      detail ? fact.merge("detail" => detail) : fact
    end

    # `Git#unsaved_work` answers nil ("clean") for a directory that isn't
    # there, so {#git_facts} has already ruled that out; nil here really
    # means nothing is unsaved.
    def collect_git(path)
      unsaved = @git.unsaved_work(path)
      upstream = @git.upstream_branch(path)
      fact = {
        "available" => true,
        "branch" => @git.worktree_branch(path),
        "changed_files" => nil,
        "ahead" => upstream && @git.commits_ahead_of_upstream(path),
        "upstream" => upstream,
        "unpushed_commits" => nil,
        "unsaved" => "unknown"
      }
      return fact.merge("available" => false, "reason" => "error") if unsaved == :unknown
      return fact.merge("changed_files" => 0, "unpushed_commits" => 0, "unsaved" => "no") if unsaved.nil?
      fact.merge("changed_files" => unsaved[:changed_files], "unpushed_commits" => unsaved[:unpushed_commits], "unsaved" => "yes")
    end

    # A missing checkout has no sessions or state worth reading, so its
    # counts are nil (unknown) rather than 0.
    def member_facts(member, sessions, agents:, timeout:)
      workspace = member.workspace
      local = member.configured && member.exists
      running = local && sessions.include?(@tmux.session_name_for(workspace))
      entries = local ? pipeline_entries(workspace) : nil
      {
        "workspace" => workspace,
        "path" => member.path,
        "kind" => member.kind,
        "configured" => member.configured,
        "exists" => member.exists,
        "running" => running ? true : false,
        "headless" => member.configured ? headless?(workspace) : false,
        "open_asks" => local ? open_asks(workspace) : nil,
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
