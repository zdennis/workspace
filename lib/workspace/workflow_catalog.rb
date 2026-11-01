require "digest"
require "yaml"

module Workspace
  # Finds workflow definitions by id: a file in the user's
  # `~/.config/workspace/workflows/` first, then the presets that ship with
  # workspace (`lib/workflows/`). A user's file of the same id replaces the
  # preset, which is how a preset is changed: copy it there and edit it.
  class WorkflowCatalog
    # Where a definition can come from, in the order they are searched.
    SOURCES = %w[global builtin].freeze

    # @param config [Workspace::Config] names the two directories
    def initialize(config:)
      @config = config
    end

    # @param id [String] the workflow's id
    # @param project [String, nil] the project whose definitions are searched too (reserved; not read yet)
    # @return [Workspace::WorkflowDefinition]
    # @raise [Workspace::Error] code `unknown_workflow` when no file has that id,
    #   `invalid_workflow` when its file doesn't pass the checks
    def find(id, project: nil)
      source, path = locate(id.to_s)
      raise_unknown(id) unless path
      WorkflowDefinition.parse(File.read(path, encoding: Encoding::UTF_8), id: id.to_s, source: source, path: path, parent_lookup: lookup_for(project))
    end

    # The file an id is read from, a user's before a preset.
    #
    # @param id [String]
    # @return [Array(String, String), nil] "global" or "builtin" and the path, or nil when no file has that id
    #   (including an id that could not be a file name)
    def locate(id)
      return nil unless WorkflowDefinition::ID_PATTERN.match?(id)
      SOURCES.each do |source|
        path = File.join(dirs.fetch(source), "#{id}.yml")
        return [source, path] if File.file?(path)
      end
      nil
    end

    # Whether a file has this id, valid or not, so `find` reaches it (and its
    # `invalid_workflow`). A ticket key, `#12` or a URL is never an id.
    #
    # @param id [String]
    # @return [Boolean]
    def known?(id)
      !locate(id.to_s).nil?
    end

    # Every id a file answers to, sorted; leaves out a `.yml` entry no id finds.
    #
    # @return [Array<String>]
    def known_ids
      ids.select { |each| locate(each) }
    end

    # The file an `extends:` names, for a definition to read as its parent: a user's before a preset.
    #
    # @param id [String]
    # @param below [String, nil] the source of the definition asking when it has this same id ("global", "builtin"; "file" and "stdin" count as "global", where they would be installed): only sources after it are searched, so a user's `rpiv` can extend the preset `rpiv`
    # @param project [String, nil] the project whose definitions are searched too (reserved; not read yet)
    # @return [Hash{String=>String}, nil] "text", "path" and "source", or nil when no file has that id or it can't be read
    def parent(id, below: nil, project: nil)
      return nil unless WorkflowDefinition::ID_PATTERN.match?(id.to_s)
      sources = if below
        SOURCES.drop(SOURCES.index(SOURCES.include?(below) ? below : "global") + 1)
      else
        SOURCES
      end
      source = sources.find { |each| File.file?(File.join(dirs.fetch(each), "#{id}.yml")) }
      return nil unless source
      path = File.join(dirs.fetch(source), "#{id}.yml")
      {"text" => File.read(path, encoding: Encoding::UTF_8), "path" => path, "source" => source}
    rescue SystemCallError
      nil
    end

    # The definitions, other than +id+ itself, that extend it, directly or through others: the ones a change to +id+ reaches.
    # A definition that is not valid is still named when its file says what it extends; one that can't be read or parsed is left out.
    #
    # @param id [String]
    # @return [Array<String>] ids, sorted
    def extended_by(id)
      parent_of = ids.reject { |other| other == id.to_s }.to_h { |other| [other, declared_parent(other)] }
      found = []
      queue = [id.to_s]
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
    # @return [Hash{String=>Object}] "source", "path", "text" (nil when the bytes are not UTF-8),
    #   "sha256" (of the raw bytes) and "problems" (empty when valid)
    # @raise [Workspace::Error] code `unknown_workflow` when no file has that id
    def source(id, project: nil)
      found, path = locate(id.to_s)
      raise_unknown(id) unless path
      read_file(id.to_s, found, path, project)
    end

    # Every definition visible, a user's file hiding the preset of the same
    # id. A file that doesn't pass the checks is still listed, with its
    # problems; so is a `.yml` entry that can't be a definition (a name that
    # is not an id, or a directory), which no id finds.
    #
    # @return [Array<Hash{String=>Object}>] "id", "title", "description", "use_when", "applies_to", "source", "path",
    #   "sha256" and "problems" (empty when valid), sorted by id
    def list(project: nil)
      ids.filter_map do |id|
        source, path = locate(id)
        next unusable(id) unless path
        begin
          read = read_file(id, source, path, project)
        rescue SystemCallError => e
          next summary(id, source, path).merge("problems" => ["can't be read (#{e.class})"])
        end
        row = summary(id, source, path).merge("sha256" => read["sha256"], "problems" => read["problems"])
        next row unless read["problems"].empty?
        data = WorkflowDefinition.parse(read["text"], id: id, source: source, path: path, parent_lookup: lookup_for(project)).to_h
        row.merge("title" => data["title"], "description" => data["description"], "use_when" => data["use_when"], "applies_to" => data["applies_to"])
      end
    end

    private

    # What the effective file of +id+ says it extends, or nil when it says nothing or can't be read as YAML.
    def declared_parent(id)
      _, path = locate(id)
      return nil unless path
      parsed = YAML.safe_load(File.read(path, encoding: Encoding::UTF_8))
      (parsed.is_a?(Hash) && parsed["extends"].is_a?(String)) ? parsed["extends"] : nil
    rescue
      nil
    end

    def lookup_for(project)
      ->(id, below: nil) { parent(id, below: below, project: project) }
    end

    def summary(id, source, path)
      {"id" => id, "title" => id, "description" => nil, "use_when" => nil, "applies_to" => [], "source" => source, "path" => path, "sha256" => nil, "problems" => []}
    end

    def unusable(name)
      # A link to a file that is gone is still an entry of the directory, and `File.exist?` says no to it.
      source, path = SOURCES.map { |each| [each, File.join(dirs.fetch(each), "#{name}.yml")] }
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
      summary(name, source, path).merge("problems" => [problem])
    end

    def dirs
      {"global" => @config.workflows_dir, "builtin" => @config.builtin_workflows_dir}
    end

    def ids
      dirs.values.flat_map { |dir| Dir.glob(File.join(dir, "*.yml")).map { |path| File.basename(path, ".yml") } }.uniq.sort
    end

    def raise_unknown(id)
      known = known_ids
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
      {"source" => source, "path" => path, "text" => text, "sha256" => Digest::SHA256.hexdigest(bytes), "problems" => problems}
    end
  end
end
