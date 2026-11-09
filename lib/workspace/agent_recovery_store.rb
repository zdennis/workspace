require "json"
require "time"

module Workspace
  # The panes whose coding agent stopped on an API error and are waiting for a
  # recovery: one `agent-recovery.json` per workspace, an entry per tmux pane
  # id. Guarded by `flock` on `<path>.lock` and written through a temp file
  # and rename, like {PromptQueueStore}; the file survives the daemon, so a
  # restarted one picks the schedule up where it was.
  #
  # An entry holds `session_id`, `transcript_path`, `cwd`, `error`,
  # `attempts`, `phase` (`waiting`, `attempting`, `watching`, `gave_up`),
  # `stopped` (our SIGINT went out and no new agent has come back),
  # `attempt_session_id`, `last_signal_at`, `last_subagent_at`, `failed_at`,
  # `next_attempt_at`, `defer_since`, `agent_pid`, `agent_started`,
  # `agent_flags`, `last_turn_uuid`, `draft_text`, `failed_during_attempt`,
  # `turn_completed`, `give_up_reason`, `prompt_seen`, `item_open`,
  # `item_error` and `resumed_elsewhere`. The store keeps
  # them as given; {AgentRecoveryDesk} decides what they mean.
  #
  # Times are ISO 8601 UTC with milliseconds.
  class AgentRecoveryStore
    # Most attempts one failure gets, the one place the number is written.
    MAX_ATTEMPTS = 12

    # Seconds before the first attempt; each later wait doubles.
    FIRST_WAIT = 60

    # Longest wait between attempts, in seconds.
    MAX_WAIT = 900

    # Seconds a signal sent to an agent that did not stop still counts as
    # holding the pane's queue: that agent may yet exit.
    SIGNAL_HOLD = 300

    # @param attempt [Integer] the attempt about to be made, from 1
    # @return [Integer] seconds to wait before it: 60 doubling to a 900 cap
    def self.wait_before(attempt)
      [FIRST_WAIT * (2**(attempt - 1)), MAX_WAIT].min
    end

    # @param time [Time, nil]
    # @return [String, nil] the time as the file stores it
    def self.stamp(time)
      time&.utc&.iso8601(3)
    end

    # @param path [String] the workspace's `agent-recovery.json`
    # @param clock [#now] time source
    def initialize(path:, clock: Time)
      @path = path
      @file = LockedJsonFile.new(path, parse: method(:parse_data), tag: -> { Thread.current.object_id },
        fingerprint: JSON.method(:generate), access_error: lambda { |e|
          Workspace::Error.new("Could not access the agent recovery record at #{path} (#{e.class}: errno #{e.errno})")
        })
      @clock = clock
    end

    # Writes a pane's entry, replacing any it had.
    #
    # @param pane_id [String] tmux pane id
    # @param entry [Hash] the entry (string keys)
    # @return [Hash] the entry as stored
    def put(pane_id, entry)
      @file.exclusive(write: :if_changed) do |data|
        data[pane_id] = stringify(entry)
        data[pane_id].dup
      end
    end

    # @param pane_id [String]
    # @return [Hash, nil] the pane's entry, or nil when it has none
    def get(pane_id)
      return nil unless File.exist?(@path)
      @file.shared { |data| data[pane_id]&.dup }
    end

    # Changes one entry under the lock, so a conditional write sees what a
    # hook wrote a moment before, and a pane's entry can be created, changed,
    # replaced or removed in one step. The block is always called, with the
    # stored entry or an empty Hash when the pane has none, and changes it in
    # place. Afterwards an empty Hash removes the entry (`entry.clear`; clear
    # then fill replaces it, a new episode); anything else is stored with its
    # keys as strings, as {#put} does. A pane left without an entry writes
    # nothing to disk.
    #
    # @param pane_id [String]
    # @yieldparam entry [Hash] the pane's current entry, or an empty Hash
    # @return [Hash, nil] the stored copy (string keys), or nil when no entry
    #   is stored
    def update(pane_id)
      @file.exclusive(write: :if_changed) do |data|
        entry = data[pane_id] || {}
        yield entry
        if entry.empty?
          data.delete(pane_id)
          next nil
        end
        data[pane_id] = stringify(entry)
        data[pane_id].dup
      end
    end

    # @param pane_id [String]
    # @return [Hash, nil] the entry removed, or nil when there was none
    def delete(pane_id)
      @file.exclusive(write: :if_changed) do |data|
        data.delete(pane_id)
      end
    end

    # @return [Hash{String => Hash}] every pane's entry; empty when the file is missing
    def entries
      return {} unless File.exist?(@path)
      @file.shared { |data| data }
    end

    # Whether the pane's queued prompts must wait for the recovery. Never in
    # `gave_up`, whatever else the entry says: nothing will come back for
    # those prompts, and a leftover `stopped` would freeze the queue for
    # good. Otherwise while an attempt is going, while `stopped` is true, or
    # while the last signal is under {SIGNAL_HOLD} seconds old (an agent that
    # did not stop may still exit, and its SessionEnd must not drop the
    # queue).
    #
    # @param pane_id [String]
    # @return [Boolean]
    def holding?(pane_id)
      entry = get(pane_id)
      return false unless entry
      return false if entry["phase"] == "gave_up"
      return true if entry["phase"] == "attempting" || entry["stopped"] == true
      signalled = parse_time(entry["last_signal_at"])
      !signalled.nil? && @clock.now - signalled < SIGNAL_HOLD
    end

    private

    def stringify(entry)
      entry.to_h { |key, value| [key.to_s, value] }
    end

    def parse_time(value)
      Time.iso8601(value.to_s)
    rescue ArgumentError
      nil
    end

    # A corrupt or unreadable-shaped file reads as empty: a lost schedule is
    # better than a recovery that can never write again. Other failures raise.
    def parse_data(text)
      return {} unless text
      parsed = JSON.parse(text)
      (parsed.is_a?(Hash) && parsed.values.all?(Hash)) ? parsed : {}
    rescue JSON::ParserError
      {}
    end
  end
end
