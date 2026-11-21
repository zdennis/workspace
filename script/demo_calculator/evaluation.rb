require "json"
require "open3"
require "time"
require_relative "cost"
require_relative "eval_checks"
require_relative "eval_report"
require_relative "eval_rows"

module DemoCalculator
  # `eval`: scores one recorded run. Loads run.json, finds each item's workflow run through the `workspace`
  # CLI, reads the run files, builds the rows and the checks and writes eval.json beside run.json.
  class Evaluation
    class Error < StandardError; end

    # @param root [String] the checkout the run happened in (git repo for the checks)
    # @param workspace [String] the `workspace` program
    # @param name [String, nil] the demo workspace's name; nil lets `workspace` detect it
    # @param run_dir [String, nil] the directory holding run.json; nil means the newest under tmp/demo-calculator/runs
    # @param pricing_path [String] demo/pricing.yml
    # @param checks [#acceptance, #lint, #leak_check] the git-backed checks
    # @param err [IO] where warnings go
    def initialize(root:, workspace:, pricing_path:, name: nil, run_dir: nil, checks: nil, err: $stderr)
      @root = File.expand_path(root)
      @workspace = workspace
      @name = name
      @run_dir = run_dir && File.expand_path(run_dir, @root)
      @pricing_path = pricing_path
      @checks = checks || EvalChecks.new(repo: @root)
      @err = err
    end

    # Scores the run, writes eval.json and returns the document.
    #
    # @return [Hash] `{record, header, rows, totals, lint, leak}` with string keys at the top
    # @raise [Error] when there is no run record or a `workspace` call fails
    def call
      dir = run_dir
      record = read_json(File.join(dir, "run.json"))
      pricing = Cost.load_pricing(@pricing_path)
      caps = workspace_json("capabilities", "--json")
      state_dir = File.dirname(caps.dig("paths", "hook_events").to_s)
      queue = (workspace_json("work-queue", "list", "--json", *name_args)["queues"] || []).first || {}
      run_ids = run_ids(record, queue)
      loaded = record["items"].map { |item| load_run(run_ids[item["id"]], File.join(state_dir, ".workflows"), item["workflow"]) }
      rows = EvalRows.rows(loaded.map { |l| l.slice(:workflow, :run, :events, :totals) })
      rows.each_with_index do |row, index|
        row[:item] = index + 1
        row[:state] = "run file missing" if loaded[index][:missing]
        next unless row[:ran]
        row[:usage] = EvalReport.usage(loaded[index][:run], pricing)
        row[:acceptance] = acceptance(record, row)
      end
      last = rows.reverse.find { |row| row[:ran] }
      lint = {head: last && real_head(last), offenses: nil}
      lint[:offenses] = lint(lint[:head]) if lint[:head]
      totals = EvalReport.totals(rows, acceptance_passed: last&.dig(:acceptance)&.fetch(:passed)&.size, lint: lint[:offenses])
      leak = leak(caps, queue, loaded)
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
        "  model: #{Fmt.value(header["model"])}  agent: #{Fmt.value(header["agent_version"])}  " \
          "base: #{header["base_sha"].to_s[0, 12]}  workspace: #{header["workspace_sha"].to_s[0, 12]}  prices: #{Fmt.value(header["price_date"])}",
        "",
        EvalReport.table(result[:rows], result[:totals]),
        "",
        EvalReport.lint_line(result[:lint]),
        EvalReport.leak_line(result[:leak]),
        "wrote #{File.join(result[:dir], "eval.json")}"
      ].join("\n") + "\n"
    end

    private

    def run_dir
      return @run_dir if @run_dir
      newest = Dir.glob(File.join(@root, "tmp", "demo-calculator", "runs", "*", "run.json")).max
      raise Error, "no run record under tmp/demo-calculator/runs: run `run` first or pass --run DIR" unless newest
      File.dirname(newest)
    end

    def read_json(path)
      JSON.parse(File.read(path))
    rescue Errno::ENOENT
      raise Error, "no run record at #{path}"
    rescue JSON::ParserError, SystemCallError => e
      raise Error, "cannot read #{path}: #{e.message}"
    end

    def name_args = @name ? ["--name", @name] : []

    def workspace_json(*argv)
      out, err, status = Open3.capture3(@workspace, *argv, chdir: @root)
      raise Error, "workspace #{argv.first(2).join(" ")} failed (exit #{status.exitstatus}): #{err.strip}" unless status.success?
      JSON.parse(out)
    rescue JSON::ParserError
      raise Error, "workspace #{argv.first(2).join(" ")} did not print JSON"
    end

    # item id => run id, from the finished history first, then the live queue.
    def run_ids(record, queue)
      history = workspace_json("work-queue", "history", "list", "--json", *name_args)["entries"] || []
      ids = (queue["items"] || []).to_h { |item| [item["id"], item["run_id"]] }
      history.each { |entry| ids[entry["id"]] = entry.dig("result", "run_id") if entry.dig("result", "run_id") }
      record["items"].to_h { |item| [item["id"], ids[item["id"]]] }
    end

    def load_run(run_id, workflows_dir, workflow)
      empty = {workflow: workflow, run: nil, events: [], totals: nil}
      return empty unless run_id
      path = %w[runs archive].map { |sub| File.join(workflows_dir, sub, "#{run_id}.json") }.find { |p| File.file?(p) }
      unless path
        @err.puts "eval: run file for #{run_id} not found under #{workflows_dir}"
        return empty.merge(missing: true)
      end
      trace = workspace_json("workflow", "trace", run_id, "--json")
      {workflow: workflow, run: read_json(path), events: read_events(path.sub(/\.json\z/, ".events.jsonl")), totals: trace["totals"]}
    end

    def read_events(path)
      return [] unless File.file?(path)
      File.foreach(path).filter_map do |line|
        JSON.parse(line)
      rescue JSON::ParserError
        nil
      end
    end

    def real_head(row)
      row[:head] if row[:head].is_a?(String) && !row[:head].empty?
    end

    def acceptance(record, row)
      head = real_head(row)
      return nil unless head
      @checks.acceptance(base_sha: record["base_sha"], head: head, index: row[:item])
    rescue EvalChecks::Error => e
      @err.puts e.message
      nil
    end

    def lint(head)
      @checks.lint(head: head, gemfile: File.join(@root, "Gemfile"))
    rescue EvalChecks::Error => e
      @err.puts e.message
      nil
    end

    def leak(caps, queue, loaded)
      runs = loaded.filter_map { |l| l[:run] }
      return nil if runs.empty?
      dir = caps.dig("paths", "hook_events")
      workspace = @name || queue["workspace"]
      hook_files = (dir && workspace) ? ["#{workspace}.jsonl", "#{workspace}.jsonl.1"].map { |f| File.join(dir, f) } : []
      transcripts = runs.flat_map { |run| EvalRows.attempts(run) }.filter_map { |a| a.dig("session", "transcript") }
      ended = runs.map { |run| run["ended_at"] }
      @checks.leak_check(hook_files: hook_files, transcripts: transcripts, from: runs.first["created_at"],
        to: ended.all? ? ended.max_by { |t| Time.parse(t) } : nil)
    end

    def build_document(record, pricing, rows, totals, lint, leak)
      usages = rows.filter_map { |row| row[:usage] }
      header = {
        "model" => join_or_nil(usages.flat_map { |u| u[:models] }),
        "agent_version" => join_or_nil(usages.flat_map { |u| u[:agent_versions] }),
        "base_sha" => record["base_sha"],
        "workspace_sha" => record.dig("workspace", "sha"),
        "price_date" => pricing["price_date"]
      }
      {"record" => record, "header" => header, "rows" => rows.map { |row| row.except(:run) }, "totals" => totals,
       "lint" => lint, "leak" => leak}
    end

    def join_or_nil(values)
      values.uniq.sort.then { |list| list.empty? ? nil : list.join(", ") }
    end
  end
end
