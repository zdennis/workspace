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
      # What a person is told when a queue is off, where it matters.
      OFF_HINT = "The queue is off; run `workspace work-queue enable` and the agent daemon advances it."

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
      # @param agent_ensurer [Workspace::Commands::EnsureAgent] starts the workspace's agent daemon (which advances an
      #   enabled queue) for `add` and `enable`
      # @param agent_running [#call] given a workspace, whether its agent daemon answers, for `list` and `status`
      # @param clock [#now] time source, for ages
      # @param watch_loop [Workspace::WatchLoop, nil] redraws the frames of `watch_list` and `watch_active`; nil builds one over +output+ and `sleep`
      # @param working_dir [String] where the current workspace is looked for
      # @param output [IO] stream for the human result
      # @param error_output [IO] stream for warnings
      # @param input [IO, Workspace::PromptInput] where `history clear` reads its answer
      def initialize(store_factory:, history_factory:, advance:, decisions:, run_store:, checkout:, go:, status_scope:,
        agent_ensurer:, agent_running:, clock: Time, watch_loop: nil, working_dir: Dir.pwd, output: $stdout, error_output: $stderr, input: $stdin)
        @store_factory = store_factory
        @history_factory = history_factory
        @advance = advance
        @decisions = decisions
        @run_store = run_store
        @checkout = checkout
        @go = go
        @status_scope = status_scope
        @agent_ensurer = agent_ensurer
        @agent_running = agent_running
        @clock = clock
        @watch_loop = watch_loop || WatchLoop.new(output: output, sleeper: Kernel.method(:sleep))
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

      # Appends an item, and makes sure the workspace's agent daemon runs, as {#enable} does.
      #
      # @param kind [String] `workflow` or `go`
      # @param spec [Hash] what to run, as {Workspace::WorkQueueStarters} reads it
      # @param position [Symbol, Hash] `:bottom`, `:top`, `:after_current`, `{before: ID}` or `{after: ID}`
      # @return [Array<Hash>] one row: `added`, or `unchanged` for a repeated `dedupe_key`; with `warnings` when the
      #   daemon could not be started
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
        @output.puts OFF_HINT unless @store_factory.call(workspace).snapshot["enabled"] == true
        [with_daemon(row(outcome.to_s, item, place), workspace)]
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

      # Turns the queue on for a workspace and makes sure its agent daemon runs, which then advances the queue.
      #
      # @return [Array<Hash>] one row: `enabled` or `unchanged`; with `warnings` when the daemon could not be started
      def enable(name: nil)
        [with_daemon(toggle(name, true, "enabled").first, workspace_of(name))]
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
      # @param and_continue [Boolean] clear any pause instead of pausing and run a pass, which starts the next item
      # @return [Array<Hash>] the `cancelled` row, then the pass's rows with `and_continue`
      # @raise [Workspace::Error] `item_not_active` for a queued item or none current, `item_starting`,
      #   `unknown_queue_item` or `ambiguous_queue_item`
      def cancel(id: nil, name: nil, and_continue: false)
        found = checkout_of(name, allow_detached: and_continue)
        workspace = found["workspace"]
        store = @store_factory.call(workspace)
        item = store.transaction { |queue| JSON.parse(JSON.generate(cancellable(queue, id, workspace))) }
        run_id = item.dig("result", "run_id")
        @decisions.cancel(run_id, actor: "person") if run_id && run_going?(run_id)
        store.transaction do |queue|
          queue.finish(item["id"], outcome: "cancelled", reason: "cancelled") if queue.items.any? { |i| i["id"] == item["id"] }
          and_continue ? queue.resume : queue.pause("cancelled")
        end
        @output.puts "Cancelled #{item["id"]} in '#{workspace}'#{and_continue ? "." : "; the queue is paused."}"
        rows = [row("cancelled", item, nil).merge("run_id" => run_id)]
        rows.concat(pass_rows(found).tap { |pass| print_pass(pass, workspace) }) if and_continue
        rows
      end

      # Runs one pass in the workspace's own checkout. In this version only this verb moves a queue.
      #
      # @return [Array<Hash>] the pass's rows
      def advance(name: nil)
        found = checkout_of(name)
        pass_rows(found).tap { |rows| print_pass(rows, found["workspace"]) }
      end

      # The queue as a table with a footer of its state, for one workspace or a project's, read only.
      #
      # @param project [nil, true, String] as {Workspace::StatusScope#resolve}
      # @return [Hash] `"queues"`, one per workspace (`workspace`, `state` of on, off or paused, `enabled`,
      #   `paused_reason`, `daemon_running`, `revision`, `items`, `next_actions`), and `"warnings"`: one
      #   `daemon_not_running` for each enabled queue whose agent daemon does not answer, also printed to the error stream
      def list(name: nil, project: nil)
        queues, warnings = read_queues(name, project)
        queues.each { |queue| print_list(queue, @output) }
        {"queues" => queues, "warnings" => warnings}
      end

      # {#list} redrawn every `interval` seconds until Ctrl-C. A `daemon_not_running` warning is a `Warning:` line
      # in the frame, not on the error stream, so it does not repeat there on every tick.
      #
      # @param interval [Numeric] seconds between frames
      # @return [Hash] `{exit_code: 0}`
      def watch_list(name: nil, project: nil, interval: 2)
        watch(interval) do |io|
          queues, warnings = gather_queues(name, project)
          queues.each { |queue| print_list(queue, io) }
          warnings.each { |w| io.puts "Warning: #{w["message"]}" }
        end
      end

      # One pending item in full.
      #
      # @param id [String] an id or unique prefix
      # @return [Hash] `"workspace"`, `"item"` (`result.log_path` is nil for workflow and go items) and `"next_actions"`
      # @raise [Workspace::Error] `unknown_queue_item` or `ambiguous_queue_item`
      def show(id:, name: nil)
        workspace = workspace_of(name)
        snapshot = @store_factory.call(workspace).snapshot
        item = find_pending(workspace, id)
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
        render_active(name, @output)
      end

      # {#active} redrawn every `interval` seconds until Ctrl-C.
      #
      # @param interval [Numeric] seconds between frames
      # @return [Hash] `{exit_code: 0}`
      def watch_active(name: nil, interval: 2)
        watch(interval) { |io| render_active(name, io) }
      end

      # One line per queue: on, off or paused, the active item and the queued count.
      #
      # @param project [nil, true, String] as {Workspace::StatusScope#resolve}
      # @return [Hash] `"queues"` (`workspace`, `state`, `paused_reason`, `daemon_running`, `active`, `queued`, `revision`,
      #   `next_actions`) and `"warnings"`, as {#list} gives them
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
        actions = entries.map { |e| e["workspace"] }.uniq.map { |w| NextAction.build("work-queue history show", "ID", "--name", w, needs: [NextAction.need("id", nil)]) }
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

      # The queued item, or the error with a pointer to history when the id is a finished item's.
      def find_pending(workspace, id)
        @store_factory.call(workspace).find(id)
      rescue Workspace::Error => e
        raise unless e.code == "unknown_queue_item"
        finished = begin
          @history_factory.call(workspace).find(id)
        rescue Workspace::Error
          nil
        end
        raise unless finished
        again = NextAction.build("work-queue history show", finished["id"], "--name", workspace)
        raise Workspace::Error.new("#{e.message} #{finished["id"]} is a finished item; run `workspace work-queue history show #{finished["id"]}`.",
          code: e.code, details: (e.details || {}).merge("next_actions" => [again]))
      end

      def print_pass(rows, workspace)
        rows.each { |r| @output.puts pass_sentence(r, workspace) }
      end

      def pass_sentence(r, workspace)
        id = r["id"]
        run = r["run_id"] ? " (run #{r["run_id"]})" : ""
        case r["outcome"]
        when "started" then "Started #{id}#{run}."
        when "active" then "#{id} is running#{run}."
        when "succeeded" then "#{id} finished#{run}."
        when "held"
          approve = (r["reason"] == "gate" && r["run_id"]) ? " Approve it with `workspace workflow approve #{r["run_id"]}`." : ""
          "#{id} is held (#{r["reason"]})#{run}; see `workspace work-queue active`.#{approve}"
        when "failed", "cancelled" then "#{id} ended #{r["outcome"]}#{run}."
        when "launch_failed" then "#{id} could not start (#{r["reason"]}); see `workspace work-queue history show #{id}`."
        when "claim_lost" then "#{id} was taken by another pass#{run}; check `workspace work-queue status`."
        when "interrupted" then "#{id} was interrupted (#{r["reason"]}); see `workspace work-queue history show #{id}`."
        when "unchanged" then unchanged_sentence(r, workspace)
        else "#{r["outcome"]}#{" #{id}" if id}#{" (#{r["reason"]})" if r["reason"]}"
        end
      end

      def unchanged_sentence(r, workspace)
        case r["reason"]
        when "disabled" then "Queue is off; nothing started. Run `workspace work-queue enable`."
        when "paused"
          why = @store_factory.call(workspace).snapshot.dig("paused", "reason")
          "Queue is paused#{" (#{why})" if why}; run `workspace work-queue resume`."
        when "empty" then "Queue is empty."
        when "run_going" then "A run is going in this workspace (run #{r["run_id"]}); nothing started."
        when "starting" then "#{r["id"]} is being started by another pass; run advance again once it has landed."
        else "Nothing changed#{" (#{r["reason"]})" if r["reason"]}."
        end
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

      # The daemon is what advances an enabled queue; one that can't be started is a warning on the row, never a failure.
      def with_daemon(row, workspace)
        result = begin
          @agent_ensurer.call(name: workspace)
        rescue Workspace::Error => e
          EnsureAgent::Result.new(:failed, e.message.lines.first.to_s.strip)
        end
        return row if result.ok?
        detail = (result.status == :invalid_config) ? "its pipeline config can't be used" : result.detail
        message = "Could not start the agent daemon of '#{workspace}' (#{detail}); the queue moves only on " \
          "`workspace work-queue advance` until `workspace agentd --ensure --name #{workspace}` starts it."
        @error_output.puts "Warning: #{message}"
        row.merge("warnings" => [{"code" => "daemon_not_started", "workspace" => workspace, "message" => message}])
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
        queues, warnings = gather_queues(name, project)
        warnings.each { |w| @error_output.puts "Warning: #{w["message"]}" }
        [queues, warnings]
      end

      def gather_queues(name, project)
        queues = workspaces_for(name, project).map { |workspace| queue_doc(workspace) }
        warnings = queues.select { |q| q["enabled"] && !q["daemon_running"] }.map do |q|
          workspace = q["workspace"]
          {"code" => "daemon_not_running", "workspace" => workspace,
           "message" => "The agent daemon of '#{workspace}' is not answering, so its queue moves only on " \
             "`workspace work-queue advance`; `workspace agentd --ensure --name #{workspace}` starts it."}
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
        running = daemon_running?(workspace)
        # A running daemon advances an enabled queue itself; without one, a person does.
        if data["enabled"] == true && !running
          actions << NextAction.build("agentd --ensure", *name)
          actions << NextAction.build("work-queue advance", *name) if !paused && data["items"].any?
        end
        {"workspace" => workspace, "state" => state, "enabled" => data["enabled"] == true, "paused_reason" => paused&.dig("reason"),
         "daemon_running" => running, "revision" => data["revision"],
         "items" => data["items"].each_with_index.map { |item, i| item_row(item, i + 1) }, "next_actions" => actions}
      end

      # A daemon whose socket path can't be made (a state dir too deep) can't be answering either.
      def daemon_running?(workspace)
        @agent_running.call(workspace) == true
      rescue Workspace::Error
        false
      end

      def item_row(item, position)
        {"id" => item["id"], "position" => position, "state" => item["state"], "kind" => item["kind"], "what" => what(item),
         "headless" => item["headless"], "on_fail" => item["on_fail"], "added_at" => item["added_at"], "started_at" => item["started_at"],
         "reason" => item["reason"], "run_id" => item.dig("result", "run_id"), "dedupe_key" => item["dedupe_key"]}
      end

      def what(item)
        text = WorkQueueStore.summary(item)
        TerminalText.escape((text.length > WHAT_LENGTH) ? "#{text[0, WHAT_LENGTH - 3]}..." : text)
      end

      # One frame of a watch: runs the block into the loop's buffer and never asks the loop to stop.
      def watch(interval)
        @watch_loop.run(interval: interval) do |io|
          yield io
          false
        end
      end

      def render_active(name, io)
        workspace = workspace_of(name)
        items = @store_factory.call(workspace).snapshot["items"]
        item = items.find { |i| WorkQueueStore::CURRENT_STATES.include?(i["state"]) }
        unless item
          io.puts "Nothing is active in '#{workspace}'."
          return {"workspace" => workspace, "item" => nil, "waiting_on" => nil, "next_actions" => [], "warnings" => []}
        end
        waiting = waiting_on(item)
        io.puts "#{item["id"]} #{item["state"]} #{item["kind"]} #{what(item)}"
        io.puts "  waiting on #{waiting["on"]}#{": #{waiting["reason"]}" if waiting["reason"]}"
        {"workspace" => workspace, "item" => item_row(item, items.index(item) + 1), "waiting_on" => waiting, "next_actions" => item_actions(item, workspace), "warnings" => []}
      end

      def print_list(queue, io)
        if queue["items"].empty?
          io.puts "'#{queue["workspace"]}': no items."
        else
          io.puts format("%-3s %-8s %-9s %-9s %-*s %-8s %s", "#", "ID", "STATE", "KIND", WHAT_LENGTH, "WHAT", "HEADLESS", "AGE")
          queue["items"].each do |i|
            io.puts format("%-3d %-8s %-9s %-9s %-*s %-8s %s", i["position"], i["id"], i["state"], i["kind"], WHAT_LENGTH, i["what"], i["headless"] ? "yes" : "no", age(i["added_at"]))
          end
        end
        io.puts "#{queue["workspace"]}: #{queue["state"]}#{" (#{queue["paused_reason"]})" if queue["paused_reason"]}, daemon #{queue["daemon_running"] ? "up" : "down"}"
        io.puts OFF_HINT if queue["state"] == "off"
      end

      def print_item(workspace, item)
        @output.puts "#{item["id"]} in '#{workspace}': #{item["state"]} #{item["kind"]} #{item["what"]}"
        @output.puts "  position #{item["position"]}, headless #{item["headless"] ? "yes" : "no"}, on_fail #{item["on_fail"]}, added #{item["added_at"]}"
        @output.puts "  run #{item["run_id"]}" if item["run_id"]
        @output.puts "  reason #{item["reason"]}" if item["reason"]
        @output.puts "  log #{item.dig("result", "log_path")}" if item.dig("result", "log_path")
        @output.puts "  error #{TerminalText.escape(item.dig("result", "error"))}" if item.dig("result", "error")
      end

      def status_line(line)
        active = line["active"]
        text = "#{line["workspace"]}: #{line["state"]}#{" (#{line["paused_reason"]})" if line["paused_reason"]}"
        text += active ? ", active #{active["id"]} (#{active["state"]})" : ", nothing active"
        "#{text}, #{line["queued"]} queued, daemon #{line["daemon_running"] ? "up" : "down"}"
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
