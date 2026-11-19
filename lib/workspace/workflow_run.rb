module Workspace
  # One stored workflow run, as a frozen value over the Hash the run file holds.
  #
  # Readers return the stored value as it is (an absent key reads nil, an Integer stays an
  # Integer), and {#to_h} gives back the Hash it was made from, every key in its order, the ones
  # this class has no reader for too, so a run file written by an older or newer workspace
  # survives a round trip byte for byte. {.from_h} never raises on a Hash with keys missing.
  class WorkflowRun
    # Keys the engine and the outside readers name; each is a reader that returns the stored value.
    KEYS = %w[
      id schema_version workflow title definition definition_source definition_path definition_sha256
      workspace project worktree base_sha base_guard task inputs note state created_at started_at ended_at
      current pane loops pending_context reason reasons artifacts_dir parked paused continue_pending backoff budget_hold timeout_hold sweep
      extra_tokens extra_attempts extra_seconds guard_config_seen cancelled_by infra_retries reboot_recoveries
    ].freeze

    # A frozen deep copy of a parsed value, or the value itself when it is already frozen all the way down.
    #
    # @param value [Object] a parsed JSON value
    # @return [Object]
    def self.deep_freeze(value)
      case value
      when Hash
        pairs = value.map { |key, each| [deep_freeze(key), deep_freeze(each)] }
        return value if value.frozen? && pairs.zip(value.to_a).all? { |(key, each), (old_key, old)| key.equal?(old_key) && each.equal?(old) }
        pairs.to_h.freeze
      when Array
        items = value.map { |each| deep_freeze(each) }
        return value if value.frozen? && items.zip(value).all? { |each, old| each.equal?(old) }
        items.freeze
      when String
        value.frozen? ? value : value.dup.freeze
      else
        value
      end
    end

    # @param hash [Hash{String=>Object}, WorkflowRun, nil] a run as parsed from its file (a WorkflowRun is returned as it is); a missing or non-Hash value reads as an empty run
    # @return [WorkflowRun]
    def self.from_h(hash)
      hash.is_a?(WorkflowRun) ? hash : new(hash)
    end

    # @return [Hash{String=>Object}] the frozen Hash this run holds, as the run file has it
    attr_reader :to_h

    # An unfrozen deep copy of a parsed value, the counterpart of {.deep_freeze}.
    #
    # @param value [Object] a parsed JSON value
    # @return [Object]
    def self.deep_thaw(value)
      case value
      when Hash then value.to_h { |key, each| [key, deep_thaw(each)] }
      when Array then value.map { |each| deep_thaw(each) }
      when String then value.dup
      else value
      end
    end

    # @return [Hash{String=>Object}] an unfrozen deep copy of {#to_h}, for code that still changes a run Hash in place
    def thawed = self.class.deep_thaw(to_h)

    # @return [Hash{String=>Step}] each step by id, in the run's order; empty when the run has no steps
    attr_reader :steps

    # @param hash [Hash{String=>Object}, nil]
    def initialize(hash)
      @to_h = self.class.deep_freeze(hash.is_a?(Hash) ? hash : {})
      steps = @to_h["steps"].is_a?(Hash) ? @to_h["steps"] : {}
      @steps = steps.to_h { |id, each| [id, Step.from_h(each)] }.freeze
      freeze
    end

    (KEYS - %w[reboot_recoveries]).each do |key|
      define_method(key) { to_h[key] }
    end

    # @return [Integer] how many restarts a reboot recovery has made on this run; 0 when none is stored
    def reboot_recoveries = to_h["reboot_recoveries"].is_a?(Integer) ? to_h["reboot_recoveries"] : 0

    # Slots a step keeps for itself under +steps[id]+, each read by its +<key>_for(step_id)+ method.
    PER_STEP_KEYS = %w[
      reason reasons backoff pending_context continue_pending pause_hold retry_of_pending
      dispatch_cause_pending review_retry pending_move budget_hold timeout_hold
    ].freeze

    PER_STEP_KEYS.each do |key|
      # @param step_id [String] a step id
      # @return [Object, nil] the step's own value when its hash holds the key, else the run-level value; nil when neither does
      define_method(:"#{key}_for") { |step_id| self.class.slot(to_h, step_id, key) }
    end

    # @param step_id [String] a step id
    # @return [String, nil] the pane the step's agent was dispatched in when its own hash records one (a step of a
    #   group does), else the run's +pane+; nil when neither does. Not one of {PER_STEP_KEYS}: it is never swept with them.
    def pane_for(step_id) = self.class.slot(to_h, step_id, "pane")

    # The one placement rule for the {PER_STEP_KEYS} slots: whether +step_id+ keeps them under its own step hash. A step
    # does when it belongs to a fan_out group, because its siblings run at the same time and a run-level slot would be
    # overwritten by theirs; every other step keeps them at the top level of the run, as a run without groups always has.
    #
    # A step belongs to a group when its entry in the run's stored definition (+definition["steps"]+) holds a non-empty
    # String under +"group"+, the id of the fan_out group, e.g. +{"id" => "lint", "group" => "checks"}+.
    #
    # @param hash [Hash{String=>Object}] a run Hash
    # @param step_id [String, nil] a step id
    # @return [Boolean]
    def self.step_scoped?(hash, step_id)
      return false unless hash.is_a?(Hash) && step_id.is_a?(String)
      list = hash["definition"].is_a?(Hash) ? hash["definition"]["steps"] : nil
      return false unless list.is_a?(Array)
      entry = list.find { |each| each.is_a?(Hash) && each["id"] == step_id }
      entry.is_a?(Hash) && entry["group"].is_a?(String) && !entry["group"].empty?
    end

    # The Hash a writer of +step_id+'s {PER_STEP_KEYS} slots writes into, by {.step_scoped?}: the step's own hash under
    # +steps+ (made when missing), or the run Hash itself.
    #
    # @param hash [Hash{String=>Object}] a mutable run Hash
    # @param step_id [String, nil] the step whose slot is written
    # @return [Hash{String=>Object}]
    def self.slots(hash, step_id)
      return hash unless step_scoped?(hash, step_id)
      steps = hash["steps"].is_a?(Hash) ? hash["steps"] : (hash["steps"] = {})
      steps[step_id].is_a?(Hash) ? steps[step_id] : (steps[step_id] = {})
    end

    # Reads one of +step_id+'s {PER_STEP_KEYS} slots from a run Hash, as the +<key>_for+ readers do.
    #
    # @param hash [Hash{String=>Object}] a run Hash
    # @param step_id [String, nil] a step id
    # @param key [String] one of {PER_STEP_KEYS}
    # A step of a fan_out group ({.step_scoped?}) reads only its own hash: the run-level fallback is there for old run
    # files, which never tag a group, so a group member's absent key is absent, never a run-level value an earlier step
    # left. Two keys still fall back for it: +pending_context+, the run-level list the step before a group hands every
    # sibling's first attempt, and +pane+ (not one of {PER_STEP_KEYS}), the run's author pane a first sibling starts in.
    #
    # @return [Object, nil] the step's own value when its hash holds the key, else the run-level value (none for a
    #   group member, see above); nil when neither does
    def self.slot(hash, step_id, key)
      return nil unless hash.is_a?(Hash)
      steps = hash["steps"].is_a?(Hash) ? hash["steps"] : nil
      own = (steps && step_id.is_a?(String)) ? steps[step_id] : nil
      return own[key] if own.is_a?(Hash) && own.key?(key)
      return nil if STRICT_KEYS.include?(key) && step_scoped?(hash, step_id)
      hash[key]
    end

    # The {PER_STEP_KEYS} a group member never reads from the run's top level ({.slot}).
    STRICT_KEYS = (PER_STEP_KEYS - %w[pending_context]).freeze
    private_constant :STRICT_KEYS

    # {.slot} dug into as +hash.dig(key, *path)+ digs the run-level key, raising as that would on a value that can't be dug.
    #
    # @param hash [Hash{String=>Object}] a run Hash
    # @param step_id [String, nil] a step id
    # @param key [String] one of {PER_STEP_KEYS}
    # @param path [Array<String, Integer>] the keys below the slot
    # @return [Object, nil]
    def self.slot_dig(hash, step_id, key, *path) = {key => slot(hash, step_id, key)}.dig(key, *path)

    # Whether the Hash {.slots} names for +step_id+ holds +key+ (even as nil); makes nothing.
    #
    # @param hash [Hash{String=>Object}] a run Hash
    # @param step_id [String, nil] a step id
    # @param key [String] one of {PER_STEP_KEYS}
    # @return [Boolean]
    def self.slot_key?(hash, step_id, key)
      return hash.key?(key) unless step_scoped?(hash, step_id)
      own = hash["steps"].is_a?(Hash) ? hash["steps"][step_id] : nil
      own.is_a?(Hash) && own.key?(key)
    end

    # Adds +line+ to the pending context +step_id+'s next attempt is given, in the Hash {.slots} names for it.
    #
    # @param hash [Hash{String=>Object}] a mutable run Hash
    # @param step_id [String, nil] the step the line is for
    # @param line [String]
    # @param first [Boolean] put the line before the others rather than after
    # @return [Hash{String=>Object}] +hash+
    def self.add_context(hash, step_id, line, first: false)
      list = (slots(hash, step_id)["pending_context"] ||= [])
      first ? list.unshift(line) : list << line
      hash
    end

    # Removes every {PER_STEP_KEYS} slot a step keeps under its own hash, from every step, so an ended run reads as no
    # step mid-retry or held. A step's +reasons+ is its reason history, not a slot of what comes next, so it stays (as
    # the run's own +reasons+ does). The run-level slots are the caller's to remove.
    #
    # @param hash [Hash{String=>Object}] a mutable run Hash
    # @return [Hash{String=>Object}] +hash+
    def self.drop_step_slots(hash)
      steps = hash["steps"].is_a?(Hash) ? hash["steps"] : {}
      steps.each_value { |each| (PER_STEP_KEYS - %w[reasons]).each { |key| each.delete(key) } if each.is_a?(Hash) }
      hash
    end

    # @param id [String] a step id
    # @return [Step, nil]
    def step(id)
      steps[id]
    end

    # @param step_id [String]
    # @param attempt [Attempt]
    # @return [WorkflowRun] this run with +attempt+ in place of the step's attempt with the same n, or appended
    #   when the step has none with that n (a retry's new attempt)
    def with_attempt(step_id, attempt)
      hash = thawed
      steps = hash["steps"].is_a?(Hash) ? hash["steps"] : (hash["steps"] = {})
      state = steps[step_id].is_a?(Hash) ? steps[step_id] : (steps[step_id] = {})
      list = state["attempts"].is_a?(Array) ? state["attempts"] : (state["attempts"] = [])
      index = list.index { |each| each.is_a?(Hash) && each["n"] == attempt.n }
      copy = attempt.thawed
      index ? list[index] = copy : list << copy
      self.class.new(hash)
    end

    # @return [WorkflowRun] this run with +request+ (a resume's "from", "note", "pane", "turn_over") parked as a {Park}
    def with_park(request, id:, requested_at:, expires_at:, retries:)
      self.class.new(to_h.merge("parked" => Park.from_h(request.merge("id" => id, "requested_at" => requested_at, "expires_at" => expires_at, "retries" => retries)).to_h))
    end

    # @return [WorkflowRun] this run with no park; a parked note moves to the pending context ({.resume_note})
    def drop_park
      hash = thawed
      note = (parked = hash.delete("parked")).is_a?(Hash) ? parked["note"] : nil
      self.class.add_context(hash, hash["current"], self.class.resume_note(note)) if note
      self.class.new(hash)
    end

    # @param since [String] when the pause began (ISO 8601)
    # @param by [String] who paused the run
    # @param text [String, nil] the person's reason for the pause
    # @return [WorkflowRun] this run with a pause; the stored reason stays under it
    def with_paused(since:, by:, text: nil)
      self.class.new(to_h.merge("paused" => {"since" => since, "by" => by}.merge(text ? {"text" => text} : {})))
    end

    # @return [WorkflowRun] this run with no pause
    def drop_paused
      hash = thawed
      hash.delete("paused")
      self.class.new(hash)
    end

    # @return [String] the pending context line that carries a resume's +note+ to the next attempt
    def self.resume_note(note) = "Note from the person who resumed the run: #{note}"

    # @return [Step, nil] the step the run is at; nil when it has none or names one it lacks
    def current_step
      step(current)
    end

    # @param reads_plan_again [Boolean, nil] whether a step still to run reads the plan (the caller knows the definition's rules)
    # @return [Summary] what a file outside workflow may know of this run
    def summary(reads_plan_again: nil)
      last = current_step&.last_attempt
      step_states = definition_steps.map { |each| {"id" => each["id"], "state" => step(each["id"])&.state} }
      Summary.new(id: id, workflow: workflow, title: title, workspace: workspace, worktree: worktree, state: state,
        step: current, attempt: last&.n, pane: pane, step_states: step_states.freeze, reads_plan_again: reads_plan_again)
    end

    # @return [Boolean]
    def ==(other)
      other.is_a?(WorkflowRun) && to_h == other.to_h
    end
    alias_method :eql?, :==

    # @return [Integer]
    def hash
      [WorkflowRun, to_h].hash
    end

    # One step of a run: its state, its attempts and its gate.
    class Step
      # @param hash [Hash{String=>Object}, nil]
      # @return [Step]
      def self.from_h(hash)
        new(hash)
      end

      # @return [Hash{String=>Object}] the frozen Hash this step holds
      attr_reader :to_h

      # @return [Array<Attempt>] the attempts in order; empty when the step has none
      attr_reader :attempts

      # @param hash [Hash{String=>Object}, nil]
      def initialize(hash)
        @to_h = WorkflowRun.deep_freeze(hash.is_a?(Hash) ? hash : {})
        list = @to_h["attempts"].is_a?(Array) ? @to_h["attempts"] : []
        @attempts = list.map { |each| Attempt.from_h(each) }.freeze
        freeze
      end

      # @return [String, nil] pending, running, checking, passed, failed ...
      def state
        to_h["state"]
      end

      # @return [Hash, nil] the gate's state, when the step has one
      def gate
        to_h["gate"]
      end

      # @return [Hash, nil] the review round now under way, when the step is being reviewed
      def review
        to_h["review"]
      end

      # @return [Boolean] whether the step's round was kept from starting by a hold (it has a `held` mark)
      def review_held?
        review.is_a?(Hash) && review.key?("held")
      end

      # @return [Boolean] whether the step's round ended without deciding (a tally or a refused round recorded `ended_at`)
      def review_stopped?
        review.is_a?(Hash) && !review["ended_at"].nil?
      end

      # @return [Boolean] whether the step is `reviewing` with a round under way: not held, not ended, delivery not failed
      def review_live?
        state == "reviewing" && review.is_a?(Hash) && !review_held? && !review_stopped? && review["delivery"] != "failed"
      end

      # @return [Integer, nil] the review rounds the step has spent
      def review_rounds
        to_h["review_rounds"]
      end

      # @return [Object, nil]
      def redelivery_pending
        to_h["redelivery_pending"]
      end

      # @return [Attempt, nil]
      def last_attempt
        attempts.last
      end

      # @return [Boolean] whether the step's gate waits for a person
      def gate_waiting?
        gate.is_a?(Hash) && gate["state"] == "waiting"
      end

      # @return [Boolean]
      def ==(other)
        other.is_a?(Step) && to_h == other.to_h
      end
      alias_method :eql?, :==

      # @return [Integer]
      def hash
        [Step, to_h].hash
      end
    end

    # One attempt at a step; each reader returns the stored value, nil when the attempt lacks the key.
    class Attempt
      # Keys of an attempt, as the engine, the attempt record and the evidence copy write them.
      KEYS = %w[
        n started_at ended_at outcome context prompt_file head definition_sha256 prompt_sha256 packs outputs
        agent session usage reasons check code proofs reported status_report asked_input evidence remote warnings redelivered redelivery
        delivery delivering_since after_park reviews review_outcome retry_of rounds stalls refusal budget_interrupt
      ].freeze

      # @param hash [Hash{String=>Object}, nil]
      # @return [Attempt]
      def self.from_h(hash)
        new(hash)
      end

      # @return [Hash{String=>Object}] the frozen Hash this attempt holds
      attr_reader :to_h

      # @return [Hash{String=>Object}] an unfrozen deep copy of {#to_h}
      def thawed = WorkflowRun.deep_thaw(to_h)

      # @param hash [Hash{String=>Object}, nil]
      def initialize(hash)
        @to_h = WorkflowRun.deep_freeze(hash.is_a?(Hash) ? hash : {})
        freeze
      end

      KEYS.each do |key|
        define_method(key) { to_h[key] }
      end

      # @return [Boolean]
      def ==(other)
        other.is_a?(Attempt) && to_h == other.to_h
      end
      alias_method :eql?, :==

      # @return [Integer]
      def hash
        [Attempt, to_h].hash
      end
    end

    # A resume parked on the run until its pane can take it (+parked+).
    class Park
      # Keys the engine writes; each is a reader that returns the stored value, nil when absent.
      KEYS = %w[id requested_at expires_at retries from note pane turn_over].freeze

      # @param hash [Hash{String=>Object}, nil]
      # @return [Park]
      def self.from_h(hash)
        new(hash)
      end

      # @return [Hash{String=>Object}] the frozen Hash this value holds, as the run file has it
      attr_reader :to_h

      # @param hash [Hash{String=>Object}, nil]
      def initialize(hash)
        @to_h = WorkflowRun.deep_freeze(hash.is_a?(Hash) ? hash : {})
        freeze
      end

      KEYS.each do |key|
        define_method(key) { to_h[key] }
      end

      # @return [Boolean]
      def ==(other)
        other.is_a?(Park) && to_h == other.to_h
      end
      alias_method :eql?, :==

      # @return [Integer]
      def hash
        [Park, to_h].hash
      end
    end

    # The wait before a looped step is retried (+backoff+); +blocked+ is the code that kept the retry from starting.
    class Backoff
      # Keys the engine writes; each is a reader that returns the stored value, nil when absent.
      KEYS = %w[until to context text pane identity blocked].freeze

      # @param hash [Hash{String=>Object}, nil]
      # @return [Backoff]
      def self.from_h(hash)
        new(hash)
      end

      # @return [Hash{String=>Object}] the frozen Hash this value holds, as the run file has it
      attr_reader :to_h

      # @param hash [Hash{String=>Object}, nil]
      def initialize(hash)
        @to_h = WorkflowRun.deep_freeze(hash.is_a?(Hash) ? hash : {})
        freeze
      end

      KEYS.each do |key|
        define_method(key) { to_h[key] }
      end

      # @return [Boolean]
      def ==(other)
        other.is_a?(Backoff) && to_h == other.to_h
      end
      alias_method :eql?, :==

      # @return [Integer]
      def hash
        [Backoff, to_h].hash
      end
    end

    # The attempt held back because the token budget is spent (+budget_hold+), with the retry context it keeps; or the
    # review round held back (+review_round+, the round its release starts).
    class BudgetHold
      # Keys the engine writes; each is a reader that returns the stored value, nil when absent.
      KEYS = %w[context pane identity text review_round].freeze

      # @param hash [Hash{String=>Object}, nil]
      # @return [BudgetHold]
      def self.from_h(hash)
        new(hash)
      end

      # @return [Hash{String=>Object}] the frozen Hash this value holds, as the run file has it
      attr_reader :to_h

      # @param hash [Hash{String=>Object}, nil]
      def initialize(hash)
        @to_h = WorkflowRun.deep_freeze(hash.is_a?(Hash) ? hash : {})
        freeze
      end

      KEYS.each do |key|
        define_method(key) { to_h[key] }
      end

      # @return [Boolean]
      def ==(other)
        other.is_a?(BudgetHold) && to_h == other.to_h
      end
      alias_method :eql?, :==

      # @return [Integer]
      def hash
        [BudgetHold, to_h].hash
      end
    end

    # The attempt held back because the run's timeout is spent (+timeout_hold+): the same record as {BudgetHold}.
    class TimeoutHold < BudgetHold
      # @return [Boolean]
      def ==(other)
        other.is_a?(TimeoutHold) && to_h == other.to_h
      end
      alias_method :eql?, :==

      # @return [Integer]
      def hash
        [TimeoutHold, to_h].hash
      end
    end

    # What the sweep noted on the run (+sweep+): the step and attempt it saw, and the +stalled+ and +recovered+ causes with their times.
    class SweepMarks
      # Keys the engine writes; each is a reader that returns the stored value, nil when absent.
      KEYS = %w[step attempt stalled recovered interrupt infra_retry].freeze

      # @param hash [Hash{String=>Object}, nil]
      # @return [SweepMarks]
      def self.from_h(hash)
        new(hash)
      end

      # @return [Hash{String=>Object}] the frozen Hash this value holds, as the run file has it
      attr_reader :to_h

      # @param hash [Hash{String=>Object}, nil]
      def initialize(hash)
        @to_h = WorkflowRun.deep_freeze(hash.is_a?(Hash) ? hash : {})
        freeze
      end

      KEYS.each do |key|
        define_method(key) { to_h[key] }
      end

      # @return [Boolean]
      def ==(other)
        other.is_a?(SweepMarks) && to_h == other.to_h
      end
      alias_method :eql?, :==

      # @return [Integer]
      def hash
        [SweepMarks, to_h].hash
      end
    end

    # What a file outside workflow may know of a run. +step_states+ lists the definition's steps in order as
    # +{"id" => ..., "state" => ...}+.
    Summary = Data.define(:id, :workflow, :title, :workspace, :worktree, :state, :step, :attempt, :pane, :step_states, :reads_plan_again)

    private

    def definition_steps
      list = definition.is_a?(Hash) ? definition["steps"] : nil
      list.is_a?(Array) ? list.select { |each| each.is_a?(Hash) } : []
    end
  end
end
