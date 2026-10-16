require "json"
require "time"
require "uri"

module Workspace
  module Commands
    # The inbox: one durable list of things that need a person, kept per
    # scope (a workspace, a project, or global) in {Workspace::InboxStore}.
    # Everything an item carries is untrusted text from agents, scripts and
    # outside tools: it is checked on the way in, never run or typed anywhere,
    # and printed with control characters escaped.
    class Inbox
      # Bumped whenever the `--json` payload's shape changes in a
      # backward-incompatible way.
      JSON_SCHEMA_VERSION = 1

      # The item types `add` accepts.
      TYPES = %w[todo alert note review_request].freeze

      # The states `list --state` accepts.
      STATES = %w[open snoozed done dismissed].freeze

      # The source kinds `add --source-kind` accepts.
      SOURCE_KINDS = %w[jira github_pr github_check session agent cli user].freeze

      TITLE_MAX = 200
      BODY_MAX = 8192
      REF_MAX = 200
      URL_MAX = 2048
      LINK_MAX = 64
      # Bytes read from `--body-file`.
      INPUT_MAX = 64 * 1024

      # One inbox file: where it is and how it is named.
      # @!attribute kind [String] `"workspace"`, `"project"` or `"global"`
      # @!attribute key [String, nil] the workspace name, a project's git common dir
      # @!attribute name [String, nil] the display name
      # @!attribute label [String] how the scope is shown (`workspace:api`)
      # @!attribute path [String] the scope's JSON file
      Scope = Struct.new(:kind, :key, :name, :label, :path)

      # @param config [Workspace::Config] inbox path lookups
      # @param project_detector [Workspace::ProjectDetector] resolves the workspace from the cwd
      # @param project_catalog [Workspace::ProjectCatalog, nil] finds a project by name or path,
      #   and the project of a directory
      # @param session_ledger [Workspace::SessionLedger, nil] says which agent session runs in a pane
      # @param store_factory [#call] `(path:, scope:, error_output:)` returning an {Workspace::InboxStore}
      # @param env [Hash] process environment, for `TMUX_PANE` and `TMUX`
      # @param input [IO] read by `--body-file -`
      # @param clock [#call] returns the current Time
      # @param event_log [Workspace::EventLog, nil] records `inbox_changed` (ids and states only,
      #   never the item's text); nil records nothing
      # @param output [IO]
      # @param error_output [IO]
      def initialize(config:, project_detector:, store_factory:, project_catalog: nil, session_ledger: nil,
        env: ENV, input: $stdin, clock: -> { Time.now }, event_log: nil, output: $stdout, error_output: $stderr)
        @config = config
        @project_detector = project_detector
        @project_catalog = project_catalog
        @session_ledger = session_ledger
        @store_factory = store_factory
        @env = env
        @input = input
        @clock = clock
        @event_log = event_log
        @output = output
        @error_output = error_output
      end

      # Creates an item. The text is checked first; nothing is written when any field is refused.
      #
      # @param title [String] one line, 1 to 200 characters
      # @param type [String] one of {TYPES}
      # @param body [String, nil] up to 8192 characters
      # @param body_file [String, nil] a path, or `-` for stdin, read instead of +body+ (64 KB cap)
      # @param source [Hash] `:kind`, `:ref`, `:url` (https only)
      # @param expires [String, nil] a duration (`2h`) or an ISO 8601 time in the future
      # @param expires_field [String] the field name an expiry error reports (`expires_at` for JSON input)
      # @param links [Hash] `:pane`, `:plan_task`, `:pr`, `:run_id`
      # @param as_user [Boolean] record the item as made by a person, not a script or agent
      # @param target [Hash] `:name`, `:project`, `:global`; none means the workspace of +working_dir+
      # @param working_dir [String] directory to detect the workspace from
      # @return [Hash] `{exit_code:, results:}` for the action document
      # @raise [Workspace::Error] `invalid_inbox_item`, `not_in_workspace`, `inbox_store_unreadable`
      def add(title:, type: "todo", body: nil, body_file: nil, source: {}, expires: nil, links: {},
        as_user: false, target: {}, working_dir: Dir.pwd, expires_field: "expires")
        raise UsageError, "Pass --body or --body-file, not both." if body && body_file
        scope = scope_for_write(target, working_dir)
        created_by = created_by(as_user)
        record = {
          "type" => checked_type(type),
          "scope" => {"kind" => scope.kind, "key" => scope.key, "name" => scope.name},
          "title" => checked_title(title),
          "body" => checked_body(body_file ? read_input(body_file, "body") : body),
          "source" => checked_source(source, created_by["kind"]),
          "dedupe_key" => nil,
          "created_by" => created_by,
          "links" => checked_links(links),
          "expires_at" => checked_expiry(expires, expires_field)
        }
        item = store_for(scope).add(record)
        record_change(item, "created")
        @output.puts "Added inbox item #{item["id"]} to #{scope.label}: #{escape(item["title"])}"
        {exit_code: 0, results: [{"id" => item["id"], "outcome" => "created", "scope" => scope.label, "item" => item}]}
      end

      # Creates an item from one JSON object holding only the item's writable
      # keys (`type`, `title`, `body`, `source`, `dedupe_key`, `expires_at`,
      # `links`, `scope`). Every field gets the same checks as {#add}; nothing
      # is written when any is refused.
      #
      # @param path [String] a file, or `-` for stdin (64 KB cap)
      # @param working_dir [String] directory to detect the workspace from when the object has no `scope`
      # @return [Hash] as {#add}
      # @raise [Workspace::Error] `invalid_inbox_item`, `not_in_workspace`, `inbox_store_unreadable`
      def add_from_json(path, working_dir: Dir.pwd)
        data = parse_item_json(read_input(path, "json"))
        title = data.fetch("title") { raise invalid("title", "is required") }
        add(title: string_field("title", title),
          type: data.key?("type") ? string_field("type", data["type"]) : "todo",
          body: string_field("body", data["body"]),
          source: json_source(data["source"]),
          expires: string_field("expires_at", data["expires_at"]),
          expires_field: "expires_at",
          links: json_links(data["links"]),
          target: json_target(data["scope"]),
          working_dir: working_dir)
      end

      # Prints items, newest change first. Without +all+ or a scope flag it reads
      # the current workspace, its project, and the global list; outside a
      # workspace, the global list.
      #
      # @param target [Hash] `:name`, `:project`, `:global`
      # @param working_dir [String]
      # @param states [Array<String>] states to show; `open` when empty
      # @param type [String, nil] only this type
      # @param all [Boolean] read every scope that has a file
      # @param json [Boolean] print `{schema_version, ok, items, warnings}`
      # @return [Hash] `{exit_code:}`
      def list(target: {}, working_dir: Dir.pwd, states: [], type: nil, all: false, json: false)
        raise UsageError, "Pass --all or a scope flag, not both." if all && target.values.any?
        checked_filter_states(states)
        checked_filter_type(type)
        states = %w[open] if states.empty?
        scopes = all ? every_scope : default_scopes(target, working_dir)
        sink = StringIO.new
        items = scopes.flat_map { |scope| store_for(scope, sink).list }
        items = items.select { |item| states.include?(item["state"]) }
        items = items.select { |item| item["type"] == type } if type
        items = items.sort_by { |item| [item["updated_at"].to_s, item["id"].to_s] }.reverse
        warnings = warnings_from(sink)

        if json
          @output.puts JSON.generate({"schema_version" => JSON_SCHEMA_VERSION, "ok" => true, "items" => items, "warnings" => warnings})
        else
          warnings.each { |w| @error_output.puts w["message"] }
          print_table(items)
        end
        {exit_code: 0}
      end

      # Prints one item, in any state.
      #
      # @param id [String]
      # @param target [Hash] `:name`, `:project`, `:global`; none searches every scope
      # @param working_dir [String]
      # @param json [Boolean] print `{schema_version, ok, item, warnings}`
      # @return [Hash] `{exit_code:}`
      # @raise [Workspace::Error] `unknown_inbox_item`, or `ambiguous_inbox_item` when
      #   the id is in more than one scope
      def show(id, target: {}, working_dir: Dir.pwd, json: false)
        sink = StringIO.new
        scope, item = locate(id, lookup_scopes(target, working_dir), sink)
        warnings = warnings_from(sink)

        if json
          @output.puts JSON.generate({"schema_version" => JSON_SCHEMA_VERSION, "ok" => true, "item" => item, "warnings" => warnings})
        else
          warnings.each { |w| @error_output.puts w["message"] }
          print_item(scope, item)
        end
        {exit_code: 0}
      end

      # Marks items done. Already-done items are `unchanged`, so a retry is safe.
      #
      # @param ids [Array<String>]
      # @param target [Hash] `:name`, `:project`, `:global`; none searches every scope
      # @param working_dir [String]
      # @return [Hash] `{exit_code:, results:}`; one row per id, outcome `resolved`,
      #   `unchanged` or `failed` (with `code` and `error`); exit 0, 3 when some failed, 1 when all did
      def done(ids, target: {}, working_dir: Dir.pwd)
        change(ids, "done", target, working_dir)
      end

      # Like {#done}, for items nobody will act on.
      #
      # @param (see #done)
      # @return [Hash] as {#done}
      def dismiss(ids, target: {}, working_dir: Dir.pwd)
        change(ids, "dismissed", target, working_dir)
      end

      # Moves done, dismissed or snoozed items back to open. Open items are `unchanged`.
      #
      # @param ids [Array<String>]
      # @param target [Hash] `:name`, `:project`, `:global`; none searches every scope
      # @param working_dir [String]
      # @return [Hash] as {#done}, with outcome `reopened` instead of `resolved`
      def reopen(ids, target: {}, working_dir: Dir.pwd)
        change(ids, "open", target, working_dir)
      end

      private

      def change(ids, to, target, working_dir)
        scopes = lookup_scopes(target, working_dir)
        by = to.start_with?("d") ? resolver : nil
        results = ids.map { |id| change_one(id, to, by, scopes) }
        failed = results.count { |row| row["outcome"] == "failed" }
        exit_code = if failed.zero? then 0
        elsif failed == results.size then 1
        else
          3
        end
        {exit_code: exit_code, results: results}
      end

      def change_one(id, to, by, scopes)
        scope, found = locate(id, scopes, @error_output)
        transition = store_for(scope).transition(found["id"], to: to, by: by)
        raise unknown_item(id) unless transition
        item = transition.record
        outcome = if !transition.changed then "unchanged"
        elsif to == "open" then "reopened"
        else
          "resolved"
        end
        record_change(item, outcome) unless outcome == "unchanged"
        say = (outcome == "unchanged") ? "#{escape(id)} is already #{item["state"]}" : "#{escape(id)} #{outcome}"
        @output.puts "#{say} (#{scope.label}): #{escape(item["title"])}"
        {"id" => item["id"], "outcome" => outcome, "scope" => scope.label, "item" => item}
      rescue Workspace::Error => e
        raise unless %w[unknown_inbox_item ambiguous_inbox_item inbox_store_unreadable].include?(e.code)
        @error_output.puts e.message
        {"id" => id, "outcome" => "failed", "code" => e.code, "error" => e.message, "details" => e.details}
      end

      # Writes `inbox_changed`: the workspace or project name for those scopes, "" for global.
      # The item's text stays in the store; EventLog#record never raises.
      def record_change(item, change)
        scope = item["scope"]
        @event_log&.record(type: "inbox_changed", project: scope["name"] || "",
          data: {"id" => item["id"], "scope" => scope["kind"], "scope_key" => scope["key"], "state" => item["state"], "change" => change})
      end

      # Who resolved an item: the calling pane, as an agent only when the session ledger says so.
      def resolver
        by = created_by(false)
        {"kind" => by["kind"], "pane" => by["pane"]}
      end

      def lookup_scopes(target, working_dir)
        target.values.any? ? [explicit_scope(target, working_dir)] : every_scope
      end

      # @return [Array] the scope and the item with this id
      # @raise [Workspace::Error] `unknown_inbox_item`, `ambiguous_inbox_item`
      def locate(id, scopes, sink)
        found = scopes.filter_map do |scope|
          item = store_for(scope, sink).find(id)
          [scope, item] if item
        end
        raise unknown_item(id) if found.empty?
        raise ambiguous_item(id, found.map { |scope, _| scope.label }) if found.size > 1
        found.first
      end

      def invalid(field, reason)
        Workspace::Error.new("Invalid inbox item: #{field} #{reason}.",
          code: "invalid_inbox_item", details: {"field" => field, "reason" => reason})
      end

      def unknown_item(id)
        Workspace::Error.new("No inbox item '#{escape(id)}'.", code: "unknown_inbox_item", details: {"id" => id})
      end

      def ambiguous_item(id, labels)
        Workspace::Error.new("Inbox id '#{escape(id)}' is in more than one scope: #{labels.join(", ")}. Pass --name, --project or --global to pick one (workspace inbox show ID --global).",
          code: "ambiguous_inbox_item", details: {"id" => id, "scopes" => labels})
      end

      # C0 controls (and DEL), C1 controls, and the Unicode line separators.
      CONTROL = /[\u0000-\u001f\u007f-\u009f  ]/
      # The same, minus a newline and a tab, which a body may hold.
      BODY_CONTROL = /[\u0000-\u0008\u000b-\u001f\u007f-\u009f  ]/
      private_constant :CONTROL, :BODY_CONTROL

      def checked_text(field, value, max:, pattern: CONTROL, required: false)
        text = value.to_s
        raise invalid(field, "must be valid UTF-8") unless text.valid_encoding?
        raise invalid(field, "is required") if required && text.strip.empty?
        raise invalid(field, "has a control character") if text.match?(pattern)
        raise invalid(field, "is longer than #{max} characters") if text.length > max
        text
      end

      def checked_title(title)
        raise invalid("title", "must be valid UTF-8") unless title.to_s.valid_encoding?
        checked_text("title", title.to_s.strip, max: TITLE_MAX, required: true)
      end

      def checked_body(body)
        return nil if body.nil?
        raise invalid("body", "must be valid UTF-8") unless body.to_s.valid_encoding?
        text = checked_text("body", body.to_s.sub(/\s+\z/, ""), max: BODY_MAX, pattern: BODY_CONTROL)
        text.empty? ? nil : text
      end

      def checked_type(type)
        raise invalid("type", "must be one of #{TYPES.join(", ")}") unless TYPES.include?(type)
        type
      end

      def checked_source(source, created_kind)
        kind = source[:kind] || created_kind
        raise invalid("source.kind", "must be one of #{SOURCE_KINDS.join(", ")}") unless SOURCE_KINDS.include?(kind)
        ref = source[:ref] && checked_text("source.ref", source[:ref], max: REF_MAX)
        {"kind" => kind, "ref" => ref, "url" => checked_url(source[:url])}
      end

      def checked_url(url)
        return nil if url.nil?
        text = checked_text("source.url", url, max: URL_MAX)
        uri = begin
          URI.parse(text)
        rescue URI::InvalidURIError
          nil
        end
        raise invalid("source.url", "must be an https:// URL") unless uri.is_a?(URI::HTTPS) && uri.host && !uri.host.empty?
        text
      end

      def checked_links(links)
        pr = links[:pr]
        raise invalid("links.pr", "must be a positive number") if pr && !(pr.is_a?(Integer) && pr.positive?)
        {
          "pane" => links[:pane] && checked_text("links.pane", links[:pane], max: LINK_MAX, required: true),
          "plan_task" => links[:plan_task] && checked_text("links.plan_task", links[:plan_task], max: LINK_MAX, required: true),
          "pr" => pr,
          "run_id" => links[:run_id] && checked_text("links.run_id", links[:run_id], max: LINK_MAX, required: true)
        }
      end

      # @return [String, nil] an ISO 8601 UTC time in the future
      def checked_expiry(expires, field = "expires")
        return nil if expires.nil?
        now = @clock.call
        at = begin
          Time.iso8601(expires.to_s)
        rescue ArgumentError
          begin
            now + Duration.parse_positive(expires)
          rescue ArgumentError
            raise invalid(field, "must be a duration like 2h or an ISO 8601 time")
          end
        end
        raise invalid(field, "must be in the future") unless at > now
        at.utc.iso8601
      end

      def read_input(path, field)
        data = (path == "-") ? @input.read(INPUT_MAX + 1) : File.open(path, "rb") { |f| f.read(INPUT_MAX + 1) }
        text = data.to_s.dup.force_encoding(Encoding::UTF_8)
        raise invalid(field, "is longer than #{INPUT_MAX / 1024} KB") if text.bytesize > INPUT_MAX
        text
      rescue SystemCallError
        raise invalid(field, "can't be read from the file")
      end

      JSON_KEYS = %w[type title body source dedupe_key expires_at links scope].freeze
      JSON_SOURCE_KEYS = %w[kind ref url].freeze
      JSON_LINK_KEYS = %w[pane plan_task pr run_id].freeze
      JSON_SCOPE_KEYS = %w[kind name].freeze
      private_constant :JSON_KEYS, :JSON_SOURCE_KEYS, :JSON_LINK_KEYS, :JSON_SCOPE_KEYS

      def parse_item_json(text)
        raise invalid("json", "must be valid UTF-8") unless text.valid_encoding?
        data = begin
          JSON.parse(text)
        rescue JSON::ParserError
          raise invalid("json", "is not valid JSON")
        end
        raise invalid("json", "must be one object") unless data.is_a?(Hash)
        unknown = data.keys - JSON_KEYS
        raise invalid(unknown.first.to_s, "is not a writable key (use #{JSON_KEYS.join(", ")})") if unknown.any?
        # Dedupe arrives with the upsert (INB7); storing a key that does not dedupe would mislead a poster.
        raise invalid("dedupe_key", "is not supported yet") unless data["dedupe_key"].nil?
        data
      end

      def string_field(field, value)
        return nil if value.nil?
        raise invalid(field, "must be a string") unless value.is_a?(String)
        value
      end

      def json_object(field, value, keys)
        return {} if value.nil?
        raise invalid(field, "must be an object") unless value.is_a?(Hash)
        unknown = value.keys - keys
        raise invalid("#{field}.#{unknown.first}", "is not a writable key (use #{keys.join(", ")})") if unknown.any?
        value
      end

      def json_source(value)
        json_object("source", value, JSON_SOURCE_KEYS)
          .to_h { |key, v| [key.to_sym, string_field("source.#{key}", v)] }.compact
      end

      def json_links(value)
        json_object("links", value, JSON_LINK_KEYS).to_h do |key, v|
          [key.to_sym, (key == "pr") ? v : string_field("links.#{key}", v)]
        end.compact
      end

      # `{"kind": "global"}`, or `workspace`/`project` with a `name` (a project
      # name or a path in it); no object means the workspace of the working directory.
      def json_target(value)
        object = json_object("scope", value, JSON_SCOPE_KEYS)
        return {} if value.nil?
        kind = string_field("scope.kind", object["kind"])
        name = string_field("scope.name", object["name"])
        case kind
        when "global"
          raise invalid("scope.name", "must be absent for the global scope") if name
          {global: true}
        when "workspace", "project"
          raise invalid("scope.name", "is required") if name.to_s.empty?
          {(kind == "workspace") ? :name : :project => name}
        else
          raise invalid("scope.kind", "must be one of workspace, project, global")
        end
      end

      # `agent` only when the ledger knows an open agent session in the pane;
      # a bare TMUX_PANE (a shell in tmux) is `cli`.
      def created_by(as_user)
        pane = @env["TMUX_PANE"].to_s
        pane = nil unless pane.match?(/\A%\d+\z/)
        server = @env["TMUX"].to_s[/\A[^,]*,(\d+),/, 1]
        session = pane && @session_ledger&.open_session_for(pane_id: pane, tmux_server: server)
        kind = if as_user then "user"
        elsif session then "agent"
        else
          "cli"
        end
        {"kind" => kind, "pane" => pane, "session_id" => session, "tmux_server" => server}
      end

      def scope_for_write(target, working_dir)
        return explicit_scope(target, working_dir) if target.values.any?
        detected_workspace(working_dir) { |name| workspace_scope(name) } ||
          raise(Workspace::Error.new("Not inside a workspace (#{working_dir}). Pass --name WORKSPACE to use one, or --project NAME or --global to add to a wider list.",
            code: "not_in_workspace", details: {"path" => working_dir}))
      end

      def explicit_scope(target, working_dir)
        raise UsageError, "Pass only one of --name, --project and --global." if target.values.count { |v| v } > 1
        if target[:global]
          global_scope
        elsif target[:project]
          raise Workspace::Error, "Projects are not available in this build." unless @project_catalog
          project_scope(@project_catalog.find(target[:project]))
        else
          name = target[:name]
          workspace_scope(name)
        end
      end

      def default_scopes(target, working_dir)
        return [explicit_scope(target, working_dir)] if target.values.any?
        scopes = []
        detected_workspace(working_dir) do |name|
          scopes << workspace_scope(name)
          project = project_of(working_dir)
          scopes << project_scope(project) if project
        end
        scopes << global_scope
      end

      def detected_workspace(working_dir)
        name = @project_detector.detect(working_dir)
        name && yield(name)
      end

      def project_of(working_dir)
        @project_catalog&.for_cwd(working_dir)
      rescue Workspace::Error
        nil
      end

      def workspace_scope(name)
        Scope.new("workspace", name, name, "workspace:#{name}", @config.inbox_path("workspace", name))
      rescue ArgumentError
        raise Workspace::Error.new("'#{escape(name)}' can't name an inbox scope.", code: "unknown_workspace", details: {"name" => name})
      end

      def project_scope(project)
        Scope.new("project", project.id, project.name, "project:#{project.name}",
          @config.inbox_path("project", project.id, name: project.name))
      end

      def global_scope
        Scope.new("global", nil, nil, "global", @config.inbox_path("global"))
      end

      # Every scope that has a file, labeled from its path.
      def every_scope
        dir = @config.inbox_dir
        workspaces = Dir.glob(File.join(dir, "workspace", "*.json")).sort.map do |path|
          Scope.new("workspace", nil, nil, "workspace:#{File.basename(path, ".json")}", path)
        end
        projects = Dir.glob(File.join(dir, "project", "*.json")).sort.map do |path|
          Scope.new("project", nil, nil, "project:#{File.basename(path, ".json")}", path)
        end
        global = global_scope
        workspaces + projects + (File.exist?(global.path) ? [global] : [])
      end

      def store_for(scope, error_output = @error_output)
        @store_factory.call(path: scope.path, scope: scope.label, error_output: error_output)
      end

      def warnings_from(sink)
        sink.string.lines.map(&:chomp).reject(&:empty?).map { |line| {"code" => "inbox_store_unreadable", "message" => line} }
      end

      def checked_filter_states(states)
        bad = states - STATES
        raise UsageError, "Unknown state: #{bad.map { |s| escape(s) }.join(", ")}. Use #{STATES.join(", ")}." if bad.any?
      end

      def checked_filter_type(type)
        raise UsageError, "Unknown type: #{escape(type)}. Use #{TYPES.join(", ")}." if type && !TYPES.include?(type)
      end

      def print_table(items)
        if items.empty?
          @output.puts "No items to show. Try --all, or --state open,snoozed,done,dismissed."
          return
        end
        @output.puts "ID         STATE     TYPE            SCOPE                    TITLE"
        items.each do |item|
          @output.puts format("%-10s %-9s %-15s %-24s %s", escape(item["id"]), escape(item["state"]), escape(item["type"]),
            escape(scope_label(item["scope"])), escape(item["title"]))
        end
      end

      def print_item(scope, item)
        @output.puts "#{escape(item["id"])}  #{escape(item["title"])}"
        @output.puts "  State:    #{escape(item["state"])}#{snooze_note(item)}"
        @output.puts "  Type:     #{escape(item["type"])}"
        @output.puts "  Scope:    #{escape(scope_label(item["scope"]) || scope.label)}"
        source = item["source"].is_a?(Hash) ? item["source"] : {}
        @output.puts "  Source:   #{escape([source["kind"], source["ref"], source["url"]].compact.join(" "))}"
        by = item["created_by"].is_a?(Hash) ? item["created_by"] : {}
        @output.puts "  By:       #{escape([by["kind"], by["pane"]].compact.join(" "))}"
        %w[created_at updated_at resolved_at expires_at].each do |key|
          @output.puts format("  %-9s %s", "#{key.sub("_at", "").capitalize}:", escape(item[key])) if item[key]
        end
        links = item["links"].is_a?(Hash) ? item["links"].compact : {}
        @output.puts "  Links:    #{escape(links.map { |k, v| "#{k}=#{v}" }.join(" "))}" if links.any?
        return unless item["body"]
        @output.puts
        item["body"].to_s.lines.each { |line| @output.puts "  #{escape(line.chomp, keep_tabs: true)}" }
      end

      def snooze_note(item)
        item["snooze_until"] ? " until #{escape(item["snooze_until"])}" : ""
      end

      def scope_label(scope)
        return nil unless scope.is_a?(Hash)
        (scope["kind"] == "global") ? "global" : "#{scope["kind"]}:#{scope["name"] || scope["key"]}"
      end

      # Text for a terminal: every control character shown as an escape, so a
      # posted title can't move the cursor, recolor the screen or fake a line.
      def escape(text, keep_tabs: false)
        text.to_s.scrub.gsub(CONTROL) do |char|
          next char if keep_tabs && char == "\t"
          case char
          when "\e" then "\\e"
          when "\n" then "\\n"
          when "\r" then "\\r"
          when "\t" then "\\t"
          else format("\\u%04X", char.ord)
          end
        end
      end
    end
  end
end
