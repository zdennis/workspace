require "json"
require "securerandom"
require "time"

module Workspace
  # The pending items of one workspace's work queue: `work-queue.json` in the
  # workspace's state directory, guarded by `flock` on `<path>.lock` and
  # written whole through a temp file and rename, mode 0600, as
  # {PromptQueueStore} is. The file holds a `revision` (an integer bumped on
  # every write), `enabled` (absent until a person toggles the queue), `paused`
  # (`{reason, at}` or nil) and `items`.
  #
  # An item is `queued`, `starting` (claimed: it carries `claim`, `claimed_at`
  # and `claimed_by`), `active` (it carries `result.run_id`) or `held`. Items
  # that are not `queued` come first, and at most one exists. A finished item
  # leaves the file and goes to the {WorkQueueHistory} inside the same lock.
  #
  # A file that can't be read raises and changes nothing.
  #
  # Each transition (a run recorded or adopted, an item held or finished, the queue
  # paused or resumed) is recorded in the {EventLog} once, after the queue file is
  # written and still under the lock, so two passes racing never record one twice.
  #
  # Times are ISO 8601 UTC with milliseconds.
  class WorkQueueStore
    # Most items a queue may hold.
    MAX_ITEMS = 50

    # What a claim writes into an item, removed once the run is recorded.
    CLAIM_KEYS = %w[claim claimed_at claimed_by].freeze

    # The states that make an item the queue's current one.
    CURRENT_STATES = %w[starting active held].freeze

    # Characters of {.summary} a `work_queue_item_started` event carries, so a long prompt stays out of the log.
    EVENT_WHAT_LENGTH = 80

    # One locked read-modify-write of the queue file. The advance pass, `skip`
    # and `cancel` change the queue through these methods, so each step of a
    # claim is one named change. Nothing is written when the block raises.
    class Transaction
      # @param data [Hash] the parsed file, changed in place
      # @param store [WorkQueueStore] the owner, for its clock, ids and cap
      # @param pending [Array<Hash>] where {#finish} leaves history entries until the queue is written
      # @param events [Array<Array>] where each transition leaves `[type, data]` until the queue is written
      def initialize(data, store, pending, events = [])
        @data = data
        @store = store
        @pending = pending
        @events = events
      end

      # @return [Integer] the revision the file had when this transaction began
      def revision
        @data["revision"]
      end

      # @return [Array<Hash>] the items in queue order
      def items
        @data["items"]
      end

      # @return [Hash, nil] the starting, active or held item
      def current
        items.find { |i| CURRENT_STATES.include?(i["state"]) }
      end

      # @return [Boolean, nil] the queue's own toggle; nil when never set
      def enabled
        @data["enabled"]
      end

      # @return [Hash, nil] `{"reason", "at"}` while the queue is paused
      def paused
        @data["paused"]
      end

      # @param id [String] an item id or a unique prefix of one
      # @return [Hash] the item
      # @raise [Workspace::Error] `unknown_queue_item` or `ambiguous_queue_item`
      def find(id)
        @store.resolve(items, id)
      end

      # Adds an item as `queued`. A dedupe key already on an item gives
      # `:unchanged` and that item.
      #
      # @param kind [String]
      # @param spec [Hash] what to run
      # @param position [Symbol, Hash] `:bottom`, `:top`, `:after_current`,
      #   `{before: ID}` or `{after: ID}`
      # @param headless [Boolean]
      # @param on_fail [String] `stop` or `continue`
      # @param dedupe_key [String, nil]
      # @param added_by [String, nil]
      # @return [Array(Symbol, Hash, Integer)] `:added` or `:unchanged`, the item and its position from 1
      # @raise [Workspace::Error] `queue_full`, `unknown_queue_item`, `ambiguous_queue_item`
      #   or `item_active` for a `before:` target that is not queued
      def add(kind:, spec:, position: :bottom, headless: false, on_fail: "stop", dedupe_key: nil, added_by: nil)
        if dedupe_key
          same = items.find { |i| i["dedupe_key"] == dedupe_key }
          return [:unchanged, same, items.index(same) + 1] if same
        end
        if items.size >= @store.max_items
          raise Workspace::Error.new("The work queue already holds #{@store.max_items} items; remove one first.",
            code: "queue_full", details: {limit: @store.max_items})
        end
        item = {"id" => @store.unused_id(items), "kind" => kind, "spec" => spec, "headless" => headless,
                "on_fail" => on_fail, "added_at" => @store.now, "added_by" => added_by,
                "dedupe_key" => dedupe_key, "state" => "queued", "started_at" => nil, "reason" => nil,
                "result" => {"run_id" => nil, "log_path" => nil, "error" => nil}}
        index = insertion_index(position)
        items.insert(index, item)
        [:added, item, index + 1]
      end

      # Removes queued items, all or none.
      #
      # @param ids [Array<String>] ids or unique prefixes
      # @return [Array<Hash>] the removed items
      # @raise [Workspace::Error] `unknown_queue_item`, `ambiguous_queue_item`, `item_starting` or `item_active`
      def remove(ids)
        found = ids.map { |id| find(id) }
        found.each { |item| refuse_unless_queued(item, "remove") }
        items.reject! { |i| found.include?(i) }
        found
      end

      # Moves a queued item.
      #
      # @param id [String]
      # @param before [String, nil] put it before this item
      # @param after [String, nil] put it after this item
      # @param top [Boolean] put it first among the queued items
      # @param bottom [Boolean] put it last
      # @param if_revision [Integer, nil] refuse unless the queue is at this revision
      # @return [Array(Symbol, Hash, Integer)] `:moved` or `:unchanged`, the item and its position from 1
      # @raise [Workspace::Error] `stale_revision`, `unknown_queue_item`, `ambiguous_queue_item`,
      #   `item_starting`, `item_active`, or `ArgumentError` unless exactly one target is given
      def move(id, before: nil, after: nil, top: false, bottom: false, if_revision: nil)
        raise ArgumentError, "give exactly one of before:, after:, top: and bottom:" unless [before, after, top || nil, bottom || nil].compact.size == 1
        if if_revision && if_revision != revision
          raise Workspace::Error.new("The work queue is at revision #{revision}, not #{if_revision}.",
            code: "stale_revision", details: {revision: revision, path: @store.path})
        end
        item = find(id)
        refuse_unless_queued(item, "move")
        return [:unchanged, item, items.index(item) + 1] if (before || after) && find(before || after).equal?(item)
        position = if before then {before: before}
        elsif after then {after: after}
        else top ? :top : :bottom
        end
        before_index = items.index(item)
        rest = items - [item]
        index = @store.index_in(rest, position, current: rest.find { |i| CURRENT_STATES.include?(i["state"]) })
        return [:unchanged, item, before_index + 1] if index == before_index
        items.delete(item)
        items.insert(index, item)
        [:moved, item, index + 1]
      end

      # Sets the queue's own toggle.
      #
      # @param value [Boolean]
      # @return [Boolean] whether it changed
      def set_enabled(value)
        changed = @data["enabled"] != value
        @data["enabled"] = value
        changed
      end

      # Pauses the queue. A queue that is paused keeps its first reason.
      #
      # @param reason [String]
      # @return [Boolean] whether it was not paused before
      def pause(reason)
        return false if paused
        @data["paused"] = {"reason" => reason, "at" => @store.now}
        @events << [EventLog::WORK_QUEUE_PAUSED, {"reason" => reason, "id" => current&.dig("id")}]
        true
      end

      # @return [Boolean] whether the queue was paused
      def resume
        was = !paused.nil?
        @data["paused"] = nil
        @events << [EventLog::WORK_QUEUE_RESUMED, {}] if was
        was
      end

      # Claims the first queued item: it becomes `starting`.
      #
      # @param claimed_by [Hash] `{"pid", "started"}` of the claiming process
      # @return [Hash, nil] the item with its claim, or nil when none is queued or a current item exists
      def claim_next(claimed_by:)
        return nil if current
        item = items.find { |i| i["state"] == "queued" }
        return nil unless item
        now = @store.now
        item.merge!("state" => "starting", "claim" => @store.claim_token, "claimed_at" => now,
          "claimed_by" => claimed_by, "started_at" => now)
        item
      end

      # Records the run a claimed start made: the item becomes `active` and its claim is cleared.
      #
      # @param id [String] the item's exact id
      # @param claim [String] the token {#claim_next} gave
      # @param run_id [String, nil]
      # @return [Symbol] `:recorded`, or `:lost` when the item is gone, no longer `starting` or carries another claim
      def record_run(id, claim:, run_id:)
        item = items.find { |i| i["id"] == id && i["state"] == "starting" && i["claim"] == claim }
        return :lost unless item
        activate(item, run_id)
        :recorded
      end

      # Takes a `starting` item whose run was found after its holder died as `active`.
      #
      # @param id [String] the item's exact id
      # @param run_id [String]
      # @return [Hash, nil] the item, or nil when it is gone or not `starting`
      def adopt(id, run_id:)
        item = items.find { |i| i["id"] == id && i["state"] == "starting" }
        activate(item, run_id) if item
        item
      end

      # Marks an `active` item `held`. Any other state, or an unknown id, changes nothing.
      #
      # @param id [String] the item's exact id
      # @param reason [String]
      # @return [Hash, nil] the item, or nil when it is gone or not `active`
      def hold(id, reason:)
        item = items.find { |i| i["id"] == id && i["state"] == "active" }
        return nil unless item
        @events << [EventLog::WORK_QUEUE_ITEM_HELD, {"id" => id, "reason" => reason}]
        item.merge!("state" => "held", "reason" => reason)
      end

      # Puts a `held` item back to `active`. Any other state, or an unknown id, changes nothing.
      #
      # @param id [String] the item's exact id
      # @return [Hash, nil] the item, or nil when it is gone or not `held`
      def unhold(id)
        item = items.find { |i| i["id"] == id && i["state"] == "held" }
        item&.merge!("state" => "active", "reason" => nil)
      end

      # Takes an item out of the queue for the history. The entry is appended after
      # the queue file is written, still under the lock.
      #
      # @param id [String] the item's exact id
      # @param outcome [String] `succeeded`, `failed`, `cancelled`, `skipped`, `interrupted` or `launch_failed`
      # @param reason [String, nil]
      # @param error [String, nil] stored as `result.error`
      # @param claim [String, nil] when given, the item must still carry this claim
      # @return [Hash, Symbol, nil] the history entry; `:lost` when a claim was given and the item is
      #   gone or carries another (nothing changes); nil when no claim was given and the item is gone
      def finish(id, outcome:, reason: nil, error: nil, claim: nil)
        item = items.find { |i| i["id"] == id }
        return (claim ? :lost : nil) unless item
        return :lost if claim && item["claim"] != claim
        items.delete(item)
        result = (item["result"] || {}).merge("error" => error || item.dig("result", "error"))
        entry = {"finished_at" => @store.now}
          .merge(item.reject { |k, _| CLAIM_KEYS.include?(k) || k == "state" })
          .merge("result" => result, "outcome" => outcome, "reason" => reason)
        @pending << entry
        @events << [EventLog::WORK_QUEUE_ITEM_FINISHED, {"id" => id, "outcome" => outcome, "reason" => reason, "run_id" => result["run_id"]}]
        entry
      end

      private

      def activate(item, run_id)
        CLAIM_KEYS.each { |key| item.delete(key) }
        item["state"] = "active"
        item["result"] = (item["result"] || {}).merge("run_id" => run_id)
        @events << [EventLog::WORK_QUEUE_ITEM_STARTED, {"id" => item["id"], "kind" => item["kind"], "what" => WorkQueueStore.summary(item)[0, EVENT_WHAT_LENGTH], "run_id" => run_id}]
      end

      def insertion_index(position)
        @store.index_in(items, position, current: current)
      end

      def refuse_unless_queued(item, verb)
        case item["state"]
        when "queued" then nil
        when "starting"
          raise Workspace::Error.new("Item #{item["id"]} is starting; retry #{verb} once its start has landed.",
            code: "item_starting", details: {id: item["id"]})
        else
          raise Workspace::Error.new("Item #{item["id"]} is #{item["state"]}; use work-queue cancel to stop it.",
            code: "item_active", details: {id: item["id"], state: item["state"]})
        end
      end
    end

    # @param path [String] the workspace's `work-queue.json`
    # @param history [WorkQueueHistory] where finished items go
    # @param clock [#now] time source
    # @param id_generator [#call] returns a new item id
    # @param max_items [Integer] most items the queue may hold
    # @param workspace [String, nil] the queue's workspace, the `project` and `data.workspace` of its events
    # @param event_log [Workspace::EventLog, nil] where transitions are recorded; nil records none
    def initialize(path:, history:, clock: Time, id_generator: -> { SecureRandom.hex(4) }, max_items: MAX_ITEMS, workspace: nil, event_log: nil)
      @path = path
      @workspace = workspace
      @event_log = event_log
      @history = history
      @clock = clock
      @id_generator = id_generator
      @max_items = max_items
      @file = LockedJsonFile.new(path, parse: method(:parse_data), tag: -> { Thread.current.object_id },
        fingerprint: JSON.method(:generate), access_error: lambda { |e|
          Workspace::Error.new("Could not access the work queue at #{path} (#{e.class}: errno #{e.errno})")
        })
    end

    # @return [String] the queue file
    attr_reader :path

    # @return [Integer] the item cap
    attr_reader :max_items

    # @return [WorkQueueHistory]
    attr_reader :history

    # Runs a block under the queue's exclusive lock. When the block changed
    # the queue the revision is bumped and the file written, then the entries
    # the block's `finish` calls made go to the history and old history is
    # pruned, still under the lock; a block that raises writes neither.
    #
    # @yieldparam queue [Transaction]
    # @return [Object] the block's result
    # @raise [Workspace::Error] when the file can't be read; the block's own error leaves the file as it was
    def transaction
      pending = []
      events = []
      changed = false
      after = lambda do |_|
        pending.each { |entry| @history.append_locked(entry) }
        @history.prune if changed
        events.each { |type, data| @event_log&.record(type: type, project: @workspace, data: data.merge("workspace" => @workspace)) }
      end
      @file.exclusive(write: :if_changed, after: after) do |data|
        before = JSON.generate(data)
        result = yield Transaction.new(data, self, pending, events)
        if JSON.generate(data) != before
          data["revision"] += 1
          changed = true
        end
        result
      end
    end

    # What an item runs, in one line: a workflow item's workflow, ref and prompt, a go item's argument, text and workflow,
    # with runs of whitespace and control characters made one space.
    #
    # @param item [Hash]
    # @return [String]
    def self.summary(item)
      spec = item["spec"] || {}
      text = case item["kind"]
      when "workflow" then [spec["workflow"], spec["ref"], spec["prompt"]].compact.join(" ")
      when "go" then [spec["argument"], spec["text"], spec["workflow"]].compact.join(" ")
      else spec.to_s
      end
      text.gsub(/[[:space:][:cntrl:]]+/, " ")
    end

    # @return [Hash] `"revision"`, `"enabled"` (nil when never set), `"paused"` and `"items"`; an empty queue when there is no file
    def snapshot
      return parse_data(nil) unless File.exist?(@path)
      @file.shared { |data| Marshal.load(Marshal.dump(data)) }
    end

    # @param prefix [String] an item id or a unique prefix of one
    # @return [Hash] the item
    # @raise [Workspace::Error] `unknown_queue_item` or `ambiguous_queue_item`
    def find(prefix)
      resolve(snapshot["items"], prefix)
    end

    # @see Transaction#add
    def add(**options)
      transaction { |queue| queue.add(**options) }
    end

    # @see Transaction#remove
    def remove(ids)
      transaction { |queue| queue.remove(ids) }
    end

    # @see Transaction#move
    def move(id, **options)
      transaction { |queue| queue.move(id, **options) }
    end

    # @see Transaction#set_enabled
    def set_enabled(value)
      transaction { |queue| queue.set_enabled(value) }
    end

    # @see Transaction#pause
    def pause(reason)
      transaction { |queue| queue.pause(reason) }
    end

    # @see Transaction#resume
    def resume
      transaction(&:resume)
    end

    # @api private
    def now
      @clock.now.utc.iso8601(3)
    end

    # @api private
    def claim_token
      SecureRandom.hex(8)
    end

    # @api private
    def unused_id(items)
      taken = items.map { |i| i["id"] }
      loop do
        id = @id_generator.call
        return id unless taken.include?(id)
      end
    end

    # @api private
    def resolve(items, prefix)
      if prefix.to_s.empty?
        raise Workspace::Error.new("Give an item id, or the start of one.",
          code: "unknown_queue_item", details: {id: prefix})
      end
      found = items.select { |i| i["id"].start_with?(prefix) }
      exact = found.select { |i| i["id"] == prefix }
      found = exact if exact.size == 1
      if found.empty?
        raise Workspace::Error.new("No queued item has an id starting with #{prefix.inspect}.",
          code: "unknown_queue_item", details: {id: prefix})
      end
      if found.size > 1
        raise Workspace::Error.new("#{prefix.inspect} starts more than one queued item; give more of the id.",
          code: "ambiguous_queue_item", details: {id: prefix, matches: found.map { |i| i["id"] }})
      end
      found.first
    end

    # @api private
    def index_in(list, position, current:)
      first_queued = list.index { |i| i["state"] == "queued" } || list.size
      case position
      when :bottom then list.size
      when :top, :after_current then first_queued
      when Hash
        if position[:before]
          target = resolve(list, position[:before])
          return list.index(target) if target["state"] == "queued"
          raise Workspace::Error.new("Item #{target["id"]} is #{target["state"]}; nothing goes before it.",
            code: (target["state"] == "starting") ? "item_starting" : "item_active",
            details: {id: target["id"], state: target["state"]})
        end
        list.index(resolve(list, position[:after])) + 1
      else raise ArgumentError, "unknown position #{position.inspect}"
      end
    end

    private

    def parse_data(content)
      return empty if content.nil? || content.strip.empty?
      parsed = JSON.parse(content)
      valid = parsed.is_a?(Hash) && parsed["items"].is_a?(Array) && parsed["items"].all?(Hash) &&
        parsed.fetch("revision", 0).is_a?(Integer) && [nil, true, false].include?(parsed["enabled"]) &&
        (parsed["paused"].nil? || parsed["paused"].is_a?(Hash))
      unreadable("it is not a work queue document") unless valid
      data = {"revision" => parsed.fetch("revision", 0), "paused" => parsed["paused"], "items" => parsed["items"]}
      data["enabled"] = parsed["enabled"] if parsed.key?("enabled")
      data
    rescue JSON::ParserError
      unreadable("it is not valid JSON")
    end

    def empty
      {"revision" => 0, "paused" => nil, "items" => []}
    end

    def unreadable(reason)
      raise Workspace::Error, "The work queue #{@path} can't be read (#{reason}); " \
        "nothing was changed. Fix or move it aside and retry."
    end
  end
end
