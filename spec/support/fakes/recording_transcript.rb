# frozen_string_literal: true

# Reads transcripts through a real reader and calls the given block after each read.
class RecordingTranscript
  def initialize(reader, &after_read)
    @reader = reader
    @after_read = after_read
  end

  def last_turn_record(*args, **options)
    @reader.last_turn_record(*args, **options).tap { @after_read.call }
  end
end
