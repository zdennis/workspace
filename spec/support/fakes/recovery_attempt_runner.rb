# frozen_string_literal: true

# Recording fakes of the collaborators Workspace::RecoveryAttemptRunner works through, beside
# RecordingRecoveryStore, RecordingRecoveryMonitor, RecordingStopMarker, FakePane and FakePaneFactory. Each
# appends its calls to +calls+ as `[method, *arguments]`, an Array several fakes may share so a spec reads the
# order of the calls across them; nothing starts a process or reads a file. `fake_contract_spec` checks that
# each accepts every call its real class accepts.

# Fake of the Workspace::RecoveryFacts reads the attempt runner makes. Every read of +agent+ takes the next of
# +agents+, the last one repeating, so a spec scripts a pane whose agent leaves or comes back.
class RecordingAttemptFacts
  CONTROL_METHODS = %i[calls].freeze

  attr_reader :calls

  # @param detail [Hash, Symbol, nil] what +pane_detail+ answers
  # @param agents [Array<Hash, nil>] the agent each +agent+ read finds, in order
  # @param tree [Object, nil] the tree +agent+ reads; nil when the table can't be read
  # @param clear [Boolean] what +pane_clear?+ answers
  # @param foreground [Boolean] what +foreground?+ answers
  # @param held [Boolean] what +session_held?+ answers
  # @param live [Hash, nil] what +live_agent+ answers
  # @param prompt_after [Boolean] what +prompt_after?+ answers
  def initialize(detail: {id: "%5", pid: 10}, agents: [nil], tree: :tree, clear: true, foreground: true, held: false,
    live: nil, prompt_after: false, calls: [])
    @detail = detail
    @agents = agents.dup
    @tree = tree
    @clear = clear
    @foreground = foreground
    @held = held
    @live = live
    @prompt_after = prompt_after
    @calls = calls
  end

  def pane_detail(pane_id)
    @calls << [:pane_detail, pane_id]
    @detail
  end

  def agent(detail)
    @calls << [:agent, detail]
    found = (@agents.size > 1) ? @agents.shift : @agents.first
    @tree && Workspace::RecoveryFacts::Agent.new(found: found, tree: @tree)
  end

  def pane_clear?(detail, tree)
    @calls << [:pane_clear?, detail, tree]
    @clear
  end

  def foreground?(agent, detail)
    @calls << [:foreground?, agent[:pid], detail]
    @foreground
  end

  def session_held?(session_id)
    @calls << [:session_held?, session_id]
    @held
  end

  def live_agent(pane_id)
    @calls << [:live_agent, pane_id]
    @live
  end

  def prompt_after?(pane_id, time)
    @calls << [:prompt_after?, pane_id, time]
    @prompt_after
  end
end

# Fake of Workspace::AgentReadiness: +deadline_in+ answers the seconds given, and +wait+ only records.
class RecordingReadiness
  CONTROL_METHODS = %i[calls].freeze

  attr_reader :calls

  def initialize(calls: [])
    @calls = calls
  end

  def deadline_in(seconds)
    @calls << [:deadline_in, seconds]
    seconds
  end

  def wait(session_name, deadline:, only_pane: nil, detector: nil)
    @calls << [:wait, session_name, deadline, only_pane]
    nil
  end
end

# Fake of Workspace::PromptTyper: +type+ asks +before_paste+ as the real one does, answering
# `:aborted` when it says no, then the next of +outcomes+ (the last repeating) as a PromptTyper::Result;
# +check+ answers +refusal+.
class RecordingAttemptTyper
  CONTROL_METHODS = %i[calls].freeze

  attr_reader :calls

  # @param outcomes [Array<Hash>] PromptTyper::Result fields for each +type+, in order
  # @param refusal [Hash, nil] what +check+ answers; nil means the input line holds what was pasted
  # @param on_type [#call, nil] called at each +type+, for a spec that stamps the clock then
  def initialize(outcomes: [{outcome: :submitted}], refusal: nil, calls: [], on_type: nil)
    @outcomes = outcomes.dup
    @refusal = refusal
    @calls = calls
    @on_type = on_type
  end

  def type(session_name:, target:, pane_id:, text:, before_paste: nil, before_enter: nil)
    @calls << [:type, pane_id, text]
    @on_type&.call
    return Workspace::PromptTyper::Result.new(outcome: :aborted) if before_paste && !before_paste.call
    fields = (@outcomes.size > 1) ? @outcomes.shift : @outcomes.first
    Workspace::PromptTyper::Result.new(**fields)
  end

  def check(pane_id, pasted: nil, exact: nil)
    @calls << [:check, pane_id, {pasted: pasted, exact: exact}.compact]
    @refusal
  end
end
