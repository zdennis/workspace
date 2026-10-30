require "json"

module Workspace
  module Commands
    # `agent-run queue list|cancel`: what `agent-run send --when-idle` has
    # queued for a workspace's panes, and taking an entry back.
    #
    # Both read and write the workspace's `prompt-queue.json`
    # ({Workspace::PromptQueueStore}) directly and never ask the agent
    # daemon, so they work with no daemon running.
    class PromptQueue
      # Bumped whenever the `--json` payload's shape changes incompatibly.
      JSON_SCHEMA_VERSION = 1

      # Characters of a prompt a list row shows.
      PREVIEW_LENGTH = 200

      # @param config [Workspace::Config] where each workspace's queue file is
      # @param locator [Workspace::PaneLocator] resolves a `window.pane` reference for `--pane`
      # @param event_log [Workspace::EventLog, nil] receives `prompt_dequeued` for a cancel
      # @param store_factory [#call] given a queue file's path, returns its {Workspace::PromptQueueStore}
      # @param clock [#now] time source, for the age column
      # @param columns [#call] returns the terminal width, for the human list
      # @param output [IO] stream for the result
      # @param error_output [IO] stream for warnings
      def initialize(config:, locator:, event_log: nil, store_factory: ->(path) { PromptQueueStore.new(path: path) },
        clock: Time, columns: -> { ENV.fetch("COLUMNS", "100").to_i }, output: $stdout, error_output: $stderr)
        @config = config
        @locator = locator
        @event_log = event_log
        @store_factory = store_factory
        @clock = clock
        @columns = columns
        @output = output
        @error_output = error_output
      end

      # Lists a workspace's queued prompts: grouped by pane, the panes in the
      # order of their oldest entry, each pane's rows in queue order.
      #
      # @param name [String] workspace name
      # @param pane [String, nil] only this pane: a pane id (`%19`, matched as
      #   given with no tmux call) or `window.pane` (resolved through tmux)
      # @param json [Boolean] print one JSON document
      # @return [Array<Hash>] the rows: `id`, `pane_id`, `position`, `state`,
      #   `queued_at`, `clear_first`, `preview` (the first 200 characters,
      #   control characters escaped) and `length` (characters in the full text)
      # @raise [Workspace::Error] when the queue file can't be read, or the
      #   {Workspace::PaneLocator} codes for a `window.pane` that doesn't resolve
      def list(name:, pane: nil, json: false)
        pane_id = pane && pane_id_for(name, pane)
        rows = rows_for(@store_factory.call(@config.prompt_queue_path(name)).entries(pane_id: pane_id))
        if json
          @output.puts JSON.generate({"schema_version" => JSON_SCHEMA_VERSION, "ok" => true, "workspace" => name, "entries" => rows})
        else
          render(rows, name)
        end
        rows
      end

      # Takes a queued prompt back. A queued entry is removed. One a delivery
      # has claimed but not started to paste gets `cancel_requested`, and the
      # delivery types nothing. Records `prompt_dequeued` with outcome `cancelled`.
      #
      # @param id [String] the entry id `send --when-idle` answered
      # @param name [String, nil] workspace name; nil looks through every
      #   workspace's queue file
      # @param json [Boolean] print one JSON document
      # @return [Hash] `cancelled`, `id`, `pane_id`, `text` (the full text),
      #   and `cancel_requested` when the delivery is to stop itself
      # @raise [Workspace::Error] `unknown_id` when the id isn't queued, or its
      #   text may already be in the pane (`details.state` is `delivering`)
      def cancel(id:, name: nil, json: false)
        outcome, entry, workspace, skipped = find_and_cancel(id, name)
        raise unknown_id(id, name, outcome, entry, skipped) if outcome == :pasting || outcome == :unknown

        # A repeated cancel of an entry already told to stop answers the same, with no second event.
        unless outcome == :cancel_pending
          @event_log&.record(type: EventLog::PROMPT_DEQUEUED, project: workspace,
            data: {"id" => id, "pane_id" => entry["pane_id"], "outcome" => "cancelled"})
        end
        result = {"cancelled" => true, "id" => id, "pane_id" => entry["pane_id"], "text" => entry["text"]}
        result["cancel_requested"] = true if outcome == :cancel_requested || outcome == :cancel_pending
        if json
          @output.puts JSON.generate({"schema_version" => JSON_SCHEMA_VERSION, "ok" => true, "workspace" => workspace}.merge(result))
        else
          stop = " (the delivery in progress types nothing)" if result["cancel_requested"]
          @output.puts "Cancelled #{id} for pane #{entry["pane_id"]} of '#{workspace}'#{stop}."
        end
        result
      end

      private

      def unknown_id(id, name, outcome, entry, skipped)
        details = {"id" => id}
        details["workspace"] = name if name
        details["unreadable"] = skipped if skipped.any?
        if outcome == :pasting
          details["state"] = "delivering"
          message = "Prompt #{id} is being typed into pane #{entry["pane_id"]}; its text may already be there, so it can't be cancelled."
        else
          message = "No queued prompt #{id}#{" in '#{name}'" if name}: it was already typed or dropped, or never existed."
        end
        Workspace::Error.new(message, code: "unknown_id", details: details)
      end

      def pane_id_for(name, pane)
        return pane.strip if pane.strip.match?(TmuxPane::PANE_ID)
        @locator.locate(name, pane)[:id]
      end

      def find_and_cancel(id, name)
        skipped = []
        (name ? [name] : workspaces_with_queues).each do |workspace|
          store = @store_factory.call(@config.prompt_queue_path(workspace))
          begin
            outcome, entry = store.cancel(id)
          rescue Workspace::Error => e
            raise if name
            @error_output.puts "workspace agent-run queue: skipping '#{workspace}': #{e.message}"
            skipped << workspace
            next
          end
          return [outcome, entry, workspace, skipped] unless outcome == :unknown
        end
        [:unknown, nil, name, skipped]
      end

      def workspaces_with_queues
        Dir.glob(File.join(@config.state_dir, "*", "prompt-queue.json")).map { |path| File.basename(File.dirname(path)) }.sort
      end

      def rows_for(entries)
        positions = Hash.new(0)
        rows = entries.map do |entry|
          text = entry["text"].to_s
          {"id" => entry["id"], "pane_id" => entry["pane_id"], "position" => positions[entry["pane_id"]] += 1,
           "state" => entry["state"], "queued_at" => entry["queued_at"], "clear_first" => entry["clear_first"] == true,
           "preview" => TerminalText.escape(text[0, PREVIEW_LENGTH]), "length" => text.length}
        end
        oldest = rows.group_by { |r| r["pane_id"] }.transform_values { |group| group.map { |r| r["queued_at"].to_s }.min }
        panes = rows.map { |r| r["pane_id"] }.uniq.each_with_index.sort_by { |pane_id, index| [oldest[pane_id], index] }.map(&:first)
        panes.flat_map { |pane_id| rows.select { |r| r["pane_id"] == pane_id } }
      end

      def render(rows, name)
        return @output.puts "No prompts queued in '#{name}'." if rows.empty?

        width = @columns.call
        rows.each do |row|
          head = format("%-5s #%-2d %-10s %-5s %-16s ", row["pane_id"], row["position"], row["state"], age(row["queued_at"]), row["id"])
          room = [width - head.length, 10].max
          preview = row["preview"]
          preview = "#{preview[0, room - 3]}..." if preview.length > room
          @output.puts "#{head}#{preview}"
        end
      end

      def age(queued_at)
        seconds = (@clock.now - Time.iso8601(queued_at.to_s)).to_i
        return "#{seconds}s" if seconds < 60
        return "#{seconds / 60}m" if seconds < 3600
        "#{seconds / 3600}h"
      rescue ArgumentError
        "?"
      end
    end
  end
end
