require_relative "../demo_calculator/evaluation"
require_relative "checks"
require_relative "config"
require_relative "metrics"

module DemoCalculator2
  # `eval` for calculator2: v1's rows and totals, without features fired, plus each step's wall time, review rounds,
  # first-pass acceptance, the acceptance loop count and a leak check that adds a scan of the run branch's diff.
  class Evaluation < DemoCalculator::Evaluation
    # @param root [String] the checkout the run happened in
    def initialize(root:, workspace:, pricing_path:, name: nil, run_dir: nil, checks: nil, err: $stderr)
      super(root: root, workspace: workspace, pricing_path: pricing_path, name: name, run_dir: run_dir, err: err,
            checks: checks || Checks.new(repo: File.expand_path(root)), config: DemoCalculator2.config)
    end

    # Scores the run, writes eval.json and returns the document.
    #
    # @return [Hash] `{document, rows, totals, lint, leak, dir}`
    def call
      dir = run_dir
      record = read_json(File.join(dir, "run.json"))
      raise Error, "run record in #{dir} has no items" unless record.is_a?(Hash) && record["items"].is_a?(Array)
      pricing = DemoCalculator::Cost.load_pricing(@pricing_path)
      caps = workspace_json("capabilities", "--json")
      state_dir = File.dirname(caps.dig("paths", "hook_events").to_s)
      queue = (workspace_json("work-queue", "list", "--json", *name_args)["queues"] || []).first || {}
      run_ids = run_ids(record, queue)
      goals = record_goals(record)
      loaded = record["items"].map { |item| load_run(run_ids[item["id"]], File.join(state_dir, ".workflows"), item["workflow"]) }
      rows = DemoCalculator::EvalRows.rows(loaded.map { |l| l.slice(:workflow, :run, :events, :totals) }, asks: read_asks(state_dir, @name || queue["workspace"]))
      rows.each_with_index do |row, index|
        row[:item] = index + 1
        row[:goal] = goals[index]
        row[:state] = "run file missing" if loaded[index][:missing]
        row.delete(:features)
        unless row[:ran]
          row.merge!(machine_wait: nil, review_wait: nil, wall_ex_wait: nil, active_ex_wait: nil, usage: nil, acceptance: nil, step_wall: nil, step_tokens: nil, review_unmatched: nil, review_wall: nil, review_tokens: nil, accept_first_pass: nil, accept_first_recorded: nil, accept_first_disagrees: nil, accept_loops: nil)
          next
        end
        row.merge!(Metrics.machine_wait(row, loaded[index][:totals]))
        row[:review_wait] = row[:machine_wait] && row[:review_deliver_wait].to_f
        row[:usage] = reviewer_priced(DemoCalculator::EvalReport.usage(loaded[index][:run], pricing), loaded[index][:run], pricing)
        row[:acceptance] = acceptance(record, row)
        accepted = Metrics.acceptance(loaded[index][:run])
        first = first_attempt(record, row, accepted[:first_head])
        review = Metrics.review(loaded[index][:trace]) || {}
        row.merge!(step_wall: Metrics.step_wall(loaded[index][:trace]), step_tokens: Metrics.step_tokens(loaded[index][:trace]), review_unmatched: Metrics.unmatched_rounds(loaded[index][:trace]), review_wall: review[:wall],
          review_tokens: review[:tokens], accept_first_pass: first, accept_first_recorded: accepted[:first_recorded],
          accept_first_disagrees: !first.nil? && !accepted[:first_recorded].nil? && first != accepted[:first_recorded], accept_loops: accepted[:loops])
      end
      last = rows.reverse.find { |row| row[:ran] }
      lint = {head: last && real_head(last), offenses: nil}
      lint[:offenses] = lint(lint[:head]) if lint[:head]
      totals = totals(rows, lint)
      leak = leak(caps, queue, loaded, lint[:head], record.dig("acceptance_ref", "removal_sha"))
      leak &&= leak.merge(diff: diff_scan(record, lint[:head]))
      document = build_document(record, pricing, rows, totals, lint, leak)
      File.write(File.join(dir, "eval.json"), JSON.pretty_generate(document) + "\n")
      {document: document, rows: rows, totals: totals, lint: lint, leak: leak, dir: dir}
    end

    # The text of the table and the lines under it.
    def self.render(result)
      document = result[:document]
      record = document["record"]
      header = document["header"]
      [
        "Eval of #{record["stamp"]} (#{record["branch"]})",
        "  model: #{DemoCalculator::Fmt.value(header["model"])}  agent: #{DemoCalculator::Fmt.value(header["agent_version"])}  " \
          "base: #{header["base_sha"].to_s[0, 12]}  workspace: #{header["workspace_sha"].to_s[0, 12]}  prices: #{DemoCalculator::Fmt.value(header["price_date"])}",
        "",
        table(result[:rows], result[:totals]),
        (result[:totals]["first_disagreements"].to_i > 0) ? "* 1st-pass is the runner's verdict; the first attempt's recorded outcome differs (#{result[:totals]["first_disagreements"]})" : "",
        step_table(result[:rows]),
        "",
        step_token_table(result[:rows]),
        "",
        "lint: #{DemoCalculator::Fmt.value(result[:lint][:offenses])} offenses in #{DEMO}#{" at #{result[:lint][:head][0, 12]}" if result[:lint][:head]}",
        leak_line(result[:leak]),
        "wrote #{File.join(result[:dir], "eval.json")}"
      ].join("\n") + "\n"
    end

    DEMO = DemoCalculator2::DEMO_DIR
    HEADER = %w[goal state att retry rnd 1st-pass a-loops manual wall active stopped wait_p bg redeliv lockw rv-wait wall-wait act-wait gap in out cache_w cache_r cost accept].freeze

    # The per-item table and its totals row.
    def self.table(rows, totals)
      fmt = DemoCalculator::Fmt
      body = rows.map { |row| row[:ran] ? ran_cells(row) : [row[:goal], row[:state].to_s] + [DemoCalculator::EvalReport::DASH] * (HEADER.size - 2) }
      partial = totals["partial"]
      lower = ->(key, text) { fmt.total(text, partial.include?(key)) }
      body << ["total", DemoCalculator::EvalReport.states_text(totals), fmt.value(totals["attempts"]), fmt.value(totals["retries"]),
        fmt.value(totals["review_rounds"]), "#{totals["first_pass"]}/#{totals["items_run"]}", fmt.value(totals["accept_loops"]),
        fmt.value(totals["manual"]), lower.call("wall", fmt.duration(totals["wall"])), lower.call("active", fmt.duration(totals["active"])),
        lower.call("stopped", fmt.duration(totals["stopped"])), lower.call("person_wait", fmt.duration(totals["person_wait"])),
        lower.call("background", fmt.duration(totals["background"])), lower.call("deliver_wait", fmt.duration(totals["deliver_wait"])),
        lower.call("machine_wait", fmt.duration(totals["machine_wait"])), lower.call("machine_wait", fmt.duration(totals["review_wait"])),
        lower.call("machine_wait", fmt.duration(totals["wall_ex_wait"])),
        lower.call("machine_wait", fmt.duration(totals["active_ex_wait"])), "",
        lower.call("input", fmt.count(totals["input"])), lower.call("output", fmt.count(totals["output"])),
        lower.call("cache_creation", fmt.count(totals["cache_creation"])), lower.call("cache_read", fmt.count(totals["cache_read"])),
        lower.call("cost_usd", fmt.dollars(totals["cost_usd"])),
        totals["acceptance_of"].to_i.zero? ? fmt::UNKNOWN : "#{totals["acceptance_passed"]}/#{totals["acceptance_of"]}"]
      grid([HEADER, *body])
    end

    # Wall time of each step, one column per item.
    def self.step_table(rows)
      ran = rows.select { |row| row[:ran] }
      steps = ran.flat_map { |row| row[:step_wall].keys }.uniq
      return "step wall time: #{DemoCalculator::Fmt::UNKNOWN}" if steps.empty?
      body = steps.map { |step| [step, *ran.map { |row| row[:step_wall][step] ? DemoCalculator::Fmt.duration(row[:step_wall][step]) : DemoCalculator::EvalReport::DASH }] }
      body << ["review", *ran.map { |row| row[:review_wall] ? DemoCalculator::Fmt.duration(row[:review_wall]) : DemoCalculator::EvalReport::DASH }]
      grid([["step wall", *ran.map { |row| row[:goal][0, 2] }], *body])
    end

    # Tokens of each step (input + output + cache creation), one column per item, and the review rounds' on their own row.
    def self.step_token_table(rows)
      ran = rows.select { |row| row[:ran] }
      steps = ran.flat_map { |row| row[:step_tokens].keys }.uniq
      return "step tokens: #{DemoCalculator::Fmt::UNKNOWN}" if steps.empty?
      body = steps.map { |step| [step, *ran.map { |row| row[:step_tokens][step] ? DemoCalculator::Fmt.count(row[:step_tokens][step]) : DemoCalculator::EvalReport::DASH }] }
      body << ["review", *ran.map { |row| row[:review_tokens] ? DemoCalculator::Fmt.count(row[:review_tokens]) : DemoCalculator::EvalReport::DASH }]
      lines = [grid([["step tokens", *ran.map { |row| row[:goal][0, 2] }], *body])]
      ran.select { |row| row[:review_unmatched].to_i > 0 }.each do |row|
        lines << "note: #{row[:goal]} has #{row[:review_unmatched]} review round(s) with no attempt of their own; the review row counts them and no step row does"
      end
      lines.join("\n")
    end

    def self.ran_cells(row)
      fmt = DemoCalculator::Fmt
      tokens = row[:usage][:tokens]
      token = lambda do |kind|
        next DemoCalculator::EvalReport::SHARED if tokens[:all_shared]
        tokens[:known] ? fmt.total(fmt.count(tokens[kind]), tokens[:partial] || tokens[:shared]) : fmt::UNKNOWN
      end
      accept = row[:acceptance]
      [row[:goal], row[:state], row[:attempts], row[:retries], row[:review_rounds], first_pass_cell(row[:accept_first_pass], row[:accept_first_disagrees]), row[:accept_loops],
        row[:manual], fmt.duration(row[:wall]), fmt.duration(row[:active]), fmt.duration(row[:stopped]), fmt.duration(row[:person_wait]), fmt.duration(row[:background]), fmt.duration(row[:deliver_wait]),
        fmt.duration(row[:machine_wait]), fmt.duration(row[:review_wait]), fmt.duration(row[:wall_ex_wait]), fmt.duration(row[:active_ex_wait]), DemoCalculator::EvalReport.gap_cell(row), token.call(:input), token.call(:output), token.call(:cache_creation), token.call(:cache_read),
        fmt.total(fmt.dollars(row[:usage][:cost_usd]), row[:usage][:cost_partial]),
        if accept
          accept[:passed].empty? ? "FAIL" : "pass"
        else
          fmt::UNKNOWN
        end]
    end

    def self.first_pass_cell(value, disagrees = false)
      text = if value.nil?
        DemoCalculator::Fmt::UNKNOWN
      else
        value ? "yes" : "no"
      end
      disagrees ? text + "*" : text
    end

    def self.grid(table)
      widths = table.first.each_index.map { |i| table.map { |cells| cells[i].to_s.length }.max }
      lines = table.map { |cells| cells.each_with_index.map { |c, i| c.to_s.ljust(widths[i]) }.join("  ").rstrip }
      lines.insert(1, widths.map { |w| "-" * w }.join("  "))
      lines.join("\n")
    end

    # The leak line: v1's read counts, then the diff scan's.
    def self.leak_line(leak)
      return "leak: #{DemoCalculator::Fmt::UNKNOWN}" unless leak
      possible = leak[:possible]
      possible_text = possible ? "possible leaks: hook #{possible[:hook]}, transcript #{possible[:transcript].values.compact.sum}" : "possible leaks: #{DemoCalculator::Fmt::UNKNOWN}"
      ["#{DemoCalculator::EvalReport.leak_line(leak)}; #{possible_text}; #{Metrics.diff_line(leak[:diff])}",
        *Metrics.possible_lines(leak[:possible_classes])].join("\n")
    end

    # The run's usage with each review round's sub-agent tokens priced at the model they ran on (a round's own
    # `agent.model` names only the review pane's), read from the sub-agent transcripts under the round's session.
    # A round whose transcripts can't be read keeps its price, and the cost is marked partial.
    #
    # @param usage [Hash] see {DemoCalculator::EvalReport.usage}
    # @param run [Hash] a stored run
    # @param pricing [Hash] the parsed demo/pricing.yml
    # @return [Hash] the usage with its cost, models and `cost_partial` corrected
    def reviewer_priced(usage, run, pricing)
      return usage unless usage[:cost_usd]
      shift = 0.0
      models = usage[:models].dup
      partial = usage[:cost_partial]
      DemoCalculator::EvalRows.attempts(run).each do |attempt|
        Array(attempt["rounds"]).each do |round|
          next if round["ended"] == "redelivered" || round["usage"].nil?
          by_model = round_models(round)
          if by_model.nil?
            partial = true
            next
          end
          result = Metrics.model_shift(by_model, round.dig("agent", "model") || attempt.dig("agent", "model"), pricing)
          shift += result[:dollars]
          models |= result[:models]
          partial = true if result[:unpriced]
        end
      end
      usage.merge(cost_usd: usage[:cost_usd] + shift, models: models.sort, cost_partial: partial)
    end

    private

    # @return [Hash, nil] {Metrics.usage_by_model} over the round's sub-agent transcripts; nil when they can't be read
    def round_models(round)
      path = round.dig("session", "transcript")
      id = round.dig("session", "id")
      return nil unless path.is_a?(String) && id.is_a?(String) && File.basename(path, ".jsonl") == id
      return nil unless File.file?(path)
      dir = File.join(File.dirname(path), id, "subagents")
      return {} unless File.directory?(dir)
      from = Time.parse(round["started_at"].to_s)
      to = round["ended_at"] ? Time.parse(round["ended_at"].to_s) + 2 : nil
      lines = Dir.children(dir).grep(/\Aagent-.*\.jsonl\z/).sort.flat_map do |name|
        File.foreach(File.join(dir, name)).filter_map do |line|
          parsed = JSON.parse(line)
          parsed if parsed.is_a?(Hash)
        rescue JSON::ParserError
          nil
        end
      end
      Metrics.usage_by_model(lines, from: from, to: to)
    rescue SystemCallError, ArgumentError
      nil
    end

    # The goal of each queue item, in order: the record's `goals`, or all of GOALS for a record that predates it.
    def record_goals(record)
      goals = record["goals"]
      goals = DemoCalculator2::GOALS unless goals.is_a?(Array)
      known = goals.all? { |goal| DemoCalculator2::GOALS.include?(goal) }
      fits = record["goals"].is_a?(Array) ? goals.size == record["items"].size : goals.size >= record["items"].size
      raise Error, "run record lists #{goals.size} goals for #{record["items"].size} items" unless known && fits
      goals
    end

    def totals(rows, lint)
      ran = rows.select { |row| row[:ran] }
      checked = ran.select { |row| row[:acceptance] }
      totals = DemoCalculator::EvalReport.totals(rows, acceptance_passed: checked.count { |row| row[:acceptance][:failed].empty? },
        acceptance_of: checked.size, lint: lint[:offenses])
      known = ran.map { |row| row[:machine_wait] }.select { |v| v.is_a?(Numeric) }
      %w[machine_wait review_wait wall_ex_wait active_ex_wait].each do |key|
        values = ran.map { |row| row[key.to_sym] }.select { |v| v.is_a?(Numeric) }
        totals[key] = values.empty? ? nil : values.sum
      end
      totals["partial"] << "machine_wait" if !known.empty? && known.size < ran.size
      totals["first_pass"] = ran.count { |row| row[:accept_first_pass] == true }
      totals["accept_loops"] = ran.sum { |row| row[:accept_loops].to_i }
      totals["first_disagreements"] = ran.count { |row| row[:accept_first_disagrees] }
      totals
    end

    # Runs the acceptance program on the checkout the first acceptance attempt began on, so the verdict does not
    # depend on how that attempt ended (a dirty-tree failure, a timeout or an infra failure is not a failed test).
    #
    # @return [Boolean, nil] nil when there is no such checkout or the check could not run
    def first_attempt(record, row, head)
      return nil unless head
      result = @checks.acceptance(base_sha: record.dig("acceptance_ref", "sha") || record["base_sha"], head: head, goal: row[:goal])
      result[:failed].empty? && !result[:passed].empty?
    rescue DemoCalculator::EvalChecks::Error => e
      @err.puts e.message
      nil
    end

    # The acceptance ref's sha from the record: run reads its tests from there, not from base.
    def acceptance(record, row)
      head = real_head(row)
      return nil unless head
      @checks.acceptance(base_sha: record.dig("acceptance_ref", "sha") || record["base_sha"], head: head, goal: row[:goal])
    rescue DemoCalculator::EvalChecks::Error => e
      @err.puts e.message
      nil
    end

    def diff_scan(record, head)
      return nil unless head
      @checks.diff_scan(base_sha: record.dig("acceptance_ref", "sha") || record["base_sha"], head: head,
        since: record.dig("acceptance_ref", "removal_sha"))
    rescue DemoCalculator::EvalChecks::Error => e
      @err.puts e.message
      nil
    end
  end
end
