module Workspace
  # Writes a file whole: to a temp file beside it, then a rename, so a reader
  # sees the old file or the new one and never half of either.
  module AtomicFile
    # @param path [String] the file to replace
    # @param content [String]
    # @param perm [Integer, nil] mode of the new file; nil leaves it to the umask (ContextStore, ProjectSettings)
    # @param fsync [Boolean] flush to disk before the rename; false for PaneBindings and ContextStore
    # @param renamer [#call] `(from, to)`, the seam for the rename (LockStore, State)
    # @param tag [String, Integer, nil] added to the default temp name as
    #   `<path>.<pid>.<tag>.tmp` (AgentRecoveryStore, PromptQueueStore: the thread's object id; State: random hex)
    # @param temp_name [#call, nil] `(path) -> String` replaces the default temp name, for
    #   stores whose names differ (SkillsState, ContextStore, ProjectSettings)
    # @param encoding [Encoding, String, nil] file encoding (WorkflowRunStore: UTF-8)
    # @param writer [#call, nil] `(temp_path, content)` replaces the write of the temp
    #   file, and `perm:`, `fsync:` and `encoding:` with it (State's `writer:`)
    # @return [void]
    # @raise [SystemCallError] when a step fails; the old file is left and the temp file removed
    def self.write(path, content, perm: 0o600, fsync: true, renamer: File.method(:rename),
      tag: nil, temp_name: nil, encoding: nil, writer: nil)
      temp = temp_name ? temp_name.call(path) : default_temp(path, tag)
      done = false
      begin
        if writer
          writer.call(temp, content)
        else
          write_temp(temp, content, perm, fsync, encoding)
        end
        renamer.call(temp, path)
        done = true
      ensure
        File.delete(temp) if !done && File.exist?(temp)
      end
    end

    def self.default_temp(path, tag)
      tag ? "#{path}.#{Process.pid}.#{tag}.tmp" : "#{path}.#{Process.pid}.tmp"
    end
    private_class_method :default_temp

    def self.write_temp(temp, content, perm, fsync, encoding)
      args = perm ? ["w", perm] : ["w"]
      options = encoding ? {encoding: encoding} : {}
      File.open(temp, *args, **options) do |file|
        file.write(content)
        next unless fsync
        file.flush
        file.fsync
      end
    end
    private_class_method :write_temp
  end
end
