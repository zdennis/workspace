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
      # @param project_config [Workspace::ProjectConfig] `render` fills a template with it and `config_path_for` finds a config
      # @param writer [Workspace::TmuxinatorConfigWriter] reads a workspace's render record
      # @param template_validator [Workspace::TemplateValidator] checks the file `render` fills
      # @param differ [#call] `(old, new, old_label:, new_label:)` to a unified diff, empty when the same (a {TextDiff})
      # @param output [IO] output stream
      # @param error_output [IO] where `render`'s problems go in text mode
      def initialize(library:, project_config:, writer:, template_validator:, differ:, output: $stdout, error_output: $stderr)
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

      private

      # The inputs `render --name` fills with, which `variables --name` shows: the record's, with the agent command
      # worked out from the current agent settings (the recorded one is the pane text written then). Left out when
      # the renderer would refuse it, so `render` reports why.
      def record_inputs(record)
        inputs = record.inputs.except(:agent_command)
        value = @project_config.agent_pane_value(inputs[:agent_kind], inputs[:workspace_name])
        value ? inputs.merge(agent_command: ProjectConfig.yaml_item(value)) : inputs
      rescue Error
        inputs
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
