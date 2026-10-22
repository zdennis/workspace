module Workspace
  # Finds the launchers on PATH for each coding agent (`claude`, `claude-dev`, `codex`, ...) and says which
  # one a workspace runs, so a person can pick the value of `agent.commands.<kind>`. Read-only: it lists
  # directories and checks file modes, and never runs or reads a candidate.
  class AgentExecutables
    # Most rows a result holds; past it `truncated` is true.
    MAX_ROWS = 200

    # @param agent_commands [Workspace::AgentCommands]
    # @param path [String, nil] the PATH to scan, the one the CLI itself runs with
    def initialize(agent_commands:, path: ENV["PATH"])
      @agent_commands = agent_commands
      @path = path.to_s
    end

    # @param workspace [String, nil] a workspace or worktree workspace name; nil reads the global layer alone
    # @param kind [String, nil] an {AgentProvider} key to list only that family
    # @return [Hash] `path_dirs` (absolute directories scanned), `executables` (rows with `kind`, `name`,
    #   `path`, `source` "path" or "configured", `found`, `builtin`, `shadowed`), `effective` (per kind:
    #   `program`, `path`, `layer` "global|project|worktree|default", `found`), `kind` (the effective
    #   `agent.kind`), and `truncated: true` when rows were cut at {MAX_ROWS}
    # @raise [ArgumentError] if `kind` is not an {AgentProvider} key
    def call(workspace: nil, kind: nil)
      providers = AgentProvider.all
      if kind
        providers = providers.select { |provider| provider.key == kind }
        raise ArgumentError, "unknown agent kind #{kind.inspect}" if providers.empty?
      end

      dirs = path_dirs
      listings = dirs.to_h { |dir| [dir, listing(dir)] }
      rows = providers.flat_map { |provider| rows_for(provider, workspace, dirs, listings) }
      result = {
        "path_dirs" => dirs,
        "executables" => rows.first(MAX_ROWS),
        "effective" => AgentProvider.all.to_h { |provider| [provider.key, effective_for(provider, workspace, dirs)] },
        "kind" => @agent_commands.kind(workspace)
      }
      result["truncated"] = true if rows.size > MAX_ROWS
      result
    end

    private

    def path_dirs
      @path.split(":").select { |dir| dir.start_with?("/") && File.directory?(dir) }.uniq { |dir| File.realpath(dir) }
    end

    def listing(dir)
      Dir.children(dir)
    rescue SystemCallError
      []
    end

    def runnable?(path)
      File.file?(path) && File.executable?(path)
    end

    def rows_for(provider, workspace, dirs, listings)
      matcher = /\A#{Regexp.escape(provider.executable)}(-[A-Za-z0-9._+-]+)?\z/
      hits = {}
      dirs.each do |dir|
        listings[dir].each do |name|
          next unless name.valid_encoding? && matcher.match?(name)
          path = File.join(dir, name)
          next unless runnable?(path)
          (hits[name] ||= []) << path
        end
      end
      rows = hits.map do |name, paths|
        row(provider, name, paths.first, "path", true, paths.drop(1))
      end
      rows.concat(configured_rows(provider, workspace, dirs, hits.keys))
      rows.sort_by { |row| [(row["name"] == provider.executable) ? 0 : 1, row["name"]] }
    end

    def configured_rows(provider, workspace, dirs, known)
      seen = known.dup
      @agent_commands.configured_commands_for(workspace, provider.key).filter_map do |command|
        word = AgentCommands.program_words(command).first
        next unless word
        absolute = word.start_with?("/")
        name = word
        next if seen.include?(name)
        next if resolve(word, dirs)
        seen << name
        row(provider, name, absolute ? word : nil, "configured", false, [])
      end
    end

    def effective_for(provider, workspace, dirs)
      command = @agent_commands.effective_command_for(workspace, provider.key)
      word = AgentCommands.program_words(command).first || provider.executable
      path = resolve(word, dirs)
      {
        "program" => File.basename(word),
        "path" => path,
        "layer" => @agent_commands.layer_for(workspace, provider.key),
        "found" => !path.nil?
      }
    end

    def resolve(word, dirs)
      return (runnable?(word) ? word : nil) if word.start_with?("/")
      return nil if word.include?("/")
      name = word
      dirs.map { |dir| File.join(dir, name) }.find { |path| runnable?(path) }
    end

    def row(provider, name, path, source, found, shadowed)
      {
        "kind" => provider.key, "name" => name, "path" => path, "source" => source,
        "found" => found, "builtin" => name == provider.executable, "shadowed" => shadowed
      }
    end
  end
end
