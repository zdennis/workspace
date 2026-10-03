require "json"

module Workspace
  module Commands
    # The six `workspace library` verbs over named play and prompt files, in
    # the global store or one project's. Reads print their own document;
    # writes return a {Result} for `CLI#run_action`.
    class Library
      # The schema version of the `list`, `show` and `info` JSON documents.
      JSON_SCHEMA_VERSION = 1

      # What a write did. `outcome` is "added", "unchanged", "replaced",
      # "updated" or "removed"; `workspace` is the project, or nil for global.
      Result = Struct.new(:outcome, :workspace, :entry, :message)

      # The message verb for each write outcome: done, and what --dry-run would do.
      VERBS = {
        "added" => %w[Added add], "replaced" => %w[Replaced replace],
        "updated" => %w[Updated update], "unchanged" => %w[Unchanged unchanged]
      }.freeze

      # @param library [Workspace::Library] the resolver
      # @param output [IO]
      # @param input [IO] where `remove` reads its confirmation
      def initialize(library:, output: $stdout, input: $stdin)
        @library = library
        @output = output
        @input = input
      end

      # Prints every entry visible from here.
      #
      # @param kind [String, nil] only this kind
      # @param scope [String, nil] "global", "project" or nil for both
      # @param project [String, nil]
      # @param cwd [String]
      # @param json [Boolean]
      # @return [void]
      def list(kind: nil, scope: nil, project: nil, cwd: Dir.pwd, json: false)
        @library.validate_kind!(kind) if kind
        entries = @library.entries(@library.stores(scope: scope, project: project, cwd: cwd), kind: kind)
        if json
          @output.puts JSON.generate({"schema_version" => JSON_SCHEMA_VERSION, "ok" => true, "entries" => entries})
        elsif entries.empty?
          @output.puts "No library entries. Add one with: workspace library add PATH --kind play"
        else
          print_table(entries)
        end
      end

      # Prints an entry's body, as it is, so it can feed `--prompt "$(...)"`.
      #
      # @param ref [String] `kind/name` or `name`
      # @param scope [String, nil]
      # @param project [String, nil]
      # @param cwd [String]
      # @param json [Boolean]
      # @return [void]
      # @raise [Workspace::Error] see {Workspace::Library#resolve} and {Workspace::LibraryStore#read}
      def show(ref, scope: nil, project: nil, cwd: Dir.pwd, json: false)
        entry, store = find(ref, scope, project, cwd)
        body = store.read(entry["kind"], entry["name"])
        if json
          @output.puts JSON.generate({"schema_version" => JSON_SCHEMA_VERSION, "ok" => true, "entry" => entry, "body" => body})
        else
          @output.write(body)
        end
      end

      # Prints an entry's metadata.
      #
      # @param ref [String]
      # @param scope [String, nil]
      # @param project [String, nil]
      # @param cwd [String]
      # @param json [Boolean]
      # @return [void]
      # @raise [Workspace::Error] see {Workspace::Library#resolve}
      def info(ref, scope: nil, project: nil, cwd: Dir.pwd, json: false)
        entry, _store = find(ref, scope, project, cwd)
        if json
          @output.puts JSON.generate({"schema_version" => JSON_SCHEMA_VERSION, "ok" => true, "entry" => entry})
        else
          entry.each { |key, value| @output.puts "#{key.ljust(12)}#{value.nil? ? "-" : value}" }
        end
      end

      # Copies a file (or a body read from stdin) into the store, or links it.
      #
      # @param kind [String]
      # @param path [String, nil] the source file; nil with `body`
      # @param body [String, nil] the content, when read from stdin
      # @param name [String, nil] the entry name; defaults to the file name in kebab case
      # @param link [Boolean] store a symlink to `path` instead of a copy
      # @param force [Boolean] replace different content under the same name
      # @param scope [String, nil] "project" stores it for `project`; anything else is global
      # @param project [String, nil]
      # @param cwd [String]
      # @param dry_run [Boolean] report the outcome and write nothing
      # @return [Result]
      # @raise [Workspace::UsageError] for a bad kind or name, or stdin without a name
      # @raise [Workspace::Error] code `library_source_missing` or `library_entry_exists`
      def add(kind:, path: nil, body: nil, name: nil, link: false, force: false, scope: nil, project: nil, cwd: Dir.pwd, dry_run: false)
        @library.validate_kind!(kind)
        raise UsageError, "library add - (stdin) needs --as NAME." if path.nil? && name.nil?
        name ||= self.class.name_from_path(path)
        @library.validate_name!(name)
        store = @library.write_store(scope: scope, project: project, cwd: cwd)
        source = path && File.expand_path(path, cwd)
        body, target = source_for(source, body, link, "#{kind}/#{name}")

        outcome = if (existing = store.find(kind, name))
          if same?(existing, store, body, target)
            "unchanged"
          elsif force
            "replaced"
          else
            raise Error.new("Library entry #{kind}/#{name} exists in #{scope_label(store)} with different content; pass --force to replace it.",
              code: "library_entry_exists", details: {"ref" => "#{kind}/#{name}", "scope" => store.scope},
              retry_with: {"flags" => ["--force"], "destructive" => true})
          end
        else
          "added"
        end
        put(store, kind, name, body, target) unless dry_run || outcome == "unchanged"
        finish(outcome, store, kind, name, dry_run)
      end

      # Replaces an existing entry's content, or repoints a link.
      #
      # @param ref [String]
      # @param path [String, nil]
      # @param body [String, nil]
      # @param link [Boolean]
      # @param scope [String, nil]
      # @param project [String, nil]
      # @param cwd [String]
      # @param dry_run [Boolean]
      # @return [Result]
      # @raise [Workspace::Error] code `unknown_library_entry`, `ambiguous_library_entry` or `library_source_missing`
      def update(ref, path: nil, body: nil, link: false, scope: nil, project: nil, cwd: Dir.pwd, dry_run: false)
        store = @library.write_store(scope: scope, project: project, cwd: cwd)
        entry = @library.resolve(ref, [store])
        kind, name = entry.values_at("kind", "name")
        source = path && File.expand_path(path, cwd)
        body, target = source_for(source, body, link, entry["ref"])

        outcome = same?(entry, store, body, target) ? "unchanged" : "updated"
        put(store, kind, name, body, target) unless dry_run || outcome == "unchanged"
        finish(outcome, store, kind, name, dry_run)
      end

      # Deletes an entry, or its symlink, after asking unless `yes`.
      #
      # @param ref [String]
      # @param yes [Boolean] skip the question
      # @param scope [String, nil]
      # @param project [String, nil]
      # @param cwd [String]
      # @param dry_run [Boolean]
      # @return [Result, nil] nil when the person declined
      # @raise [Workspace::Error] code `unknown_library_entry`, `ambiguous_library_entry` or `confirmation_required`
      def remove(ref, yes: false, scope: nil, project: nil, cwd: Dir.pwd, dry_run: false)
        store = @library.write_store(scope: scope, project: project, cwd: cwd)
        entry = @library.resolve(ref, [store])
        kind, name = entry.values_at("kind", "name")
        unless yes || dry_run
          answer = Prompt.ask(@input, @output, "Remove #{entry["ref"]} from #{scope_label(store)}? [y/N] ", retry_flags: ["--yes"], destructive: true)
          unless answer.to_s.strip.casecmp?("y")
            @output.puts "Cancelled."
            return nil
          end
        end
        store.delete(kind, name) unless dry_run
        message = "#{dry_run ? "Would remove" : "Removed"} #{entry["ref"]} from #{scope_label(store)}."
        @output.puts message
        Result.new("removed", store.project, entry, message)
      end

      # The default entry name for a file: its name without extension, in kebab case.
      #
      # @param path [String]
      # @return [String]
      def self.name_from_path(path)
        base = File.basename(path.to_s).sub(/\.[^.]+\z/, "")
        base.downcase.gsub(/[^a-z0-9]+/, "-").gsub(/\A-+|-+\z/, "")
      end

      private

      def find(ref, scope, project, cwd)
        stores = @library.stores(scope: scope, project: project, cwd: cwd)
        entry = @library.resolve(ref, stores)
        [entry, stores.find { |s| s.scope == entry["scope"] && s.project == entry["project"] }]
      end

      # The body to copy, or the target to link: `[body, nil]` or `[nil, target]`.
      def source_for(source, body, link, ref)
        if link
          raise UsageError, "--link needs a file path, not stdin (-)." unless source
          raise Errno::ENOENT, source unless File.file?(source) && File.readable?(source)
          [nil, source]
        elsif body
          [body, nil]
        else
          [File.read(source), nil]
        end
      rescue SystemCallError => e
        raise Error.new("Can't read #{source}: #{e.message}", code: "library_source_missing", details: {"ref" => ref, "path" => source})
      end

      # Whether the stored entry already is what this write would store: the
      # same link target, or the same body in a copy.
      def same?(existing, store, body, target)
        if target
          existing["link"] && File.expand_path(existing["link"]) == File.expand_path(target)
        else
          existing["link"].nil? && existing["readable"] && store.read(existing["kind"], existing["name"]) == body
        end
      end

      def put(store, kind, name, body, target)
        if target
          store.link(kind, name, target)
        else
          store.write(kind, name, body)
        end
      end

      def finish(outcome, store, kind, name, dry_run)
        entry = store.find(kind, name) || {
          "kind" => kind, "name" => name, "ref" => "#{kind}/#{name}", "scope" => store.scope,
          "project" => store.project, "path" => store.path_for(kind, name),
          "link" => nil, "readable" => nil, "description" => nil, "updated_at" => nil
        }
        done, would = VERBS.fetch(outcome)
        verb = (dry_run && outcome != "unchanged") ? "Would #{would}" : done
        message = "#{verb} #{kind}/#{name} in #{scope_label(store)}."
        @output.puts message
        Result.new(outcome, store.project, entry, message)
      end

      def scope_label(store)
        store.project ? "project #{store.project}" : "the global library"
      end

      def print_table(entries)
        rows = entries.map do |e|
          scope = e["project"] ? "project:#{e["project"]}" : "global"
          scope += " (hidden)" unless e["effective"]
          [e["kind"], e["name"], scope, e["readable"] ? e["description"].to_s : "(unreadable)"]
        end
        widths = (0..2).map { |i| rows.map { |r| r[i].length }.max }
        rows.each { |r| @output.puts(r.each_with_index.map { |c, i| (i < 3) ? c.ljust(widths[i]) : c }.join("  ").rstrip) }
      end
    end
  end
end
