module Workspace
  module Commands
    # `work-queue`: one method per verb over a workspace's queue of items
    # ({Workspace::WorkQueueStore}) and its history ({Workspace::WorkQueueHistory}).
    #
    # Every method takes parsed values. An action (`add`, `rm`, `move`, `enable`,
    # `disable`, `resume`, `skip`, `cancel`, `advance`, `history_clear`) returns
    # rows of `{"outcome", "id", "position", "kind", ...}` for `run_action`, and
    # {#action_extra} gives the `extra` of its document. A read (`list`, `show`,
    # `active`, `status`, `history_list`, `history_show`) returns a Hash with its
    # payload and `"warnings"`, and prints for a person. The workspace comes from
    # `name`, else the one the working directory is in. `--project` reads never
    # write, not even a pruned history.
    class WorkQueue
      # The warning code for a workspace whose agent daemon is not answering.
      DAEMON_WARNING = "daemon_not_running"

      # Characters of an item's summary a list row shows.
      WHAT_LENGTH = 60

      # @param store_factory [#call] workspace name to its {Workspace::WorkQueueStore}
      # @param history_factory [#call] workspace name to its {Workspace::WorkQueueHistory}
      # @param advance [Workspace::WorkQueueAdvance] the pass `advance` and `cancel --and-continue` run
      # @param decisions [Workspace::WorkflowDecisions] cancels a run
      # @param run_store [Workspace::WorkflowRunStore] reads a run's state
      # @param checkout [Workspace::WorkspaceCheckout] names a workspace and its checkout
      # @param go [Workspace::Commands::Go] says whether a checkout can run `go` in place
      # @param status_scope [Workspace::StatusScope] picks the workspaces of `--project`
      # @param config [Workspace::Config] says whether a workspace's daemon answers
      # @param clock [#now] time source, for ages
      # @param working_dir [String] where the current workspace is looked for
      # @param output [IO] stream for the human result
      # @param error_output [IO] stream for warnings
      # @param input [IO, Workspace::PromptInput] where `history clear` reads its answer
      def initialize(store_factory:, history_factory:, advance:, decisions:, run_store:, checkout:, go:, status_scope:, config:,
        clock: Time, working_dir: Dir.pwd, output: $stdout, error_output: $stderr, input: $stdin)
        @store_factory = store_factory
        @history_factory = history_factory
        @advance = advance
        @decisions = decisions
        @run_store = run_store
        @checkout = checkout
        @go = go
        @status_scope = status_scope
        @config = config
        @clock = clock
        @working_dir = working_dir
        @output = output
        @error_output = error_output
        @input = input
      end

      # @param name [String, nil] the workspace
      # @return [Hash] `{"queue" => workspace, "revision" => n}`, the `extra` of an action document
      def action_extra(name: nil)
        workspace = workspace_of(name)
        {"queue" => workspace, "revision" => @store_factory.call(workspace).snapshot["revision"]}
      end

      # Appends an item.
      #
      # @param kind [String] `workflow` or `go`
      # @param spec [Hash] what to run, as {Workspace::WorkQueueStarters} reads it
      # @param position [Symbol, Hash] `:bottom`, `:top`, `:after_current`, `{before: ID}` or `{after: ID}`
      # @return [Array<Hash>] one row: `added`, or `unchanged` for a repeated `dedupe_key`
      # @raise [Workspace::Error] `go_here_unavailable` for a `go` item on a checkout that can't run in place,
      #   and the store's `queue_full`, `unknown_queue_item`, `ambiguous_queue_item` and `item_active`
      def add(kind:, spec:, name: nil, position: :bottom, headless: false, on_fail: "stop", dedupe_key: nil, added_by: "person")
        found = @checkout.resolve(name, working_dir: @working_dir, allow_detached: true)
        workspace = found["workspace"]
        if kind == "go" && @go.in_place_checkout(found["path"], workspace: workspace).nil?
          raise Workspace::Error.new("go can't run in place in '#{workspace}' (#{found["path"]}): it works only in a linked worktree workspace off the default branch, so this item could only fail. Nothing was queued.",
            code: "go_here_unavailable", details: {"path" => found["path"]})
        end
        outcome, item, place = @store_factory.call(workspace).add(kind: kind, spec: spec, position: position, headless: headless,
          on_fail: on_fail, dedupe_key: dedupe_key, added_by: added_by)
        @output.puts((outcome == :added) ? "Queued #{item["id"]} (#{kind}) at position #{place} in '#{workspace}'." : "Item #{item["id"]} is already queued for that key.")
        [row(outcome.to_s, item, place)]
      end

      # Removes queued items, all or none.
      #
      # @param ids [Array<String>] ids or unique prefixes
      # @return [Array<Hash>] a `removed` row per item
      # @raise [Workspace::Error] `item_starting`, `item_active`, `unknown_queue_item` or `ambiguous_queue_item`
      def rm(ids:, name: nil)
        workspace = workspace_of(name)
        removed = @store_factory.call(workspace).remove(ids)
        removed.each { |item| @output.puts "Removed #{item["id"]} from '#{workspace}'." }
        removed.map { |item| row("removed", item, nil) }
      end

      # Moves a queued item.
      #
      # @param id [String] an id or unique prefix
      # @param before [String, nil] put it before this item
      # @param after [String, nil] put it after this item
      # @param top [Boolean] put it first among the queued items
      # @param bottom [Boolean] put it last
      # @param if_revision [Integer, nil] refuse unless the queue is at this revision
      # @return [Array<Hash>] one row: `moved` or `unchanged`
      # @raise [Workspace::Error] `stale_revision`, `item_starting`, `item_active`, `unknown_queue_item` or `ambiguous_queue_item`
      def move(id:, name: nil, before: nil, after: nil, top: false, bottom: false, if_revision: nil)
        workspace = workspace_of(name)
        outcome, item, place = @store_factory.call(workspace).move(id, before: before, after: after, top: top, bottom: bottom, if_revision: if_revision)
        @output.puts((outcome == :moved) ? "Moved #{item["id"]} to position #{place} in '#{workspace}'." : "Item #{item["id"]} is already there.")
        [row(outcome.to_s, item, place)]
      end

      # Turns the queue on for a workspace.
      #
      # @return [Array<Hash>] one row: `enabled` or `unchanged`
      def enable(name: nil)
        toggle(name, true, "enabled")
      end

      # Turns the queue off for a workspace. The current item keeps being read by a pass.
      #
      # @return [Array<Hash>] one row: `disabled` or `unchanged`
      def disable(name: nil)
        toggle(name, false, "disabled")
      end

      # Clears the queue's pause and nothing else.
      #
      # @return [Array<Hash>] one row: `resumed` or `unchanged`
      def resume(name: nil)
        workspace = workspace_of(name)
        changed = @store_factory.call(workspace).resume
        @output.puts(changed ? "Resumed the queue of '#{workspace}'." : "The queue of '#{workspace}' is not paused.")
        [row(changed ? "resumed" : "unchanged", nil, nil)]
      end

      # Records the held item as `skipped`, clears the pause and leaves its run alone.
      #
      # @param id [String, nil] the item; nil means the held one
      # @return [Array<Hash>] one row: `skipped`, with `run_id`, and a `workflow cancel` next action when the run still goes
      # @raise [Workspace::Error] `item_not_held` for none held (or a given item that is not held), `item_starting`,
      #   `unknown_queue_item` or `ambiguous_queue_item`
      def skip(id: nil, name: nil)
        workspace = workspace_of(name)
        item = @store_factory.call(workspace).transaction do |queue|
          held = skippable(queue, id, workspace)
          queue.finish(held["id"], outcome: "skipped", reason: held["reason"])
          queue.resume
          JSON.parse(JSON.generate(held))
        end
        run_id = item.dig("result", "run_id")
        result = row("skipped", item, nil).merge("run_id" => run_id)
        @output.puts "Skipped #{item["id"]} in '#{workspace}'; the queue is resumed."
        if run_id && run_going?(run_id)
          message = "Run #{run_id} is still going and blocks the next start until it ends."
          result["warnings"] = [{"code" => "run_still_going", "message" => message}]
          result["next_actions"] = [NextAction.build("workflow cancel", run_id)]
          @error_output.puts "warning: #{message}"
        end
        [result]
      end

      # Cancels the current item: cancels its run, records it `cancelled` and pauses the queue.
      #
      # @param id [String, nil] the item; nil means the starting, active or held one
      # @param and_continue [Boolean] skip the pause and run a pass, which starts the next item
      # @return [Array<Hash>] the `cancelled` row, then the pass's rows with `and_continue`
      # @raise [Workspace::Error] `item_not_active` for a queued item or none current, `item_starting`,
      #   `unknown_queue_item` or `ambiguous_queue_item`
      def cancel(id: nil, name: nil, and_continue: false)
        found = checkout_of(name, allow_detached: and_continue)
        workspace = found["workspace"]
        store = @store_factory.call(workspace)
        item = store.transaction { |queue| JSON.parse(JSON.generate(cancellable(queue, id, workspace))) }
        run_id = item.dig("result", "run_id")
        @decisions.cancel(run_id, actor: "person") if run_id
        store.transaction do |queue|
          queue.finish(item["id"], outcome: "cancelled", reason: "cancelled") if queue.items.any? { |i| i["id"] == item["id"] }
          queue.pause("cancelled") unless and_continue
        end
        @output.puts "Cancelled #{item["id"]} in '#{workspace}'#{and_continue ? "." : "; the queue is paused."}"
        rows = [row("cancelled", item, nil).merge("run_id" => run_id)]
        rows.concat(pass_rows(found)) if and_continue
        rows
      end

      # Runs one pass in the workspace's own checkout, whatever the daemon does.
      #
      # @return [Array<Hash>] the pass's rows
      def advance(name: nil)
        pass_rows(checkout_of(name)).tap do |rows|
          rows.each { |r| @output.puts "#{r["outcome"]}#{" #{r["id"]}" if r["id"]}#{" (#{r["reason"]})" if r["reason"]}" }
        end
      end

      # The queue as a table with a footer of its state, for one workspace or a project's, read only.
      #
      # @param project [nil, true, String] as {Workspace::StatusScope#resolve}
      # @return [Hash] `"queues"`, one per workspace (`workspace`, `state` of on, off or paused, `enabled`,
      #   `paused_reason`, `daemon_running`, `revision`, `items`, `next_actions`), and `"warnings"`
      def list(name: nil, project: nil)
        queues, warnings = read_queues(name, project)
        queues.each { |queue| print_list(queue) }
        {"queues" => queues, "warnings" => warnings}
      end

      # One pending item in full.
      #
      # @param id [String] an id or unique prefix
      # @return [Hash] `"workspace"`, `"item"` (`result.log_path` is nil for workflow and go items) and `"next_actions"`
      # @raise [Workspace::Error] `unknown_queue_item` or `ambiguous_queue_item`
      def show(id:, name: nil)
        workspace = workspace_of(name)
        snapshot = @store_factory.call(workspace).snapshot
        item = @store_factory.call(workspace).find(id)
        position = snapshot["items"].index { |i| i["id"] == item["id"] } + 1
        doc = item.merge("position" => position, "what" => what(item), "run_id" => item.dig("result", "run_id"))
        print_item(workspace, doc)
        {"workspace" => workspace, "item" => doc, "next_actions" => item_actions(item, workspace), "warnings" => []}
      end

      # The current item and what it waits on.
      #
      # @return [Hash] `"workspace"`, `"item"` (nil when none), `"waiting_on"` (`on`, `reason`, `run_id`, `run_state`, `step`)
      #   and `"next_actions"`
      def active(name: nil)
        workspace = workspace_of(name)
        items = @store_factory.call(workspace).snapshot["items"]
        item = items.find { |i| WorkQueueStore::CURRENT_STATES.include?(i["state"]) }
        unless item
          @output.puts "Nothing is active in '#{workspace}'."
          return {"workspace" => workspace, "item" => nil, "waiting_on" => nil, "next_actions" => [], "warnings" => []}
        end
        waiting = waiting_on(item)
        @output.puts "#{item["id"]} #{item["state"]} #{item["kind"]} #{what(item)}"
        @output.puts "  waiting on #{waiting["on"]}#{": #{waiting["reason"]}" if waiting["reason"]}"
        {"workspace" => workspace, "item" => item_row(item, items.index(item) + 1), "waiting_on" => waiting, "next_actions" => item_actions(item, workspace), "warnings" => []}
      end

      # One line per queue: on, off or paused, daemon, the active item and the queued count.
      #
      # @param project [nil, true, String] as {Workspace::StatusScope#resolve}
      # @return [Hash] `"queues"` (`workspace`, `state`, `paused_reason`, `daemon_running`, `active`, `queued`, `revision`,
      #   `next_actions`) and `"warnings"`
      def status(name: nil, project: nil)
        queues, warnings = read_queues(name, project)
        rows = queues.map do |queue|
          current = queue["items"].find { |i| WorkQueueStore::CURRENT_STATES.include?(i["state"]) }
          line = queue.slice("workspace", "state", "paused_reason", "daemon_running", "revision", "next_actions")
          line.merge("active" => current, "queued" => queue["items"].count { |i| i["state"] == "queued" })
        end
        rows.each { |r| @output.puts status_line(r) }
        {"queues" => rows, "warnings" => warnings}
      end

      # Finished items, oldest first.
      #
      # @param since [Time, nil] finished at or after
      # @param before [Time, nil] finished before
      # @param state [String, nil] only this outcome
      # @param project [nil, true, String] as {Workspace::StatusScope#resolve}
      # @return [Hash] `"entries"` (each with its `workspace`), `"next_actions"` and `"warnings"`; a `project` read never prunes the files
      def history_list(name: nil, project: nil, since: nil, before: nil, state: nil)
        workspaces = workspaces_for(name, project)
        entries = workspaces.flat_map do |workspace|
          @history_factory.call(workspace).entries(since: since, before: before, state: state, prune: project.nil?).map { |e| e.merge("workspace" => workspace) }
        end
        entries.each { |e| @output.puts "#{e["id"]} #{e["outcome"]} #{e["kind"]} #{e["finished_at"]} #{what(e)}" }
        @output.puts "No finished items." if entries.empty?
        actions = entries.empty? ? [] : [NextAction.build("work-queue history show", "ID", "--name", workspaces.first, needs: [NextAction.need("id", nil)])]
        {"entries" => entries, "next_actions" => actions, "warnings" => []}
      end

      # One finished item with its spec, so it can be added again.
      #
      # @param id [String] an id or unique prefix
      # @return [Hash] `"workspace"`, `"entry"` and `"next_actions"` (the command that adds it again)
      # @raise [Workspace::Error] `unknown_queue_item` or `ambiguous_queue_item`
      def history_show(id:, name: nil)
        workspace = workspace_of(name)
        entry = @history_factory.call(workspace).find(id)
        @output.puts JSON.pretty_generate(entry)
        {"workspace" => workspace, "entry" => entry, "next_actions" => [add_again(entry, workspace)], "warnings" => []}
      end

      # Removes history.
      #
      # @param before [Time, nil] drop entries finished before this
      # @param all [Boolean] drop every entry
      # @param yes [Boolean] skip the question
      # @param json [Boolean] whether the result goes out as JSON, which can't ask
      # @return [Array<Hash>] one row: `cleared` or `unchanged` with `count`, or `cancelled` when the answer was no
      # @raise [Workspace::UsageError] unless exactly one of `before` and `all` is given
      # @raise [Workspace::Error] `confirmation_required` when the question can't be asked (json, no input, no tty)
      def history_clear(name: nil, before: nil, all: false, yes: false, json: false)
        raise UsageError, "Give exactly one of --before DATE and --all." unless [before, all || nil].compact.size == 1
        workspace = workspace_of(name)
        unless yes
          refuse_to_ask!(json)
          answer = Prompt.ask(@input, @output, "Delete #{all ? "all" : "old"} finished items of '#{workspace}'? [y/N] ", retry_flags: ["--yes"], destructive: true)
          unless answer.to_s.strip.downcase.start_with?("y")
            @output.puts "Nothing deleted."
            return [row("cancelled", nil, nil).merge("count" => 0)]
          end
        end
        count = @history_factory.call(workspace).clear(before: before, all: all)
        @output.puts "Removed #{count} finished item#{"s" unless count == 1} from '#{workspace}'."
        [row(count.zero? ? "unchanged" : "cleared", nil, nil).merge("count" => count)]
      end

      private

      def workspace_of(name)
        @checkout.resolve(name, working_dir: @working_dir, allow_detached: true)["workspace"]
      end

      def checkout_of(name, allow_detached: false)
        @checkout.resolve(name, working_dir: @working_dir, allow_detached: allow_detached)
      end

      def pass_rows(found)
        here = WorkflowStart::Here.new(workspace: found["workspace"], path: found["path"], caller_pane: nil)
        @advance.call(workspace: found["workspace"], checkout: here).map { |r| r.merge("position" => nil) }
      end

      def toggle(name, value, word)
        workspace = workspace_of(name)
        changed = @store_factory.call(workspace).set_enabled(value)
        @output.puts(changed ? "The queue of '#{workspace}' is #{word}." : "The queue of '#{workspace}' is already #{word}.")
        [row(changed ? word : "unchanged", nil, nil)]
      end

      def row(outcome, item, position)
        {"outcome" => outcome, "id" => item&.dig("id"), "position" => position, "kind" => item&.dig("kind")}
      end

      def skippable(queue, id, workspace)
        resume_action = [NextAction.build("work-queue resume", "--name", workspace)]
        item = id ? queue.find(id) : queue.items.find { |i| i["state"] == "held" }
        item ||= queue.current
        raise starting(item) if item&.dig("state") == "starting"
        return item if item&.dig("state") == "held"
        message = if item
          "Item #{item["id"]} is #{item["state"]}, not held; skip takes the held item. Use rm for a queued one."
        else
          "No item is held in '#{workspace}'; a failed run that ended has already gone to history. Use work-queue resume to clear a pause."
        end
        raise Workspace::Error.new(message, code: "item_not_held", details: {"id" => item&.dig("id"), "state" => item&.dig("state"), "next_actions" => resume_action})
      end

      def cancellable(queue, id, workspace)
        item = id ? queue.find(id) : queue.current
        raise starting(item) if item&.dig("state") == "starting"
        return item if item && item["state"] != "queued"
        message = item ? "Item #{item["id"]} is only queued; use rm to remove it." : "Nothing is active in '#{workspace}' to cancel."
        raise Workspace::Error.new(message, code: "item_not_active", details: {"id" => item&.dig("id"), "state" => item&.dig("state")})
      end

      def starting(item)
        Workspace::Error.new("Item #{item["id"]} is starting; retry once its start has landed.", code: "item_starting", details: {"id" => item["id"]})
      end

      def run_going?(run_id)
        !WorkflowRunStore::TERMINAL_STATES.include?(@run_store.run(run_id).state)
      rescue Workspace::Error => e
        raise unless e.code == "unknown_run"
        false
      end

      def waiting_on(item)
        run_id = item.dig("result", "run_id")
        run = read_run(run_id)
        base = {"run_id" => run_id, "run_state" => run&.state, "step" => run&.current}
        case item["state"]
        when "starting" then base.merge("on" => "start", "reason" => "its start has not landed")
        when "held" then base.merge("on" => "person", "reason" => item["reason"])
        else base.merge("on" => "run", "reason" => nil)
        end
      end

      def read_run(run_id)
        run_id && @run_store.run(run_id)
      rescue Workspace::Error => e
        raise unless e.code == "unknown_run"
        nil
      end

      def item_actions(item, workspace)
        run_id = item.dig("result", "run_id")
        name = ["--name", workspace]
        case item["state"]
        when "queued" then [NextAction.build("work-queue rm", item["id"], *name)]
        when "starting" then [NextAction.build("work-queue status", *name)]
        else
          first = if run_id && item["reason"] == "gate"
            NextAction.build("workflow approve", run_id)
          elsif run_id
            NextAction.build("workflow status", run_id)
          end
          skip = (item["state"] == "held") ? [NextAction.build("work-queue skip", item["id"], *name)] : []
          [first, *skip, NextAction.build("work-queue cancel", item["id"], *name)].compact
        end
      end

      def workspaces_for(name, project)
        return [workspace_of(name)] if project.nil?
        scope = @status_scope.resolve(name: name, project: project, all: nil, working_dir: @working_dir)
        return [scope.workspace] if scope.kind == :workspace
        scope.project.members.filter_map(&:workspace)
      end

      def read_queues(name, project)
        warnings = []
        queues = workspaces_for(name, project).map do |workspace|
          queue = queue_doc(workspace)
          unless queue["daemon_running"]
            message = "The agent daemon of '#{workspace}' is not answering, so only a manual work-queue advance moves its queue."
            warnings << {"code" => DAEMON_WARNING, "workspace" => workspace, "message" => message}
            @error_output.puts "warning: #{message}"
          end
          queue
        end
        [queues, warnings]
      end

      def queue_doc(workspace)
        data = @store_factory.call(workspace).snapshot
        paused = data["paused"]
        state = if paused
          "paused"
        elsif data["enabled"] == true
          "on"
        else
          "off"
        end
        name = ["--name", workspace]
        actions = []
        actions << NextAction.build("work-queue resume", *name) if paused
        actions << NextAction.build("work-queue enable", *name) if data["enabled"] != true
        actions << NextAction.build("work-queue advance", *name) if data["enabled"] == true && !paused && data["items"].any?
        {"workspace" => workspace, "state" => state, "enabled" => data["enabled"] == true, "paused_reason" => paused&.dig("reason"),
         "daemon_running" => @config.agent_running?(workspace), "revision" => data["revision"],
         "items" => data["items"].each_with_index.map { |item, i| item_row(item, i + 1) }, "next_actions" => actions}
      end

      def item_row(item, position)
        {"id" => item["id"], "position" => position, "state" => item["state"], "kind" => item["kind"], "what" => what(item),
         "headless" => item["headless"], "on_fail" => item["on_fail"], "added_at" => item["added_at"], "started_at" => item["started_at"],
         "reason" => item["reason"], "run_id" => item.dig("result", "run_id"), "dedupe_key" => item["dedupe_key"]}
      end

      def what(item)
        spec = item["spec"] || {}
        text = case item["kind"]
        when "workflow" then [spec["workflow"], spec["ref"], spec["prompt"]].compact.join(" ")
        when "go" then [spec["argument"], spec["text"], spec["workflow"]].compact.join(" ")
        else spec.to_s
        end
        text = text.gsub(/\s+/, " ")
        TerminalText.escape((text.length > WHAT_LENGTH) ? "#{text[0, WHAT_LENGTH - 3]}..." : text)
      end

      def print_list(queue)
        if queue["items"].empty?
          @output.puts "'#{queue["workspace"]}': no items."
        else
          @output.puts format("%-3s %-8s %-9s %-9s %-*s %-8s %s", "#", "ID", "STATE", "KIND", WHAT_LENGTH, "WHAT", "HEADLESS", "AGE")
          queue["items"].each do |i|
            @output.puts format("%-3d %-8s %-9s %-9s %-*s %-8s %s", i["position"], i["id"], i["state"], i["kind"], WHAT_LENGTH, i["what"], i["headless"] ? "yes" : "no", age(i["added_at"]))
          end
        end
        @output.puts "#{queue["workspace"]}: #{queue["state"]}#{" (#{queue["paused_reason"]})" if queue["paused_reason"]}, daemon #{queue["daemon_running"] ? "up" : "down"}"
      end

      def print_item(workspace, item)
        @output.puts "#{item["id"]} in '#{workspace}': #{item["state"]} #{item["kind"]} #{item["what"]}"
        @output.puts "  position #{item["position"]}, headless #{item["headless"] ? "yes" : "no"}, on_fail #{item["on_fail"]}, added #{item["added_at"]}"
        @output.puts "  run #{item["run_id"]}" if item["run_id"]
        @output.puts "  reason #{item["reason"]}" if item["reason"]
        @output.puts "  log #{item.dig("result", "log_path") || "none"}"
        @output.puts "  error #{TerminalText.escape(item.dig("result", "error"))}" if item.dig("result", "error")
      end

      def status_line(line)
        active = line["active"]
        text = "#{line["workspace"]}: #{line["state"]}#{" (#{line["paused_reason"]})" if line["paused_reason"]}, daemon #{line["daemon_running"] ? "up" : "down"}"
        text += active ? ", active #{active["id"]} (#{active["state"]})" : ", nothing active"
        "#{text}, #{line["queued"]} queued"
      end

      def age(time)
        seconds = (@clock.now - Time.iso8601(time.to_s)).to_i
        return "#{seconds}s" if seconds < 60
        return "#{seconds / 60}m" if seconds < 3600
        return "#{seconds / 3600}h" if seconds < 86_400
        "#{seconds / 86_400}d"
      rescue ArgumentError
        "?"
      end

      def refuse_to_ask!(json)
        Prompt.refuse_if_no_input!(@input, "Delete finished items?", retry_flags: ["--yes"], destructive: true)
        return unless json || !tty?
        raise Workspace::Error.new("history clear asks first and can't here; pass --yes to skip the question.",
          code: "confirmation_required", details: {"prompt" => "Delete finished items?"},
          retry_with: {"flags" => ["--yes"], "destructive" => true})
      end

      def add_again(entry, workspace)
        spec = entry["spec"] || {}
        flags = []
        words = case entry["kind"]
        when "workflow"
          flags += ["--ref", spec["ref"]] if spec["ref"]
          flags += ["--prompt", spec["prompt"]] if spec["prompt"]
          [spec["workflow"]]
        else
          flags += ["--text"] if spec["text"]
          flags += ["--workflow", spec["workflow"]] if spec["workflow"]
          [spec["argument"] || spec["text"]]
        end
        (spec["inputs"] || {}).each { |k, v| flags += ["--input", "#{k}=#{v}"] }
        flags << "--headless" if entry["headless"]
        flags += ["--on-fail", entry["on_fail"]] if entry["on_fail"]
        NextAction.build("work-queue add", entry["kind"], *words.compact, *flags, "--name", workspace)
      end

      def tty?
        @input.respond_to?(:tty?) && @input.tty?
      end
    end
  end
end
