module Workspace
  # Picks the workflow `workflow start --ref REF` runs, from a table and never a guess: the key
  # {WorkflowDefaults} reads for the ref's kind (`workflows.by_ref.<kind>`, then `workflows.default`),
  # else the one workflow that fits the kind. A definition fits a kind when its `applies_to:` lists it
  # or is left out. With no key, a definition that cannot be read might fit, so while any is broken
  # nothing is taken as the only fit.
  class WorkflowRouter
    # Cuts a `use_when` line in a refusal.
    LISTED_USE_WHEN = 120

    # @param catalog [Workspace::WorkflowCatalog]
    # @param workflow_defaults [Workspace::WorkflowDefaults]
    def initialize(catalog:, workflow_defaults:)
      @catalog = catalog
      @workflow_defaults = workflow_defaults
    end

    # @param kind [String] a {WorkflowDefinition::REF_KINDS} entry, from {StartRef}
    # @param workspace [String] the project the ref would join; its file and the global one are read, and its
    #   own workflow definitions are searched before the user's and the presets
    # @param ref [String, nil] the ref, for a refusal's details
    # @param force [Boolean] let a configured default whose `applies_to:` leaves out the kind through
    # @param registered [Boolean] whether +workspace+ is a registered project (else `config set --scope project` has no file to write)
    # @return [Hash{String=>String, nil}] "workflow", "kind", "source" (`default` or `only_fit`), "scope" (`project` or
    #   `global` for a default, else nil), "key" (the config key) and "definition_source" (`project`, `global` or `builtin`: the directory
    #   the chosen definition is read from)
    # @raise [Workspace::Error] code `invalid_workflow_default` (the configured workflow is unknown, unusable, or not
    #   for the kind and not +force+) or `no_default_workflow` (several or none fit, or a definition is broken, and no default is set)
    def route(kind:, workspace:, ref: nil, force: false, registered: true)
      rows, broken = readable(workspace)
      hit = @workflow_defaults.lookup(kind, workspace: workspace)
      return default_route(hit[:id], hit[:scope], hit[:key], kind, rows, force, workspace, registered) if hit

      key = "workflows.by_ref.#{kind}"
      fits = rows.select { |row| fits?(row, kind) }
      return {"workflow" => fits.first["id"], "kind" => kind, "source" => "only_fit", "scope" => nil, "key" => key, "definition_source" => fits.first["source"]} if fits.size == 1 && broken.empty?

      refuse_unrouted(kind, ref, key, fits, broken, workspace, registered, rows)
    end

    # What `no_default_workflow` says of a kind, for a start that named no workflow and no key answered.
    #
    # @param kind [String] a {ConfigSchema::WORKFLOW_REF_KINDS} entry; `prompt` has no `applies_to` check, so every workflow fits it
    # @param workspace [String, nil] the project the ref would join
    # @return [Hash{String=>Object}] "key", "reason", "candidates" (id and use_when of each fit) and "broken"
    def unrouted(kind, workspace: nil)
      rows, broken = readable(workspace)
      unrouted_details(kind, "workflows.by_ref.#{kind}", rows.select { |row| fits?(row, kind) }, broken)
    end

    private

    def readable(workspace)
      @catalog.list(project: WorkflowCatalog.project_of(workspace)).partition { |row| row["problems"].empty? }.then { |rows, bad| [rows, bad.map { |row| row["id"] }] }
    end

    def unrouted_details(kind, key, fits, broken)
      candidates = fits.map { |row| {"id" => row["id"], "use_when" => row["use_when"]} }
      reason = if broken.any? then "broken_definition"
      elsif candidates.empty? then "none_fit"
      else "several"
      end
      {"key" => key, "reason" => reason, "candidates" => candidates, "broken" => broken.map { |id| TerminalText.escape(id) }}
    end

    def default_route(configured, scope, key, kind, rows, force, workspace, registered)
      reason = if !configured.is_a?(String) || !IdPatterns::WORKFLOW_ID.match?(configured)
        "invalid_value"
      elsif (row = rows.find { |each| each["id"] == configured }).nil?
        "unknown_workflow"
      elsif !fits?(row, kind)
        "not_for_kind" unless force
      end
      raise_invalid_default(reason, configured, key, kind, row, rows, workspace, registered) if reason
      {"workflow" => configured, "kind" => kind, "source" => "default", "scope" => scope, "key" => key,
       "definition_source" => rows.find { |each| each["id"] == configured }["source"]}
    end

    def raise_invalid_default(reason, configured, key, kind, row, rows, workspace, registered)
      shown = TerminalText.escape(configured.to_s[0, 60])
      set = set_command(key, workspace, registered)
      message = case reason
      when "invalid_value" then "#{key} is #{shown.inspect}, which is not a workflow id. Fix it with `#{set}`, or unset it."
      when "unknown_workflow" then "#{key} names #{shown}, which is not a usable workflow (known: #{rows.map { |each| each["id"] }.join(", ")}). --force does not help. Fix it with `#{set}`, or unset it."
      else "#{key} names #{shown}, whose applies_to: (#{row["applies_to"].join(", ")}) leaves out #{kind}. Pass --force to start it anyway (the run starts with a warning), or change the default with `#{set}`."
      end
      details = {"key" => key, "workflow" => configured.to_s[0, 60], "kind" => kind, "reason" => reason}
      details["applies_to"] = row["applies_to"] if row
      raise Workspace::Error.new(message, code: "invalid_workflow_default", details: details)
    end

    def refuse_unrouted(kind, ref, key, fits, broken, workspace, registered, rows)
      details = unrouted_details(kind, key, fits, broken)
      candidates = details["candidates"]
      shown_broken = details["broken"]
      set = set_command(key, workspace, registered)
      unread = "Could not be read, so may fit: #{shown_broken.join(", ")} (see `workspace workflow show`)." if broken.any?
      head = if candidates.empty?
        "No readable workflow fits #{kind}."
      else
        width = candidates.map { |each| each["id"].length }.max
        lines = candidates.map { |each| "  #{each["id"].ljust(width)}   #{TerminalText.escape(each["use_when"].to_s)[0, LISTED_USE_WHEN]}".rstrip }
        "#{(candidates.size == 1) ? "One readable workflow fits #{kind}:" : "Several workflows fit #{kind}. Pick one:"}\n#{lines.join("\n")}"
      end
      message = [head, unread, "Name one with `workspace workflow start ID REF`, or set a default with `#{set}`."].compact.join("\n")
      raise Workspace::Error.new(message, code: "no_default_workflow",
        details: {"kind" => kind, "ref" => ref, "known" => rows.map { |row| row["id"] }}.merge(details))
    end

    def set_command(key, workspace, registered)
      "workspace config set #{key} ID#{" --scope project --name #{workspace}" if registered}"
    end

    def fits?(row, kind)
      return true if kind == "prompt"

      applies = Array(row["applies_to"])
      applies.empty? || applies.include?(kind)
    end
  end
end
