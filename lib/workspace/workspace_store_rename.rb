require "fileutils"

module Workspace
  # Renames the things keyed on one workspace's name, from +old+ to +new+: its
  # tmux session, project settings file, daemon run files, state directory,
  # inbox files, key in the state file, `.workspace-project` marker and, last,
  # its tmuxinator config. The two names may differ in more than case.
  #
  # A step that fails is a warning and the next step still runs; a target name
  # already taken is left alone and warned about. The tmuxinator config is
  # rewritten last, and held back while any other step failed, so a config
  # under the new name means done and a retry finishes the failed steps.
  #
  # macOS file systems ignore case, so `File.exist?` can't tell `Notes` from
  # `notes`: names are checked against directory listings, and a rename that
  # changes only case goes through a temporary name.
  class WorkspaceStoreRename
    # @!attribute renamed [Array<Hash>] `{"what", "from", "to"}` for each step that moved something
    # @!attribute failed [Array<String>] the steps that raised
    # @!attribute warnings [Array<String>] one line per failed step, plus the held-back config
    Outcome = Struct.new(:renamed, :failed, :warnings, keyword_init: true)

    # The retry hint of the held-back config warning: what the daemon-driven rename does.
    DEFAULT_RETRY_HINT = "the next agentd start tries again (a name already taken has to be cleared by hand)"

    # A target name that is already taken.
    class Conflict < Workspace::Error; end

    # Whether the directory listing holds this exact name; on a file system
    # that ignores case, File.exist? would also find a name that differs in case.
    #
    # @param path [String]
    # @return [Boolean]
    def self.listed?(path)
      dir = File.dirname(path)
      Dir.exist?(dir) && Dir.children(dir).include?(File.basename(path))
    end

    # @param config [Workspace::Config]
    # @param project_config [Workspace::ProjectConfig] reads a config's root
    # @param tmux [Workspace::Tmux] reads and renames sessions
    # @param state [Workspace::State] the state file whose key is renamed
    # @param project_catalog_factory [#call] builds a fresh {Workspace::ProjectCatalog}, for the project inbox file
    # @param old [String] the workspace's current name
    # @param new [String] the name it gets
    # @param session [String] the tmux session name now
    # @param new_session [String] the tmux session name it gets
    # @param root [String, nil] the config's new `root:`; nil keeps the line as it is
    # @param branch [String, nil] the branch the worktree template's banner line names now
    # @param new_branch [String, nil] the branch it gets; nil keeps that line as it is
    # @param display [String, nil] the banner text (`ascii-banner "..."`) now
    # @param new_display [String, nil] the banner text it gets; nil keeps the banner as it is
    # @param retry_hint [String] what the held-back config warning says about trying again
    def initialize(config:, project_config:, tmux:, state:, project_catalog_factory:, old:, new:, session:, new_session:,
      root: nil, branch: nil, new_branch: nil, display: nil, new_display: nil,
      retry_hint: DEFAULT_RETRY_HINT)
      @config = config
      @project_config = project_config
      @tmux = tmux
      @state = state
      @project_catalog_factory = project_catalog_factory
      @old = old
      @new = new
      @session = session
      @new_session = new_session
      @root = root
      @branch = branch
      @new_branch = new_branch
      @display = display
      @new_display = new_display
      @retry_hint = retry_hint
    end

    # Runs every step. Never raises for a failed step.
    #
    # @return [Outcome]
    def call
      old = @old
      new = @new
      outcome = Outcome.new(renamed: [], failed: [], warnings: [])
      step = lambda do |what, &block|
        moved = block.call
        outcome.renamed << {"what" => what, "from" => moved[0], "to" => moved[1]} if moved
      rescue SystemCallError, IOError, Workspace::Error => e
        outcome.failed << what
        outcome.warnings << "#{old}: #{what} not renamed (#{e.message})"
      end

      step.call("tmux_session") { rename_session }
      step.call("project_settings") { move(@config.project_config_path(old), @config.project_config_path(new)) }
      step.call("socket") { move(@config.agent_socket_path(old), @config.agent_socket_path(new)) }
      step.call("log") { move(@config.agent_log_path(old), @config.agent_log_path(new)) }
      # Only tidies away an old lock file: the startup lock is keyed on the
      # lowercase name, so for a long name (whose file name carries a hash of
      # the name) the caller's lock file already exists and the old one is left.
      step.call("lock") { move(@config.agent_lock_path(old), @config.agent_lock_path(new), keep_if_taken: true) }
      step.call("state_dir") { move(@config.pipeline_state_dir(old), @config.pipeline_state_dir(new)) }
      step.call("inbox") { move(@config.inbox_path("workspace", old), @config.inbox_path("workspace", new)) }
      step.call("project_inbox") { move_project_inbox }
      step.call("state") { rename_state_key }
      step.call("marker") { rewrite_marker(outcome) }
      # A config under the new name means done, so it waits until every other
      # step went through, and the next call tries the failed ones again.
      if outcome.failed.empty?
        step.call("tmuxinator_config") { rewrite_config }
      else
        outcome.warnings << "#{old}: tmuxinator_config not renamed until the steps above succeed; #{@retry_hint}"
      end
      outcome
    end

    private

    def rename_session
      session = @session
      new_session = @new_session
      return nil if session == new_session
      return nil unless @tmux.session_exists?(session, project: @old)
      raise Conflict, "a tmux session named #{new_session} already exists" if @tmux.session_exists?(new_session, project: @old)
      raise Workspace::Error, "tmux rename-session failed" unless @tmux.rename_session(session, new_session, project: @old)

      [session, new_session]
    end

    # The project's inbox file is named for the project, which is the name of
    # the workspace at its main checkout, so only that workspace renames it.
    def move_project_inbox
      old = @old
      new = @new
      project = @project_catalog_factory.call.all.find { |candidate| candidate.name == old }
      return nil unless project

      new_id = (project.id == "workspace:#{old}") ? "workspace:#{new}" : project.id
      move(@config.inbox_path("project", project.id, name: old), @config.inbox_path("project", new_id, name: new))
    end

    def rename_state_key
      old = @old
      new = @new
      entries = @state.load.to_h
      return nil unless entries.key?(old)
      raise Conflict, "the state file already has #{new}" if entries.key?(new)

      value = @state[old]
      @state[new] = value
      @state.delete(old)
      @state.save
      [old, new]
    end

    # Rewrites a marker that names the old workspace, in any case. A marker
    # that names neither the old nor the new name stays as it is, with a warning
    # when a new root was given; the lowercase migration gives none and stays silent.
    # The marker is looked for in the new root first, for a checkout that moved.
    def rewrite_marker(outcome)
      old_root = @project_config.project_root_for(@old)
      roots = [@root, old_root].select { |root| root.is_a?(String) && !root.empty? }.uniq
      path = roots.map { |root| File.join(File.expand_path(root), WorkspaceLineage::MARKER_FILE) }.find { |candidate| File.file?(candidate) }
      return nil unless path

      content = File.read(path).strip
      return nil if content == @new
      unless content.casecmp?(@old)
        outcome.warnings << "#{@old}: marker #{path} names #{content.inspect}, neither #{@old} nor #{@new}; left as it is" if @root
        return nil
      end

      write_through_temp(path, @new)
      [@old, @new]
    end

    # Rewrites the names where the templates put them: the `name:` line, the
    # `tmux ... -t <session>:` and `-t '=<session>:'` targets, the
    # `workspace-<session>` window and title, `@workspace`, the "Ready to work
    # on" line, the config's own path on its first line, and, when given, the
    # `root:` line, the banner and the worktree line's branch. Each name is
    # matched whole, so `feat` does not touch `feat-2`. Other text keeps its case.
    def rewrite_config
      old = @old
      new = @new
      new_session = @new_session
      from = @config.config_path_for(old)
      to = @config.config_path_for(new)
      return nil unless listed?(from)
      raise Conflict, "#{to} already exists" if listed?(to)

      session = Regexp.escape(@session)
      name = Regexp.escape(old)
      text = File.read(from).each_line.with_index.map do |line, index|
        line = line.sub("workspace.#{old}.yml", "workspace.#{new}.yml") if index.zero? && line.start_with?("#")
        next line.sub(/\A(name:\s*)#{session}(?=\s*\z)/) { "#{$1}#{new_session}" } if line.start_with?("name:")
        next line.sub(/\A(root:\s*).*?(?=\s*\z)/) { "#{$1}#{@root}" } if line.start_with?("root:") && @root
        next line if line.match?(/\A\s*root:/)

        # One pass over both forms: a new session such as `workspace-a` must not be matched again.
        line = line.gsub(/(-t\s+['"]?=?)#{session}(?=:)|(?<![\w.-])(workspace-)#{session}(?![\w.-])/) { "#{$1 || $2}#{new_session}" }
          .gsub(/(@workspace\s+)#{name}(?![\w.-])/) { "#{$1}#{new}" }
          .sub(/(echo 'Ready to work on )#{name}(?=')/) { "#{$1}#{new}" }
        line = line.sub(/(ascii-banner ")#{Regexp.escape(@display)}(?=")/) { "#{$1}#{@new_display}" } if @display && @new_display
        line = line.sub(/(Worktree — )#{Regexp.escape(@branch)}(?= \()/) { "#{$1}#{@new_branch}" } if @branch && @new_branch
        line
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

    def listed?(path)
      self.class.listed?(path)
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
