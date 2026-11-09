require "digest"
require "fileutils"
require "json"
require "yaml"

module Workspace
  # Installs the `workflows.sources` entries: fetches each one into a staging directory
  # (a local one is read in place), checks every `.yml` file in it through
  # {WorkflowDefinition.parse} against a staged {WorkflowCatalog} whose layers are in the
  # order a run will use, and only then swaps a GitHub source's staging directory into its
  # cache directory. A source with any invalid file is refused whole and the cache keeps
  # the version it had. Writes only to the state-directory cache.
  class WorkflowSourceInstaller
    # Code of a problem entry for a definition that sets `prompt_file:`.
    PROMPT_FILE_CODE = "workflow_source_prompt_file".freeze

    # @param config [Workspace::Config] names the global and preset directories
    # @param source_dirs [Workspace::WorkflowSourceDirs] lists the entries and the directories they are read from now
    # @param fetcher [Workspace::WorkflowSourceFetcher]
    # @param state_dir [String] the state root the cache lives under
    # @param home [String, nil] what a leading `~` stands for
    def initialize(config:, source_dirs:, fetcher:, state_dir:, home: ENV["HOME"])
      @config = config
      @source_dirs = source_dirs
      @fetcher = fetcher
      @state_dir = state_dir
      @home = home
    end

    # @param only [Integer, nil] the 1-based position of the one source to install; nil installs every one
    # @return [Hash{String=>Object}] "sources" (a row per source: "index", "source", "kind", "outcome"
    #   `installed`, `unchanged`, `local` or `refused`, "path", "workflows", "installed", "changed", "removed", "problems"),
    #   "warnings" and "failed" (true when a source was refused)
    # @raise [Workspace::UsageError] when +only+ is not a position in the list
    # @raise [Workspace::Error] `workflow_source_invalid`, `workflow_source_local_missing`, `workflow_source_gh_missing`
    #   or `workflow_source_failed`, from the fetch; nothing is swapped in
    def install(only: nil)
      entries = @source_dirs.entries
      if only && !(1..entries.size).cover?(only)
        listed = entries.empty? ? "none is listed" : "#{entries.size} listed"
        raise Workspace::UsageError, "--source #{only} is not a position in workflows.sources (#{listed})."
      end
      targets = only ? [only] : (1..entries.size).to_a
      # Duplicate entries share one cache directory; the first position installs it and the
      # later ones are the same source, so they are not worked or reported again.
      seen = {}
      targets = targets.select { |n| seen.key?(entries[n - 1]) ? false : (seen[entries[n - 1]] = true) }
      staged = {}
      begin
        targets.each { |n| staged[n] = stage(entries[n - 1]) }
        current = @source_dirs.call
        dirs = entries.each_index.map { |i| staged[i + 1]&.dir || current[i] }
        catalog = WorkflowCatalog.new(config: @config, sources: -> { dirs })
        rows = targets.map { |n| check(n, entries[n - 1], staged[n], catalog) }
        warnings = rows.flat_map { |row| row["problems"].empty? ? shadowing(row, staged[row["index"]], catalog) : [] }
        rows.each { |row| swap(row, staged[row["index"]]) }
        {"sources" => rows, "warnings" => warnings, "failed" => rows.any? { |row| row["outcome"] == "refused" }}
      ensure
        staged.each_value { |each| FileUtils.rm_rf(each.staging) }
      end
    end

    # Drops every workflow installed from the `workflows.sources` entries: the cache
    # directory of each GitHub source is deleted, a local source is only reported (it is
    # read where it is, so there is nothing to remove), and the presets and the user's own
    # files are never touched. The entries stay listed in `workflows.sources`.
    #
    # @param dry_run [Boolean]
    # @return [Hash{String=>Object}] "sources" (a row per entry: "index", "source", "kind",
    #   "outcome" `removed`, `absent` or `local`, "path") and "removed" (the count)
    def uninstall(dry_run: false)
      entries = begin
        @source_dirs.entries
      rescue Workspace::ConfigParseError, ArgumentError
        # A stored list the schema refuses is one the catalog reads as nothing, so
        # there is nothing installed from a source to remove.
        return {"sources" => [], "removed" => 0, "unreadable" => true}
      end
      # A duplicate entry shares one cache directory; the first position removes it and the
      # later ones are the same source, so they are not reported again.
      seen = {}
      rows = entries.each_with_index.filter_map do |entry, i|
        next nil if seen.key?(entry)
        seen[entry] = true
        parsed = WorkflowSource.parse(entry, home: @home)
        row = {"index" => i + 1, "source" => entry, "kind" => parsed.kind.to_s, "path" => nil, "outcome" => nil}
        if parsed.kind == :local
          row.merge("outcome" => "local", "path" => parsed.path)
        else
          target = WorkflowSourceDirs.cache_dir(@state_dir, entry)
          present = File.directory?(target)
          FileUtils.rm_rf(target) if present && !dry_run
          outcome = if present
            dry_run ? "dry_run" : "removed"
          else
            "absent"
          end
          row.merge("outcome" => outcome, "path" => target)
        end
      rescue Workspace::UsageError
        {"index" => i + 1, "source" => entry, "kind" => "invalid", "path" => nil, "outcome" => "invalid"}
      end
      {"sources" => rows, "removed" => rows.count { |row| row["outcome"] == "removed" }}
    end

    private

    Staged = Struct.new(:dir, :local, :manifest, :staging, :target, keyword_init: true)

    def stage(entry)
      target = WorkflowSourceDirs.cache_dir(@state_dir, entry)
      staging = "#{target}.staging-#{Process.pid}"
      FileUtils.rm_rf(staging)
      fetched = false
      begin
        result = @fetcher.fetch(entry, into: staging)
        fetched = true
      ensure
        FileUtils.rm_rf(staging) unless fetched
      end
      Staged.new(dir: result.dir, local: result.local, manifest: result.manifest, staging: staging, target: target)
    end

    def check(index, entry, staged, catalog)
      names = Dir.glob(File.join(staged.dir, "*.yml")).map { |path| File.basename(path, ".yml") }.sort
      problems = names.flat_map { |id| problems_of(id, index, staged.dir, catalog) }
      row = {"index" => index, "source" => entry, "kind" => staged.local ? "local" : "github", "path" => staged.local ? staged.dir : staged.target,
             "workflows" => names, "installed" => [], "changed" => [], "removed" => [], "problems" => problems, "outcome" => nil}
      return row.merge("outcome" => "refused") unless problems.empty?
      return row.merge("outcome" => "local") if staged.local
      diff(row, previous_files(staged.target), staged.manifest.fetch("files"))
    end

    def problems_of(id, index, dir, catalog)
      file = "#{id}.yml"
      path = File.join(dir, file)
      unless IdPatterns::WORKFLOW_ID.match?(id)
        return [problem(file, "invalid_workflow", "the file's name must be a workflow id: #{IdPatterns::WORKFLOW_ID_RULE}")]
      end
      text = File.read(path, encoding: Encoding::UTF_8)
      return [problem(file, "invalid_workflow", "is not valid UTF-8 text")] unless text.valid_encoding?
      return [problem(file, PROMPT_FILE_CODE, "sets prompt_file:, which a workflow source may not (use prompt:)")] if prompt_file?(text)
      WorkflowDefinition.parse(text, id: id, source: "source:#{index}", path: path, parent_lookup: catalog.parent_lookup)
      []
    rescue Workspace::Error => e
      (e.details["problems"] || [e.message]).map { |message| problem(file, (e.code == "error") ? "invalid_workflow" : e.code, message) }
    rescue SystemCallError => e
      [problem(file, "invalid_workflow", "can't be read (#{e.class})")]
    end

    def problem(file, code, message)
      {"file" => file, "code" => code, "message" => message}
    end

    # Any `prompt_file:` anywhere in the file, including inside a `replace:` step a later
    # `extends:` would merge in, refuses the source — the resolved definition a run reads
    # must not carry one.
    def prompt_file?(text)
      found = ->(node) do
        case node
        when Hash then node.any? { |key, value| key == "prompt_file" || found.call(value) }
        when Array then node.any? { |each| found.call(each) }
        else false
        end
      end
      found.call(YAML.safe_load(text))
    rescue Psych::Exception, ArgumentError
      false
    end

    def previous_files(target)
      doc = JSON.parse(File.read(File.join(target, WorkflowSourceFetcher::MANIFEST)))
      files = doc.is_a?(Hash) ? doc["files"] : nil
      files.is_a?(Hash) ? files : {}
    rescue SystemCallError, JSON::ParserError
      {}
    end

    def diff(row, before, after)
      ids = ->(names) { names.map { |name| File.basename(name, ".yml") } }
      installed = ids.call(after.keys - before.keys)
      changed = ids.call((after.keys & before.keys).reject { |name| after[name] == before[name] })
      removed = ids.call(before.keys - after.keys)
      same = installed.empty? && changed.empty? && removed.empty?
      row.merge("installed" => installed, "changed" => changed, "removed" => removed, "outcome" => same ? "unchanged" : "installed")
    end

    # The old cache is renamed aside first and the staging directory takes its place in one
    # rename, so a source is never without a cache; a failed rename puts the old one back.
    def swap(row, staged)
      return if staged.local || row["outcome"] == "refused"
      FileUtils.mkdir_p(File.dirname(staged.target))
      return File.rename(staged.staging, staged.target) unless File.directory?(staged.target)

      aside = "#{staged.target}.replaced-#{Process.pid}"
      FileUtils.rm_rf(aside)
      File.rename(staged.target, aside)
      begin
        File.rename(staged.staging, staged.target)
      rescue SystemCallError
        File.rename(aside, staged.target)
        raise
      end
      FileUtils.rm_rf(aside)
    end

    # A source file hides the preset or a later source's file of its id, unless it extends that id on purpose.
    def shadowing(row, staged, catalog)
      source = "source:#{row["index"]}"
      row["workflows"].filter_map do |id|
        found = catalog.locate(id)
        text = File.read(File.join(staged.dir, "#{id}.yml"), encoding: Encoding::UTF_8)
        if found && found.first != source
          {"code" => "shadowed", "message" => "A #{found.first} definition of #{id} (#{found.last}) is found first, so #{source} #{id} is not the one a run reads."}
        elsif extends_self?(text, id)
          nil
        elsif (hidden = catalog.parent(id, below: source))
          {"code" => "shadowed", "message" => "#{source} #{id} shadows the #{hidden["source"]} definition of the same id (#{hidden["path"]})."}
        end
      end
    end

    def extends_self?(text, id)
      doc = YAML.safe_load(text)
      doc.is_a?(Hash) && doc["extends"] == id
    rescue Psych::Exception, ArgumentError
      false
    end
  end
end
