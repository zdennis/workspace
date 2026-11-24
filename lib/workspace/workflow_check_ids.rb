module Workspace
  # The coverage check behind `workspace step check-ids`: every numbered ID one file defines (`R1`,
  # `AC-3`) must be named by another file or by the plan's `## Task details`. It reads files and the plan
  # and prints nothing; the command object turns its {Result} into output and an exit code.
  class WorkflowCheckIds
    # The most bytes a defined or covered file may hold, as for a plan file.
    MAX_BYTES = 1_048_576

    # What one check came to.
    #
    # @!attribute passed [Boolean] every defined ID is covered (or the defined file is absent and that is allowed)
    # @!attribute defined [Array<String>] the IDs the defining file holds, in its order, as it spelled them first
    # @!attribute covered [Array<String>] the defined IDs that are covered
    # @!attribute missing [Array<String>] the defined IDs that are not
    # @!attribute reason [String, nil] nil on a pass; `uncovered`, `no_plan`, `defined_absent` (also set on an allowed absence) or `covered_absent`
    # @!attribute message [String] one line, starting `check-ids:`
    # @!attribute defined_path [String, nil] the defining file's absolute path
    # @!attribute covered_path [String, nil] the covering file's absolute path, or the plan's with plan details
    Result = Struct.new(:passed, :defined, :covered, :missing, :reason, :message, :defined_path, :covered_path, keyword_init: true)

    # @param plans [Workspace::PlanAccess] answers `path_for(name)`, a workspace's plan file
    def initialize(plans:)
      @plans = plans
    end

    # @param prefixes [Array<String>] letters only, such as `R` or `AC`
    # @param defined [String] the file whose lines start with the IDs; relative to +base_dir+
    # @param covered [String, nil] the file that must name them; relative to +base_dir+
    # @param plan_details_for [String, nil] a workspace whose plan's `## Task details` must name them, instead of +covered+
    # @param line_regex [Regexp, nil] an ID counts as covered only on a line of the covered file that matches
    # @param allow_missing [Boolean] a defining file that does not exist passes
    # @param base_dir [String] what relative paths resolve against
    # @return [Result]
    # @raise [ArgumentError] if a prefix is not letters only, or not exactly one of +covered+ and +plan_details_for+ is given
    # @raise [Workspace::Error] if the workspace's plan path can't be worked out
    def call(prefixes:, defined:, base_dir:, covered: nil, plan_details_for: nil, line_regex: nil, allow_missing: false)
      raise ArgumentError, "give at least one prefix" if prefixes.empty?
      bad = prefixes.find { |prefix| !prefix.match?(/\A[A-Za-z]+\z/) }
      raise ArgumentError, "prefix #{bad.inspect} must be letters only" if bad
      raise ArgumentError, "give exactly one of covered and plan_details_for" if covered.nil? == plan_details_for.nil?

      alternation = prefixes.uniq.sort_by { |prefix| -prefix.length }.map { |prefix| Regexp.escape(prefix) }.join("|")
      defined_path = File.expand_path(defined, base_dir)
      covered_path = File.expand_path(covered, base_dir) if covered

      details = nil
      if plan_details_for
        covered_path = @plans.path_for(plan_details_for)
        details = plan_details(covered_path)
        return outcome(false, reason: "no_plan", message: "check-ids: no plan with tasks at #{covered_path}", defined_path: defined_path, covered_path: covered_path) unless details
      end

      defined_text, why = read_text(defined_path)
      if why
        return outcome(allow_missing, reason: "defined_absent", message: "check-ids: #{defined_path} does not exist", defined_path: defined_path, covered_path: covered_path) if why == :absent
        return outcome(false, reason: "defined_absent", message: "check-ids: #{why % defined_path}", defined_path: defined_path, covered_path: covered_path)
      end

      ids = defined_ids(defined_text, alternation)
      if covered
        covered_text, why = read_text(covered_path)
        if why
          message = (why == :absent) ? "#{covered_path} does not exist" : why % covered_path
          return outcome(false, defined: ids.values, reason: "covered_absent", message: "check-ids: #{message}", defined_path: defined_path, covered_path: covered_path)
        end
        named = line_regex ? ids_on_matching_lines(covered_text, alternation, line_regex) : ids_in(covered_text, alternation)
      else
        named = ids_in(details, alternation)
      end

      verdict(ids, named, defined_path: defined_path, covered_path: covered_path, line_regex: line_regex, plan: !details.nil?)
    end

    private

    def verdict(ids, named, defined_path:, covered_path:, line_regex:, plan:)
      covered, missing = ids.partition { |key, _| named.include?(key) }.map { |pairs| pairs.map(&:last) }
      if missing.empty?
        return outcome(true, defined: ids.values, covered: covered, message: "check-ids: all #{ids.size} IDs covered", defined_path: defined_path, covered_path: covered_path)
      end
      list = missing.join(" ")
      message = if plan
        "In no task of ## Task details: #{list}"
      elsif line_regex
        "check-ids: no line of #{covered_path} names these and matches /#{line_regex.source}/: #{list}"
      else
        "check-ids: not in #{covered_path}: #{list}"
      end
      outcome(false, defined: ids.values, covered: covered, missing: missing, reason: "uncovered", message: message, defined_path: defined_path, covered_path: covered_path)
    end

    def outcome(passed, message:, defined_path:, covered_path:, defined: [], covered: [], missing: [], reason: nil)
      Result.new(passed: passed, defined: defined, covered: covered, missing: missing, reason: reason, message: message,
        defined_path: defined_path, covered_path: covered_path).freeze
    end

    # @return [Hash{String => String}] normalised ID to the spelling the file used first, in file order
    def defined_ids(text, alternation)
      ids = {}
      text.scan(/^(#{alternation})-?(\d+)\b/) do |prefix, digits|
        spelling = Regexp.last_match(0)
        ids[prefix + digits] ||= spelling
      end
      ids
    end

    # @return [Array<String>] the normalised IDs named anywhere in +text+
    def ids_in(text, alternation)
      text.scan(/\b(#{alternation})-?(\d+)\b/).map { |prefix, digits| prefix + digits }
    end

    def ids_on_matching_lines(text, alternation, line_regex)
      text.each_line.select { |line| line.chomp.match?(line_regex) }.flat_map { |line| ids_in(line, alternation) }
    end

    # @return [String, nil] the plan's `## Task details` section, nil when the plan is missing or has no tasks
    def plan_details(path)
      plan = PlanFile.read(path)
      return nil if plan.nil? || plan.counts["total"].zero?
      text = File.open(path, "rb") { |file| file.read(PlanFile::MAX_BYTES) }.to_s.dup.force_encoding(Encoding::UTF_8).scrub
      text[/^## Task details\r?$(.*?)(?=^## |\z)/m, 1].to_s
    rescue SystemCallError
      nil
    end

    # A link is not followed, and a file over {MAX_BYTES} is refused rather than half read.
    #
    # @return [Array(String, nil)] the text, or nil and why: +:absent+, or a format string taking the path
    def read_text(path)
      info = File.lstat(path)
      return [nil, "%s is a link; give the file itself"] if info.symlink?
      return [nil, "%s is not a regular file"] unless info.file?
      return [nil, "%s is over #{MAX_BYTES} bytes"] if info.size > MAX_BYTES
      bytes = File.open(path, File::RDONLY | File::NOFOLLOW) { |file| file.read(MAX_BYTES + 1) }.to_s
      return [nil, "%s is over #{MAX_BYTES} bytes"] if bytes.bytesize > MAX_BYTES
      [bytes.dup.force_encoding(Encoding::UTF_8).scrub, nil]
    rescue Errno::ENOENT, Errno::ENOTDIR
      [nil, :absent]
    rescue SystemCallError => e
      [nil, "%s can't be read (#{e.class})"]
    end
  end
end
