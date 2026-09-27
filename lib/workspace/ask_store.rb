require "json"
require "fileutils"
require "securerandom"
require "time"

module Workspace
  # Records questions an unattended agent hits, along with the default it
  # took, durable on disk and guarded by `flock` so concurrent CLI
  # invocations (multiple panes or agents in the same workspace) never
  # clobber each other's writes.
  #
  # Modeled on {Workspace::LockStore}'s tmp-file-then-rename write pattern,
  # but much simpler: there is no queue or liveness to reap, just a flat list
  # of records a human resolves later with `workspace ask answer`.
  class AskStore
    # @param path [String] path to this workspace's `asks.json`
    # @param error_output [IO] where a read that skips an unreadable file warns
    def initialize(path:, error_output: $stderr)
      @path = path
      @error_output = error_output
      @lockfile_path = "#{path}.lock"
    end

    # Appends a new open question. Never blocks on anything but the file
    # lock, so the calling agent can record it and move on with its default.
    #
    # @param question [String]
    # @param default [String] the default the agent took
    # @param context [String, nil] free-text pointer to the code in question (e.g. "file:line")
    # @param pane [String, nil] tmux pane id, when run inside tmux
    # @param worktree [String, nil] absolute path to the working directory that asked
    # @return [Hash] the new record
    def add(question:, default:, context: nil, pane: nil, worktree: nil)
      with_lock do |data|
        record = {
          "id" => unused_id(data),
          "question" => question,
          "default" => default,
          "context" => context,
          "pane" => pane,
          "worktree" => worktree,
          "asked_at" => now_iso,
          "status" => "open",
          "answer" => nil,
          "answered_at" => nil
        }
        data << record
        record
      end
    end

    # Never creates the store: nothing recorded yet reads as empty. An
    # unreadable file also reads as empty, with a warning, since nothing is
    # written back.
    #
    # @param open_only [Boolean] only unanswered questions
    # @return [Array<Hash>] records, oldest first
    def list(open_only: false)
      return [] unless File.exist?(@path)
      records = with_lock(readonly: true) { |data| records_in(data) }
      records = records.select { |r| r["status"] == "open" } if open_only
      records
    end

    # Marks a question answered.
    #
    # @param id [String]
    # @param answer [String]
    # @return [Hash, nil] the updated record, or nil when no open question has this id
    def answer(id, answer)
      with_lock do |data|
        record = records_in(data).find { |r| r["id"] == id && r["status"] == "open" }
        next nil unless record
        record["answer"] = answer
        record["status"] = "answered"
        record["answered_at"] = now_iso
        record
      end
    end

    private

    # @param readonly [Boolean] shared lock, and never rewrites the file. A
    #   write raises rather than replace a file it couldn't read, since that
    #   would drop every question in it.
    def with_lock(readonly: false)
      FileUtils.mkdir_p(File.dirname(@path), mode: 0o700)
      result = nil
      File.open(@lockfile_path, File::RDWR | File::CREAT, 0o600) do |f|
        f.flock(readonly ? File::LOCK_SH : File::LOCK_EX)
        data = read_data(readonly: readonly)
        result = yield data
        write_data(data) unless readonly
      end
      result
    rescue SystemCallError => e
      raise Workspace::Error, "Could not access question store at #{@path} (#{e.class}: errno #{e.errno})"
    end

    def read_data(readonly:)
      return [] unless File.exist?(@path)
      content = File.read(@path)
      return [] if content.strip.empty?
      parsed = JSON.parse(content)
      return parsed if parsed.is_a?(Array)
      unreadable("it is not a JSON list", readonly)
    rescue JSON::ParserError
      unreadable("it is not valid JSON", readonly)
    end

    def unreadable(reason, readonly)
      unless readonly
        raise Workspace::Error, "Question store #{@path} can't be read (#{reason}); " \
          "nothing was recorded and the file was left unchanged. Fix or move it aside and retry."
      end
      @error_output.puts "workspace: ignoring question store #{@path} (#{reason})"
      []
    end

    # Entries that aren't JSON objects are kept on disk but never matched or listed.
    def records_in(data)
      data.grep(Hash)
    end

    def unused_id(data)
      taken = records_in(data).map { |r| r["id"] }
      loop do
        id = SecureRandom.hex(3)
        return id unless taken.include?(id)
      end
    end

    def write_data(data)
      tmp = "#{@path}.#{Process.pid}.tmp"
      File.open(tmp, "w", 0o600) do |f|
        f.write(JSON.pretty_generate(data))
        f.flush
        f.fsync
      end
      File.rename(tmp, @path)
    end

    def now_iso
      Time.now.utc.iso8601
    end
  end
end
