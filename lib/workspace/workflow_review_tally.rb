require "fileutils"

module Workspace
  # Decides a review round from the verdict files in its directory ({ReviewRoundPath.round_dir}), and makes that
  # directory when the round starts ({#open_round}). Owns the verdict format: a verdict is `<reviewer>.md` directly in
  # the round's directory whose first three lines are {HEADER_KEYS} in order ({.header_lines}), then free text.
  #
  # A verdict counts only when it is a non-empty regular file and not a link ({WorkflowProduced}'s strict rule), its
  # header names its own reviewer, a verdict in {VERDICTS} and the revision the round recorded, the +proof+ shows
  # it was written by a sub-agent of the round's review pane ({ReviewVerdictProof}) with the hash of the bytes read
  # here, and no other counted verdict came from the same sub-agent. The round is approved once the counted
  # approvals reach `need` and include every `must`; rejected once the verdicts not counted could not make that
  # true; otherwise incomplete (a missing or broken verdict is never a rejection).
  #
  # Reads files and asks +proof+; never raises for anything a file holds.
  class WorkflowReviewTally
    # The verdict file's header lines, in order.
    HEADER_KEYS = %w[reviewer verdict revision].freeze

    # The verdicts a reviewer can give.
    VERDICTS = %w[approve reject].freeze

    # The largest verdict file read.
    MAX_BYTES = ReviewVerdictProof::MAX_BYTES

    # The header lines a reviewer writes first, which {.parse} reads back.
    #
    # @param reviewer [String]
    # @param verdict [String] one of {VERDICTS}
    # @param revision [String]
    # @return [Array<String>] one line per {HEADER_KEYS} entry, no newlines
    # @raise [ArgumentError] for a verdict not in {VERDICTS} or a value that is empty or not one line
    def self.header_lines(reviewer:, verdict:, revision:)
      values = {"reviewer" => reviewer, "verdict" => verdict, "revision" => revision}
      raise ArgumentError, "verdict must be one of #{VERDICTS.join(", ")}" unless VERDICTS.include?(verdict)
      values.each { |key, value| raise ArgumentError, "#{key} must be one line of text" unless header_value?(value) }
      HEADER_KEYS.map { |key| "#{key}: #{values[key]}" }
    end

    # A leading UTF-8 byte order mark is skipped; everything else is read as written (the verdict's case is judged by {#call}).
    #
    # @param text [String] a verdict file's text
    # @return [Hash{String=>String}, nil] each of {HEADER_KEYS} to its value, or nil when the first lines are not the header
    def self.parse(text)
      return nil unless text.is_a?(String) && text.valid_encoding?
      lines = text.delete_prefix("﻿").each_line.first(HEADER_KEYS.size).map(&:chomp)
      return nil unless lines.size == HEADER_KEYS.size
      HEADER_KEYS.zip(lines).to_h do |key, line|
        found = line.match(/\A#{key}:[ \t]*(\S(?:.*\S)?)[ \t]*\z/)
        return nil unless found
        [key, found[1]]
      end
    end

    def self.header_value?(value) = value.is_a?(String) && !value.strip.empty? && !value.match?(/[[:cntrl:]]/)
    private_class_method :header_value?

    # @param proof [#proven?] given `round_dir:`, `path:`, `review_pane:` and `workspace:`, answers `{ok:, agent_id:, sha256:, problem:}`
    # @param files [#read, #directory_problem, #make] the file reads and the directory make (default {Files})
    def initialize(proof:, files: Files.new)
      @proof = proof
      @files = files
    end

    # @param run [WorkflowRun, Hash{String=>Object}] the run, on a step being reviewed
    # @param step [Hash{String=>Object}] the step's definition
    # @param round [Hash{String=>Object}] the step's round ("round", "pane", "revision", ...)
    # @return [Hash{Symbol=>Object}] :outcome (`:approved`, `:rejected` or `:incomplete`), :reviews (one row per
    #   reviewer in `from`: "reviewer", "path" (under the run's directory), "verdict", "revision", "agent_id",
    #   "sha256", "counted" and "problem"), :approvals (the counted approvals), :need, :must and, for an
    #   incomplete round, :problem
    def call(run:, step:, round:)
      stored = WorkflowRun.from_h(run).to_h
      review = WorkflowDefinition.review(step) || {}
      from = Array(review["from"])
      need = review["need"].is_a?(Integer) ? review["need"] : from.size
      must = Array(review["must"])
      # No reviewers, or none needed, decides nothing: approving would pass a step no one reviewed.
      if from.empty? || need < 1
        return {outcome: :incomplete, reviews: [], approvals: 0, need: need, must: must, problem: "the step names no reviewers to need, so the round decides nothing"}
      end
      round = round.is_a?(Hash) ? round : {}
      dir = round_dir(stored, step["id"], round["round"])
      shared = round_problem(stored, round, dir)
      rows = from.map { |name| row(name, dir, stored, round, shared) }
      drop_shared_agents(rows)
      decide(rows, need, must)
    end

    # Makes the round's directory, which must not be there yet: an entry already at its path was not made by this
    # round, so nothing in it can count.
    #
    # @param run [WorkflowRun, Hash{String=>Object}] the run, on the step being reviewed
    # @param round [Integer] the round about to start
    # @return [Hash{Symbol=>String}, nil] nil once made; else :code (`review_tampered` for an entry already there,
    #   `review_incomplete` for a directory that could not be made) and :problem
    def open_round(run:, round:)
      stored = WorkflowRun.from_h(run).to_h
      dir = round_dir(stored, stored["current"], round)
      return {code: "review_incomplete", problem: "the run has no artifacts directory to hold the round's verdicts"} unless dir
      @files.make(stored["artifacts_dir"], dir)
    end

    # The file system half: reading a verdict, checking the round's directory and making it.
    class Files
      # @param path [String]
      # @return [Hash{Symbol=>String}] :text and :sha256 of the bytes read, or :problem (`missing`, `symlink`,
      #   `not_regular_file`, `empty`, `too_large` or `unreadable`)
      def read(path)
        found = WorkflowProduced.inspect_file(path, strict: true)
        return {problem: "missing"} unless found.exists
        return {problem: found.rule} if found.rule
        bytes = String.new(encoding: Encoding::BINARY)
        content = WorkflowProduced.digest(path, max_bytes: MAX_BYTES, sink: bytes)
        return {problem: "unreadable"} unless content
        return {problem: "too_large"} if content.too_large
        {text: bytes.force_encoding(Encoding::UTF_8), sha256: content.sha256}
      end

      # @param artifacts [String] the run's directory
      # @param dir [String] the round's directory under it
      # @return [String, nil] `round_dir_missing` or `round_dir_link` when it, `reviews` or the run's directory is not a
      #   plain directory; nil when all are
      def directory_problem(artifacts, dir)
        [artifacts, File.dirname(dir), dir].each do |each|
          stat = File.lstat(each)
          return "round_dir_link" if stat.symlink?
          return "round_dir_missing" unless stat.directory?
        end
        nil
      rescue SystemCallError
        "round_dir_missing"
      end

      # @param artifacts [String] the run's directory
      # @param dir [String] the round's directory to make
      # @return [Hash{Symbol=>String}, nil] see {WorkflowReviewTally#open_round}
      def make(artifacts, dir)
        reviews = File.dirname(dir)
        FileUtils.mkdir_p(reviews, mode: 0o700)
        if [artifacts, reviews].any? { |each| File.lstat(each).symlink? }
          return {code: "review_tampered", problem: "#{reviews} is reached through a link, so the round's verdicts could land anywhere"}
        end
        begin
          Dir.mkdir(dir, 0o700)
        rescue Errno::EEXIST
          return {code: "review_tampered", problem: "#{dir} was there before the round began, so it was not made for this round"}
        end
        nil
      rescue SystemCallError => e
        {code: "review_incomplete", problem: "could not make the round's directory #{dir}: #{e.message}"}
      end
    end

    private

    def round_dir(stored, step_id, round)
      artifacts = stored["artifacts_dir"]
      attempt = Array(stored.dig("steps", step_id, "attempts")).last
      return nil unless artifacts.is_a?(String) && artifacts.start_with?("/") && attempt.is_a?(Hash) && round.is_a?(Integer)
      ReviewRoundPath.round_dir(artifacts, step_id, attempt["n"], round)
    end

    # What keeps every verdict of the round from counting, before any file is read.
    def round_problem(stored, round, dir)
      return "no_round_dir" unless dir
      return "no_review_pane" unless round["pane"].is_a?(String) && !round["pane"].empty?
      return "no_revision" unless round["revision"].is_a?(String) && !round["revision"].empty?
      @files.directory_problem(stored["artifacts_dir"], dir)
    end

    def row(name, dir, stored, round, shared)
      path = dir && File.join(dir, "#{name}.md")
      row = {"reviewer" => name, "path" => path&.delete_prefix("#{stored["artifacts_dir"]}/"), "verdict" => nil, "revision" => nil,
             "agent_id" => nil, "sha256" => nil, "counted" => false, "problem" => shared}
      return row if shared
      row.merge(judge(name, dir, path, stored, round))
    end

    # The first rule a verdict breaks, else the fields of a counted one.
    def judge(name, dir, path, stored, round)
      read = @files.read(path)
      return {"problem" => read[:problem]} if read[:problem]
      header = self.class.parse(read[:text])
      return {"sha256" => read[:sha256], "problem" => "bad_header"} unless header
      # `Approve` is approve: the verdict alone is read without case.
      verdict = VERDICTS.include?(header["verdict"].downcase) ? header["verdict"].downcase : header["verdict"]
      fields = {"verdict" => verdict, "revision" => header["revision"], "sha256" => read[:sha256]}
      problem = if header["reviewer"] != name then "wrong_reviewer"
      elsif !VERDICTS.include?(verdict) then "bad_verdict"
      elsif header["revision"] != round["revision"] then "wrong_revision"
      end
      return fields.merge("problem" => problem) if problem
      proven = @proof.proven?(round_dir: dir, path: path, review_pane: round["pane"], workspace: stored["workspace"])
      fields["agent_id"] = proven[:agent_id]
      return fields.merge("problem" => proven[:problem] || "unproven") unless proven[:ok]
      # The proof hashed the file again: bytes that changed since they were read here are not the ones it proved.
      return fields.merge("problem" => "changed") unless proven[:sha256] == read[:sha256]
      fields.merge("counted" => true, "problem" => nil)
    end

    # One sub-agent is one reviewer: verdicts written by the same one can't be told apart, so none of them counts.
    def drop_shared_agents(rows)
      counted = rows.select { |row| row["counted"] }
      counted.group_by { |row| row["agent_id"] }.each_value do |group|
        next if group.size < 2
        group.each { |row| row.merge!("counted" => false, "problem" => "same_agent") }
      end
    end

    def decide(rows, need, must)
      counted = rows.select { |row| row["counted"] }
      approved = counted.select { |row| row["verdict"] == "approve" }.map { |row| row["reviewer"] }
      rejected = counted.select { |row| row["verdict"] == "reject" }.map { |row| row["reviewer"] }
      open = rows.reject { |row| row["counted"] }
      outcome = if approved.size >= need && (must - approved).empty? then :approved
      elsif approved.size + open.size < need || must.intersect?(rejected) then :rejected
      else :incomplete
      end
      problem = (outcome == :incomplete) ? "no counted verdict from #{open.map { |row| "#{row["reviewer"]} (#{row["problem"]})" }.join(", ")}" : nil
      {outcome: outcome, reviews: rows, approvals: approved.size, need: need, must: must, problem: problem}.compact
    end
  end
end
