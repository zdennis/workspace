require "digest"

module Workspace
  # Finds the note a workflow gate asks a person to read. After a passing
  # review round it is the round's `summary.md` ({WorkflowReviewSummary}),
  # which the engine wrote in the round's directory. Otherwise the gated
  # step's first `produces` file names it on its first line, `note: <file>`,
  # and the file is a plain file name in the workspace's notes directory, a
  # regular file and not a link. `workflow approve` and `workflow status`
  # both ask this class, so both name the same file.
  class WorkflowGateNote
    # The line that names the note; the name is checked by {NotePath}.
    NOTE_LINE = /\Anote:[ \t]*(\S(?:.*\S)?)[ \t]*\r?\n?\z/

    # Bytes of the step's file read for its first line.
    FIRST_LINE_BYTES = 4096

    # @param notes [Workspace::Commands::Notes] says where a workspace's notes directory is
    def initialize(notes:)
      @notes = notes
    end

    # @param run [WorkflowRun, Hash{String=>Object}] a stored run
    # @param step_id [String] the gated step
    # @return [Hash{String=>String}, nil] "name", "path" and "sha256" (of the bytes read now);
    #   nil when the step passed no review with a summary and its first file is missing or has no `note:` line
    # @raise [Workspace::Error] code `gate_note_unreadable` when the named note is not a
    #   readable regular file in the notes directory, or the review summary is gone or not a regular file
    def find(run, step_id = WorkflowRun.from_h(run).current)
      run = WorkflowRun.from_h(run)
      summary = review_summary(run, step_id)
      return summary if summary
      name = named(run, step_id)
      return nil unless name
      raise unreadable(run, step_id, "#{name} is not a plain file name", name: name) if name.include?("/")
      dir = notes_dir(run, step_id, name)
      unsafe = ShellSafePath.unsafe_characters(dir)
      raise unreadable(run, step_id, "the notes directory holds #{unsafe.join(", ")}, which a shell command can't hold safely", name: name) unless unsafe.empty?
      begin
        NotePath.resolve(name, dir)
      rescue NotePath::Refused => e
        raise unreadable(run, step_id, "#{name} #{e.reason}", name: name, path: File.join(dir, name))
      end
      path = File.join(dir, name)
      sha = self.class.sha256(path)
      raise unreadable(run, step_id, "#{path} can't be read as a regular file", name: name, path: path) unless sha
      {"name" => name, "path" => path, "sha256" => sha}
    end

    # @param workspace [String]
    # @return [String, nil] the workspace's notes directory; nil when it can't be found
    def notes_dir_of(workspace)
      @notes.info(name: workspace)["dir"]
    rescue Workspace::Error, SystemCallError
      nil
    end

    # The error for a gate that names no note, for a caller that needs one.
    #
    # @param run [WorkflowRun, Hash{String=>Object}] a stored run
    # @param step_id [String] the gated step
    # @return [Workspace::Error] code `gate_note_unreadable`
    def missing(run, step_id = WorkflowRun.from_h(run).current)
      run = WorkflowRun.from_h(run)
      unreadable(run, step_id, "its first file #{first_file(run, step_id) || "(none)"} has no `note:` line")
    end

    # The sha256 of a regular file's bytes, read without following a link.
    #
    # @param path [String]
    # @return [String, nil] lowercase hex; nil when it isn't a readable regular file
    def self.sha256(path)
      File.open(path, File::RDONLY | File::NOFOLLOW | File::NONBLOCK) do |file|
        return nil unless file.stat.file?
        digest = Digest::SHA256.new
        while (chunk = file.read(65_536))
          digest << chunk
        end
        digest.hexdigest
      end
    rescue SystemCallError, IOError
      nil
    end

    private

    # The summary of the round that passed the step's last attempt, when the engine wrote one: its path is worked
    # out from the run's directory, step, attempt and round, never read from the run, and it must be a regular
    # file, not a link, whose bytes still hash to what the round's record says the engine wrote. A run stored before
    # summaries has none, and its gate reads the step's `note:` line.
    def review_summary(run, step_id)
      attempt = run.steps.fetch(step_id).last_attempt
      stored = attempt&.to_h || {}
      outcome = stored["review_outcome"]
      return nil unless outcome.is_a?(Hash) && outcome["passed"] == true && outcome["summary"].is_a?(String) && outcome["round"].is_a?(Integer)
      artifacts = run.artifacts_dir
      return nil unless artifacts.is_a?(String) && artifacts.start_with?("/")
      path = WorkflowReviewSummary.path(artifacts, step_id, attempt.n, outcome["round"])
      name = ReviewRoundPath::SUMMARY
      way_out = "approve can't go on: `workspace workflow reject #{run.id} --note ...` runs the step again (a new round writes a new summary), " \
        "`workspace workflow resume #{run.id} --from #{step_id}` starts it over, or `workspace workflow cancel #{run.id}`"
      sha = self.class.sha256(path)
      raise unreadable(run, step_id, "the review summary #{path} is gone or not a regular file; #{way_out}", name: name, path: path) unless sha
      written = written_sha(stored, outcome["round"])
      if written && written != sha
        raise unreadable(run, step_id, "the review summary #{path} changed since the engine wrote it (sha256 #{written}, now #{sha}); #{way_out}", name: name, path: path)
      end
      {"name" => name, "path" => path, "sha256" => sha}
    end

    # The hash the engine recorded for the round's summary, from the newest record of that round that has one.
    def written_sha(attempt, round)
      record = Array(attempt["rounds"]).reverse.find { |each| each.is_a?(Hash) && each["round"] == round && each["summary"].is_a?(Hash) }
      sha = record&.dig("summary", "sha256")
      sha.is_a?(String) ? sha : nil
    end

    def first_file(run, step_id)
      step = run.definition["steps"].find { |each| each["id"] == step_id }
      produced = Array(step && step["produces"]).first
      produced && File.join(run.artifacts_dir, produced)
    end

    # A step file that is gone, a link, or not a regular file names no note; it is opened
    # without waiting, so a FIFO there can't hold the run's lock. A `note:` line that is
    # not UTF-8 text (or is cut at the read limit) names a note that can't be read.
    def named(run, step_id)
      path = first_file(run, step_id)
      return nil unless path
      line = read_first_line(path)
      return nil unless line&.start_with?("note:")
      text = line.dup.force_encoding(Encoding::UTF_8)
      raise unreadable(run, step_id, "the note: line of #{path} is not UTF-8 text", path: path) unless text.valid_encoding?
      NOTE_LINE.match(text)&.[](1)
    end

    def read_first_line(path)
      File.open(path, File::RDONLY | File::NOFOLLOW | File::NONBLOCK) do |file|
        file.stat.file? ? file.binmode.gets("\n", FIRST_LINE_BYTES) : nil
      end
    rescue SystemCallError, IOError
      nil
    end

    def notes_dir(run, step_id, name)
      @notes.info(name: run.workspace)["dir"]
    rescue Workspace::Error, SystemCallError => e
      raise unreadable(run, step_id, "the notes directory of #{run.workspace} can't be found (#{e.message})", name: name)
    end

    def unreadable(run, step_id, why, name: nil, path: nil)
      attempt = run.steps.fetch(step_id).last_attempt&.n
      Workspace::Error.new("The gate of step #{step_id} in run #{run.id} has no note that can be read: #{why}.",
        code: "gate_note_unreadable",
        details: {"run_id" => run.id, "step" => step_id, "attempt" => attempt, "name" => name, "path" => path})
    end
  end
end
