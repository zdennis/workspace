require "fileutils"

module Workspace
  # Renames a workspace written with a mixed-case name (`Notes`) to its
  # lowercase name (`notes`), with everything keyed on the name: the live tmux
  # session, the project settings file, the daemon's run files, its state
  # directory, its inbox files, its key in the state file, its
  # `.workspace-project` marker and, last, its tmuxinator config. A project's
  # worktree workspaces (`<project>.worktree-<dir>`) are renamed with it, except
  # one whose own agent daemon is running or starting; that one is renamed when
  # its daemon next starts.
  #
  # The caller holds the workspace's agent startup lock, with no daemon running.
  # The tmuxinator config is renamed last, and only after every other step went
  # through, so a workspace whose config is already lowercase is done, a second
  # call does nothing, and one with a failed step is tried again next time. A step that fails
  # is a warning and the next step still runs; a target name already taken is
  # left alone and warned about.
  #
  # macOS file systems ignore case, so `File.exist?` can't tell `Notes` from
  # `notes`: names are checked against directory listings, and a rename that
  # changes only case goes through a temporary name.
  class NameMigration
    # @!attribute name [String] the lowercase name the workspace has now
    # @!attribute from [String, nil] the mixed-case name it had; nil when there was nothing to rename
    # @!attribute renamed [Array<Hash>] `{"what", "from", "to"}` for each rename, worktrees included
    # @!attribute warnings [Array<String>] the steps that failed or were skipped
    Result = Struct.new(:name, :from, :renamed, :warnings, keyword_init: true)

    # A target name that is already taken (see {WorkspaceStoreRename::Conflict}).
    Conflict = WorkspaceStoreRename::Conflict

    # A startup lock in {#with_locks} that could not be taken; errors from its block pass as they are.
    class LockUnavailable < StandardError; end

    # @param config [Workspace::Config]
    # @param project_config [Workspace::ProjectConfig] reads a config's root
    # @param tmux [Workspace::Tmux] reads and renames sessions
    # @param state [Workspace::State] the state file whose key is renamed
    # @param event_log [Workspace::EventLog, nil] gets a `workspace_renamed` line per renamed workspace
    # @param project_catalog_factory [#call] builds a fresh {Workspace::ProjectCatalog}, for the project inbox file
    # @param writer [Workspace::TmuxinatorConfigWriter, nil] carries each config's render record; nil builds one over +config+
    def initialize(config:, project_config:, tmux:, state:, event_log:, project_catalog_factory:, writer: nil)
      @config = config
      @writer = writer || TmuxinatorConfigWriter.new(config: config)
      @project_config = project_config
      @tmux = tmux
      @state = state
      @event_log = event_log
      @project_catalog_factory = project_catalog_factory
    end

    # Renames the workspace; the caller holds its startup lock (keyed on the
    # lowercase name) with no daemon running. Never raises: what could not be
    # done is in the result's warnings. The rename and each warning are also
    # appended to the daemon log, under the new name.
    #
    # @param name [String] the workspace name, in any case
    # @return [Result]
    def call(name)
      lowercase = WorkspaceName.normalize(name)
      renamed = []
      warnings = []
      begin
        from = mixed_case_configs.find { |config| WorkspaceName.normalize(config) == lowercase }
        migrate(from, renamed, warnings) if from
        migrate_worktrees(lowercase, renamed, warnings) unless WorkspaceName.split(lowercase)
      rescue SystemCallError, IOError, Workspace::Error => e
        warnings << "#{name}: renaming to #{lowercase} did not finish (#{e.message})"
      end
      Result.new(name: lowercase, from: from, renamed: renamed, warnings: warnings).tap { |result| write_log(result) }
    end

    # {#call} under the workspace's startup lock, when no daemon answers for it.
    #
    # @param name [String] the workspace name, in any case
    # @param wait [Boolean] wait for the lock; false gives up at once when another process holds it
    # @return [Result, nil] nil when the lock was held elsewhere (with +wait+ false), a daemon
    #   answers, or the lock file can't be opened
    def call_locked(name, wait: true)
      with_lock(name, wait: wait) { call(name) }
    end

    # The startup lock {Commands::EnsureAgent} and the agent daemon take: keyed on
    # the lowercase name, so every spelling of a name shares one lock file.
    #
    # @param name [String] the workspace name, in any case
    # @return [String]
    def lock_path(name)
      @config.agent_lock_path(WorkspaceName.normalize(name))
    end

    # Waits for the startup locks of several names, in sorted order so two callers never deadlock,
    # and holds them around the block.
    #
    # @param names [Array<String>] workspace names, in any case
    # @yield with every lock held
    # @return [Object] the block's value
    # @raise [LockUnavailable] when a lock file can't be opened or locked
    def with_locks(*names)
      files = []
      begin
        names.map { |name| lock_path(name) }.uniq.sort.each do |path|
          files << File.open(path, File::RDWR | File::CREAT, 0o600)
          files.last.flock(File::LOCK_EX)
        end
      rescue SystemCallError => e
        raise LockUnavailable, e.message
      end
      yield
    ensure
      files.each(&:close)
    end

    private

    # @return [Object, nil] the block's value; nil when the lock is taken elsewhere or the daemon answers
    def with_lock(name, wait:)
      File.open(lock_path(name), File::RDWR | File::CREAT, 0o600) do |file|
        return nil unless file.flock(wait ? File::LOCK_EX : File::LOCK_EX | File::LOCK_NB)
        return nil if @config.agent_running?(name) || @config.agent_running?(WorkspaceName.normalize(name))

        yield
      end
    rescue SystemCallError, Workspace::Error
      nil
    end

    def write_log(result)
      return if result.from.nil? && result.warnings.empty?

      File.open(@config.agent_log_path(result.name), "a") do |log|
        log.puts "workspace agent: renamed workspace '#{result.from}' to '#{result.name}'" if result.from
        result.warnings.each { |warning| log.puts "Warning: #{warning}" }
      end
    rescue SystemCallError, IOError, Workspace::Error
      nil
    end

    def mixed_case_configs
      dir = @config.tmuxinator_dir
      return [] unless Dir.exist?(dir)

      Dir.children(dir).sort.filter_map do |entry|
        next unless entry.start_with?("workspace.") && entry.end_with?(".yml")

        name = entry.delete_prefix("workspace.").delete_suffix(".yml")
        name if WorkspaceName.mixed_case?(name) && !name.match?(/^project-.*template$/)
      end
    end

    def migrate_worktrees(project, renamed, warnings)
      mixed_case_configs.each do |worktree|
        split = WorkspaceName.split(worktree)
        next unless split && WorkspaceName.normalize(split.first) == project

        unless with_lock(worktree, wait: false) { migrate(worktree, renamed, warnings) || true }
          warnings << "#{worktree}: its agent daemon is running or starting; it is renamed when that daemon next starts"
        end
      end
    end

    def migrate(old, renamed, warnings)
      new = WorkspaceName.normalize(old)
      session = @tmux.session_name_for(old)
      outcome = WorkspaceStoreRename.new(config: @config, project_config: @project_config, tmux: @tmux, state: @state,
        project_catalog_factory: @project_catalog_factory, old: old, new: new, session: session, new_session: WorkspaceName.normalize(session), writer: @writer).call
      warnings.concat(outcome.warnings)
      renamed.concat(outcome.renamed)
      # Names only, never paths or messages, like every lifecycle event.
      @event_log&.record(type: "workspace_renamed", project: new,
        data: {"workspace" => new, "from" => old, "renamed" => outcome.renamed.map { |entry| entry["what"] }, "failed" => outcome.failed})
    end
  end
end
