require "json"

module Workspace
  module Commands
    # `workspace skills install` and `skills uninstall`: link the four workspace
    # skills (whole directories, never files) into the skills directory of each
    # harness the person picks, and into `~/.agents/skills` when it exists. See
    # {Workspace::SkillLinks} for what is never replaced.
    #
    # Both commands print their report (text, or one JSON document) and return
    # whether everything asked for was done; the CLI turns false into exit 1.
    class Skills
      # The directory the shared skills live in; not a harness, so never asked about.
      AGENTS_KEY = "agents".freeze

      # @param harnesses [Workspace::SkillHarnesses]
      # @param source [Workspace::SkillSource]
      # @param links [Workspace::SkillLinks]
      # @param state [Workspace::SkillsState]
      # @param input [IO, Workspace::PromptInput] where the answer comes from
      # @param output [IO]
      # @param error_output [IO] where questions go when the report is JSON, so stdout holds one document
      # @param version [String] this tool's version, reported in the document
      def initialize(harnesses:, source:, links:, state:, input: $stdin, output: $stdout, error_output: $stderr, version: Workspace::VERSION)
        @harnesses = harnesses
        @source = source
        @links = links
        @state = state
        @input = input
        @output = output
        @error_output = error_output
        @version = version
      end

      # @param install_all [Boolean] install for every harness found, ask nothing, clear declines
      # @param dry_run [Boolean] write nothing
      # @param json [Boolean] print one document
      # @return [Boolean] false when anything was refused or failed
      # @raise [Workspace::Error] `skill_source_worktree`, `skills_source_missing`,
      #   `no_harness_found`, `confirmation_required`
      def install(install_all: false, dry_run: false, json: false)
        source = @source.resolve
        found = @harnesses.found
        raise Error.new("No coding-agent harness found: none of claude, codex, pi or opencode is on PATH, and none has a config directory.", code: "no_harness_found") if found.empty?

        declined = @state.declined
        linked = found.select { |harness| fully_linked?(harness.dir) }
        waiting = found - linked
        pending = install_all ? [] : waiting.reject { |harness| declined.include?(harness.key) }
        answer = if install_all
          waiting
        else
          ask(pending, json ? @error_output : @output)
        end
        chosen = answer || []
        refused_now = answer ? pending - chosen : []
        selected = found.select { |harness| (linked + chosen).include?(harness) }
        new_declined = install_all ? [] : (declined - selected.map(&:key) + refused_now.map(&:key))
        @state.declined = new_declined if !dry_run && new_declined != declined

        targets = selected.map { |harness| [harness.key, harness.name, harness.dir] }
        targets << [AGENTS_KEY, "shared skills", @harnesses.agents_dir] if selected.any? && @harnesses.agents_dir?
        targets = targets.uniq { |_, _, dir| dir }
        plans = targets.to_h { |_, _, dir| [dir, @links.plan(dir, source.root, SkillSource::NAMES)] }
        plans.each_value { |plan| @links.apply(plan) } unless dry_run

        rows = found.map { |harness| harness_row(harness, plans[harness.dir], new_declined, selected) }
        rows << row(AGENTS_KEY, @harnesses.agents_dir, status_of(plans[@harnesses.agents_dir]), plans[@harnesses.agents_dir]) if plans[@harnesses.agents_dir]
        (@harnesses.all - found).each { |harness| rows << row(harness.key, harness.dir, "skipped", nil) }
        warnings = plans.values.flat_map(&:warnings)
        ok = plans.values.none? { |plan| plan.steps.any? { |step| %w[refused failed].include?(step.outcome) } }
        report(rows, plans, targets, source: source, dry_run: dry_run, json: json, ok: ok, warnings: warnings, declined: found.select { |h| new_declined.include?(h.key) && !selected.include?(h) })
        ok
      end

      # @param dry_run [Boolean] write nothing
      # @param json [Boolean]
      # @return [Boolean] true; what uninstall leaves is reported, not a failure
      def uninstall(dry_run: false, json: false)
        rows = []
        removed = 0
        left = 0
        @harnesses.known_dirs.each do |dir|
          steps = @links.removal_steps(dir, SkillSource::NAMES)
          steps.each { |step| @links.remove(step) if step.outcome == "removed" && !dry_run }
          removed += steps.count { |step| step.outcome == "removed" }
          left += steps.count { |step| step.outcome == "left" }
          rows << {"key" => key_for(dir), "dir" => dir, "status" => (steps.any? { |step| step.outcome == "removed" }) ? "removed" : "skipped", "skills" => steps.map { |step| skill_row(step) }}
        end
        ok = rows.none? { |r| r["skills"].any? { |s| s["outcome"] == "failed" } }
        if json
          @output.puts JSON.generate(document(rows, source: nil, dry_run: dry_run, ok: ok, warnings: []))
        else
          rows.each do |r|
            next if r["skills"].empty?
            @output.puts r["dir"]
            r["skills"].each { |s| @output.puts "  #{s["outcome"].ljust(8)} #{s["name"]}#{note(s["code"], s["message"])}" }
          end
          verb = dry_run ? "Would remove" : "Removed"
          @output.puts "#{verb} #{removed} skill #{(removed == 1) ? "link" : "links"}#{"; left #{left} that #{(left == 1) ? "is" : "are"} not ours" if left > 0}."
        end
        ok
      end

      private

      def note(code, message)
        message ? "  #{code}: #{message}" : ""
      end

      def fully_linked?(dir)
        SkillSource::NAMES.all? { |name| @links.ours?(File.join(dir, name), name) }
      end

      # One screen for every harness still undecided. Returns the harnesses chosen, or nil
      # when there was no answer (end of input): nothing is installed and nothing is recorded.
      def ask(pending, out)
        return [] if pending.empty?
        out.puts "Harnesses found:"
        pending.each_with_index { |harness, i| out.puts "  #{i + 1}. #{harness.name.ljust(12)} #{harness.dir}" }
        loop do
          line = Prompt.ask(@input, out, "Choose numbers or names, \"all\", or \"none\" [all]: ", retry_flags: ["--install-all"])
          if line.nil?
            out.puts "\nNo answer: nothing installed, nothing recorded. Run it again, or use --install-all."
            return
          end
          chosen = parse_choice(line, pending)
          return chosen if chosen
          out.puts "Not understood: #{line.strip.inspect}. Use numbers (1-#{pending.size}), names (#{pending.map(&:key).join(", ")}), all or none."
        end
      end

      def parse_choice(line, pending)
        words = line.downcase.split(/[\s,]+/).reject(&:empty?)
        return pending if words.empty? || words == ["all"]
        return [] if words == ["none"]
        picked = words.map { |word|
          if word.match?(/\A\d+\z/)
            (word.to_i >= 1) ? pending[word.to_i - 1] : nil
          else
            pending.find { |h| h.key == word }
          end
        }
        picked.all? ? pending.select { |h| picked.include?(h) } : nil
      end

      def harness_row(harness, plan, declined, selected)
        return row(harness.key, harness.dir, status_of(plan), plan) if selected.include?(harness)
        row(harness.key, harness.dir, declined.include?(harness.key) ? "declined" : "skipped", nil)
      end

      def status_of(plan)
        outcomes = plan.steps.map(&:outcome)
        return "refused" if outcomes.include?("refused")
        return "failed" if outcomes.include?("failed")
        "linked"
      end

      def row(key, dir, status, plan)
        {"key" => key, "dir" => dir, "status" => status, "skills" => plan ? plan.steps.map { |step| skill_row(step) } : []}
      end

      def skill_row(step)
        r = {"name" => step.name, "outcome" => step.outcome, "from" => step.from, "to" => step.to, "code" => step.code}
        r["message"] = step.message if step.message
        r["mv"] = step.mv if step.mv
        r["backup"] = step.backup if step.backup && step.outcome == "adopted"
        r
      end

      def key_for(dir)
        harness = @harnesses.all.find { |h| h.dir == dir }
        harness ? harness.key : AGENTS_KEY
      end

      def document(rows, source:, dry_run:, ok:, warnings:)
        {"schema_version" => 1, "ok" => ok, "version" => @version, "source" => source&.root, "dry_run" => dry_run,
         "harnesses" => rows, "warnings" => warnings}
      end

      def report(rows, plans, targets, source:, dry_run:, json:, ok:, warnings:, declined:)
        if json
          @output.puts JSON.generate(document(rows, source: source, dry_run: dry_run, ok: ok, warnings: warnings))
          return
        end
        @output.puts "Skills from #{source.root} (#{source.kind}), workspace #{@version}"
        warnings.each { |warning| @output.puts "Warning: #{warning}" }
        targets.each do |_, name, dir|
          @output.puts "#{name} (#{dir})"
          plans[dir].steps.each do |step|
            @output.puts "  #{step.outcome.ljust(9)} #{step.name}#{note(step.code, step.message)}"
            @output.puts "            to keep it, run: #{step.mv}" if step.mv
            @output.puts "            the old directory is now in #{step.backup}" if step.backup && step.outcome == "adopted" && !dry_run
          end
        end
        declined.each { |harness| @output.puts "Declined: #{harness.name}. 'workspace skills install --install-all' installs it." }
        @output.puts summary(plans, dry_run: dry_run, ok: ok)
      end

      def summary(plans, dry_run:, ok:)
        steps = plans.values.flat_map(&:steps)
        return "Nothing to install: every harness found is declined. 'workspace skills install --install-all' installs them." if plans.empty?
        counts = steps.map(&:outcome).tally
        changed = steps.count { |step| %w[linked relinked adopted].include?(step.outcome) }
        dirs = plans.size
        return "Skills already current in #{dirs} #{(dirs == 1) ? "directory" : "directories"}." if ok && changed.zero?
        text = "#{dry_run ? "Would link" : "Linked"} #{changed} skill #{(changed == 1) ? "link" : "links"} in #{plans.values.count { |p| p.steps.any? { |s| %w[linked relinked adopted].include?(s.outcome) } }} of #{dirs} #{(dirs == 1) ? "directory" : "directories"}"
        text += "; #{plans.values.count(&:refused?)} refused (nothing was linked there)" unless ok
        text + "." + (((counts["failed"] || 0) > 0) ? " #{counts["failed"]} failed." : "")
      end
    end
  end
end
