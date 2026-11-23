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
    # Where a definition can come from, in the order they are searched. Each
    # `workflows.sources` entry is its own layer, "source:N" (N the 1-based position in
    # the list), between "global" and "builtin"; see {#ordered_sources}.
    SOURCES = %w[project global builtin].freeze

    # The project a workspace's definitions come from: the parent project of a worktree
    # workspace (the rule {Workspace::ConfigResolver} reads project settings by), else the
    # workspace itself.
    #
    # @param workspace [String, nil]
    # @return [String, nil]
    def self.project_of(workspace)
      return nil if workspace.nil? || workspace.to_s.empty?
      WorkspaceName.project_of(workspace.to_s)
    end

    # @param config [Workspace::Config] names the directories
    # @param sources [#call, nil] answers an Array with a directory per `workflows.sources` entry, in list order, nil for one not there; nil adds no source layer
    # @param globber [#call] lists the paths matching a glob pattern, as +Dir.glob+ does
    def initialize(config:, sources: nil, globber: Dir.method(:glob))
      @config = config
      @sources = sources
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
      WorkflowDefinition.parse(File.read(path, encoding: Encoding::UTF_8), id: id.to_s, source: source, path: path, parent_lookup: parent_lookup(project),
        import_lookup: import_lookup(project), confine_dir: confine_dir(source, project))
    end

    # Reads a definition from a file path (`--file`), the one way a path becomes a definition. The id is a string
    # `id:` in the file, else the file name without its extension when that is a workflow id, else
    # {IdPatterns::FILE_ID}; {#load_file!} is the variant a run uses, which refuses that last fallback. Its
    # `extends:` resolves through {#parent}, as for an installed definition. Nothing is installed or looked up
    # by id.
    #
    # @param path [String] the file; a relative path is expanded against the current directory
    # @param project [String, nil] the project whose definitions an `extends:` finds first
    # @return [Workspace::WorkflowDefinition] with source "file" and the absolute path
    # @raise [Workspace::UsageError] when the file can't be read
    # @raise [Workspace::Error] code `invalid_workflow` when it doesn't pass the checks
    def load_file(path, project: nil)
      full = File.expand_path(path.to_s)
      text = begin
        File.binread(full).force_encoding(Encoding::UTF_8)
      rescue SystemCallError => e
        raise UsageError, "Can't read #{path}: #{e.message.sub(/ (@ .*)?- .*\z/, "")}"
      end
      id = IdPatterns.claimed_id(text) || IdPatterns.file_id(full)
      layer = scope_of(full, project: project)
      WorkflowDefinition.parse(text, id: id, source: "file", path: full, parent_lookup: parent_lookup(project),
        import_lookup: import_lookup(project, file_layer: layer), confine_dir: layer && confine_dir(layer, project))
    end

    # Like {#load_file}, but refuses a definition whose id fell all the way back to {IdPatterns::FILE_ID}: a run
    # needs a name. `workflow start --file`, `workflow run --file` and `go --file` all read through this one
    # door, so they refuse the same file with the same words.
    #
    # @param path [String] the file; a relative path is expanded against the current directory
    # @param project [String, nil] the project whose definitions an `extends:` finds first
    # @return [Workspace::WorkflowDefinition] with source "file" and the absolute path
    # @raise [Workspace::UsageError] when the file can't be read, or names no id
    # @raise [Workspace::Error] code `invalid_workflow` when it doesn't pass the checks
    def load_file!(path, project: nil)
      definition = load_file(path, project: project)
      return definition unless definition.id == IdPatterns::FILE_ID

      raise UsageError, "#{path} has no workflow id: add an `id:` key to the YAML, or name the file after its id (ID.yml)."
    end

    # The file an id is read from: the project's, else a user's, else a preset.
    #
    # @param id [String]
    # @param project [String, nil]
    # @return [Array(String, String), nil] "project", "global", "source:N" or "builtin" and the path, or nil when no file has that id
    #   (including an id that could not be a file name)
    def locate(id, project: nil)
      return nil unless IdPatterns::WORKFLOW_ID.match?(id)
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
    # @return [Hash{String=>String}, nil] "text", "path", "source" and "confine_dir" (see {#confine_dir}), or nil when no file has that id or it can't be read
    def parent(id, below: nil, project: nil)
      return nil unless IdPatterns::WORKFLOW_ID.match?(id.to_s)
      all = dirs(project)
      names = all.keys
      names = names.drop(names.index(all.key?(below) ? below : "global") + 1) if below
      source = names.find { |each| File.file?(File.join(all.fetch(each), "#{id}.yml")) }
      return nil unless source
      path = File.join(all.fetch(source), "#{id}.yml")
      {"text" => File.read(path, encoding: Encoding::UTF_8), "path" => path, "source" => source, "confine_dir" => confine_dir(source, project)}
    rescue SystemCallError
      nil
    end

    # The step library file a bare-name `import:` names: the first `<layer>/steps/NAME.yml` from +layer+ down, +layer+
    # included, so a project's library shadows the user's for a project workflow while a user's never reaches a source
    # or a preset. A layer the catalog does not have ("file", "stdin", or "project" with no project) searches from the top.
    #
    # @param name [String] the library step's name
    # @param layer [String] the importing file's layer: "project", "global", "source:N" or "builtin"
    # @param project [String, nil] the project whose layer is on top
    # @return [Hash{String=>Object}] "path" (nil when no layer has the file), "layer" (where it was found), "searched"
    #   (each layer tried, in order, as "layer" and "path") and "shadows" (the lower layers' files of that name)
    def import_step(name, layer:, project: nil)
      found = {"path" => nil, "layer" => nil, "searched" => [], "shadows" => []}
      return found unless IdPatterns::WORKFLOW_ID.match?(name.to_s)
      all = dirs(project)
      names = all.keys
      names = names.drop(names.index(layer)) if all.key?(layer)
      names.each do |each|
        path = File.join(all.fetch(each), "steps", "#{name}.yml")
        if found["path"]
          found["shadows"] << path if File.file?(path)
        else
          found["searched"] << {"layer" => each, "path" => path}
          found.merge!("path" => path, "layer" => each) if File.file?(path)
        end
      end
      found
    end

    # The lookup a definition being read finds its bare-name imports with: {#import_step} for a fixed project. One
    # lookup serves a whole `extends:` chain, each file asking from its own layer.
    #
    # @param project [String, nil] the project whose definitions are searched first
    # @param file_layer [String, nil] the layer a definition read by path (source "file") sits in, per {#scope_of}; nil searches from the top
    # @return [#call] `(name, layer:)` answering what {#import_step} answers
    def import_lookup(project = nil, file_layer: nil)
      lambda do |name, layer:|
        layer = file_layer if layer == "file"
        import_step(name, layer: layer, project: project)
      end
    end

    # The directory a definition's file references must stay inside: a source's or the presets' own directory,
    # symlinks followed, since neither is the person's own file; nil for the other layers.
    #
    # @param source [String] the definition's layer
    # @param project [String, nil]
    # @return [String, nil]
    def confine_dir(source, project = nil)
      return nil unless source == "builtin" || source.to_s.start_with?("source:")
      dir = dirs(project)[source]
      return nil unless dir
      File.realpath(dir)
    rescue SystemCallError
      dir
    end

    # Which layer's step library directory (`<layer>/steps/`) a file sits in, for a file read by path (`validate`).
    # A file in any project's `workflows/steps/` counts as "project", whatever the caller's project.
    #
    # @param path [String]
    # @param project [String, nil]
    # @return [String, nil] "project", "global", "source:N", "builtin", or nil when it is in none
    def library_scope_of(path, project: nil)
      dir = File.dirname(File.expand_path(path))
      found = dirs(project).find { |_, each| same_dir?(File.join(each, "steps"), dir) }&.first
      return found if found
      "project" if project_names.filter_map { |name| @config.project_workflows_dir(name) }.any? { |own| same_dir?(File.join(own, "steps"), dir) }
    end

    # Every workflow file, in every layer and every project's directory, with a step whose `import:` reaches the
    # library file at +realpath+, symlinks followed. Read from each file's raw YAML, not a parse, so an importer is
    # found even while the library is broken; a file that can't be read or parsed as YAML is left out.
    #
    # @param realpath [String] the library file
    # @return [Array<Hash{String=>Object}>] "id", "source", "project" (the project's name for a project file, else nil)
    #   and "path", sorted by project then source order then id
    def importers_of(realpath)
      target = real(realpath)
      return [] unless target
      scopes = [[nil, dirs.to_a]] + project_names.filter_map { |name| (own = @config.project_workflows_dir(name)) && [name, [["project", own]]] }
      scopes.flat_map do |project, layers|
        layers.flat_map do |source, dir|
          @globber.call(File.join(dir, "*.yml")).sort.filter_map do |path|
            id = File.basename(path, ".yml")
            next unless IdPatterns::WORKFLOW_ID.match?(id) && File.file?(path)
            next unless declared_imports(path).any? { |reference| real(import_path(reference, path, source, project)) == target }
            {"id" => id, "source" => source, "project" => project, "path" => path}
          end
        end
      end
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

    # The names of the layers searched, first to last: "project" (when the project has a directory), "global",
    # "source:1", "source:2", ... and "builtin".
    #
    # @param project [String, nil]
    # @return [Array<String>]
    def ordered_sources(project = nil)
      dirs(project).keys
    end

    # The lookup a definition being read finds the workflow its `extends:` names with: {#parent} for a fixed project.
    #
    # @param project [String, nil] the project whose definitions are searched first
    # @return [#call] `(id, below: nil)` answering what {#parent} answers
    def parent_lookup(project = nil)
      ->(id, below: nil) { parent(id, below: below, project: project) }
    end

    # Where a user's file of this id is (or would be) written.
    #
    # @param id [String]
    # @return [String]
    # @raise [Workspace::Error] code `invalid_workflow` when the id could not be a file name
    def global_path(id)
      unless IdPatterns::WORKFLOW_ID.match?(id.to_s)
        problem = "the workflow id #{id.to_s[0, 60].inspect} must be #{IdPatterns::WORKFLOW_ID_RULE}"
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
        data = WorkflowDefinition.parse(read["text"], id: id, source: source, path: path, parent_lookup: parent_lookup(project),
          import_lookup: import_lookup(project), confine_dir: confine_dir(source, project)).to_h
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

    # The `import:` references a definition file's own `steps:` and `replace:` entries write, or none when it can't be read as YAML.
    def declared_imports(path)
      parsed = YAML.safe_load(File.read(path, encoding: Encoding::UTF_8))
      return [] unless parsed.is_a?(Hash)
      %w[steps replace].flat_map do |key|
        next [] unless parsed[key].is_a?(Hash)
        parsed[key].values.filter_map { |step| step["import"] if step.is_a?(Hash) && step["import"].is_a?(String) && !step.key?("fan_out") }
      end
    rescue
      []
    end

    # The library file a reference written in the file at +path+ (of layer +source+) names, by {WorkflowImports}' rules; nil when it names none.
    def import_path(reference, path, source, project)
      return import_step(reference, layer: source, project: project)["path"] if IdPatterns::WORKFLOW_ID.match?(reference)
      match = WorkflowImports::FILE_REFERENCE.match(reference)
      match && File.expand_path(match[:path], File.dirname(path))
    end

    def real(path)
      path && File.realpath(path)
    rescue SystemCallError
      nil
    end

    def same_dir?(dir, other)
      File.expand_path(dir) == other || (!real(dir).nil? && real(dir) == real(other))
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
      elsif IdPatterns::WORKFLOW_ID.match?(name)
        "#{path} is not a file"
      else
        "the file's name must be a workflow id: #{IdPatterns::WORKFLOW_ID_RULE}, at most 40 characters"
      end
      summary(name, source, path, project).merge("problems" => [problem])
    end

    # The directories searched, in order. A project name that could not be a directory name
    # under the config (see {Workspace::Config#project_workflows_dir}) has no directory.
    def dirs(project = nil)
      own = project && @config.project_workflows_dir(project)
      (own ? {"project" => own} : {}).merge("global" => @config.workflows_dir).merge(source_dirs).merge("builtin" => @config.builtin_workflows_dir)
    end

    # "source:N" => directory, for each listed source whose directory exists, N counting the listed ones.
    def source_dirs
      return {} unless @sources
      @sources.call.each_with_index.filter_map { |dir, index| ["source:#{index + 1}", dir] if dir }.to_h
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
        WorkflowDefinition.parse(bytes.dup.force_encoding(Encoding::UTF_8), id: id, source: source, path: path, parent_lookup: parent_lookup(project),
          import_lookup: import_lookup(project), confine_dir: confine_dir(source, project))
        []
      rescue Workspace::Error => e
        e.details["problems"] || [e.message]
      end
      {"source" => source, "project" => (source == "project") ? project : nil, "path" => path, "text" => text, "sha256" => Digest::SHA256.hexdigest(bytes), "problems" => problems}
    end
  end
end
