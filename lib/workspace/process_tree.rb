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
    # `ps` runs under a fixed locale and time zone so `lstart` reads the same
    # from every caller: it is stored and compared as a process identity.
    #
    # @return [ProcessTree::Snapshot]
    # @raise [Workspace::Error] if `ps` fails; an empty table would read as
    #   every process having exited
    def snapshot
      stdout, stderr, status = Open3.capture3(PS_ENV, "ps", "-axo", "pid=,ppid=,lstart=,comm=,args=")
      unless status.success?
        @logger.debug { "process_tree: ps failed: #{stderr.strip}" }
        raise Workspace::Error, "could not read the process table (ps failed: #{stderr.strip})"
      end
      Snapshot.new(parse(stdout))
    end

    PS_ENV = {"LC_ALL" => "C", "TZ" => "UTC"}.freeze
    private_constant :PS_ENV

    private

    # Under PS_ENV, `lstart` is always five whitespace-separated tokens
    # ("Thu Sep 26 09:12:03 2026"), so it can be split out even though `comm`
    # and `args` afterward are variable width. `comm` is reported as a bare
    # name, an absolute path, or (for a versioned install) a path whose
    # basename is the version rather than the executable, so `args` is
    # carried alongside it and both are matched against.
    LINE_PATTERN = /\A(\d+)\s+(\d+)\s+(\S+\s+\S+\s+\S+\s+\S+\s+\S+)\s+(\S+)\s*(.*)\z/

    def parse(stdout)
      stdout.lines.filter_map do |line|
        m = LINE_PATTERN.match(line.strip)
        next unless m
        pid, ppid, lstart, command, args = m.captures
        {pid: pid.to_i, ppid: ppid.to_i, lstart: lstart, command: command, args: args.to_s}
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
      # executables, skipping any that is a background helper.
      #
      # The exclusions matter: an agent CLI often leaves long-lived background
      # helpers in the tree, and matching one of those would report a pane as
      # running an interactive session long after the session exited.
      #
      # A marker names a helper's subcommand ("daemon run"), so it matches
      # only the words immediately after the program, never text further
      # along such as a prompt. Markers belong to one agent CLI, so pass a
      # Hash to apply each executable's markers only to processes matched as
      # that executable; an Array applies to every name.
      #
      # @param pid [Integer] root process to search below
      # @param names [Array<String>] executable names to look for
      # @param exclude [Array<String>, Hash{String => Array<String>}] helper
      #   subcommands that disqualify a match, for every name or per name
      # @param include_root [Boolean] also consider pid itself. tmux reports a
      #   pane's command resolved through symlinks, so a pane running the agent
      #   directly is often only recognizable from its own process entry.
      # @return [Hash, nil] the nearest matching process
      def find_descendant(pid, names, exclude: [], include_root: false)
        candidates = descendants(pid)
        candidates = [find(pid), *candidates].compact if include_root
        candidates.find { |process| agent?(process, names, exclude) }
      end

      # @param pid [Integer]
      # @return [Hash, nil] that process's entry
      def find(pid)
        @by_pid ||= @processes.to_h { |p| [p[:pid], p] }
        @by_pid[pid]
      end

      # Walks the ppid chain above pid, nearest first, stopping at the first
      # unknown or cyclic ancestor.
      #
      # @param pid [Integer] process to walk up from, not itself included
      # @return [Array<Hash>] ancestors, nearest first
      def ancestors(pid)
        found = []
        seen = {pid => true}
        current = find(pid)

        while current
          parent = find(current[:ppid])
          break if parent.nil? || seen[parent[:pid]]
          seen[parent[:pid]] = true
          found << parent
          current = parent
        end
        found
      end

      # Finds the nearest ancestor of pid that looks like one of the named
      # executables, skipping any that is a background helper (see
      # {#find_descendant} for how exclude is matched).
      #
      # @param pid [Integer] process to walk up from
      # @param names [Array<String>] executable names to look for
      # @param exclude [Array<String>, Hash{String => Array<String>}] helper
      #   subcommands that disqualify a match, for every name or per name
      # @return [Hash, nil] the nearest matching ancestor
      def find_ancestor(pid, names, exclude: [])
        ancestors(pid).find { |process| agent?(process, names, exclude) }
      end

      private

      # `ps comm=` truncates at 16 characters, which mangles any absolute path,
      # so argv[0] is the reliable source and `comm` only a fallback for a
      # process whose arguments are unreadable. A versioned install runs from a
      # path whose basename is the version, so the name is also looked for as a
      # path segment.
      def agent?(process, names, exclude)
        name = names.find { |candidate| matches_name?(process, candidate) }
        return false unless name
        markers = exclude.is_a?(Hash) ? exclude.fetch(name, []) : exclude
        !helper?(process, markers)
      end

      def matches_name?(process, name)
        wanted = name.downcase
        [argv0(process), process[:command].to_s.downcase].any? do |candidate|
          next false if candidate.empty?
          File.basename(candidate) == wanted || candidate.include?("/#{wanted}/")
        end
      end

      def argv0(process)
        words(process).first.to_s
      end

      def helper?(process, markers)
        subcommand = words(process).drop(1)
        markers.any? do |marker|
          marker_words = marker.downcase.split
          subcommand.first(marker_words.size) == marker_words
        end
      end

      def words(process)
        process[:args].to_s.downcase.split
      end
    end
  end
end
