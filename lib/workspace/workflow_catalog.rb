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
    # @return [Workspace::WorkflowDefinition]
    # @raise [Workspace::Error] code `unknown_workflow` when no file has that id,
    #   `invalid_workflow` when its file doesn't pass the checks
    def find(id)
      source, path = locate(id.to_s)
      unless path
        known = ids.select { |each| locate(each) }
        raise Workspace::Error.new("No workflow named #{id.to_s[0, 60].inspect}. Known: #{known.join(", ")}.",
          code: "unknown_workflow", details: {"workflow" => id.to_s[0, 60], "known" => known})
      end
      WorkflowDefinition.parse(File.read(path, encoding: Encoding::UTF_8), id: id.to_s, source: source, path: path)
    end

    # Every definition visible, a user's file hiding the preset of the same
    # id. A file that doesn't pass the checks is still listed, with its
    # problems; so is a `.yml` entry that can't be a definition (a name that
    # is not an id, or a directory), which no id finds.
    #
    # @return [Array<Hash{String=>Object}>] "id", "title", "description", "source", "path",
    #   "sha256" and "problems" (empty when valid), sorted by id
    def list
      ids.filter_map do |id|
        source, path = locate(id)
        next unusable(id) unless path
        begin
          definition = WorkflowDefinition.parse(File.read(path, encoding: Encoding::UTF_8), id: id, source: source, path: path)
          summary(id, source, path).merge("title" => definition.to_h["title"], "description" => definition.to_h["description"],
            "sha256" => definition.sha256)
        rescue Workspace::Error => e
          summary(id, source, path).merge("problems" => e.details["problems"] || [e.message])
        rescue SystemCallError => e
          summary(id, source, path).merge("problems" => ["can't be read (#{e.class})"])
        end
      end
    end

    private

    def summary(id, source, path)
      {"id" => id, "title" => id, "description" => nil, "source" => source, "path" => path, "sha256" => nil, "problems" => []}
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
        "the file's name must be a workflow id: lowercase letters, digits, '-' and '_', at most 40 characters"
      end
      summary(name, source, path).merge("problems" => [problem])
    end

    def dirs
      {"global" => @config.workflows_dir, "builtin" => @config.builtin_workflows_dir}
    end

    def ids
      dirs.values.flat_map { |dir| Dir.glob(File.join(dir, "*.yml")).map { |path| File.basename(path, ".yml") } }.uniq.sort
    end

    # An id that could not be a file name here is simply not found.
    def locate(id)
      return nil unless WorkflowDefinition::ID_PATTERN.match?(id)
      SOURCES.each do |source|
        path = File.join(dirs.fetch(source), "#{id}.yml")
        return [source, path] if File.file?(path)
      end
      nil
    end
  end
end
