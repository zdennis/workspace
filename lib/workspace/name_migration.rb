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

    # A target name that is already taken.
    class Conflict < Workspace::Error; end

    # @param config [Workspace::Config]
    # @param project_config [Workspace::ProjectConfig] reads a config's root
    # @param tmux [Workspace::Tmux] reads and renames sessions
    # @param state [Workspace::State] the state file whose key is renamed
    # @param event_log [Workspace::EventLog, nil] gets a `workspace_renamed` line per renamed workspace
    # @param project_catalog_factory [#call] builds a fresh {Workspace::ProjectCatalog}, for the project inbox file
    def initialize(config:, project_config:, tmux:, state:, event_log:, project_catalog_factory:)
      @config = config
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
        from = mixed_case_configs.find { |config| config.downcase == lowercase }
        migrate(from, renamed, warnings) if from
        migrate_worktrees(lowercase, renamed, warnings) unless WorkspaceLineage.split_worktree_name(lowercase)
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
        name if name != name.downcase && !name.match?(/^project-.*template$/)
      end
    end

    def migrate_worktrees(project, renamed, warnings)
      mixed_case_configs.each do |worktree|
        split = WorkspaceLineage.split_worktree_name(worktree)
        next unless split && split.first.downcase == project

        unless with_lock(worktree, wait: false) { migrate(worktree, renamed, warnings) || true }
          warnings << "#{worktree}: its agent daemon is running or starting; it is renamed when that daemon next starts"
        end
      end
    end

    def migrate(old, renamed, warnings)
      new = old.downcase
      session = @tmux.session_name_for(old)
      new_session = session.downcase
      own_renamed = []
      failed = []
      step = lambda do |what, &block|
        moved = block.call
        own_renamed << {"what" => what, "from" => moved[0], "to" => moved[1]} if moved
      rescue SystemCallError, IOError, Workspace::Error => e
        failed << what
        warnings << "#{old}: #{what} not renamed (#{e.message})"
      end

      step.call("tmux_session") { rename_session(old, session, new_session) }
      step.call("project_settings") { move(@config.project_config_path(old), @config.project_config_path(new)) }
      step.call("socket") { move(@config.agent_socket_path(old), @config.agent_socket_path(new)) }
      step.call("log") { move(@config.agent_log_path(old), @config.agent_log_path(new)) }
      # Only tidies away an old mixed-case lock file: the startup lock is keyed on
      # the lowercase name, so for a long name (whose file name carries a hash of
      # the name) the caller's lock file already exists and the old one is left.
      step.call("lock") { move(@config.agent_lock_path(old), @config.agent_lock_path(new), keep_if_taken: true) }
      step.call("state_dir") { move(@config.pipeline_state_dir(old), @config.pipeline_state_dir(new)) }
      step.call("inbox") { move(@config.inbox_path("workspace", old), @config.inbox_path("workspace", new)) }
      step.call("project_inbox") { move_project_inbox(old, new) }
      step.call("state") { rename_state_key(old, new) }
      step.call("marker") { rewrite_marker(old, new) }
      # A lowercase config means done, so it waits until every other step went
      # through, and the next start tries the failed ones again.
      if failed.empty?
        step.call("tmuxinator_config") { rewrite_config(old, new, session, new_session) }
      else
        warnings << "#{old}: tmuxinator_config not renamed until the steps above succeed; the next agentd start tries again (a name already taken has to be cleared by hand)"
      end

      renamed.concat(own_renamed)
      # Names only, never paths or messages, like every lifecycle event.
      @event_log&.record(type: "workspace_renamed", project: new,
        data: {"workspace" => new, "from" => old, "renamed" => own_renamed.map { |entry| entry["what"] }, "failed" => failed})
    end

    def rename_session(config_name, session, new_session)
      return nil if session == new_session
      return nil unless @tmux.session_exists?(session, project: config_name)
      raise Conflict, "a tmux session named #{new_session} already exists" if @tmux.session_exists?(new_session, project: config_name)
      raise Workspace::Error, "tmux rename-session failed" unless @tmux.rename_session(session, new_session, project: config_name)

      [session, new_session]
    end

    # The project's inbox file is named for the project, which is the name of
    # the workspace at its main checkout, so only that workspace renames it.
    def move_project_inbox(old, new)
      project = @project_catalog_factory.call.all.find { |candidate| candidate.name == old }
      return nil unless project

      new_id = (project.id == "workspace:#{old}") ? "workspace:#{new}" : project.id
      move(@config.inbox_path("project", project.id, name: old), @config.inbox_path("project", new_id, name: new))
    end

    def rename_state_key(old, new)
      entries = @state.load.to_h
      return nil unless entries.key?(old)
      raise Conflict, "the state file already has #{new}" if entries.key?(new)

      value = @state[old]
      @state[new] = value
      @state.delete(old)
      @state.save
      [old, new]
    end

    def rewrite_marker(old, new)
      root = @project_config.project_root_for(old)
      return nil unless root.is_a?(String) && !root.empty?

      path = File.join(File.expand_path(root), WorkspaceLineage::MARKER_FILE)
      return nil unless File.file?(path)

      content = File.read(path).strip
      return nil unless content.casecmp?(new) && content != new

      write_through_temp(path, new)
      [old, new]
    end

    # Rewrites the session name where the templates put it (the `name:` line,
    # `tmux ... -t <session>:` targets, the `workspace-<session>` window) and
    # the config's own path on its first line. The `root:` line and other text
    # keep their case.
    def rewrite_config(old, new, session, new_session)
      from = @config.config_path_for(old)
      to = @config.config_path_for(new)
      return nil unless listed?(from)
      raise Conflict, "#{to} already exists" if listed?(to)

      quoted = Regexp.escape(session)
      text = File.read(from).each_line.with_index.map do |line, index|
        line = line.sub("workspace.#{old}.yml", "workspace.#{new}.yml") if index.zero? && line.start_with?("#")
        next line.sub(/\A(name:\s*)#{quoted}(?=\s*\z)/) { "#{$1}#{new_session}" } if line.start_with?("name:")
        next line if line.match?(/\A\s*root:/)

        line.gsub(/(-t\s+)#{quoted}(?=:)/) { "#{$1}#{new_session}" }.gsub(/workspace-#{quoted}(?![\w.-])/, "workspace-#{new_session}")
      end.join

      # Between the two renames no config exists for a moment; the daemon's
      # startup lock is held, and `launch` takes it too.
      dir = File.dirname(from)
      staged = File.join(dir, ".workspace.#{new}.yml.#{Process.pid}.tmp")
      held = File.join(dir, ".workspace.#{old}.yml.#{Process.pid}.old")
      File.write(staged, text)
      File.chmod(File.stat(from).mode & 0o7777, staged)
      File.rename(from, held)
      begin
        File.rename(staged, to)
      rescue SystemCallError
        File.rename(held, from)
        raise
      end
      File.delete(held)
      [from, to]
    ensure
      File.delete(staged) if staged && File.exist?(staged)
    end

    # @param keep_if_taken [Boolean] leave +from+ alone, without a warning, when +to+ exists
    # @return [Array(String, String), nil] the paths, when +from+ was there and was moved
    def move(from, to, keep_if_taken: false)
      return nil if from == to || !listed?(from)
      if listed?(to)
        return nil if keep_if_taken
        raise Conflict, "#{to} already exists"
      end

      if File.dirname(from) == File.dirname(to) && File.basename(from).casecmp?(File.basename(to))
        temp = File.join(File.dirname(from), ".#{File.basename(from)}.#{Process.pid}.renaming")
        File.rename(from, temp)
        begin
          File.rename(temp, to)
        rescue SystemCallError
          File.rename(temp, from)
          raise
        end
      else
        File.rename(from, to)
      end
      [from, to]
    end

    # Whether the directory listing holds this exact name; on a file system
    # that ignores case, File.exist? would also find a name that differs in case.
    def listed?(path)
      dir = File.dirname(path)
      Dir.exist?(dir) && Dir.children(dir).include?(File.basename(path))
    end

    def write_through_temp(path, text)
      temp = "#{path}.#{Process.pid}.tmp"
      File.write(temp, text)
      File.rename(temp, path)
    ensure
      File.delete(temp) if temp && File.exist?(temp)
    end
  end
end
