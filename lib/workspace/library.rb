module Workspace
  # Resolves library entries across scopes. The lookup order lives in
  # {#stores}: a project's store first, then the global one, so a project
  # entry hides a global one of the same kind and name. A later item adds a
  # built-in scope there, after global.
  class Library
    # @param config [Workspace::Config] for {Config#library_dir}
    # @param lineage [Workspace::WorkspaceLineage] names the project of a directory
    # @param project_config [Workspace::ProjectConfig] knows which workspaces exist
    def initialize(config:, lineage:, project_config:)
      @config = config
      @lineage = lineage
      @project_config = project_config
    end

    # The stores to search, in lookup order. With no `scope`, the project of
    # `project` (or of `cwd`, when it is a known workspace) comes before
    # global; `"global"` or `"project"` narrows it to that one store.
    #
    # @param scope [String, nil] "global", "project" or nil for both
    # @param project [String, nil] the project name; nil resolves it from `cwd`
    # @param cwd [String, nil] where the command runs
    # @return [Array<Workspace::LibraryStore>]
    # @raise [Workspace::Error] code `unknown_workspace` when the named or resolved project isn't one
    def stores(scope: nil, project: nil, cwd: nil)
      case scope
      when "global" then [global_store]
      when "project" then [project_store(project || require_project(cwd))]
      else
        name = project || known_project(cwd)
        [name && project_store(name), global_store].compact
      end
    end

    # The one store a write goes to: global unless `scope` is "project".
    #
    # @param scope [String, nil]
    # @param project [String, nil]
    # @param cwd [String, nil]
    # @return [Workspace::LibraryStore]
    # @raise [Workspace::Error] code `unknown_workspace`
    def write_store(scope: nil, project: nil, cwd: nil)
      (scope == "project") ? project_store(project || require_project(cwd)) : global_store
    end

    # @return [Workspace::LibraryStore]
    def global_store
      LibraryStore.new(dir: File.join(@config.library_dir, "global"), scope: "global")
    end

    # @param name [String] a known workspace
    # @return [Workspace::LibraryStore]
    # @raise [Workspace::Error] code `unknown_workspace`
    def project_store(name)
      require_known!(name)
      LibraryStore.new(dir: File.join(@config.library_dir, "projects", name), scope: "project", project: name)
    end

    # Every entry of the stores, sorted by kind then name, an earlier store's
    # entry before a later one's of the same name; `effective` marks the one
    # a lookup would use.
    #
    # @param stores [Array<Workspace::LibraryStore>] in lookup order
    # @param kind [String, nil] only this kind
    # @return [Array<Hash>]
    def entries(stores, kind: nil)
      seen = {}
      stores.each_with_index.flat_map { |store, rank| store.entries(kind: kind).map { |e| [e, rank] } }
        .sort_by { |e, rank| [e["kind"], e["name"], rank] }
        .map do |e, _|
          key = e["ref"]
          e.merge("effective" => !seen.key?(key)).tap { seen[key] = true }
        end
    end

    # The entry a `REF` names: `kind/name`, or a bare `name` when one kind has it.
    #
    # @param ref [String]
    # @param stores [Array<Workspace::LibraryStore>] in lookup order
    # @return [Hash] the effective entry
    # @raise [Workspace::UsageError] for a bad kind or name
    # @raise [Workspace::Error] code `unknown_library_entry` or `ambiguous_library_entry`
    def resolve(ref, stores)
      kind, name = parse_ref(ref)
      matches = entries(stores).select { |e| e["effective"] && e["name"] == name && (kind.nil? || e["kind"] == kind) }
      scopes = stores.map { |s| s.project ? "project:#{s.project}" : s.scope }
      if matches.empty?
        raise Error.new("No library entry '#{ref}' in #{scopes.join(", ")}.", code: "unknown_library_entry",
          details: {"ref" => ref, "scopes" => scopes})
      elsif matches.size > 1
        refs = matches.map { |e| e["ref"] }
        raise Error.new("'#{ref}' matches more than one kind: #{refs.join(", ")}. Name one of them.",
          code: "ambiguous_library_entry", details: {"ref" => ref, "candidates" => refs})
      end
      matches.first
    end

    # @param ref [String] `kind/name` or `name`
    # @return [Array(String, String)] the kind (nil for a bare name) and the name
    # @raise [Workspace::UsageError] for an unknown kind or a bad name
    def parse_ref(ref)
      kind, name = ref.to_s.include?("/") ? ref.split("/", 2) : [nil, ref.to_s]
      validate_kind!(kind) if kind
      validate_name!(name)
      [kind, name]
    end

    # @param kind [String]
    # @return [void]
    # @raise [Workspace::UsageError]
    def validate_kind!(kind)
      return if LibraryStore::KINDS.include?(kind)
      raise UsageError, "Unknown kind '#{kind}': one of #{LibraryStore::KINDS.join(", ")}."
    end

    # @param name [String]
    # @return [void]
    # @raise [Workspace::UsageError]
    def validate_name!(name)
      return if name.to_s.match?(LibraryStore::NAME)
      raise UsageError, "'#{name}' is not a valid library name: lowercase letters, digits and hyphens, e.g. my-play."
    end

    private

    # The project of `cwd` when it is a workspace `list` knows, else nil.
    def known_project(cwd)
      return nil unless cwd
      name = @lineage.resolve(cwd: cwd).name
      @project_config.exists?(name) ? name : nil
    end

    def require_project(cwd)
      name = @lineage.resolve(cwd: cwd || Dir.pwd).name
      require_known!(name)
      name
    end

    def require_known!(name)
      return if @project_config.exists?(name)
      raise Error.new("Unknown workspace '#{name}': --project needs a workspace `workspace list --all` knows.",
        code: "unknown_workspace", details: {"name" => name})
    end
  end
end
