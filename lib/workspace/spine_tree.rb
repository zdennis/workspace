module Workspace
  # A workspace's plan spine: the `spine/` folder of its notes directory, read as a tree of stages.
  # One Markdown file per stage, named `<number>-<id>.md` (the number orders, the id names), and a
  # folder named like a stage file without `.md` holds that stage's sub-stages, to three levels.
  # `goal.md` holds the goal. Reading never fails and never follows a link: each problem is a
  # warning on the stage (or the tree) it belongs to.
  #
  # {#to_h} is the document `spine show --json` prints. `spine set` and the others use {#find}
  # and the {Stage#file} behind it (path, revision, frontmatter line spans).
  class SpineTree
    # The folder's name in the notes directory.
    DIR_NAME = "spine"

    # The goal's file name, at the top of the folder.
    GOAL_FILE = "goal.md"

    # Names read per folder; the rest are left out and `truncated` says `entries`.
    MAX_ENTRIES = 64

    # Stages read per folder.
    MAX_PER_FOLDER = 24

    # Stages read in all; later ones are left out and `truncated` says `stages`.
    MAX_STAGES = 96

    # Levels of stages.
    MAX_DEPTH = 3

    # Values `kind:` may hold.
    KINDS = %w[research plan implement verify review ship custom].freeze

    # Values `gates:` may hold.
    GATES = %w[plan checklist pushed pr ci merged review].freeze

    # The counts a roll-up lists, in this order.
    ROLLUP_STATES = %w[completed in_progress not_started blocked skipped unknown].freeze

    STAGE_FILE = /\A(\d{1,3})-([a-z0-9][a-z0-9-]{0,62})\.md\z/
    STAGE_DIR = /\A(\d{1,3})-([a-z0-9][a-z0-9-]{0,62})\z/
    private_constant :STAGE_FILE, :STAGE_DIR

    # One stage.
    #
    # @!attribute path [String] ids from the top joined with `/`, e.g. `implement/api`; a repeated id repeats the path
    # @!attribute id [String]
    # @!attribute number [Integer]
    # @!attribute level [Integer] 1 for a top-level stage
    # @!attribute file [SpineFile, nil] nil when only a folder has the stage's name
    # @!attribute relative [String, nil] the stage file's name below `spine/`
    # @!attribute children [Array<Stage>]
    # @!attribute warnings [Array<Hash>] the tree's warnings about this stage; {#all_warnings} adds the file's
    # @!attribute kind [String] one of {KINDS}
    # @!attribute depends_on [Array<String>] sibling ids that exist and do not form a cycle
    # @!attribute gates [Array<String>] the known gates
    Stage = Struct.new(:path, :id, :number, :level, :file, :relative, :children, :warnings, :kind, :depends_on, :gates, keyword_init: true) do
      # @return [String] one of {SpineFile::STATUSES}, or `unknown`
      def status = file ? file.status : "unknown"

      # @return [Array<Hash>] the file's warnings and the tree's, ordered by line
      def all_warnings
        ((file&.warnings || []) + warnings).each_with_index.sort_by { |w, i| [w["line"] || Float::INFINITY, i] }.map(&:first)
      end

      # @return [String] the `title:`, else the id with its hyphens read as spaces and a capital first letter
      def title = file&.value("title") || id.tr("-", " ").sub(/\A./, &:upcase)

      # @return [Hash, nil] `status` over the children and `counts`; nil without children
      def rollup
        return nil if children.empty?
        counts = ROLLUP_STATES.to_h { |state| [state, 0] }
        children.each { |child| counts[child.status] += 1 }
        status = if counts["completed"].positive? && counts["completed"] + counts["skipped"] == children.size
          "completed"
        elsif counts["blocked"].positive?
          "blocked"
        elsif counts["in_progress"] + counts["completed"] > 0
          "in_progress"
        else
          "not_started"
        end
        {"status" => status, "counts" => counts}
      end

      # @return [Hash] the stage as `spine show --json` lists it
      def to_h
        doc = {
          "path" => path, "file" => relative, "number" => number, "id" => id,
          "revision" => file&.revision, "title" => title,
          "description" => file&.value("description"), "status" => status, "status_raw" => file&.status_raw,
          "note" => file&.value("note"), "kind" => kind, "owner" => file&.value("owner"),
          "depends_on" => depends_on, "gates" => gates, "artifacts" => file ? file.list("artifacts") : [],
          "play" => file&.value("play"), "agent" => file&.value("agent"),
          "updated" => file&.value("updated"), "updated_by" => file&.value("updated_by"),
          "modified_at" => file&.modified_at,
          "done_when" => file ? file.done_when : {"total" => 0, "done" => 0, "items" => []},
          "rollup" => rollup, "warnings" => all_warnings, "truncated" => file ? file.truncated : false,
          "children" => children.map(&:to_h)
        }
        doc.delete("rollup") unless doc["rollup"]
        doc
      end
    end

    # @return [String] absolute path of the `spine/` folder
    attr_reader :dir

    # @return [Boolean] whether `spine` exists in the notes directory (a link or a file in its place counts, with a warning)
    attr_reader :exists

    # @return [SpineFile, nil] `goal.md`
    attr_reader :goal

    # @return [Array<Stage>] the top-level stages in order
    attr_reader :stages

    # @return [Array<String>] names below `spine/` that are not stages (and not the goal), sorted
    attr_reader :not_stages

    # @return [String, nil] `entries` or `stages` when a limit left something out
    attr_reader :truncated

    # @return [Array<Hash>] warnings about the folder itself
    attr_reader :warnings

    # Reads the spine of a notes directory.
    #
    # @param notes_dir [String] the workspace's notes directory
    # @return [SpineTree]
    def self.read(notes_dir) = new(File.join(notes_dir, DIR_NAME))

    # @param dir [String] the `spine/` folder
    def initialize(dir)
      @dir = dir
      @stages = []
      @not_stages = []
      @warnings = []
      @count = 0
      @exists = true
      begin
        stat = File.lstat(dir)
        if stat.symlink?
          @warnings << SpineFile.warning("link", nil, "spine is a link, so nothing under it is read.")
        elsif !stat.directory?
          @warnings << SpineFile.warning("not_a_file", nil, "spine is not a folder, so it isn't read.")
        else
          @stages = read_folder(dir, "", nil, 1, @warnings)
        end
      rescue Errno::ENOENT, Errno::ENOTDIR
        @exists = false
      rescue SystemCallError => e
        @warnings << SpineFile.warning("not_a_file", nil, "spine can't be read: #{e.message}")
      end
    end

    # @param path [String] a stage path such as `implement/api`
    # @return [Stage, nil] the first stage with that path
    def find(path)
      walk(@stages) { |stage| return stage if stage.path == path }
      nil
    end

    # @yieldparam stage [Stage] each stage, parents before their children, in order
    def each_stage(&block) = walk(@stages, &block)

    # @return [Hash] `dir`, `exists`, `goal`, `stages`, `not_stages`, `truncated`, `warnings`
    def to_h
      {
        "dir" => @dir, "exists" => @exists,
        "goal" => goal && {"file" => goal.relative, "title" => goal.value("title"), "revision" => goal.revision, "warnings" => goal.warnings},
        "stages" => @stages.map(&:to_h), "not_stages" => @not_stages.sort, "truncated" => @truncated, "warnings" => @warnings
      }
    end

    private

    def walk(stages, &block)
      stages.each do |stage|
        yield stage
        walk(stage.children, &block)
      end
    end

    # @return [Array<Stage>] the stages of one folder; problems with the folder go to +problems+
    def read_folder(dir, prefix, parent_path, level, problems)
      names = begin
        Dir.children(dir).reject { |name| !name.valid_encoding? || name.start_with?(".") || name.match?(/[\p{Cc}\p{Cf}]/) }.sort
      rescue SystemCallError => e
        problems << SpineFile.warning("not_a_file", nil, "#{prefix.empty? ? "spine" : prefix} can't be read: #{e.message}")
        []
      end
      if names.size > MAX_ENTRIES
        names = names.first(MAX_ENTRIES)
        @truncated ||= "entries"
      end

      groups = {}
      names.each do |name|
        stat = begin
          File.lstat(File.join(dir, name))
        rescue SystemCallError
          nil
        end
        if name == GOAL_FILE && prefix.empty?
          @goal = SpineFile.read(File.join(dir, name), relative: name)
        elsif (m = name.match(STAGE_FILE))
          (groups[name.delete_suffix(".md")] ||= {number: m[1].to_i, id: m[2]})[:file] = name
        elsif (m = name.match(STAGE_DIR)) && stat && (stat.directory? || stat.symlink?)
          (groups[name] ||= {number: m[1].to_i, id: m[2]})[:dir] = [name, stat]
        else
          @not_stages << "#{prefix}#{name}"
        end
      end

      ordered = groups.sort_by { |stem, group| [group[:number], group[:id], stem] }.map(&:last)
      if ordered.size > MAX_PER_FOLDER
        ordered = ordered.first(MAX_PER_FOLDER)
        @truncated ||= "stages"
      end

      seen = {}
      stages = []
      pending = []
      ordered.each do |group|
        if @count >= MAX_STAGES
          @truncated = "stages"
          break
        end
        @count += 1
        stages << read_stage(dir, prefix, parent_path, level, group, seen)
        pending << [stages.last, group[:dir]] if group[:dir]
      end
      resolve(stages)
      pending.each { |stage, entry| read_children(stage, dir, prefix, entry) }
      stages
    end

    def read_stage(dir, prefix, parent_path, level, group, seen)
      id = group[:id]
      path = [parent_path, id].compact.join("/")
      file = nil
      relative = nil
      if group[:file]
        relative = "#{prefix}#{group[:file]}"
        file = SpineFile.read(File.join(dir, group[:file]), relative: relative)
      end
      stage = Stage.new(path: path, id: id, number: group[:number], level: level, file: file, relative: relative,
        children: [], warnings: [], kind: "custom", depends_on: [], gates: [])
      if seen[id]
        stage.warnings << SpineFile.warning("duplicate_id", nil, "Stage id #{id} is already used by #{seen[id]}; depends_on #{id} means that one.", value: id)
      else
        seen[id] = relative || "#{prefix}#{group[:dir][0]}/"
      end
      stage
    end

    def read_children(stage, dir, prefix, entry)
      name, stat = entry
      if stat.symlink?
        stage.warnings << SpineFile.warning("link", nil, "#{prefix}#{name} is a link, so nothing under it is read.")
        return
      end
      stage.warnings << SpineFile.warning("folder_without_file", nil, "#{prefix}#{name}/ has no stage file #{name}.md.") unless stage.file
      if stage.level >= MAX_DEPTH
        stage.warnings << SpineFile.warning("too_deep", nil, "#{prefix}#{name}/ is below the third level of stages, so it isn't read.")
        return
      end
      stage.children = read_folder(File.join(dir, name), "#{prefix}#{name}/", stage.path, stage.level + 1, stage.warnings)
    end

    # Fills each stage's kind, depends_on and gates from its file, with a warning for every value it drops.
    def resolve(stages)
      by_id = {}
      stages.each { |stage| by_id[stage.id] ||= stage }
      stages.each do |stage|
        file = stage.file
        stage.kind = (KINDS.include?(stage.id) && stage.id != "custom") ? stage.id : "custom"
        next unless file&.read?

        kind = file.value("kind")&.downcase
        if kind && KINDS.include?(kind)
          stage.kind = kind
        elsif kind
          stage.warnings << SpineFile.warning("unknown_kind", file.key_span("kind")&.first, "kind #{kind} is not one of #{KINDS.join(", ")}.", value: kind)
        end
        stage.gates = file.list("gates").map(&:downcase).uniq.select do |gate|
          known = GATES.include?(gate)
          stage.warnings << SpineFile.warning("unknown_gate", file.key_span("gates")&.first, "gate #{gate} is not one of #{GATES.join(", ")}.", value: gate) unless known
          known
        end
        stage.depends_on = file.list("depends_on").uniq.select do |dep|
          known = by_id.key?(dep)
          stage.warnings << SpineFile.warning("unknown_dependency", file.key_span("depends_on")&.first, "depends_on #{dep} is not a stage of this folder.", value: dep) unless known
          known
        end
      end

      graph = by_id.transform_values(&:depends_on)
      stages.each do |stage|
        cyclic = stage.depends_on.select { |dep| dep == stage.id || reaches?(graph, dep, stage.id) }
        next if cyclic.empty?
        stage.depends_on -= cyclic
        stage.warnings << SpineFile.warning("dependency_cycle", stage.file.key_span("depends_on")&.first,
          "depends_on #{cyclic.join(", ")} leads back to #{stage.id}, so it is ignored.", value: cyclic.join(","))
      end
    end

    def reaches?(graph, from, target, seen = {})
      return false if seen[from]
      seen[from] = true
      graph.fetch(from, []).any? { |dep| dep == target || reaches?(graph, dep, target, seen) }
    end
  end
end
