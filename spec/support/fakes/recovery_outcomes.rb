# frozen_string_literal: true

# Recording fakes of the collaborators Workspace::RecoveryOutcomes and Workspace::RecoveryAttempts work through,
# beside RecordingRecoveryStore, RecordingConfirmerFacts, RecordingStopMarker, RecordingRecoveryStopper and
# RecordingRecoveryEventLog. Each appends its calls to +calls+ as `[method, *arguments]`, an Array several fakes
# may share so a spec reads the order of the calls across them; nothing starts a process or reads a file.
# `fake_contract_spec` checks that each accepts every call its real class accepts.

# Fake of the Workspace::InboxStore writes a give-up makes: keeps each item upserted in +items+.
class RecordingRecoveryInbox
  CONTROL_METHODS = %i[calls items].freeze

  attr_reader :calls, :items

  # @param error [Exception, nil] raised by every write
  # @param on_upsert [#call, nil] called before an upsert is kept
  def initialize(error: nil, on_upsert: nil, calls: [])
    @error = error
    @on_upsert = on_upsert
    @calls = calls
    @items = []
  end

  def upsert(record, reopen: false)
    @calls << [:upsert, record["dedupe_key"], reopen]
    raise @error if @error
    @on_upsert&.call
    @items << record
    record
  end

  def transition_by_key(key, to:, by: nil, snooze_until: nil)
    @calls << [:transition_by_key, key, to]
    raise @error if @error
    :transitioned
  end
end

# Fake of Workspace::RecoveryAttemptRunner: +restart+ and +typed+ answer the outcome given for each, and
# +rebind+ records the pane.
class RecordingStepRunner
  CONTROL_METHODS = %i[calls].freeze

  attr_reader :calls

  # @param restart [Array] what +restart+ answers, `[outcome, agent]`
  # @param typed [Array] what +typed+ answers
  def initialize(restart: ["resumed"], typed: ["typed"], calls: [])
    @restart = restart
    @typed = typed
    @calls = calls
  end

  def restart(attempt)
    @calls << [:restart, attempt.number]
    @restart
  end

  def typed(attempt)
    @calls << [:typed, attempt.number]
    @typed
  end

  def rebind(pane_id)
    @calls << [:rebind, pane_id]
  end
end

# Fake of Workspace::RecoveryOutcomes: records each call; +take_back+ answers the answer it was given.
class RecordingRecoveryOutcomes
  CONTROL_METHODS = %i[calls].freeze

  attr_reader :calls

  def initialize(calls: [])
    @calls = calls
  end

  def refuse(pane_id, seen, answer)
    @calls << [:refuse, pane_id, answer]
    nil
  end

  def clear(pane_id, seen)
    @calls << [:clear, pane_id]
    nil
  end

  def report_give_up(pane_id, entry)
    @calls << [:report_give_up, pane_id]
    nil
  end

  def resolve(session_id)
    @calls << [:resolve, session_id]
    nil
  end

  def finish(attempt, outcome, agent: nil)
    @calls << [:finish, attempt.number, outcome, agent]
    nil
  end

  def take_back(attempt, seen, answer)
    @calls << [:take_back, attempt.number, answer]
    answer
  end
end

# Fake of the Workspace::RecoveryFacts reads step 1 makes. Each answers what it was given.
class RecordingOpeningFacts
  CONTROL_METHODS = %i[calls].freeze

  attr_reader :calls

  # @param screen [String, nil] what +still_screen+ answers
  # @param detail [Hash, Symbol, nil] what +pane_detail+ answers
  # @param transcript [Hash, nil] what +transcript_error+ answers
  # @param ledger [Hash, Symbol, nil] what +ledger_session+ answers
  # @param prompted [Boolean] what +prompt_since_failure?+ answers
  def initialize(screen: "❯ ", detail: {id: "%5", pid: 10}, transcript: nil, ledger: nil, prompted: false, calls: [])
    @screen = screen
    @detail = detail
    @transcript = transcript
    @ledger = ledger
    @prompted = prompted
    @calls = calls
  end

  def still_screen(pane_id, quiet = nil)
    @calls << [:still_screen, pane_id]
    @screen
  end

  def pane_detail(pane_id)
    @calls << [:pane_detail, pane_id]
    @detail
  end

  def transcript_error(entry)
    @calls << [:transcript_error, entry["session_id"]]
    @transcript
  end

  def ledger_session(pane_id)
    @calls << [:ledger_session, pane_id]
    @ledger
  end

  def prompt_since_failure?(pane_id, entry)
    @calls << [:prompt_since_failure?, pane_id]
    @prompted
  end
end
