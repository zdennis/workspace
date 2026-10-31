require "timeout"

module Workspace
  # Finds the real coding-agent process in a pane and interrupts it. Only SIGINT is ever sent, and only to
  # the pid {#find_agent} found, never to the pane's shell: in a `claude ... || claude` pane any other
  # signal would start a new, empty conversation.
  class AgentStopper
    # Seconds a `ps` call may take; `check` runs it on the monitor scan and under the delivery lock.
    PS_TIMEOUT = 5

    # The flags that name the session a Claude Code process resumes.
    RESUME_FLAGS = %w[--resume -r].freeze

    # Reads `pgid` and `tpgid` of a process through `ps`, as +[pgid, tpgid]+, or nil when it can't be read.
    DEFAULT_GROUP_READER = lambda do |pid|
      out, _err, ok = TimedProcess.run(["ps", "-o", "pgid=,tpgid=", "-p", pid.to_i.to_s], chdir: "/", timeout: PS_TIMEOUT)
      next nil unless ok
      ids = out.split
      (ids.size == 2 && ids.all? { |id| id.match?(/\A-?\d+\z/) }) ? ids.map(&:to_i) : nil
    rescue SystemCallError, Timeout::Error
      nil
    end

    # @param process_tree [Workspace::ProcessTree] reads the fresh snapshot {#stop} checks against
    # @param signaller [#call] +call(signal, pid)+; defaults to `Process.kill`
    # @param group_reader [#call] +call(pid)+ answering +[pgid, tpgid]+ or nil; defaults to a `ps` call
    def initialize(process_tree:, signaller: Process.method(:kill), group_reader: DEFAULT_GROUP_READER)
      @process_tree = process_tree
      @signaller = signaller
      @group_reader = group_reader
    end

    # @param pane_pid [Integer] the pane's process (its shell)
    # @param detector [Workspace::AgentDetector] finds the agent with the workspace's configured names
    # @param tree [Workspace::ProcessTree::Snapshot]
    # @return [Hash, nil] +{pid:, started:}+ for the Claude process under the pane, or nil
    def find_agent(pane_pid:, detector:, tree:)
      found = detector.call(command: "", pid: pane_pid, tree: tree, providers: [AgentProvider.find("claude")])
      process = found && tree.find(found[:pid])
      process && {pid: process[:pid], started: process[:lstart]}
    end

    # @return [Boolean] whether every process from the agent's parent up to and including +pane_pid+ is a
    #   shell; false when the chain doesn't reach +pane_pid+
    def restartable?(pid:, pane_pid:, tree:)
      chain = []
      tree.ancestors(pid).each do |process|
        chain << process
        return chain.all? { |p| shell?(p) } if process[:pid] == pane_pid
      end
      false
    end

    # Sends SIGINT to +pid+ once, after checking against a fresh snapshot that it is the same process and
    # that it holds the pane's terminal: a `claude -p &` is found ahead of a wrapper's agent and must not
    # get the signal. A group that can't be read counts as not holding it.
    #
    # @param pid [Integer]
    # @param started [String] the +lstart+ recorded by {#find_agent}
    # @param pane_pid [Integer] the pane's process (its shell)
    # @return [Symbol] +:not_running+, +:stale+, +:background+ or +:signalled+
    # @raise [Workspace::Error] when the process table can't be read; nothing was sent
    def stop(pid:, started:, pane_pid:)
      process = @process_tree.snapshot.find(pid)
      return :not_running unless process
      return :stale unless process[:lstart] == started
      return :background unless foreground?(pid: pid, pane_pid: pane_pid)
      @signaller.call("INT", pid)
      :signalled
    rescue Errno::ESRCH
      :not_running
    end

    # @param pid [Integer] the agent's process
    # @param pane_pid [Integer] the pane's process (its shell), which answers for the terminal
    # @return [Boolean] whether the process group of +pid+ holds the pane's terminal; false when a group
    #   can't be read. Each call runs `ps` twice, so the answer is fresh and no snapshot is involved.
    def foreground?(pid:, pane_pid:)
      pgid, = @group_reader.call(pid)
      _, tpgid = @group_reader.call(pane_pid)
      !pgid.nil? && pgid == tpgid
    rescue
      false
    end

    # @return [Boolean] whether the pane is at a shell prompt that holds the terminal, with no agent under it
    def pane_clear?(pane_pid:, command:, detector:, tree:)
      return false if find_agent(pane_pid: pane_pid, detector: detector, tree: tree)
      return false unless shell_name?(command)
      pgid, tpgid = @group_reader.call(pane_pid)
      !pgid.nil? && pgid == tpgid
    rescue
      false
    end

    # @param session_id [String]
    # @param tree [Workspace::ProcessTree::Snapshot]
    # @return [Boolean] whether any process, in this pane or elsewhere, was started to resume the session, so
    #   another resume would give the conversation a second process. The id counts only as a resume flag's
    #   whole argument: a `tail -f <id>.jsonl` or a path holding it doesn't hold the session.
    def session_held?(session_id:, tree:)
      tree.processes.any? { |process| resumes?(process[:args].to_s.split, session_id) }
    end

    private

    def resumes?(words, session_id)
      words.include?("--resume=#{session_id}") ||
        words.each_cons(2).any? { |flag, value| RESUME_FLAGS.include?(flag) && value == session_id }
    end

    def shell?(process)
      shell_name?(process[:args].to_s.split.first || process[:command])
    end

    def shell_name?(name)
      Commands::Restore::SHELLS.include?(File.basename(name.to_s).delete_prefix("-"))
    end
  end
end
