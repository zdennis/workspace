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
      current pane loops pending_context reason reasons artifacts_dir parked backoff budget_hold sweep
      extra_tokens extra_attempts guard_config_seen cancelled_by
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

    # @return [Hash{String=>Step}] each step by id, in the run's order; empty when the run has no steps
    attr_reader :steps

    # @param hash [Hash{String=>Object}, nil]
    def initialize(hash)
      @to_h = self.class.deep_freeze(hash.is_a?(Hash) ? hash : {})
      steps = @to_h["steps"].is_a?(Hash) ? @to_h["steps"] : {}
      @steps = steps.to_h { |id, each| [id, Step.from_h(each)] }.freeze
      freeze
    end

    KEYS.each do |key|
      define_method(key) { to_h[key] }
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
      hash = self.class.deep_thaw(to_h)
      steps = hash["steps"].is_a?(Hash) ? hash["steps"] : (hash["steps"] = {})
      state = steps[step_id].is_a?(Hash) ? steps[step_id] : (steps[step_id] = {})
      list = state["attempts"].is_a?(Array) ? state["attempts"] : (state["attempts"] = [])
      index = list.index { |each| each.is_a?(Hash) && each["n"] == attempt.n }
      index ? list[index] = self.class.deep_thaw(attempt.to_h) : list << self.class.deep_thaw(attempt.to_h)
      self.class.new(hash)
    end

    # @return [WorkflowRun] this run with +request+ (a resume's "from", "note", "pane", "turn_over") parked as a {Park}
    def with_park(request, id:, requested_at:, expires_at:, retries:)
      self.class.new(to_h.merge("parked" => Park.from_h(request.merge("id" => id, "requested_at" => requested_at, "expires_at" => expires_at, "retries" => retries)).to_h))
    end

    # @return [WorkflowRun] this run with no park; a parked note moves to the pending context ({.resume_note})
    def drop_park
      hash = self.class.deep_thaw(to_h)
      note = (parked = hash.delete("parked")).is_a?(Hash) ? parked["note"] : nil
      hash["pending_context"] << self.class.resume_note(note) if note
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
        agent session usage reasons check code proofs reported evidence remote warnings redelivered redelivery
        delivery after_park
      ].freeze

      # @param hash [Hash{String=>Object}, nil]
      # @return [Attempt]
      def self.from_h(hash)
        new(hash)
      end

      # @return [Hash{String=>Object}] the frozen Hash this attempt holds
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

    # The attempt held back because the token budget is spent (+budget_hold+), with the retry context it keeps.
    class BudgetHold
      # Keys the engine writes; each is a reader that returns the stored value, nil when absent.
      KEYS = %w[context pane identity text].freeze

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

    # What the sweep noted on the run (+sweep+): the step and attempt it saw, and the +stalled+ and +recovered+ causes with their times.
    class SweepMarks
      # Keys the engine writes; each is a reader that returns the stored value, nil when absent.
      KEYS = %w[step attempt stalled recovered interrupt].freeze

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
