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
    # @param generate [#call] `(data) -> String`; JSON.pretty_generate for all stores but
    #   ContextStore (compact), SkillsState (adds a newline)
    # @param fsync [Boolean] false for PaneBindings and ContextStore
    # @param renamer [#call] `(from, to)` for the rename; LockStore
    # @param tag [String, Integer, #call, nil] temp name tag, or a callable read at each write;
    #   AgentRecoveryStore and PromptQueueStore pass the writing thread's object id
    # @param fingerprint [#call] `(data) -> Object` what `write: :if_changed` compares before and
    #   after the block; default a deep copy of the data. AgentRecoveryStore and PromptQueueStore
    #   pass `JSON.method(:generate)`, so a key reorder with equal values still writes
    # @param perm [Integer, nil] mode of the written file; nil for ContextStore
    # @param lock [FileLock, nil] replaces the lock built from `lock_path:`; LockStore, for
    #   `chmod_dir:` and `open_readonly:`
    # @param lock_path [String] the sidecar lock file
    # @param access_error [#call, nil] `(SystemCallError) -> Exception` the store's own error
    #   for a file or directory that can't be reached; every store but SkillsState and
    #   ContextStore, which have none (the error is raised as it came)
    # @param read_error [#call, nil] `(SystemCallError) -> Exception` raised instead when reading
    #   an existing document fails, ahead of `access_error:`; InboxAcks, whose unreadable-file message differs
    def initialize(path, parse:, generate: JSON.method(:pretty_generate), fsync: true,
      renamer: File.method(:rename), tag: nil, perm: 0o600, lock: nil,
      lock_path: "#{path}.lock", access_error: nil, read_error: nil,
      fingerprint: ->(data) { Marshal.load(Marshal.dump(data)) })
      @path = path
      @parse = parse
      @generate = generate
      @fsync = fsync
      @renamer = renamer
      @tag = tag
      @perm = perm
      @lock = lock || FileLock.new(lock_path)
      @access_error = access_error
      @read_error = read_error
      @fingerprint = fingerprint
    end

    # Reads under a shared lock and never writes.
    #
    # @param nonblocking [Boolean] return nil, without yielding, when a writer holds the lock; LockStore
    # @param after_write [#call, nil] runs under the lock after the block, as LockStore's audit flush does
    # @yieldparam data [Object] what `parse:` made of the file
    # @return [Object, nil] the block's result
    def shared(nonblocking: false, after_write: nil, &block)
      guarded do
        @lock.hold(shared: true, nonblocking: nonblocking) do
          data = read
          result = block.call(data)
          after_write&.call
          result
        end
      end
    end

    # Reads under an exclusive lock, yields the data to change in place, and writes it.
    #
    # @param nonblocking [Boolean] return nil, without yielding, when the lock is taken; LockStore
    # @param write [Symbol] `:always`; `:if_changed` skips a write when the data equals what
    #   was read (AgentRecoveryStore, PromptQueueStore, LockStore); `:if_true` writes only
    #   when the block returned a true value (InboxAcks)
    # @param after_write [#call, nil] runs under the lock after the write decision, written or
    #   not; LockStore flushes its audit events here
    # @yieldparam data [Object] what `parse:` made of the file
    # @return [Object, nil] the block's result; nil when `nonblocking` and the lock is taken
    # @raise [Exception] whatever `parse:` or the block raises; nothing is written then
    def exclusive(nonblocking: false, write: :always, after_write: nil, &block)
      guarded do
        @lock.hold(nonblocking: nonblocking) do
          data = read
          before = @fingerprint.call(data) if write == :if_changed
          result = block.call(data)
          store(data) unless skip_write?(write, before, data, result)
          after_write&.call
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
      AtomicFile.write(@path, @generate.call(data), perm: @perm, fsync: @fsync, renamer: @renamer,
        tag: @tag.respond_to?(:call) ? @tag.call : @tag)
    end
  end
end
