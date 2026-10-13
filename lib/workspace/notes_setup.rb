module Workspace
  # Fixes a new workspace's notes directory: writes the path the resolver computes as
  # the workspace's own `notes.dir`, so a later change to the project's
  # `notes.default_dir` rule does not move its notes, then makes the directory and, when
  # it is inside the checkout, lists it in `info/exclude`. `start` and `add` call it.
  #
  # It never raises for a problem with the setup itself: each one comes back as a
  # warning, because notes are not worth a failed start.
  class NotesSetup
    # @param notes [Workspace::Commands::Notes] answers which directory a workspace's notes use
    # @param project_settings [Workspace::ProjectSettings] reads and writes the workspace's own config
    def initialize(notes:, project_settings:)
      @notes = notes
      @project_settings = project_settings
    end

    # @param workspace [String] the workspace's full name, e.g. "api.worktree-x"
    # @return [Hash] `"dir"` (the absolute directory, nil when it could not be worked out)
    #   and `"warnings"` (a list of sentences, empty when all went well)
    def call(workspace)
      path = @notes.info(name: workspace)["dir"]
      warnings = []
      store(workspace, path, warnings) if WorkspaceLineage.split_worktree_name(workspace)
      create(workspace, path, warnings)
      {"dir" => path, "warnings" => warnings}
    rescue Workspace::Error, SystemCallError => e
      {"dir" => nil, "warnings" => ["Warning: could not set up the notes directory for #{workspace}: #{e.message}"]}
    end

    private

    # Only a `<project>.worktree-<dir>` name is pinned: a config `add` names after the
    # directory has no parent project to take a rule from, so its default stays the default.
    # A `notes.dir` already in the file, valid or not, is the person's and stays.
    def store(workspace, path, warnings)
      @project_settings.ensure_exists(workspace)
      data = @project_settings.load(workspace)
      notes = data["notes"]
      return if notes && !(notes.is_a?(Hash) && notes["dir"].nil?)
      data["notes"] = (notes || {}).merge("dir" => path)
      @project_settings.save(workspace, data)
    rescue Workspace::Error, SystemCallError => e
      warnings << "Warning: could not record the notes directory #{path} in the config of #{workspace}: #{e.message}"
    end

    def create(workspace, path, warnings)
      @notes.info(name: workspace, create: true)
    rescue Workspace::Error, SystemCallError => e
      warnings << "Warning: could not finish setting up the notes directory for #{workspace} (#{path}): #{e.message}"
    end
  end
end
