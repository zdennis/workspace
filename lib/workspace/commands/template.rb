require "digest"
require "json"

module Workspace
  module Commands
    # `template list|show|path`: the tmuxinator template sets a new tmuxinator config can be
    # rendered from, which of them each kind selects, and where their files are. A set is a
    # `template` library entry (a directory holding `project.yml` and `worktree.yml`); the choice
    # is the `tmuxinator.template` and `tmuxinator.worktree_template` keys, resolved by
    # {Workspace::Library#tmuxinator_template}. Everything here reads; nothing is written.
    class Template
      # Bumped whenever a `--json` payload's shape changes in a backward-incompatible way.
      JSON_SCHEMA_VERSION = 1

      # The kinds of tmuxinator config a set has a file for, in the order they are shown.
      KINDS = %i[project worktree].freeze

      # The scopes `list --scope` takes.
      SCOPES = %w[global project builtin].freeze

      # @param library [Workspace::Library] finds the sets and resolves the one a kind selects
      # @param output [IO] output stream
      def initialize(library:, output: $stdout)
        @library = library
        @output = output
      end

      # Prints every tmuxinator template set with the kinds each selects for +workspace+.
      #
      # @param workspace [String, nil] the workspace whose layered config picks the sets; nil reads the global file alone
      # @param scope [String, nil] `global`, `project` or `builtin`; nil lists every scope
      # @param cwd [String, nil] where the command runs, for the project scope
      # @param json [Boolean] print the document instead of the table
      # @return [void]
      # @raise [Workspace::UsageError] for a scope other than {SCOPES}
      # @raise [Workspace::Error] `unknown_workspace` for `project` outside a project
      def list(workspace: nil, scope: nil, cwd: nil, json: false)
        raise UsageError, "Unknown scope: #{scope}. One of #{SCOPES.join(", ")}." if scope && !SCOPES.include?(scope)

        warnings = []
        selected = KINDS.to_h { |kind| [kind.to_s, selection(kind, workspace, warnings)] }
        entries = @library.entries(@library.stores(scope: scope, cwd: cwd), kind: "template")
        rows = entries.map { |entry| row(entry, selected) }
        rows += legacy_rows(selected) if scope.nil?
        if json
          @output.puts JSON.generate({"schema_version" => JSON_SCHEMA_VERSION, "ok" => true, "workspace" => workspace,
            "selected" => selected, "templates" => rows, "warnings" => warnings})
        else
          print_table(rows, warnings)
        end
      end

      # Prints the file of a set, or the file each kind selects.
      #
      # @param set [String, nil] a set name; nil is the set each kind selects
      # @param kind [String, nil] `project` or `worktree`; nil is both
      # @param workspace [String, nil] see {#list}
      # @param json [Boolean] print the document, with each file's sha256 and text
      # @return [void]
      # @raise [Workspace::UsageError] for a kind other than {KINDS}
      # @raise [Workspace::Error] `unknown_template`, `library_source_missing`, `config_parse`
      def show(set: nil, kind: nil, workspace: nil, json: false)
        targets = targets(set, kind, workspace)
        files = targets.map { |target| target.merge("content" => read(target)) }
        if json
          docs = files.map { |file| file.merge("sha256" => Digest::SHA256.hexdigest(file["content"])) }
          @output.puts JSON.generate(JsonEnvelope.document("templates", docs, schema_version: JSON_SCHEMA_VERSION))
        elsif files.one?
          @output.write(files.first["content"])
        else
          files.each_with_index do |file, index|
            @output.puts if index.positive?
            @output.puts "==> #{file["path"]} <=="
            @output.write(file["content"])
          end
        end
      end

      # Prints where the file of a set is, or where the file each kind selects is.
      #
      # @param set [String, nil] see {#show}
      # @param kind [String, nil] see {#show}
      # @param workspace [String, nil] see {#list}
      # @param json [Boolean] print the document instead of the paths
      # @return [void]
      # @raise [Workspace::UsageError] for a kind other than {KINDS}
      # @raise [Workspace::Error] `unknown_template`, `library_source_missing`, `config_parse`
      def path(set: nil, kind: nil, workspace: nil, json: false)
        targets = targets(set, kind, workspace)
        if json
          @output.puts JSON.generate(JsonEnvelope.document("templates", targets, schema_version: JSON_SCHEMA_VERSION))
        else
          targets.each { |target| @output.puts target["path"] }
        end
      end

      private

      # What a kind selects, or nil with a warning when its set can't be found.
      def selection(kind, workspace, warnings)
        found = @library.tmuxinator_template(kind, workspace: workspace)
        found.slice("name", "scope", "source")
      rescue Error => e
        raise unless %w[unknown_template library_source_missing].include?(e.code)
        warnings << {"code" => e.code, "kind" => kind.to_s, "message" => e.message}
        nil
      end

      def row(entry, selected)
        chosen = KINDS.map(&:to_s).select do |kind|
          pick = selected[kind]
          entry["effective"] && pick && pick["name"] == entry["name"] && pick["scope"] == entry["scope"]
        end
        entry.slice("name", "ref", "scope", "project", "description", "path", "files", "effective").merge("selected_for" => chosen)
      end

      # The edited copy in `~/.config/tmuxinator/` that `init` installed, when a kind renders from it.
      def legacy_rows(selected)
        kinds = selected.select { |_, pick| pick && pick["name"] == Workspace::Library::LEGACY_TEMPLATE }.keys
        return [] if kinds.empty?

        [{"name" => Workspace::Library::LEGACY_TEMPLATE, "ref" => Workspace::Library::LEGACY_TEMPLATE, "scope" => Workspace::Library::LEGACY_TEMPLATE, "project" => nil,
          "description" => "Your edited copy installed by `workspace init`", "path" => nil, "files" => [], "effective" => true,
          "selected_for" => kinds}]
      end

      def print_table(rows, warnings)
        @output.puts "Tmuxinator template sets (a new config of each kind is rendered from the one selected):"
        warnings.each { |w| @output.puts "Warning: #{w["message"]}" }
        if rows.empty?
          @output.puts "No tmuxinator templates in that scope."
          return
        end

        table = rows.map do |r|
          scope = r["project"] ? "project:#{r["project"]}" : r["scope"]
          scope += " (hidden)" unless r["effective"]
          [r["name"], scope, r["selected_for"].empty? ? "-" : r["selected_for"].join(", "), r["description"].to_s]
        end
        table.unshift(["NAME", "SCOPE", "SELECTED FOR", "DESCRIPTION"])
        widths = (0..2).map { |i| table.map { |r| r[i].length }.max }
        table.each { |r| @output.puts(r.each_with_index.map { |c, i| (i < 3) ? c.ljust(widths[i]) : c }.join("  ").rstrip) }
      end

      # One hash per file asked for: kind, template (the set), scope, source and path.
      def targets(set, kind, workspace)
        kinds = kinds_for(kind)
        kinds.map do |k|
          found = if set
            entry = @library.tmuxinator_set(set, workspace: workspace)
            {"template" => entry["name"], "scope" => entry["scope"], "source" => "argument", "path" => File.join(entry["path"], "#{k}.yml")}
          else
            chosen = @library.tmuxinator_template(k, workspace: workspace)
            {"template" => chosen["name"], "scope" => chosen["scope"], "source" => chosen["source"], "path" => chosen["path"]}
          end
          target = {"kind" => k.to_s}.merge(found)
          missing!(target) unless File.file?(target["path"]) && File.readable?(target["path"])
          target
        end
      end

      def kinds_for(kind)
        return KINDS unless kind

        raise UsageError, "Unknown kind: #{kind}. One of #{KINDS.join(", ")}." unless KINDS.map(&:to_s).include?(kind)
        [kind.to_sym]
      end

      def read(target)
        File.read(target["path"])
      rescue SystemCallError
        missing!(target)
      end

      def missing!(target)
        raise Error.new("Can't read the #{target["kind"]} tmuxinator template of '#{target["template"]}' at #{target["path"]}.",
          code: "library_source_missing", details: {"ref" => "template/#{target["template"]}/#{target["kind"]}.yml", "path" => target["path"]})
      end
    end
  end
end
