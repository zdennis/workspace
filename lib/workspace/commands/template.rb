require "digest"
require "json"

module Workspace
  module Commands
    # `template list|show|path`: the tmuxinator template sets a new tmuxinator config can be
    # rendered from, which of them each kind selects, and where their files are. A set is a
    # `template` library entry (a directory holding `project.yml` and `worktree.yml`); the choice
    # is the `tmuxinator.template` and `tmuxinator.worktree_template` keys, resolved by
    # {Workspace::Library#tmuxinator_template}. `list`, `show`, `path`, `variables`, `render`, `validate` and `diff`
    # read; `new`, `edit` and `use` change a set or the key that selects one.
    class Template
      # Bumped whenever a `--json` payload's shape changes in a backward-incompatible way.
      JSON_SCHEMA_VERSION = 1

      # The kinds of tmuxinator config a set has a file for, in the order they are shown.
      KINDS = %i[project worktree].freeze

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
      # @param output [IO] output stream
      # @param error_output [IO] where `render`'s problems go in text mode
      def initialize(library:, project_config:, writer:, template_validator:, differ:, config_command: nil, selection: nil, status: nil, output: $stdout, error_output: $stderr)
        @config_command = config_command
        @selection = selection
        @status = status
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
        rows = TemplateVariables::ROWS.select { |row| (row.kinds & kinds).any? }.map { |row| variable_row(row, inputs, workspace) }
        if json
          doc = JsonEnvelope.document("variables", rows, schema_version: JSON_SCHEMA_VERSION).merge("workspace" => workspace)
          doc["value_state"] = if workspace
            record ? "recorded" : "no_record"
          end
          @output.puts JSON.generate(doc)
        else
          print_variables(rows, workspace, !record.nil?)
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

      def print_status(rows)
        if rows.empty?
          @output.puts "No workspaces to check."
          return
        end

        table = rows.map do |row|
          note = row.reasons.map { |reason| STATUS_REASONS.fetch(reason, reason) }.join(", ")
          note = "edited since it was rendered#{"; also #{note}" unless note.empty?}" if row.state == "modified"
          note = "no render record" if row.state == "untracked"
          [TerminalText.escape(row.workspace), row.state, TerminalText.escape(row.template || "-"), note]
        end
        table.unshift(%w[WORKSPACE STATE TEMPLATE NOTE])
        widths = (0..2).map { |i| table.map { |r| r[i].length }.max }
        table.each { |r| @output.puts(r.each_with_index.map { |c, i| (i < 3) ? c.ljust(widths[i]) : c }.join("  ").rstrip) }
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

      def print_variables(rows, workspace, record)
        header = %w[NAME KINDS REQUIRED] + (workspace ? ["VALUE"] : []) + %w[DESCRIPTION]
        table = rows.map do |r|
          required = r["required"].select { |_, needed| needed }.keys
          cells = [r["name"], r["kinds"].join(", "), required.empty? ? "no" : required.join(", ")]
          cells << (record ? TerminalText.escape(r["value"].to_s) : "(no record)") if workspace
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
