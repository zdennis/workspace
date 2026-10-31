require "timeout"

module Workspace
  # Finds the real coding-agent process in a pane and interrupts it. Only SIGINT is ever sent, and only to
  # the pid {#find_agent} found, never to the pane's shell: in a `claude ... || claude` pane any other
  # signal would start a new, empty conversation.
  class AgentStopper
    # Seconds a `ps` call may take; `check` runs it on the monitor scan and under the delivery lock.
    PS_TIMEOUT = 5

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

    # Sends SIGINT to +pid+ once, after checking against a fresh snapshot that it is the same process.
    #
    # @param pid [Integer]
    # @param started [String] the +lstart+ recorded by {#find_agent}
    # @return [Symbol] +:not_running+, +:stale+ or +:signalled+
    def stop(pid:, started:)
      process = @process_tree.snapshot.find(pid)
      return :not_running unless process
      return :stale unless process[:lstart] == started
      @signaller.call("INT", pid)
      :signalled
    rescue Errno::ESRCH
      :not_running
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

    private

    def shell?(process)
      shell_name?(process[:args].to_s.split.first || process[:command])
    end

    def shell_name?(name)
      Commands::Restore::SHELLS.include?(File.basename(name.to_s).delete_prefix("-"))
    end
  end
end
