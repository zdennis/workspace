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
    def initialize(config:, project_config:, tmux:, state:, project_catalog_factory:, old:, new:, session:, new_session:)
      @config = config
      @project_config = project_config
      @tmux = tmux
      @state = state
      @project_catalog_factory = project_catalog_factory
      @old = old
      @new = new
      @session = session
      @new_session = new_session
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
      step.call("marker") { rewrite_marker }
      # A config under the new name means done, so it waits until every other
      # step went through, and the next call tries the failed ones again.
      if outcome.failed.empty?
        step.call("tmuxinator_config") { rewrite_config }
      else
        outcome.warnings << "#{old}: tmuxinator_config not renamed until the steps above succeed; the next agentd start tries again (a name already taken has to be cleared by hand)"
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

    # Rewrites a marker that names the old workspace, in any case.
    def rewrite_marker
      root = @project_config.project_root_for(@old)
      return nil unless root.is_a?(String) && !root.empty?

      path = File.join(File.expand_path(root), WorkspaceLineage::MARKER_FILE)
      return nil unless File.file?(path)

      content = File.read(path).strip
      return nil unless content.casecmp?(@old) && content != @new

      write_through_temp(path, @new)
      [@old, @new]
    end

    # Rewrites the session name where the templates put it (the `name:` line,
    # `tmux ... -t <session>:` targets, the `workspace-<session>` window) and
    # the config's own path on its first line. The `root:` line and other text
    # keep their case.
    def rewrite_config
      old = @old
      new = @new
      new_session = @new_session
      from = @config.config_path_for(old)
      to = @config.config_path_for(new)
      return nil unless listed?(from)
      raise Conflict, "#{to} already exists" if listed?(to)

      quoted = Regexp.escape(@session)
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
