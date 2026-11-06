require "digest"
require "yaml"

module Workspace
  # Finds workflow definitions by id: for a project, a file in the user's
  # `~/.config/workspace/projects/NAME/workflows/` first, then
  # `~/.config/workspace/workflows/`, then the presets that ship with workspace
  # (`lib/workflows/`). A file of the same id in an earlier directory replaces a
  # later one, which is how a preset is changed: copy it there and edit it.
  #
  # Definitions are read only from the user's config and the install, never from a
  # repository: a step's `status:` is a shell command, so a checked-in file would let
  # a branch or a fork run code on the developer's machine. Every reader takes the
  # `project:` it works for, or nil for the user directory and presets alone.
  class WorkflowCatalog
    # Where a definition can come from, in the order they are searched.
    SOURCES = %w[project global builtin].freeze

    # The project a workspace's definitions come from: the parent project of a worktree
    # workspace (the rule {Workspace::ConfigResolver} reads project settings by), else the
    # workspace itself.
    #
    # @param workspace [String, nil]
    # @return [String, nil]
    def self.project_of(workspace)
      return nil if workspace.nil? || workspace.to_s.empty?
      WorkspaceLineage.split_worktree_name(workspace.to_s)&.first || workspace.to_s
    end

    # @param config [Workspace::Config] names the directories
    # @param globber [#call] lists the paths matching a glob pattern, as +Dir.glob+ does
    def initialize(config:, globber: Dir.method(:glob))
      @config = config
      @globber = globber
    end

    # @param id [String] the workflow's id
    # @param project [String, nil] the project whose definitions come first
    # @return [Workspace::WorkflowDefinition]
    # @raise [Workspace::Error] code `unknown_workflow` when no file has that id,
    #   `invalid_workflow` when its file doesn't pass the checks
    def find(id, project: nil)
      source, path = locate(id.to_s, project: project)
      raise_unknown(id, project) unless path
      WorkflowDefinition.parse(File.read(path, encoding: Encoding::UTF_8), id: id.to_s, source: source, path: path, parent_lookup: lookup_for(project))
    end

    # The file an id is read from: the project's, else a user's, else a preset.
    #
    # @param id [String]
    # @param project [String, nil]
    # @return [Array(String, String), nil] "project", "global" or "builtin" and the path, or nil when no file has that id
    #   (including an id that could not be a file name)
    def locate(id, project: nil)
      return nil unless WorkflowDefinition::ID_PATTERN.match?(id)
      dirs(project).each do |source, dir|
        path = File.join(dir, "#{id}.yml")
        return [source, path] if File.file?(path)
      end
      nil
    end

    # Whether a file has this id, valid or not, so `find` reaches it (and its
    # `invalid_workflow`). A ticket key, `#12` or a URL is never an id.
    #
    # @param id [String]
    # @param project [String, nil] the project whose definitions are searched too
    # @return [Boolean]
    def known?(id, project: nil)
      !locate(id.to_s, project: project).nil?
    end

    # Every id a file answers to, sorted; leaves out a `.yml` entry no id finds.
    #
    # @param project [String, nil] the project whose definitions are searched too
    # @return [Array<String>]
    def known_ids(project: nil)
      ids(project).select { |each| locate(each, project: project) }
    end

    # The file an `extends:` names, for a definition to read as its parent: the project's, then a user's, then a preset.
    #
    # @param id [String]
    # @param below [String, nil] the source of the definition asking when it has this same id ("project", "global", "builtin"; "file" and "stdin" count as "global", where they would be installed): only sources after it are searched, so a user's `rpiv` can extend the preset `rpiv` and a project's `rpiv` the user's or the preset
    # @param project [String, nil] the project whose definitions are searched first
    # @return [Hash{String=>String}, nil] "text", "path" and "source", or nil when no file has that id or it can't be read
    def parent(id, below: nil, project: nil)
      return nil unless WorkflowDefinition::ID_PATTERN.match?(id.to_s)
      all = dirs(project)
      names = all.keys
      names = names.drop(names.index(all.key?(below) ? below : "global") + 1) if below
      source = names.find { |each| File.file?(File.join(all.fetch(each), "#{id}.yml")) }
      return nil unless source
      path = File.join(all.fetch(source), "#{id}.yml")
      {"text" => File.read(path, encoding: Encoding::UTF_8), "path" => path, "source" => source}
    rescue SystemCallError
      nil
    end

    # The definitions, other than +id+ itself, that extend it, directly or through others: the ones a change to the
    # user's or the preset's +id+ reaches. Every project's directory is scanned, whatever the caller's project, since
    # the change reaches them all; a project's own definition of +id+ shields that project unless it extends +id+, which reads the user's or the preset's one. An unreadable project directory is left out. A definition that is not
    # valid is still named when its file says what it extends; one that can't be read or parsed is left out.
    #
    # @param id [String]
    # @return [Array<String>] the ids of the user's and the presets' definitions, sorted, then `ID (project NAME)` for each project's own
    def extended_by(id)
      found = children_of(id.to_s, nil)
      project_names.each do |name|
        own = locate(id.to_s, project: name)&.first == "project"
        next if own && declared_parent(id.to_s, name) != id.to_s
        names = children_of(id.to_s, name).select { |child| locate(child, project: name)&.first == "project" }
        names.unshift(id.to_s) if own
        found += names.map { |child| "#{child} (project #{name})" }
      end
      found
    end

    # Which directory a definition file sits in, for a file read by path (`validate`).
    #
    # @param path [String]
    # @param project [String, nil]
    # @return [String, nil] "project", "global", "builtin", or nil when it is in none
    def scope_of(path, project: nil)
      dir = File.dirname(File.expand_path(path))
      dirs(project).find { |_, each| File.expand_path(each) == dir }&.first
    end

    # Where a user's file of this id is (or would be) written.
    #
    # @param id [String]
    # @return [String]
    # @raise [Workspace::Error] code `invalid_workflow` when the id could not be a file name
    def global_path(id)
      unless WorkflowDefinition::ID_PATTERN.match?(id.to_s)
        problem = "the workflow id #{id.to_s[0, 60].inspect} must be #{WorkflowDefinition::ID_RULE}"
        raise Workspace::Error.new(problem, code: "invalid_workflow", details: {"workflow" => id.to_s[0, 60], "problems" => [problem]})
      end
      File.join(dirs.fetch("global"), "#{id}.yml")
    end

    # One definition's file as the bytes say, valid or not: for a reader that
    # loads a broken file into an editor. Never raises `invalid_workflow`.
    #
    # @param id [String]
    # @param project [String, nil]
    # @return [Hash{String=>Object}] "source", "project", "path", "text" (nil when the bytes are not UTF-8),
    #   "sha256" (of the raw bytes) and "problems" (empty when valid)
    # @raise [Workspace::Error] code `unknown_workflow` when no file has that id
    def source(id, project: nil)
      found, path = locate(id.to_s, project: project)
      raise_unknown(id, project) unless path
      read_file(id.to_s, found, path, project)
    end

    # Every definition visible, a project's file hiding a user's and a user's hiding the
    # preset of the same id. A file that doesn't pass the checks is still listed, with its
    # problems; so is a `.yml` entry that can't be a definition (a name that
    # is not an id, or a directory), which no id finds.
    #
    # @param project [String, nil]
    # @return [Array<Hash{String=>Object}>] "id", "title", "description", "use_when", "applies_to", "source" ("project", "global" or "builtin"),
    #   "project" (the project's name for a project definition, else nil), "path",
    #   "sha256" and "problems" (empty when valid), sorted by id
    def list(project: nil)
      ids(project).filter_map do |id|
        source, path = locate(id, project: project)
        next unusable(id, project) unless path
        begin
          read = read_file(id, source, path, project)
        rescue SystemCallError => e
          next summary(id, source, path, project).merge("problems" => ["can't be read (#{e.class})"])
        end
        row = summary(id, source, path, project).merge("sha256" => read["sha256"], "problems" => read["problems"])
        next row unless read["problems"].empty?
        data = WorkflowDefinition.parse(read["text"], id: id, source: source, path: path, parent_lookup: lookup_for(project)).to_h
        row.merge("title" => data["title"], "description" => data["description"], "use_when" => data["use_when"], "applies_to" => data["applies_to"])
      end
    end

    private

    # The names of the directories that hold workflows under the user's config (a name that could not be a project
    # has no directory in {#dirs}, so it reads as empty).
    def project_names
      Dir.glob(File.join(@config.workspace_projects_dir, "*", "workflows")).map { |dir| File.basename(File.dirname(dir)) }.sort
    end

    # Ids, sorted, whose definition (as +project+ sees it) extends +id+, directly or through others.
    def children_of(id, project)
      parent_of = ids(project).reject { |other| other == id }.to_h { |other| [other, declared_parent(other, project)] }
      found = []
      queue = [id]
      until queue.empty?
        current = queue.shift
        parent_of.each do |other, parent|
          next unless parent == current && !found.include?(other)
          found << other
          queue << other
        end
      end
      found.sort
    end

    # What the effective file of +id+ says it extends, or nil when it says nothing or can't be read as YAML.
    def declared_parent(id, project = nil)
      _, path = locate(id, project: project)
      return nil unless path
      parsed = YAML.safe_load(File.read(path, encoding: Encoding::UTF_8))
      (parsed.is_a?(Hash) && parsed["extends"].is_a?(String)) ? parsed["extends"] : nil
    rescue
      nil
    end

    def lookup_for(project)
      ->(id, below: nil) { parent(id, below: below, project: project) }
    end

    def summary(id, source, path, project)
      {"id" => id, "title" => id, "description" => nil, "use_when" => nil, "applies_to" => [], "source" => source, "project" => (source == "project") ? project : nil, "path" => path, "sha256" => nil, "problems" => []}
    end

    def unusable(name, project)
      # A link to a file that is gone is still an entry of the directory, and `File.exist?` says no to it.
      source, path = dirs(project).map { |each, dir| [each, File.join(dir, "#{name}.yml")] }
        .find { |_, file| File.symlink?(file) || File.exist?(file) }
      # Removed since the directory was listed: nothing to list.
      return nil unless path
      problem = if File.symlink?(path) && !File.exist?(path)
        "#{path} is a link to a file that is not there"
      elsif WorkflowDefinition::ID_PATTERN.match?(name)
        "#{path} is not a file"
      else
        "the file's name must be a workflow id: #{WorkflowDefinition::ID_RULE}, at most 40 characters"
      end
      summary(name, source, path, project).merge("problems" => [problem])
    end

    # The directories searched, in order. A project name that could not be a directory name
    # under the config (see {Workspace::Config#project_workflows_dir}) has no directory.
    def dirs(project = nil)
      own = project && @config.project_workflows_dir(project)
      (own ? {"project" => own} : {}).merge("global" => @config.workflows_dir, "builtin" => @config.builtin_workflows_dir)
    end

    def ids(project = nil)
      dirs(project).values.flat_map { |dir| @globber.call(File.join(dir, "*.yml")).map { |path| File.basename(path, ".yml") } }.uniq.sort
    end

    def raise_unknown(id, project = nil)
      known = known_ids(project: project)
      raise Workspace::Error.new("No workflow named #{id.to_s[0, 60].inspect}. Known: #{known.join(", ")}.",
        code: "unknown_workflow", details: {"workflow" => id.to_s[0, 60], "known" => known})
    end

    # The one read of a definition file: binary, the digest of its raw bytes, its text (nil
    # unless UTF-8) and the problems a parse finds.
    def read_file(id, source, path, project = nil)
      bytes = File.binread(path)
      text = bytes.dup.force_encoding(Encoding::UTF_8)
      text = nil unless text.valid_encoding?
      problems = begin
        WorkflowDefinition.parse(bytes.dup.force_encoding(Encoding::UTF_8), id: id, source: source, path: path, parent_lookup: lookup_for(project))
        []
      rescue Workspace::Error => e
        e.details["problems"] || [e.message]
      end
      {"source" => source, "project" => (source == "project") ? project : nil, "path" => path, "text" => text, "sha256" => Digest::SHA256.hexdigest(bytes), "problems" => problems}
    end
  end
end
