require "open3"

module Workspace
  # Answers "what is running under this pane?" from a single snapshot of the
  # process table.
  #
  # One `ps` call builds the whole child map, rather than a `pgrep -P` per node:
  # a pane running a coding agent can have a deep tree, and forking once per
  # level makes the monitor's poll interval the bottleneck.
  class ProcessTree
    # @param logger [Workspace::Logger] debug logger
    def initialize(logger: Workspace::Logger.new)
      @logger = logger
    end

    # Reads the process table once. Hold the result for the length of one scan
    # and then discard it — it is a snapshot, not a live view.
    #
    # @return [ProcessTree::Snapshot]
    def snapshot
      stdout, _, status = Open3.capture3("ps", "-axo", "pid=,ppid=,comm=,args=")
      unless status.success?
        @logger.debug { "process_tree: ps failed" }
        return Snapshot.new([])
      end
      Snapshot.new(parse(stdout))
    end

    private

    # `comm` is reported as a bare name, an absolute path, or (for a versioned
    # install) a path whose basename is the version rather than the executable,
    # so `args` is carried alongside it and both are matched against.
    def parse(stdout)
      stdout.lines.filter_map do |line|
        pid, ppid, command, args = line.strip.split(/\s+/, 4)
        next unless pid && ppid && command
        {pid: pid.to_i, ppid: ppid.to_i, command: command, args: args.to_s}
      end
    end

    # An immutable view of the process table with parent/child lookups.
    class Snapshot
      # @param processes [Array<Hash>] :pid, :ppid, :command entries
      def initialize(processes)
        @processes = processes
        @children = processes.group_by { |p| p[:ppid] }
      end

      # @return [Array<Hash>] every process, in `ps` order
      attr_reader :processes

      # Walks the tree below pid, breadth first.
      #
      # @param pid [Integer] the root process, not itself included
      # @return [Array<Hash>] descendants, nearest first
      def descendants(pid)
        found = []
        queue = [pid]
        seen = {pid => true}

        until queue.empty?
          @children.fetch(queue.shift, []).each do |child|
            next if seen[child[:pid]]
            seen[child[:pid]] = true
            found << child
            queue << child[:pid]
          end
        end
        found
      end

      # Finds the nearest process under pid that looks like one of the named
      # executables, skipping any whose arguments match an excluded marker.
      #
      # The exclusions matter: an agent CLI often leaves long-lived background
      # helpers in the tree, and matching one of those would report a pane as
      # running an interactive session long after the session exited.
      #
      # @param pid [Integer] root process to search below
      # @param names [Array<String>] executable names to look for
      # @param exclude [Array<String>] argument substrings that disqualify a match
      # @param include_root [Boolean] also consider pid itself. tmux reports a
      #   pane's command resolved through symlinks, so a pane running the agent
      #   directly is often only recognizable from its own process entry.
      # @return [Hash, nil] the nearest matching process
      def find_descendant(pid, names, exclude: [], include_root: false)
        candidates = descendants(pid)
        candidates = [find(pid), *candidates].compact if include_root
        candidates.find do |process|
          matches_name?(process, names) && !excluded?(process, exclude)
        end
      end

      # @param pid [Integer]
      # @return [Hash, nil] that process's entry
      def find(pid)
        @by_pid ||= @processes.to_h { |p| [p[:pid], p] }
        @by_pid[pid]
      end

      private

      # `ps comm=` truncates at 16 characters, which mangles any absolute path,
      # so argv[0] is the reliable source and `comm` only a fallback for a
      # process whose arguments are unreadable. A versioned install runs from a
      # path whose basename is the version, so the name is also looked for as a
      # path segment.
      def matches_name?(process, names)
        wanted = names.map(&:downcase)
        candidates = [argv0(process), process[:command].to_s.downcase]

        candidates.any? do |candidate|
          next false if candidate.empty?
          wanted.include?(File.basename(candidate)) ||
            wanted.any? { |name| candidate.include?("/#{name}/") }
        end
      end

      def argv0(process)
        process[:args].to_s.split(/\s+/).first.to_s.downcase
      end

      def excluded?(process, exclude)
        args = process[:args].to_s.downcase
        exclude.any? { |marker| args.include?(marker.downcase) }
      end
    end
  end
end
