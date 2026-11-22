require_relative "evaluation"

module DemoCalculator2
  # `eval` for a `run --lanes` record: both workspaces' items as rows tagged with their lane, the fork, the integration
  # and the numbers across them (wall, critical path, waits). Every item's own acceptance runs under `--dag`, and the
  # integrated branch gets the plain 07 run, the lint and the diff scan; the leak scans read both workspaces. The critical path's
  # check is a start-agreement check against the harness's wall plus an ordering check, not proof that each part is right.
  class LanesEvaluation < Evaluation
    def initialize(**options)
      super
      @dag = true
    end

    # Scores the run, writes eval.json and returns the result.
    #
    # @return [Hash] `{document, rows, totals, lint, leak, dir, lanes, fork}`; `lanes` is {Metrics.lanes} plus `catches` and `plain_acceptance`
    def call
      dir = run_dir
      record = read_json(File.join(dir, "run.json"))
      raise Error, "run record in #{dir} has no items" unless record.is_a?(Hash) && record["items"].is_a?(Array) && record["lanes"].is_a?(Hash)
      pricing = DemoCalculator::Cost.load_pricing(@pricing_path)
      caps = workspace_json("capabilities", "--json")
      state_dir = File.dirname(caps.dig("paths", "hook_events").to_s)
      lanes = record["lanes"]
      a_name = @name || lanes.dig("a", "workspace")
      b_name = lanes.dig("b", "workspace")
      b_items = Array(lanes.dig("b", "items"))
      a = lane_loaded(record["items"], a_name, state_dir)
      b = lane_loaded(b_items, b_name, state_dir)
      rows = tagged_rows("A", item_rows(record, a[:loaded], record_goals(record), pricing, a_name, state_dir), a[:loaded]) +
        tagged_rows("B", item_rows(record, b[:loaded], b_items.map { |item| item["goal"] }, pricing, b_name, state_dir), b[:loaded])
      rows.each_with_index { |row, index| row[:item] = index + 1 }
      integration = record["integration"]
      integrate = integrate_loaded(integration, a[:ids], state_dir)
      last = rows.reverse.find { |row| row[:lane] == "A" && row[:ran] }
      head = integration&.fetch("head", nil) || (last && real_head(last))
      lint = {head: head, offenses: nil}
      lint[:offenses] = lint(head) if head
      totals = totals(rows, lint)
      loaded = a[:loaded] + b[:loaded] + [integrate].compact
      leak = leak(caps, {}, loaded, head, record.dig("acceptance_ref", "removal_sha"), workspaces: [a_name, b_name])
      leak &&= leak.merge(diff: diff_scan(record, head))
      summary = Metrics.lanes(rows, fork: record["fork"], integration: integration, integrate_attempts: integrate && integrate_attempts(integrate), first_item_at: lanes["first_item_at"])
      summary[:catches] = %w[A B].to_h { |lane| [lane, catches(rows.select { |row| row[:lane] == lane })] }
      summary[:integration][:plain_acceptance] = plain_acceptance(record, head)
      document = build_document(record, pricing, rows, totals, lint, leak).merge("lanes" => summary)
      File.write(File.join(dir, "eval.json"), JSON.pretty_generate(document) + "\n")
      {document: document, rows: rows, totals: totals, lint: lint, leak: leak, dir: dir, lanes: summary, fork: record["fork"]}
    end

    # The text of the table and the lines under it.
    def self.render(result)
      document = result[:document]
      record = document["record"]
      header = document["header"]
      rows = result[:rows]
      [
        "Eval of #{record["stamp"]} (#{record["branch"]}), lanes: A #{record.dig("lanes", "a", "workspace")}, B #{record.dig("lanes", "b", "workspace")}, workflow #{record.dig("lanes", "workflow")}",
        "  model: #{DemoCalculator::Fmt.value(header["model"])}  agent: #{DemoCalculator::Fmt.value(header["agent_version"])}  " \
          "base: #{header["base_sha"].to_s[0, 12]}  workspace: #{header["workspace_sha"].to_s[0, 12]}  prices: #{DemoCalculator::Fmt.value(header["price_date"])}",
        "",
        table(rows.map { |row| row.merge(goal: "#{row[:lane]} #{row[:goal]}") }, result[:totals]),
        (result[:totals]["first_disagreements"].to_i > 0) ? "* 1st-pass is the runner's verdict; the first attempt's recorded outcome differs (#{result[:totals]["first_disagreements"]})" : "",
        step_table(rows),
        "",
        step_token_table(rows),
        "",
        *Metrics.lanes_lines(result[:lanes], result[:fork]),
        catches_line(result[:lanes][:catches]),
        "lint: #{DemoCalculator::Fmt.value(result[:lint][:offenses])} offenses in #{DEMO}#{" at #{result[:lint][:head][0, 12]}" if result[:lint][:head]} (the integrated branch)",
        leak_line(result[:leak]),
        "wrote #{File.join(result[:dir], "eval.json")}"
      ].join("\n") + "\n"
    end

    # @return [String]
    def self.catches_line(catches)
      parts = catches.map { |lane, found| "lane #{lane} verify fixes #{found[:verify_fixes]}, review rejections #{found[:review_rejections]}" }
      "catches: #{parts.join("; ")}"
    end

    private

    # @return [Hash] `loaded` (see Evaluation#load_run, one per item) and `ids` (item id => run id) from the workspace's queue and history
    def lane_loaded(items, name, state_dir)
      args = name ? ["--name", name] : []
      queue = (workspace_json("work-queue", "list", "--json", *args)["queues"] || []).first || {}
      history = workspace_json("work-queue", "history", "list", "--json", *args)["entries"] || []
      ids = (queue["items"] || []).to_h { |item| [item["id"], item["run_id"]] }
      history.each { |entry| ids[entry["id"]] = entry.dig("result", "run_id") if entry.dig("result", "run_id") }
      loaded = items.map { |item| load_run(ids[item["id"]], File.join(state_dir, ".workflows"), item["workflow"]) }
      {loaded: loaded, ids: ids}
    end

    def tagged_rows(lane, rows, loaded)
      rows.each_with_index do |row, index|
        row[:lane] = lane
        row[:column] = "#{lane}#{row[:goal].to_s[0, 2]}"
        run = loaded[index][:run]
        next unless row[:ran] && run
        row.merge!(started_at: first_attempt_start(run) || run["started_at"], ended_at: run["ended_at"], lock_wait: loaded[index][:totals]&.dig("machine_waiting_seconds", "waiting_lock"))
        row.merge!(Metrics.catches(run))
      end
    end

    # An item's start is its first attempt's: the closing LOOP DONE line measures its wall from the same instant.
    def first_attempt_start(run)
      times = run.fetch("steps", {}).values.flat_map { |step| Array(step["attempts"]).filter_map { |attempt| attempt["started_at"] } }
      times.min_by { |text| Time.parse(text) }
    rescue ArgumentError
      nil
    end

    def catches(rows)
      {verify_fixes: rows.sum { |row| row[:verify_fixes].to_i }, review_rejections: rows.sum { |row| row[:review_rejections].to_i }}
    end

    # The integrate-branch run loaded like an item, or nil when the integration needed none or its run is not found.
    def integrate_loaded(integration, ids, state_dir)
      item = integration&.dig("integrate_run", "item")
      run_id = item && (ids[item] || integration.dig("integrate_run", "run_id"))
      return nil unless run_id
      loaded = load_run(run_id, File.join(state_dir, ".workflows"), DemoCalculator2::INTEGRATE_WORKFLOW_ID)
      loaded[:run] ? loaded : nil
    end

    def integrate_attempts(loaded)
      DemoCalculator::EvalRows.rows([loaded.slice(:workflow, :run, :events, :totals)]).first[:attempts]
    end

    # The plain acceptance run, groups 1..7, at the integrated head: the same check the harness made after the merge.
    #
    # @return [Boolean, nil] nil when there is no head or the run could not be made
    def plain_acceptance(record, head)
      return nil unless head
      result = @checks.acceptance(base_sha: record.dig("acceptance_ref", "sha") || record["base_sha"], head: head, goal: "07-repl")
      result[:failed].empty? && !result[:passed].empty?
    rescue DemoCalculator::EvalChecks::Error => e
      @err.puts e.message
      nil
    end
  end
end
