require "digest"
require "find"
require "tmpdir"
require "fileutils"
require "json"

module Workspace
  module Commands
    # `template list|show|path`: the tmuxinator template sets a new tmuxinator config can be
    # rendered from, which of them each kind selects, and where their files are. A set is a
    # `template` library entry (a directory holding `project.yml` and `worktree.yml`); the choice
    # is the `tmuxinator.template` and `tmuxinator.worktree_template` keys, resolved by
    # {Workspace::Library#tmuxinator_template}. `list`, `show`, `path`, `variables`, `render`, `validate`, `diff` and `status`
    # read; `new`, `edit` and `use` change a set or the key that selects one, `apply` re-renders configs and `adopt` writes the render records of configs that have none.
    class Template
      # Bumped whenever a `--json` payload's shape changes in a backward-incompatible way.
      JSON_SCHEMA_VERSION = 1

      # The kinds of tmuxinator config a set has a file for, in the order they are shown.
      KINDS = %i[project worktree].freeze

      # The name of the global set `import` with no path makes from the installed copies.
      LEGACY_IMPORT_NAME = "local"

      # The scopes `list --scope` takes.
      SCOPES = %w[global project builtin].freeze

      # @param library [Workspace::Library] finds the sets and resolves the one a kind selects
      # @param project_config [Workspace::ProjectConfig] `render` fills a template with it and `config_path_for` finds a config
      # @param writer [Workspace::TmuxinatorConfigWriter] reads a workspace's render record
      # @param template_validator [Workspace::TemplateValidator] checks the file `render` fills
      # @param differ [#call] `(old, new, old_label:, new_label:)` to a unified diff, empty when the same (a {TextDiff})
      # @param config_command [Workspace::Commands::Config, nil] `use` sets the key through it; nil refuses `use`
      # @param selection [Workspace::TemplateSelection, nil] settles which workspaces `status` reports on; nil refuses `status`
      # @param status [Workspace::TemplateStatus, nil] classifies each one; nil refuses `status`
      # @param apply [Workspace::TemplateApply, nil] re-renders the selected configs; nil refuses `apply`
      # @param adopt [Workspace::TemplateAdopt, nil] builds render records for configs that have none; nil refuses `adopt` (and `variables` shows no recovered values)
      # @param backups [Workspace::TmuxinatorBackupStore, nil] `import` copies a set it replaces into a batch of its own; nil refuses replacing one
      # @param template_in_use [Workspace::TemplateInUse, nil] `import` refuses to replace a set a key selects; nil checks nothing
      # @param tmuxinator_dir [String, nil] where `workspace init` once installed its copies; `import` with no path reads them; nil refuses that
      # @param output [IO] output stream
      # @param error_output [IO] where `render`'s problems go in text mode
      def initialize(library:, project_config:, writer:, template_validator:, differ:, config_command: nil, selection: nil, status: nil, apply: nil, adopt: nil, backups: nil, template_in_use: nil, tmuxinator_dir: nil, output: $stdout, error_output: $stderr)
        @config_command = config_command
        @selection = selection
        @status = status
        @apply = apply
        @adopt = adopt
        @backups = backups
        @template_in_use = template_in_use
        @tmuxinator_dir = tmuxinator_dir
        @library = library
        @project_config = project_config
        @writer = writer
        @template_validator = template_validator
        @differ = differ
        @output = output
        @error_output = error_output
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

      # Prints the placeholders a tmuxinator template may hold, with what each holds in a workspace's config.
      #
      # @param kind [String, nil] `project` or `worktree`; nil is both
      # @param workspace [String, nil] adds each placeholder's value from that workspace's render record
      # @param json [Boolean] print the document instead of the table
      # @return [void]
      # @raise [Workspace::UsageError] for a kind other than {KINDS}
      def variables(kind: nil, workspace: nil, json: false)
        kinds = kinds_for(kind)
        record = workspace && @writer.record(workspace)
        inputs = record_inputs(record) if record
        recovered = workspace && !record && @adopt&.recover(workspace)
        inputs = TemplateStatus.record_inputs(TmuxinatorConfigWriter::Record.new(kind: recovered.kind, template: "", template_sha: "", inputs: recovered.inputs, rendered_sha: ""), @project_config) if recovered
        rows = TemplateVariables::ROWS.select { |row| (row.kinds & kinds).any? }.map { |row| variable_row(row, inputs, workspace) }
        if json
          doc = JsonEnvelope.document("variables", rows, schema_version: JSON_SCHEMA_VERSION).merge("workspace" => workspace)
          doc["value_state"] = if workspace
            if record then "recorded"
            elsif recovered then "recovered"
            else
              "no_record"
            end
          end
          @output.puts JSON.generate(doc)
        else
          print_variables(rows, workspace, if record
            :recorded
          else
            (recovered ? :recovered : nil)
          end)
        end
      end

      # Fills a tmuxinator template and prints the result; nothing is written. The file is checked first
      # and its problems are reported, but a file with errors is still filled as far as it goes.
      #
      # @param set [String, nil] a set name; nil is the set the kind selects (or +file+)
      # @param file [String, nil] a template file, saved or not, instead of a set
      # @param kind [String, nil] `project` or `worktree`; nil is the workspace's recorded kind, else the kind its name says
      # @param workspace [String, nil] fill from this workspace's render record and its current agent settings
      # @param context [String, nil] the workspace whose settings choose the set when +workspace+ is nil
      # @param sample [Boolean] fill with each placeholder's sample value instead
      # @param diff [Boolean] print a unified diff against the workspace's current config instead of the text
      # @param json [Boolean] print the document
      # @return [Boolean] false when a problem is an error (the CLI exits 1)
      # @raise [Workspace::UsageError] for a bad combination of options or a kind other than {KINDS}
      # @raise [Workspace::Error] `no_render_record`, `unknown_template`, `library_source_missing`
      def render(set: nil, file: nil, kind: nil, workspace: nil, context: nil, sample: false, diff: false, json: false)
        raise UsageError, "Give a tmuxinator template NAME or --file, not both." if set && file
        raise UsageError, "Give --name or --sample, not both." if sample && workspace
        unless sample || workspace
          raise Error.new("Not in a workspace: pass --name WORKSPACE to fill from one, or --sample to fill with sample values.", code: "not_in_workspace")
        end
        raise UsageError, "--diff compares with a workspace's config; give --name, not --sample." if diff && sample

        record = workspace && @writer.record(workspace)
        raise no_record(workspace) if workspace && !record
        kind = (kind ? kinds_for(kind).first : nil) || record&.kind || default_kind(workspace)
        target = render_target(set, file, kind, workspace || context)
        problems = @template_validator.call_file(kind, target["path"]).map(&:to_h)
        text = read(target.merge("kind" => kind.to_s))
        inputs = sample ? sample_inputs(kind) : record_inputs(record)
        content = filled(kind, inputs, text, problems)
        difference = (current_diff(workspace, content) if diff && content)
        ok = problems.none? { |p| p["severity"] == "error" }
        if json
          @output.puts JSON.generate({"schema_version" => JSON_SCHEMA_VERSION, "ok" => ok, "template" => target["template"],
                                      "source" => target["source"], "path" => target["path"], "kind" => kind.to_s, "workspace" => workspace,
                                      "inputs" => inputs.transform_keys(&:to_s), "content" => content, "diff" => difference, "warnings" => problems}
            .merge(diff ? {"changed" => !difference.to_s.empty?} : {}))
        else
          print_render(problems, diff ? difference : content, diff)
        end
        ok
      end

      # Checks a tmuxinator template set, or one file, with {TemplateValidator}; nothing is written.
      #
      # @param set [String, nil] a set name; nil is the set each kind selects (unless +file+)
      # @param file [String, nil] one template file, saved or not, instead of a set
      # @param kind [String, nil] `project` or `worktree`; nil checks both files of a set, and for +file+ is read from its name (else `project`)
      # @param workspace [String, nil] the workspace whose settings choose the set
      # @param json [Boolean] print the document
      # @return [Boolean] false when a file has an error (the CLI exits 1); warnings alone are true
      # @raise [Workspace::UsageError] for NAME with --file, or a kind other than {KINDS}
      # @raise [Workspace::Error] `unknown_template` for a set that isn't there
      def validate(set: nil, file: nil, kind: nil, workspace: nil, json: false)
        raise UsageError, "Give a tmuxinator template NAME or --file, not both." if set && file

        files = validation_targets(set, file, kind, workspace).map do |target|
          problems = @template_validator.call_file(target["kind"].to_sym, target["path"]).map(&:to_h)
          target.merge("problems" => problems)
        end
        problems = files.flat_map { |f| f["problems"] }
        errors = problems.count { |p| p["severity"] == "error" }
        ok = errors.zero?
        if json
          @output.puts JSON.generate({"schema_version" => JSON_SCHEMA_VERSION, "ok" => ok, "files" => files, "errors" => errors,
                                      "warnings" => problems.size - errors})
        else
          print_validation(files)
        end
        ok
      end

      # Prints where each selected workspace stands against the tmuxinator template it would be rendered from:
      # `current`, `stale`, `modified` or `untracked` (see {TemplateStatus}). Reads only.
      #
      # @param names [Array<String>] workspaces by name
      # @param all [Boolean] every workspace that has a config
      # @param project [nil, true, String] `--project`: true for the current workspace's project, else a name
      # @param cwd [String] where the current workspace is looked for
      # @param json [Boolean] print the document instead of the table
      # @return [void]
      # @raise [Workspace::UsageError] for names mixed with `--all` or `--project`
      # @raise [Workspace::Error] `unknown_workspace`, `not_in_workspace`
      def status(names: [], all: false, project: nil, cwd: Dir.pwd, json: false)
        raise Error, "template status is not available: no selection was wired" unless @selection && @status

        rows = @status.call(@selection.call(names: names, all: all, project: project, working_dir: cwd))
        if json
          counts = TemplateStatus::STATES.to_h { |state| [state, rows.count { |row| row.state == state }] }
          @output.puts JSON.generate(JsonEnvelope.document("workspaces", rows.map(&:to_h), schema_version: JSON_SCHEMA_VERSION).merge("counts" => counts))
        else
          print_status(rows)
        end
      end

      # Re-renders each selected workspace's tmuxinator config from its render record (see {TemplateApply}) and
      # answers what `CLI::Common#run_action` reports; in text mode each row is also printed.
      #
      # @param names [Array<String>] see {#status}
      # @param all [Boolean] see {#status}
      # @param project [nil, true, String] see {#status}
      # @param cwd [String] see {#status}
      # @param dry_run [Boolean] decide every row and write nothing
      # @param diff [Boolean] show what each config would change by
      # @param force [Boolean] overwrite configs edited since they were rendered
      # @param rollback [Boolean] put back the whole batch on the first failed row
      # @param json [Boolean] print nothing; the caller prints the action document
      # @return [Hash] `results`, `status`, `exit_code`, `warnings` and `extra` (`backup`, `rolled_back`, and `skipped`: the skipped rows counted by reason)
      # @raise [Workspace::UsageError] for names mixed with `--all` or `--project`
      # @raise [Workspace::Error] `unknown_workspace`, `not_in_workspace`, or a backup batch that can't be made
      def apply(names: [], all: false, project: nil, cwd: Dir.pwd, dry_run: false, diff: false, force: false, rollback: false, json: false)
        raise Error, "template apply is not available: no selection was wired" unless @selection && @apply

        selected = @selection.call(names: names, all: all, project: project, working_dir: cwd)
        result = @apply.call(selected, dry_run: dry_run, diff: diff, force: force, rollback: rollback)
        status = if result.rolled_back then "failed"
        elsif result.rows.any? { |row| row["outcome"] == "failed" } then JsonEnvelope.action_status(result.rows)
        elsif dry_run then "dry_run"
        else
          "ok"
        end
        print_apply(result, dry_run) unless json
        {results: result.rows, status: status, exit_code: JsonEnvelope::ACTION_EXIT_CODES.fetch(status), warnings: result.warnings,
         extra: {"backup" => result.backup, "rolled_back" => result.rolled_back,
                 "skipped" => result.rows.select { |row| row["outcome"] == "skipped" }.map { |row| row["reason"] }.tally}}
      end

      # Builds the render record of each selected workspace that has none (see {TemplateAdopt}) and answers what
      # `CLI::Common#run_action` reports; in text mode each row is also printed. Only records are written.
      #
      # @param names [Array<String>] see {#status}
      # @param all [Boolean] see {#status}
      # @param project [nil, true, String] see {#status}
      # @param cwd [String] see {#status}
      # @param dry_run [Boolean] decide every row and write nothing
      # @param json [Boolean] print nothing; the caller prints the action document
      # @return [Hash] `results`, `status`, `exit_code` and `extra` (`adopted`: the adopted rows counted by `match`)
      # @raise [Workspace::UsageError] for names mixed with `--all` or `--project`
      # @raise [Workspace::Error] `unknown_workspace`, `not_in_workspace`
      def adopt(names: [], all: false, project: nil, cwd: Dir.pwd, dry_run: false, json: false)
        raise Error, "template adopt is not available: no selection was wired" unless @selection && @adopt

        rows = @adopt.call(@selection.call(names: names, all: all, project: project, working_dir: cwd), dry_run: dry_run)
        status = if rows.any? { |row| row["outcome"] == "failed" } then JsonEnvelope.action_status(rows)
        elsif dry_run then "dry_run"
        else
          "ok"
        end
        print_adopt(rows, dry_run) unless json
        {results: rows, status: status, exit_code: JsonEnvelope::ACTION_EXIT_CODES.fetch(status),
         extra: {"adopted" => rows.select { |row| row["match"] }.map { |row| row["match"] }.tally}}
      end

      # Prints a unified diff of each file of a tmuxinator template set against the same file of another set.
      #
      # @param set [String, nil] the set to compare; nil is the set each kind selects
      # @param against [String, nil] the set to compare with; nil is `default`
      # @param kind [String, nil] `project` or `worktree`; nil is both
      # @param workspace [String, nil] the workspace whose settings choose the set
      # @param json [Boolean] print the document, with each file's diff
      # @return [void]
      # @raise [Workspace::UsageError] for a kind other than {KINDS}
      # @raise [Workspace::Error] `unknown_template`, `library_source_missing`
      def diff(set: nil, against: nil, kind: nil, workspace: nil, json: false)
        against ||= "default"
        olds = targets(against, kind, workspace)
        rows = targets(set, kind, workspace).zip(olds).map do |target, old|
          text = @differ.call(read(old), read(target), old_label: old["path"], new_label: target["path"])
          {"kind" => target["kind"], "template" => target["template"], "path" => target["path"], "against_path" => old["path"],
           "changed" => !text.empty?, "diff" => text}
        end
        changed = rows.any? { |row| row["changed"] }
        if json
          @output.puts JSON.generate(JsonEnvelope.document("files", rows, schema_version: JSON_SCHEMA_VERSION)
            .merge("against" => against, "changed" => changed))
        else
          @error_output.puts "No differences from #{against}." unless changed
          rows.each { |row| write_text(row["diff"]) }
        end
      end

      # Copies a tmuxinator template set into a new set of the global or project library, so it can be edited.
      # The source is checked first; nothing is written when it has an error.
      #
      # @param name [String] the new set's name: lowercase letters, digits and hyphens
      # @param from [String, nil] the set to copy; nil is `default`
      # @param scope [String, nil] `global` (the default) or `project`
      # @param workspace [String, nil] the workspace whose project's sets `from` is looked up in
      # @param cwd [String, nil] where the command runs, for the project scope
      # @return [Hash] the action row: `template`, `scope`, `path`, `from` and the files' `warnings`
      # @raise [Workspace::UsageError] for a bad name, or the built-in scope
      # @raise [Workspace::Error] `template_exists`, `unknown_template`, `invalid_template`
      def new(name:, from: nil, scope: nil, workspace: nil, cwd: nil)
        raise UsageError, "'#{name}' is not a valid tmuxinator template name: lowercase letters, digits and hyphens, e.g. team." unless name.to_s.match?(IdPatterns::LIBRARY_NAME)
        raise UsageError, "'#{name}' is reserved for the edited copy `workspace init` installed. Pick another name." if name == Workspace::Library::LEGACY_TEMPLATE
        raise UsageError, "Unknown scope: #{scope}. One of global, project." unless [nil, "global", "project"].include?(scope)

        project = (WorkspaceName.project_of(workspace) if workspace && scope == "project")
        store = @library.write_store(scope: scope, project: project, cwd: cwd)
        source = @library.tmuxinator_set(from || "default", workspace: workspace)
        if store.find("template", name)
          raise Error.new("A tmuxinator template '#{name}' already exists in the #{store.scope} library (#{store.path_for("template", name)}). Edit it with: workspace template edit #{name}",
            code: "template_exists", details: {"template" => name, "scope" => store.scope, "path" => store.path_for("template", name)})
        end
        checked = @template_validator.call_set(source["path"])
        unless checked.valid?
          raise Error.new("The tmuxinator template #{source["ref"]} is not valid: #{checked.errors.map(&:to_s).join("; ")}",
            code: "invalid_template", details: {"ref" => source["ref"], "problems" => checked.errors.map(&:to_h)})
        end
        shadowed = shadowed_scopes(store, name, project, cwd)
        store.copy_tree("template", name, source["path"])
        path = store.path_for("template", name)
        @output.puts "Created the tmuxinator template '#{name}' from '#{source["name"]}' at #{path}. Edit it with: workspace template edit #{name}"
        {"workspace" => nil, "outcome" => "created", "reason" => nil, "message" => nil, "template" => name, "scope" => store.scope,
         "path" => path, "from" => source["name"], "warnings" => checked.warnings.map(&:to_h) + shadowed}
      end

      # Opens the files of a tmuxinator template set in the editor, then checks them. A built-in set is read-only.
      #
      # @param set [String, nil] a set name; nil is the set each kind selects
      # @param kind [String, nil] `project` or `worktree`; nil is both files
      # @param workspace [String, nil] the workspace whose settings choose the set
      # @param opener [#call, nil] given the file paths, opens them in the editor; nil opens nothing (`--json`)
      # @return [Hash] the action row: `template`, `files` (each with `kind`, `path` and `problems`), outcome
      #   `edited`, or `failed` (reason `invalid_template`) when a file has an error
      # @raise [Workspace::UsageError] for a kind other than {KINDS}
      # @raise [Workspace::Error] `template_builtin_readonly`, `unknown_template`, `library_source_missing`, `editor_failed`
      def edit(set: nil, kind: nil, workspace: nil, opener: nil)
        targets = targets(set, kind, workspace)
        builtin = targets.find { |target| target["scope"] == "builtin" }
        if builtin
          raise Error.new("The tmuxinator template '#{builtin["template"]}' ships with workspace and can't be edited. Make a copy with: workspace template new NAME --from #{builtin["template"]}",
            code: "template_builtin_readonly", details: {"template" => builtin["template"], "path" => builtin["path"]})
        end

        opener&.call(targets.map { |target| target["path"] })
        files = targets.map do |target|
          target.slice("kind", "template", "path").merge("problems" => @template_validator.call_file(target["kind"].to_sym, target["path"]).map(&:to_h))
        end
        print_validation(files)
        failed = files.any? { |file| file["problems"].any? { |p| p["severity"] == "error" } }
        {"workspace" => nil, "outcome" => failed ? "failed" : "edited", "reason" => failed ? "invalid_template" : nil,
         "message" => failed ? "A tmuxinator template file has an error." : nil, "template" => targets.map { |t| t["template"] }.uniq.join(", "), "files" => files}
      end

      # Makes new tmuxinator configs render from a set: `config set tmuxinator.template NAME` (or `tmuxinator.worktree_template`
      # with +kind+ `worktree`), after checking the set exists.
      #
      # @param name [String] the set's name
      # @param scope [String, nil] `global` or `project`; nil is the config layer `config set` picks (global outside a workspace)
      # @param kind [String, nil] `worktree` sets `tmuxinator.worktree_template`; nil or `project` sets `tmuxinator.template`
      # @param workspace [String, nil] the workspace whose layer is written for the project scope
      # @return [Hash] the action row: `template`, `key`, `layer` and `file`
      # @raise [Workspace::UsageError] for a kind other than {KINDS}, or a missing config command
      # @raise [Workspace::Error] `unknown_template`, and `config set`'s own errors
      def use(name:, scope: nil, kind: nil, workspace: nil, cwd: nil)
        raise Error, "template use is not available: no config command was wired" unless @config_command

        kind = kinds_for(kind).then { |kinds| (kinds.size == 1) ? kinds.first : :project }
        @library.tmuxinator_set(name, workspace: workspace)
        key = (kind == :worktree) ? "tmuxinator.worktree_template" : "tmuxinator.template"
        scope ||= "global" if workspace.nil?
        result = @config_command.set(key, name, project: workspace, scope: scope, cwd: cwd || Dir.pwd)
        @output.puts "New tmuxinator configs now render from '#{name}'; existing configs are unchanged until `workspace template apply`."
        {"workspace" => result.workspace, "outcome" => "selected", "reason" => nil, "message" => nil, "template" => name, "key" => key,
         "layer" => result.layer, "file" => result.path}
      end

      # Copies every tmuxinator template set of a library scope into +dir+, one folder per set (regular files only, no dotfiles),
      # and writes `templates.json` there: the workspace version and the sha256 of every file of every set folder in +dir+. The
      # file is for people to read; `import` does not check it. The `legacy` set is not exported.
      #
      # @param dir [String] the directory to write into; made when missing; never the library or inside it
      # @param scope [String, nil] `global` (default) or `project`
      # @param force [Boolean] replace a set's folder already in +dir+
      # @param workspace [String, nil] the workspace whose project `--scope project` exports
      # @param cwd [String, nil] where the command runs, for the project scope
      # @return [Hash] the action row: `scope`, `dir`, `templates` (each `template`, `path`, `files`: relative path to sha256), `warnings`
      # @raise [Workspace::UsageError] for a scope other than global or project, or a +dir+ in the library
      # @raise [Workspace::Error] `template_exists` when a set's folder is already in +dir+ and not +force+
      def export(dir:, scope: nil, force: false, workspace: nil, cwd: nil)
        raise UsageError, "Unknown scope: #{scope}. One of global, project." unless [nil, "global", "project"].include?(scope)

        store = @library.write_store(scope: scope, project: (WorkspaceName.project_of(workspace) if workspace && scope == "project"), cwd: cwd)
        target = File.expand_path(dir, cwd || Dir.pwd)
        refuse_library_dir!(target, cwd)
        entries = store.entries(kind: "template").select { |entry| entry["readable"] != false }
        skipped, entries = entries.partition { |entry| entry["name"] == Workspace::Library::LEGACY_TEMPLATE }
        warnings = skipped.map do |entry|
          message = "The tmuxinator template '#{entry["name"]}' is the edited copy `workspace init` installed, so it is not exported: an exported folder imports back under its own names. Import it with template import after selecting it."
          @error_output.puts "Warning: #{message}"
          {"severity" => "warning", "code" => "legacy_not_exported", "kind" => nil, "scope" => store.scope, "message" => message}
        end
        if entries.empty?
          @output.puts "No tmuxinator templates in the #{store.scope} library to export."
          return {"workspace" => nil, "outcome" => "nothing_to_export", "reason" => nil, "message" => nil, "scope" => store.scope, "dir" => target, "templates" => [], "warnings" => warnings}
        end
        entries.each do |entry|
          dest = File.join(target, entry["name"])
          next unless File.exist?(dest) && !force
          raise Error.new("#{dest} already exists. Pass --force to replace it.", code: "template_exists",
            details: {"template" => entry["name"], "scope" => store.scope, "path" => dest}, retry_with: {"flags" => ["--force"], "destructive" => true})
        end
        FileUtils.mkdir_p(target)
        exported = entries.map { |entry| export_set(entry, File.join(target, entry["name"])) }
        write_manifest(target)
        @output.puts "Exported #{count(exported.size, "tmuxinator template")} to #{target}."
        {"workspace" => nil, "outcome" => "exported", "reason" => nil, "message" => nil, "scope" => store.scope, "dir" => target, "templates" => exported, "warnings" => warnings}
      end

      # Puts the tmuxinator template sets found at +path+ into the library: a folder holding project.yml and worktree.yml is one
      # set (named after the folder), a folder of such folders (what {#export} writes) is each of them. Dotfiles are left out
      # and a folder holding a symbolic link is refused. Every set is checked first and nothing is written when one is invalid or
      # refused. A set that already exists with other content is copied into a backup batch (reason `import`, put back by
      # `template restore`) and replaced, and a set it adds is recorded in the batch so a restore removes it again, unless a key selects it and not +force+; a new set that hides a lower scope's is warned about.
      #
      # With no +path+ it brings the edited copies `workspace init` once put in `~/.config/tmuxinator/` into the library: when
      # either is edited (not byte for byte any version workspace shipped) both kinds become the global set `local` (a kind
      # that is missing or stock is taken from the built-in `default`), checked like any import, and `tmuxinator.template` is
      # set to `local` globally. The old files are left. With nothing edited it does nothing and says so.
      #
      # @param path [String, nil] a set's folder, or an exported folder of sets; nil reads the installed copies
      # @param scope [String, nil] `global` (default) or `project`
      # @param force [Boolean] replace a set a key selects, or add a `default` that hides the built-in one
      # @param workspace [String, nil] the workspace whose project `--scope project` writes to
      # @param cwd [String, nil] where the command runs
      # @return [Hash] the action row: `scope`, `backup` (the batch id, or nil), `templates` (each `template`, `outcome` `added`, `replaced` or `unchanged`, `scope`, `path`, `warnings`)
      # @raise [Workspace::UsageError] for a bad scope or set name
      # @raise [Workspace::Error] `library_source_missing`, `invalid_template` (a problem, or a symbolic link), `template_in_use`
      def import(path: nil, scope: nil, force: false, workspace: nil, cwd: nil)
        raise UsageError, "Unknown scope: #{scope}. One of global, project." unless [nil, "global", "project"].include?(scope)

        legacy = path.nil?
        if legacy
          raise UsageError, "'template import' with no PATH imports into the global library; --scope project needs a PATH." if scope == "project"
          raise Error, "template import with no PATH is not available: no tmuxinator directory was wired" unless @tmuxinator_dir
          edited = LegacyTmuxinatorTemplates::FILES.keys.select { |kind| LegacyTmuxinatorTemplates.edited?(kind, LegacyTmuxinatorTemplates.path(kind, @tmuxinator_dir)) }
          if edited.empty?
            @output.puts "Nothing to import: no edited copy of a tmuxinator template in #{@tmuxinator_dir}; new configs render from the built-in set."
            return {"workspace" => nil, "outcome" => "unchanged", "reason" => nil, "message" => nil, "scope" => "global", "backup" => nil, "templates" => [], "selected" => nil}
          end
        else
          source = File.expand_path(path, cwd || Dir.pwd)
        end
        store = @library.write_store(scope: scope, project: (WorkspaceName.project_of(workspace) if workspace && scope == "project"), cwd: cwd)
        Dir.mktmpdir("template-import") do |stage|
          pairs = legacy ? [[LEGACY_IMPORT_NAME, legacy_set(stage, edited)]] : import_sources(source)
          plan = pairs.map do |name, dir|
            import_plan(store, name, dir, stage, force)
          rescue Error => e
            raise unless legacy && e.code == "invalid_template"
            files = edited.map { |kind| LegacyTmuxinatorTemplates.path(kind, @tmuxinator_dir) }.join(" and ")
            raise Error.new("#{e.message} (in your edited copy at #{files})", code: e.code, details: e.details)
          end
          batch = nil
          written = plan.reject { |item| item["outcome"] == "unchanged" }
          unless written.empty?
            raise Error, "template import can't record what it changes: no backup store was wired" unless @backups
            batch = @backups.open(reason: "import")
            written.each { |item| @backups.add_set(batch, name: item["template"], scope: store.scope, project: store.project, path: item["path"]) }
          end
          plan.each do |item|
            next if item["outcome"] == "unchanged"
            store.copy_tree("template", item["template"], item["staged"])
            @backups.finish_set(batch, name: item["template"], scope: store.scope, project: store.project, sha_after: LibraryStore.tree_sha(item["path"])) if batch
            item["warnings"] += shadowed_scopes(store, item["template"], store.project, cwd)
          end
          plan.each { |item| @output.puts "#{item["outcome"].capitalize} #{item["template"]} (#{item["path"]})" }
          @output.puts "Backed up what was replaced as #{batch.id}; put it back with `workspace template restore #{batch.id}`." if batch
          changed = plan.count { |item| item["outcome"] != "unchanged" }
          if legacy
            kept = selecting_key
            if kept
              message = "#{kept["key"]} already selects #{kept["name"]}; kept it. Run `workspace template use #{LEGACY_IMPORT_NAME}` to switch."
              @output.puts message
              warning = {"severity" => "warning", "code" => "selection_kept", "kind" => nil, "message" => message}
            else
              selected = use(name: LEGACY_IMPORT_NAME, scope: "global", cwd: cwd).fetch("template")
              @output.puts "Selected #{selected} for new configs; the old files in #{@tmuxinator_dir} are left in place."
            end
          end
          row = {"workspace" => nil, "outcome" => changed.zero? ? "unchanged" : "imported", "reason" => nil, "message" => nil, "scope" => store.scope,
                 "backup" => batch&.id, "templates" => plan.map { |item| item.except("staged") }}
          if legacy
            row["selected"] = selected
            row["warnings"] = [warning].compact
          end
          row
        end
      end

      private

      # A warning (also on stderr) for each lower-scope set of the same name that the new one now hides.
      def shadowed_scopes(store, name, project, cwd)
        stores = @library.stores(project: project, cwd: cwd)
        rank = stores.index { |other| other.scope == store.scope && other.project == store.project } || -1
        stores.drop(rank + 1).select { |other| other.find("template", name) }.map do |other|
          message = "The new tmuxinator template '#{name}' hides the #{other.scope} one of the same name (#{other.path_for("template", name)}); configs that used that one now render from this copy."
          @error_output.puts "Warning: #{message}"
          {"severity" => "warning", "code" => "shadows_template", "kind" => nil, "scope" => other.scope, "message" => message}
        end
      end

      # The inputs `render --name` fills with, which `variables --name` shows: the record's, with the agent command
      # worked out from the current agent settings (the recorded one is the pane text written then). Left out when
      # the renderer would refuse it, so `render` reports why.
      def record_inputs(record)
        TemplateStatus.record_inputs(record, @project_config)
      end

      STATUS_REASONS = {"template_switched" => "another tmuxinator template is selected now", "template_changed" => "the tmuxinator template changed", "agent_changed" => "the agent settings changed",
                        "template_unavailable" => "its tmuxinator template can't be read", "render_failed" => "it can't be rendered with today's agent settings"}.freeze
      private_constant :STATUS_REASONS

      def export_set(entry, dest)
        tmp = "#{dest}.#{Process.pid}.tmp"
        FileUtils.rm_rf(tmp)
        root = File.realpath(entry["path"])
        files = entry["files"].to_h do |rel|
          FileUtils.mkdir_p(File.dirname(File.join(tmp, rel)))
          FileUtils.cp(File.join(root, rel), File.join(tmp, rel))
          [rel, Digest::SHA256.file(File.join(tmp, rel)).hexdigest]
        end
        FileUtils.rm_rf(dest)
        File.rename(tmp, dest)
        {"template" => entry["name"], "path" => dest, "files" => files}
      ensure
        FileUtils.rm_rf(tmp) if tmp
      end

      # `templates.json` lists the set folders that are in +target+ now, whatever put them there.
      def write_manifest(target, version: Workspace::VERSION)
        sets = Dir.children(target).sort.reject { |child| child.start_with?(".") }.filter_map do |child|
          dir = File.join(target, child)
          next unless File.directory?(dir) && !File.symlink?(dir) && %w[project.yml worktree.yml].any? { |file| File.file?(File.join(dir, file)) }
          root = File.realpath(dir)
          [child, {"files" => LibraryStore.files_of(dir).to_h { |rel| [rel, Digest::SHA256.file(File.join(root, rel)).hexdigest] }}]
        end
        document = {"schema" => 1, "workspace_version" => version, "templates" => sets.to_h}
        AtomicFile.write(File.join(target, "templates.json"), JSON.pretty_generate(document) + "\n", perm: 0o644)
      end

      # An export into the library would be read back as library entries, and a later import would copy it over itself.
      def refuse_library_dir!(target, cwd)
        real = real_path(target)
        (@library.stores(cwd: cwd).map(&:dir) + [@library.root]).each do |library_dir|
          root = real_path(library_dir)
          next unless real == root || real.start_with?(root + File::SEPARATOR)
          raise UsageError, "#{target} is the library (#{root}) or inside it. Export to a folder outside it."
        end
      end

      # The path with its nearest existing parent's links resolved.
      def real_path(path)
        tail = []
        current = File.expand_path(path)
        until File.exist?(current) || current == File.dirname(current)
          tail.unshift(File.basename(current))
          current = File.dirname(current)
        end
        File.join(File.realpath(current), *tail)
      end

      # The first `tmuxinator.template` or `tmuxinator.worktree_template` any layer (global, each project or worktree) sets to a
      # set, as `{"key", "name"}`; nil when none does, which is when the installed copy is what renders.
      def selecting_key
        ([nil] + @project_config.available_projects).each do |workspace|
          KINDS.each do |kind|
            pick = @library.tmuxinator_template(kind, workspace: workspace)
            next if %w[legacy default].include?(pick["source"])
            return {"key" => (kind == :worktree) ? "tmuxinator.worktree_template" : "tmuxinator.template", "name" => pick["name"]}
          rescue Error, ConfigParseError
            next
          end
        end
        nil
      end

      # The set `template import` with no path stages: each kind's edited copy, else the built-in default's file.
      def legacy_set(stage, edited)
        dir = File.join(stage, "legacy-source")
        FileUtils.mkdir_p(dir)
        default = @library.builtin_store.path_for("template", "default")
        KINDS.each do |kind|
          from = edited.include?(kind) ? LegacyTmuxinatorTemplates.path(kind, @tmuxinator_dir) : File.join(default, "#{kind}.yml")
          FileUtils.cp(from, File.join(dir, "#{kind}.yml"))
        end
        dir
      end

      # The `[name, folder]` pairs at +source+.
      def import_sources(source)
        unless File.exist?(source)
          raise Error.new("Nothing at #{source} to import.", code: "library_source_missing", details: {"path" => source})
        end
        raise Error.new("#{source} is a file; import takes a folder.", code: "library_source_missing", details: {"path" => source}) unless File.directory?(source)

        if %w[project.yml worktree.yml].any? { |file| File.file?(File.join(source, file)) }
          [[File.basename(source), source]]
        else
          sets = Dir.children(source).sort.reject { |child| child.start_with?(".") }.select { |child| File.directory?(File.join(source, child)) }
          if sets.empty?
            raise Error.new("#{source} holds no tmuxinator template sets: expected project.yml and worktree.yml, or folders that hold them.",
              code: "library_source_missing", details: {"path" => source})
          end
          sets.map { |child| [child, File.join(source, child)] }
        end
      end

      # What importing one set would do, after checking its name, links and files and the keys that select what it replaces.
      # The files are staged first (regular non-dot files), so what is checked and compared is what would be written.
      def import_plan(store, name, dir, stage, force)
        raise UsageError, "'#{name}' is not a valid tmuxinator template name: lowercase letters, digits and hyphens, e.g. team." unless name.match?(IdPatterns::LIBRARY_NAME)
        raise UsageError, "'#{name}' is reserved for the edited copy `workspace init` installed. Rename the folder." if name == Workspace::Library::LEGACY_TEMPLATE
        links = [dir, *Find.find(dir).to_a].select { |entry| File.symlink?(entry) }
        unless links.empty?
          problems = links.map { |link| {"severity" => "error", "code" => "symlink", "kind" => nil, "message" => "#{link} is a symbolic link; a template set is plain files"} }
          raise Error.new("The tmuxinator template #{name} is not valid: #{problems.map { |p| p["message"] }.join("; ")}",
            code: "invalid_template", details: {"ref" => "template/#{name}", "problems" => problems})
        end
        staged = File.join(stage, name)
        FileUtils.mkdir_p(staged)
        LibraryStore.files_of(dir).each do |rel|
          FileUtils.mkdir_p(File.dirname(File.join(staged, rel)))
          FileUtils.cp(File.join(dir, rel), File.join(staged, rel))
        end
        checked = @template_validator.call_set(staged)
        unless checked.valid?
          raise Error.new("The tmuxinator template #{name} is not valid: #{checked.errors.map(&:to_s).join("; ")}",
            code: "invalid_template", details: {"ref" => "template/#{name}", "problems" => checked.errors.map(&:to_h)})
        end
        existing = store.path_for("template", name)
        outcome = if store.find("template", name).nil? then "added"
        elsif File.directory?(existing) && LibraryStore.tree_sha(existing) == LibraryStore.tree_sha(staged) then "unchanged"
        else
          "replaced"
        end
        if @template_in_use && !force && outcome != "unchanged"
          @template_in_use.check_default!(name, store)
          @template_in_use.check!(name, store, verb: "replace") if outcome == "replaced"
        end
        {"template" => name, "outcome" => outcome, "scope" => store.scope, "path" => existing, "staged" => staged,
         "warnings" => checked.warnings.map(&:to_h)}
      end

      def print_status(rows)
        if rows.empty?
          @output.puts "No workspaces to check."
          return
        end

        table = rows.map do |row|
          note = row.reasons.map { |reason| STATUS_REASONS.fetch(reason, reason) }.join(", ")
          note = "edited since it was rendered#{"; also #{note}" unless note.empty?}" if row.state == "modified"
          note = "adopted without an exact render; may hold edits (apply --force re-renders it)#{"; also #{note}" unless note.empty?}" if row.state == "modified" && row.approx
          note = "no render record" if row.state == "untracked"
          [TerminalText.escape(row.workspace), row.state, TerminalText.escape(row.template || "-"), note]
        end
        table.unshift(%w[WORKSPACE STATE TEMPLATE NOTE])
        widths = (0..2).map { |i| table.map { |r| r[i].length }.max }
        table.each { |r| @output.puts(r.each_with_index.map { |c, i| (i < 3) ? c.ljust(widths[i]) : c }.join("  ").rstrip) }
      end

      def print_apply(result, dry_run)
        @output.puts "No workspaces to apply to." if result.rows.empty?
        result.rows.each do |row|
          line = "#{TerminalText.escape(row["workspace"])}: #{row["outcome"].tr("_", " ")}"
          line += ": #{row["reason"]}" if row["reason"]
          line += " (#{TerminalText.escape(row["message"])})" if row["message"]
          @output.puts line
          write_text(row["diff"]) if row["diff"] && !row["diff"].empty?
        end
        result.warnings.each { |warning| @error_output.puts "Warning: #{TerminalText.escape(warning["message"])}" }
        @output.puts "Backup: #{result.backup}" if result.backup
        @output.puts "Dry run: nothing was written." if dry_run
      end

      def variable_row(row, inputs, workspace)
        data = {"name" => row.name, "kinds" => row.kinds.map(&:to_s), "required" => row.kinds.to_h { |k| [k.to_s, row.required[k]] },
                "description" => row.description, "source" => row.source, "sample" => row.sample, "whole_line" => row.fill == :line}
        data["value"] = variable_value(row, inputs) if inputs
        data
      end

      # What the renderer writes for a placeholder; a whole-line one with no value is dropped.
      def variable_value(row, inputs)
        value = inputs[row.input]
        return value unless row.fill == :line
        value ? "pre_window: export WORKSPACE_TASK=#{value}" : "(dropped)"
      end

      def print_adopt(rows, dry_run)
        @output.puts "No workspaces to adopt." if rows.empty?
        rows.each do |row|
          line = "#{TerminalText.escape(row["workspace"])}: #{row["outcome"].tr("_", " ")}"
          line += " #{row["match"]}" if row["match"]
          line += ": #{row["reason"]}" if row["reason"]
          line += " (#{TerminalText.escape(row["message"])})" if row["message"]
          @output.puts line
        end
        @output.puts "Dry run: nothing was written." if dry_run
      end

      def print_variables(rows, workspace, record)
        header = %w[NAME KINDS REQUIRED] + (workspace ? ["VALUE"] : []) + %w[DESCRIPTION]
        table = rows.map do |r|
          required = r["required"].select { |_, needed| needed }.keys
          cells = [r["name"], r["kinds"].join(", "), required.empty? ? "no" : required.join(", ")]
          if workspace
            cells << (if record
                        TerminalText.escape(r["value"].to_s) + ((record == :recovered) ? " (recovered)" : "")
                      else
                        "(no record)"
            end)
          end
          cells << r["description"]
        end
        table.unshift(header)
        widths = (0...header.size - 1).map { |i| table.map { |r| r[i].length }.max }
        table.each { |r| @output.puts(r.each_with_index.map { |c, i| (i < widths.size) ? c.ljust(widths[i]) : c }.join("  ").rstrip) }
      end

      # A worktree's name says its kind; anything else is a project.
      def default_kind(workspace)
        (workspace && WorkspaceName.worktree?(workspace)) ? :worktree : :project
      end

      def no_record(workspace)
        Error.new("Workspace '#{workspace}' has no render record, so there are no inputs to fill the tmuxinator template with. Use --sample to fill it with sample values.",
          code: "no_render_record", details: {"name" => workspace})
      end

      def render_target(set, file, kind, workspace)
        return {"template" => nil, "source" => "file", "path" => File.expand_path(file)} if file
        if set
          dir = @library.tmuxinator_set(set, workspace: workspace)["path"]
          return {"template" => set, "source" => "argument", "path" => File.join(dir, "#{kind}.yml")}
        end

        chosen = @library.tmuxinator_template(kind, workspace: workspace)
        {"template" => chosen["name"], "source" => chosen["source"], "path" => chosen["path"]}
      end

      def sample_inputs(kind)
        TemplateVariables.sample_inputs(kind).merge(agent_command: ProjectConfig.yaml_item(TemplateVariables.find("AGENT_COMMAND").sample))
      end

      # The filled text, or nil with the reason added to +problems+ when the renderer refuses.
      def filled(kind, inputs, text, problems)
        @project_config.render(kind, inputs, text)
      rescue Error => e
        unless problems.any? { |p| p["code"] == "render_failed" }
          problems << {"severity" => "error", "code" => "render_failed", "kind" => kind.to_s, "message" => e.message}
        end
        nil
      end

      def current_diff(workspace, content)
        path = @project_config.config_path_for(workspace)
        @differ.call(File.exist?(path) ? File.read(path) : "", content, old_label: path, new_label: "rendered")
      end

      def print_render(problems, text, diff)
        problems.each { |p| @error_output.puts "#{(p["severity"] == "error") ? "Error" : "Warning"}: #{TerminalText.escape(p["message"])}" }
        return unless text
        @error_output.puts "No differences from the current config." if diff && text.empty?
        write_text(text)
      end

      # Text goes out as it is to a pipe, escaped on a terminal.
      def write_text(text)
        if @output.respond_to?(:tty?) && @output.tty?
          text.each_line { |line| @output.write(TerminalText.escape(line.chomp, keep_tabs: true) + (line.end_with?("\n") ? "\n" : "")) }
        else
          @output.write(text)
        end
      end

      # One hash per file to check: kind, template, path. A missing file is left for the validator to report.
      def validation_targets(set, file, kind, workspace)
        if file
          path = File.expand_path(file)
          kinds = if kind
            kinds_for(kind)
          else
            [(File.basename(path) == "worktree.yml") ? :worktree : :project]
          end
          return [{"kind" => kinds.first.to_s, "template" => nil, "path" => path}]
        end

        kinds_for(kind).map do |k|
          if set
            entry = @library.tmuxinator_set(set, workspace: workspace)
            {"kind" => k.to_s, "template" => entry["name"], "path" => File.join(entry["path"], TemplateValidator::TEMPLATE_FILES[k])}
          else
            chosen = @library.tmuxinator_template(k, workspace: workspace)
            {"kind" => k.to_s, "template" => chosen["name"], "path" => chosen["path"]}
          end
        end
      end

      def count(number, word)
        "#{number} #{word}#{"s" unless number == 1}"
      end

      def print_validation(files)
        files.each do |target|
          problems = target["problems"]
          errors = problems.count { |p| p["severity"] == "error" }
          label = [target["template"] && "#{target["template"]}:", target["path"]].compact.join(" ")
          warnings = problems.size - errors
          @output.puts(problems.empty? ? "#{label}: valid" : "#{label}: #{count(errors, "error")}, #{count(warnings, "warning")}")
          problems.each { |p| @output.puts "  #{(p["severity"] == "error") ? "Error" : "Warning"}: #{TerminalText.escape(p["message"])}" }
        end
      end

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
