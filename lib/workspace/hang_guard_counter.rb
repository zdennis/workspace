require "json"
require "time"
require_relative "core/file_lock"
require_relative "core/atomic_file"
require_relative "core/locked_json_file"

module Workspace
  # How many undecided permission requests the hang guard has denied for one
  # turn of one agent: `hang-guard.json` in the state directory, one entry per
  # key with a count and an `updated_at`. `take` counts a deny until the cap,
  # so a dialog shows after that many; the guard waits for the file's lock for
  # a fraction of a second at most and gives up with `:unknown`, because a
  # hook must not stall the agent. Entries a day old are dropped at each write.
  #
  # Loads without the rest of Workspace, for the `session-event` fast path.
  class HangGuardCounter
    MAX_AGE = 86_400
    LOCK_WAIT = 0.25

    # The key of the turn the guard counts under, from the pane's binding and ids.
    #
    # @param binding [Hash, nil] the pane's binding entry (`kind`, `id`, `step`, `attempt`, `role`, `round`, `group`, `bound_at`)
    # @param pane_id [String] the tmux pane id
    # @param session_id [String] the agent's session id
    # @return [String] `run:ID:STEP:ATTEMPT` for a step's author, with `:rROUND` for a reviewer,
    #   `run:ID:group:GROUP:BOUND_AT` for a fan_out group's pane, `pane:PANE:SESSION` for an unbound pane
    def self.key_for(binding:, pane_id:, session_id:)
      run = binding.is_a?(Hash) && binding["kind"] == "run" && binding["id"]
      return "pane:#{pane_id}:#{session_id}" unless run
      return "run:#{run}:group:#{binding["group"]}:#{binding["bound_at"]}" if binding["group"]
      return "pane:#{pane_id}:#{session_id}" unless binding["step"] && binding["attempt"]
      key = "run:#{run}:#{binding["step"]}:#{binding["attempt"]}"
      (binding["role"] == "reviewer") ? "#{key}:r#{binding["round"]}" : key
    end

    # @param path [String] `hang-guard.json`
    # @param wait [Numeric] seconds to wait for the file's lock
    # @param clock [#call] `() -> Time`, the seam for `updated_at` and pruning
    def initialize(path:, wait: LOCK_WAIT, clock: -> { Time.now })
      @path = path
      @wait = wait
      @clock = clock
      @file = LockedJsonFile.new(path, parse: method(:parse), tag: -> { Process.pid })
    end

    # Counts one deny under `key` while the count is under `max`.
    #
    # @param key [String] from {.key_for}
    # @param max [Integer] denies allowed before a dialog is left to show
    # @return [Symbol] `:deny` (counted), `:capped` (`max` reached, nothing counted) or `:unknown`
    #   (the lock wait ran out, or the file can't be used)
    def take(key, max:)
      take_counted(key, max: max).first
    end

    # {#take}, with the count under `key` once it has run.
    #
    # @param key [String] from {.key_for}
    # @param max [Integer] denies allowed before a dialog is left to show
    # @return [Array(Symbol, Integer), Array(Symbol, nil)] the result of {#take} and the count after it (`max`
    #   once capped); nil with `:unknown`
    def take_counted(key, max:)
      result = update do |data|
        entry = data[key]
        count = entry ? entry["count"] : 0
        if count >= max
          [:capped, count]
        else
          data[key] = {"count" => count + 1, "updated_at" => now.iso8601}
          [:deny, count + 1]
        end
      end
      (result == LockedJsonFile::UNAVAILABLE) ? [:unknown, nil] : result
    rescue SystemCallError
      [:unknown, nil]
    end

    # Drops the unbound-pane entries of one pane, for a new prompt or session. Costs one stat
    # when the file does not exist yet, and one read with no lock when it holds no entry of the pane.
    #
    # @param pane_id [String]
    # @return [void]
    def clear_pane(pane_id)
      return unless File.exist?(@path)
      prefix = "pane:#{pane_id}:"
      return unless File.read(@path).include?(JSON.generate(prefix).delete_suffix("\""))
      update { |data| data.delete_if { |key, _| key.start_with?(prefix) } }
      nil
    rescue SystemCallError
      nil
    end

    private

    def update
      @file.exclusive(wait: @wait, write: :if_changed) do |data|
        prune(data)
        yield data
      end
    end

    def prune(data)
      cutoff = now - MAX_AGE
      data.delete_if { |_, entry| !fresh?(entry, cutoff) }
    end

    def fresh?(entry, cutoff)
      Time.iso8601(entry["updated_at"]) >= cutoff
    rescue ArgumentError
      false
    end

    def parse(text)
      return {} if text.nil? || text.strip.empty?
      data = JSON.parse(text)
      return {} unless data.is_a?(Hash)
      data.select { |key, entry| key.is_a?(String) && entry.is_a?(Hash) && entry["count"].is_a?(Integer) && entry["updated_at"].is_a?(String) }
    rescue JSON::ParserError
      {}
    end

    def now = @clock.call
  end
end
