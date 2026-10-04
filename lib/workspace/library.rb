require "digest"

module Workspace
  # Resolves library entries across scopes. The lookup order lives in
  # {#stores}: a project's store first, then the global one, then the
  # built-in one that ships with workspace, so a project entry hides a global
  # one of the same kind and name, and either hides a built-in one. {#pack}
  # is the one exception: an instruction pack is looked up built-in first, so
  # no entry can replace a pack workspace ships.
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
    # global, and the built-in store comes last; `"global"`, `"project"` or
    # `"builtin"` narrows it to that one store.
    #
    # @param scope [String, nil] "global", "project", "builtin" or nil for all
    # @param project [String, nil] the project name; nil resolves it from `cwd`
    # @param cwd [String, nil] where the command runs
    # @return [Array<Workspace::LibraryStore>]
    # @raise [Workspace::Error] code `unknown_workspace` when the named or resolved project isn't one
    def stores(scope: nil, project: nil, cwd: nil)
      case scope
      when "global" then [global_store]
      when "project" then [project_store(project || require_project(cwd))]
      when "builtin" then [builtin_store]
      else
        name = project || known_project(cwd)
        [name && project_store(name), global_store, builtin_store].compact
      end
    end

    # The one store a write goes to: global unless `scope` is "project".
    #
    # @param scope [String, nil]
    # @param project [String, nil]
    # @param cwd [String, nil]
    # @return [Workspace::LibraryStore]
    # @raise [Workspace::UsageError] for the built-in scope, which is read-only
    # @raise [Workspace::Error] code `unknown_workspace`
    def write_store(scope: nil, project: nil, cwd: nil)
      raise UsageError, "The built-in entries ship with workspace and can't be changed." if scope == "builtin"
      (scope == "project") ? project_store(project || require_project(cwd)) : global_store
    end

    # @return [Workspace::LibraryStore]
    def global_store
      LibraryStore.new(dir: File.join(@config.library_dir, "global"), scope: "global")
    end

    # The entries that ship with workspace: the instruction packs, as plays.
    # Read-only; {#write_store} never returns it.
    #
    # @return [Workspace::LibraryStore]
    def builtin_store
      LibraryStore.new(dir: @config.builtin_library_dir, scope: "builtin")
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

    # The entry a `REF` names: `kind/name`, or a bare `name` when one kind has
    # it. A bare name that a project or global entry has is never made
    # ambiguous by a built-in entry of another kind.
    #
    # @param ref [String]
    # @param stores [Array<Workspace::LibraryStore>] in lookup order
    # @return [Hash] the effective entry
    # @raise [Workspace::UsageError] for a bad kind or name
    # @raise [Workspace::Error] code `unknown_library_entry` or `ambiguous_library_entry`
    def resolve(ref, stores)
      kind, name = parse_ref(ref)
      matches = entries(stores).select { |e| e["effective"] && e["name"] == name && (kind.nil? || e["kind"] == kind) }
      own = matches.reject { |e| e["scope"] == "builtin" }
      matches = own if kind.nil? && own.any?
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

    # The play `start --play` and `launch --play` send, looked up from `cwd`
    # (its project, then global, then built-in) and read once to prove it is readable: a
    # link into iCloud can leave only a placeholder behind. A bare name means
    # a play, so a prompt of the same name doesn't make it ambiguous.
    #
    # @param ref [String] `name` or `play/name`
    # @param cwd [String, nil] the project's directory; nil searches global only
    # @return [Hash] "ref", "scope", "path" and the body's "sha256"
    # @raise [Workspace::UsageError] for a bad name or a kind other than play
    # @raise [Workspace::Error] code `unknown_library_entry`, or `library_source_missing` when the file can't be read
    def play(ref, cwd:)
      find_play(ref, stores(cwd: expand(cwd)), "--play").first.slice("ref", "scope", "path", "sha256")
    end

    # The play `instructions compose --pack` composes, with its body. Unlike
    # every other lookup, the built-in store is searched first: a project or
    # global play named like a pack workspace ships (`review`, say) never takes
    # that pack's place. Any other play can be named as a pack.
    #
    # @param ref [String] `name` or `play/name`
    # @param cwd [String, nil] the project's directory; nil searches built-in and global only
    # @return [Array(Hash, String)] "ref", "scope", "project", "path" and the body's "sha256", then the body
    # @raise [Workspace::UsageError] for a bad name or a kind other than play
    # @raise [Workspace::Error] code `unknown_library_entry`, or `library_source_missing` when the file can't be read
    def pack(ref, cwd:)
      find_play(ref, [builtin_store] + user_stores(cwd), "--pack")
    end

    # The kinds `start --agent` and `--skill` copy into a worktree, and the article for each.
    COPY_KINDS = {"agent" => "an agent", "skill" => "a skill"}.freeze

    # The agent or skill `start --agent`/`--skill` copies into a worktree,
    # looked up from `cwd` (its project, then global; the built-in store holds
    # plays only and is not searched) and checked readable
    # before anything is created. A bare name means the flag's kind.
    #
    # @param kind [String] "agent" or "skill"
    # @param ref [String] `name` or `kind/name`
    # @param cwd [String, nil] the project's directory; nil searches global only
    # @return [Hash] "ref", "kind", "name", "scope" and "path" (the store's file, or a skill's directory)
    # @raise [ArgumentError] for a kind that is not copied
    # @raise [Workspace::UsageError] for a bad name or an entry of another kind
    # @raise [Workspace::Error] code `unknown_library_entry`, or `library_source_missing` when it can't be read
    def copyable(kind, ref, cwd:)
      article = COPY_KINDS.fetch(kind) { raise ArgumentError, "#{kind} entries are not copied into a worktree" }
      given, name = parse_ref(ref)
      if given && given != kind
        raise UsageError, "--#{kind} takes #{article}, and '#{ref}' is a #{given}."
      end
      entry = resolve("#{kind}/#{name}", user_stores(cwd))
      raise source_missing(entry) unless entry["readable"]
      entry.slice("ref", "kind", "name", "scope", "path")
    end

    # The text sent to the agent for a play: one line pointing at its file,
    # so the agent can read it again after `/clear`, then any prompt text.
    #
    # @param play [Hash] from {#play}
    # @param prompt [String, nil] `--prompt` text
    # @return [String]
    def play_prompt(play, prompt)
      text = "Read \"#{play["path"]}\" and follow it."
      prompt.to_s.strip.empty? ? text : "#{text}\n\n#{prompt}"
    end

    # The pane binding recorded for a delivered play, so the SessionStart hook
    # points the agent back at the play after `/clear`. See {Workspace::PaneBindings}.
    #
    # @param play [Hash] from {#play}
    # @return [Hash{String=>String}] `kind`, `id` (the play ref) and `instructions` (its path)
    def play_binding(play)
      {"kind" => "play", "id" => play["ref"], "instructions" => play["path"]}
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

    # A tmuxinator `root:` is often written `~/...`, which git -C won't expand.
    def expand(cwd)
      cwd && File.expand_path(cwd)
    end

    # The project's store (when `cwd` is a known workspace), then global.
    def user_stores(cwd)
      stores(cwd: expand(cwd)).reject { |store| store.scope == "builtin" }
    end

    # The play `ref` names in `stores`, read once, and its body. `flag` is the
    # option the name was given to.
    def find_play(ref, stores, flag)
      kind, name = parse_ref(ref)
      if kind && kind != "play"
        hint = (kind == "prompt" && flag == "--play") ? " Send its text with --prompt \"$(workspace library show #{ref})\"." : ""
        raise UsageError, "#{flag} takes a play, and '#{ref}' is a #{kind}.#{hint}"
      end
      entry = resolve("play/#{name}", stores)
      body = read_play(entry)
      [entry.slice("ref", "scope", "project", "path").merge("sha256" => Digest::SHA256.hexdigest(body)), body]
    end

    def read_play(entry)
      raise Errno::EACCES, entry["path"] unless entry["readable"]
      File.read(entry["path"])
    rescue SystemCallError
      raise source_missing(entry)
    end

    def source_missing(entry)
      Error.new("Can't read #{entry["ref"]} at #{entry["path"]}: the file, or the file its link points to, " \
        "is missing or unreadable.", code: "library_source_missing", details: {"ref" => entry["ref"], "path" => entry["path"]})
    end

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
