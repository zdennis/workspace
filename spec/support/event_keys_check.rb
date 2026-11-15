require "json"
require "set"

# Checks the four keys every event queued in a WorkflowRunChange carries: `from_state` and `to_state` present,
# `actor` (one of WorkflowRunChange::ACTORS) and `cause` not null. A spec over a real WorkflowRunStore calls
# {.verify!} in an `after` hook with the store's runs and archive directories; an example that writes raw
# lines on purpose (a golden or legacy fixture) opts out with `:raw_events` metadata. Every type it reads is
# remembered in {.seen}; `EVENT_KEYS_REPORT=1` prints them when the process ends.
module EventKeysCheck
  # Types that are not queued inside a run change, so they carry no actor and cause (or no states) on purpose.
  # command_denied: written by the PreToolUse hook, outside any change.
  # review_delivered: the simulator's round runner stub writes it after its own store.change.
  # simulated_*: lines the simulator writes to narrate what its fake agent and person did.
  EXEMPT_TYPES = %w[
    command_denied
    review_delivered
    simulated_agent
    simulated_person
    simulated_refused
    simulated_reviewers
    simulated_wait
  ].freeze

  @seen = Set.new
  at_exit { puts "event types seen: #{@seen.sort.join(" ")}" } if ENV["EVENT_KEYS_REPORT"]

  class << self
    # @return [Set<String>] every event type read by {.problems} so far in this process
    attr_reader :seen

    # @param events [Array<Hash>] parsed event lines
    # @param label [String] what the lines came from, for the message
    # @return [Array<String>] one message per line that lacks a key
    def problems(events, label)
      events.each_with_object([]) do |event, found|
        @seen << event["type"]
        next if EXEMPT_TYPES.include?(event["type"])
        where = "#{label} n=#{event["n"]} #{event["type"]}"
        found << "#{where}: no from_state key" unless event.key?("from_state")
        found << "#{where}: no to_state key" unless event.key?("to_state")
        found << "#{where}: actor #{event["actor"].inspect} is not one of the actors" unless Workspace::WorkflowRunChange::ACTORS.include?(event["actor"])
        found << "#{where}: cause is null" if event["cause"].nil?
      end
    end

    # Reads every `*.events.jsonl` in the directories and fails the example listing each line that lacks a key.
    def verify!(*dirs)
      found = dirs.flat_map { |dir| Dir.glob(File.join(dir.to_s, "*.events.jsonl")) }.flat_map do |path|
        events = File.readlines(path).map { |line| JSON.parse(line) }
        problems(events, File.basename(path))
      end
      raise "event lines without their keys:\n  #{found.join("\n  ")}" unless found.empty?
    end
  end
end
