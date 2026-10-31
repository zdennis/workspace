require "json"
require "time"

module Workspace
  # Reads the last thing the assistant said from a Claude Code transcript, so
  # `review` can show what the agent reported when it stopped. Only the tail
  # of the file is read and only the text blocks of the final main-thread
  # assistant message are kept; tool calls, thinking and sub-agent (sidechain)
  # messages are skipped.
  class TranscriptSummary
    # Bytes read from the end of a transcript.
    TAIL_BYTES = 512 * 1024

    # Longest message returned, in characters; longer text is cut and flagged.
    MAX_LENGTH = 4000

    # Records Claude Code writes after an ordinary Stop, which say nothing of a
    # new turn. Everything else counts as activity, a type not seen before
    # included: `queue-operation` comes when a notification is queued, ahead of
    # the request.
    HOUSEKEEPING_RECORDS = %w[
      system attachment last-prompt ai-title atis-latch mode permission-mode
      file-history-snapshot file-history-delta cost-state tools-used
    ].freeze

    # What {#main_activity_after?} answers for a transcript it can't read.
    UNREADABLE = "unreadable"

    # @param path [String, nil] a transcript path from a hook event
    # @return [Hash, nil] `{"text" =>, "truncated" =>, "at" =>}`, `at` being the entry's timestamp as
    #   written; nil for a path that is nil, not a `.jsonl` file or unreadable, or when the tail holds
    #   no assistant text
    def last_assistant_message(path)
      return nil unless path.is_a?(String) && path.end_with?(".jsonl")

      stat = File.stat(path)
      return nil unless stat.file?

      lines = tail_lines(path, stat.size)
      lines.reverse_each do |line|
        next unless line.include?('"assistant"')

        message = assistant_message(line)
        return message if message
      end
      nil
    rescue SystemCallError, IOError
      nil
    end

    # The newest main-thread `user` or `assistant` record of a transcript, so a caller can tell whether the
    # agent's last turn ended in an API error. Housekeeping lines (`last-prompt`, `ai-title`, ...),
    # sub-agent (sidechain) records and `isMeta` records (injected by Claude Code, neither a prompt nor an
    # answer) are skipped. Only a top-level `isApiErrorMessage: true` counts as an error.
    #
    # @param path [String, nil] a transcript path from a hook event
    # @return [Hash, nil] `{"type" =>, "api_error" =>, "uuid" =>}`; nil for a path that is nil, not a
    #   `.jsonl` file or unreadable, or when the tail holds no such record
    def last_turn_record(path)
      return nil unless path.is_a?(String) && path.end_with?(".jsonl")

      stat = File.stat(path)
      return nil unless stat.file?

      tail_lines(path, stat.size).reverse_each do |line|
        record = turn_record(line)
        return record if record
      end
      nil
    rescue SystemCallError, IOError
      nil
    end

    # Whether the main agent wrote anything after a time, from the tail of its
    # transcript. Records are not in time order, so the whole tail is read.
    # Housekeeping and sidechain records don't count; unstamped records are
    # skipped, since a stamped `api-request` sits beside each `api-request-blob`.
    #
    # @param path [String, nil] a transcript path from a hook event
    # @param time [Time] when the main turn ended
    # @return [String, nil] the type of a record stamped after +time+, or
    #   {UNREADABLE} when the transcript or a line of its tail can't be read;
    #   nil when neither was found
    def main_activity_after?(path, time)
      return UNREADABLE unless path.is_a?(String) && path.end_with?(".jsonl")

      stat = File.stat(path)
      return UNREADABLE unless stat.file?

      tail_lines(path, stat.size).reverse_each do |line|
        found = activity_after(line, time)
        return found if found
      end
      nil
    rescue SystemCallError, IOError
      UNREADABLE
    end

    private

    def activity_after(line, time)
      return nil if line.strip.empty?

      entry = JSON.parse(line)
      return UNREADABLE unless entry.is_a?(Hash)
      return nil if entry["isSidechain"] == true || HOUSEKEEPING_RECORDS.include?(entry["type"]) || entry["timestamp"].nil?

      (Time.iso8601(entry["timestamp"]) > time) ? entry["type"].to_s[0, 64] : nil
    rescue JSON::ParserError, ArgumentError, TypeError
      UNREADABLE
    end

    def tail_lines(path, size)
      lines = File.open(path, "rb") { |file|
        file.seek(size - TAIL_BYTES) if size > TAIL_BYTES
        file.read.to_s.force_encoding(Encoding::UTF_8).scrub.lines
      }
      # A tail read starts mid-line, so the first line may be a fragment.
      lines.shift if size > TAIL_BYTES
      lines
    end

    def turn_record(line)
      entry = JSON.parse(line)
      return nil unless entry.is_a?(Hash) && %w[user assistant].include?(entry["type"])
      return nil if entry["isSidechain"] == true || entry["isMeta"] == true

      {"type" => entry["type"], "api_error" => entry["isApiErrorMessage"] == true, "uuid" => entry["uuid"]}
    rescue JSON::ParserError
      nil
    end

    def assistant_message(line)
      entry = JSON.parse(line)
      return nil unless entry.is_a?(Hash) && entry["type"] == "assistant" && entry["isSidechain"] != true

      content = entry.dig("message", "content")
      return nil unless content.is_a?(Array)

      text = content.filter_map { |block| block["text"] if block.is_a?(Hash) && block["type"] == "text" && block["text"].is_a?(String) }.join("\n").strip
      return nil if text.empty?

      {"text" => text[0, MAX_LENGTH], "truncated" => text.length > MAX_LENGTH, "at" => entry["timestamp"]}
    rescue JSON::ParserError
      nil
    end
  end
end
