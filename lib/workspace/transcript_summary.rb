require "json"

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

    private

    def tail_lines(path, size)
      lines = File.open(path, "rb") { |file|
        file.seek(size - TAIL_BYTES) if size > TAIL_BYTES
        file.read.to_s.force_encoding(Encoding::UTF_8).scrub.lines
      }
      # A tail read starts mid-line, so the first line may be a fragment.
      lines.shift if size > TAIL_BYTES
      lines
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
