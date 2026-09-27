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
    def initialize(path:)
      @path = path
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
          "id" => SecureRandom.hex(3),
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

    # @param open_only [Boolean] only unanswered questions
    # @return [Array<Hash>] records, oldest first
    def list(open_only: false)
      records = with_lock(readonly: true) { |data| data }
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
        record = data.find { |r| r["id"] == id && r["status"] == "open" }
        next nil unless record
        record["answer"] = answer
        record["status"] = "answered"
        record["answered_at"] = now_iso
        record
      end
    end

    private

    # @param readonly [Boolean] shared lock, and never rewrites the file
    def with_lock(readonly: false)
      FileUtils.mkdir_p(File.dirname(@path), mode: 0o700)
      result = nil
      File.open(@lockfile_path, File::RDWR | File::CREAT, 0o600) do |f|
        f.flock(readonly ? File::LOCK_SH : File::LOCK_EX)
        data = read_data
        result = yield data
        write_data(data) unless readonly
      end
      result
    rescue SystemCallError => e
      raise Workspace::Error, "Could not access question store at #{@path} (#{e.class}: errno #{e.errno})"
    end

    def read_data
      return [] unless File.exist?(@path)
      content = File.read(@path)
      return [] if content.strip.empty?
      parsed = JSON.parse(content)
      parsed.is_a?(Array) ? parsed : []
    rescue JSON::ParserError
      []
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
