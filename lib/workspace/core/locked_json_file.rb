require "json"

module Workspace
  # One JSON document guarded by a sidecar lock: lock, read, yield the data,
  # write it back whole, unlock. The store keeps the meaning of the document;
  # this class keeps the steps. Corrupt-file rules and messages are the
  # store's, through `parse:`.
  class LockedJsonFile
    # @param path [String] the document
    # @param parse [#call] `(text_or_nil) -> data`; gets nil for no file. Returns the empty
    #   value for a missing or blank file, and raises (or warns and returns empty) for a
    #   corrupt one. Every store passes its own.
    # @param tag [#call, nil] read at each write for the temp name; AgentRecoveryStore and
    #   PromptQueueStore pass the writing thread's object id
    # @param fingerprint [#call] `(data) -> Object` what `write: :if_changed` compares before and
    #   after the block; default a deep copy of the data. AgentRecoveryStore and PromptQueueStore
    #   pass `JSON.method(:generate)`, so a key reorder with equal values still writes
    # @param access_error [#call, nil] `(SystemCallError) -> Exception` the store's own error
    #   for a file or directory that can't be reached; every store passes one
    # @param read_error [#call, nil] `(SystemCallError) -> Exception` raised instead when reading
    #   an existing document fails, ahead of `access_error:`; InboxAcks, whose unreadable-file message differs
    def initialize(path, parse:, tag: nil, access_error: nil, read_error: nil,
      fingerprint: ->(data) { Marshal.load(Marshal.dump(data)) })
      @path = path
      @parse = parse
      @tag = tag
      @lock = FileLock.new("#{path}.lock")
      @access_error = access_error
      @read_error = read_error
      @fingerprint = fingerprint
    end

    # Reads under a shared lock and never writes.
    #
    # @yieldparam data [Object] what `parse:` made of the file
    # @return [Object] the block's result
    def shared(&block)
      guarded do
        @lock.hold(shared: true) { block.call(read) }
      end
    end

    # Reads under an exclusive lock, yields the data to change in place, and writes it.
    #
    # @param write [Symbol] `:always`; `:if_changed` skips a write when the data equals what
    #   was read (AgentRecoveryStore, PromptQueueStore); `:if_true` writes only
    #   when the block returned a true value (InboxAcks)
    # @yieldparam data [Object] what `parse:` made of the file
    # @return [Object] the block's result
    # @raise [Exception] whatever `parse:` or the block raises; nothing is written then
    def exclusive(write: :always, &block)
      guarded do
        @lock.hold do
          data = read
          before = @fingerprint.call(data) if write == :if_changed
          result = block.call(data)
          store(data) unless skip_write?(write, before, data, result)
          result
        end
      end
    end

    private

    def skip_write?(write, before, data, result)
      case write
      when :if_changed then @fingerprint.call(data) == before
      when :if_true then !result
      else false
      end
    end

    def guarded
      yield
    rescue SystemCallError => e
      raise @access_error ? @access_error.call(e) : e
    end

    def read
      text = begin
        File.exist?(@path) ? File.read(@path, encoding: Encoding::UTF_8) : nil
      rescue SystemCallError => e
        raise @read_error.call(e) if @read_error
        raise
      end
      @parse.call(text)
    end

    def store(data)
      AtomicFile.write(@path, JSON.pretty_generate(data), tag: @tag&.call)
    end
  end
end
