require "yaml"
require_relative "boundary_scan"

# The dependency-direction rules that need no layer list. Each violation is a
# Violation row; its key ("rule|file|constant") is what boundary_allow.yml lists.
#
#   core_references_nothing  a file under lib/workspace/core/ references a
#                            constant defined outside core/ (stdlib is not in lib/)
#   commands_below_commands  a file outside commands/ and the cli files
#                            references a constant defined in commands/;
#                            lib/workspace.rb (build_cli, the composition root)
#                            builds every command object and is exempt
#   run_file_parse           a file other than the run store and run_liveness
#                            parses JSON and names a workflow run directory
#   process_outside_adapter  a file other than the tool's adapter names git, tmux
#                            or gh as the program of a process (BoundaryScan.process_literals:
#                            the first words of Open3, Process.spawn, IO.popen, system,
#                            spawn, exec and backticks, an array whose first element is the
#                            tool, and for gh any call whose first argument is "gh").
#                            git: only git.rb; tmux: only tmux.rb; gh: only the files that
#                            run it through their injected runner. WorkflowGuard takes its
#                            git program as git_path:, a variable, so it is not seen.
#
# Layers and entry lists come in a later task (T57).
module BoundaryRules
  Violation = Struct.new(:rule, :file, :line, :constant, :message, keyword_init: true) do
    def key
      "#{rule}|#{file}|#{constant}"
    end
  end

  CORE = "lib/workspace/core/"
  COMMANDS = "lib/workspace/commands/"
  CLI_LOCATIONS = %w[lib/workspace/cli.rb lib/workspace/cli/].freeze
  COMPOSITION_ROOT = "lib/workspace.rb"
  RUN_FILE_READERS = %w[lib/workspace/workflow_run_store.rb lib/workspace/run_liveness.rb].freeze
  RUN_DIR_PATTERN = /workflow_runs_dir|workflow_archive_dir|"\.workflows"/
  JSON_PARSE_PATTERN = /\bJSON\.(?:parse|load)\b/

  PROCESS_ADAPTERS = {
    "git" => %w[lib/workspace/git.rb],
    "tmux" => %w[lib/workspace/tmux.rb],
    "gh" => %w[
      lib/workspace/git.rb
      lib/workspace/gh_pull_requests.rb
      lib/workspace/pull_request_status.rb
      lib/workspace/pull_request_feedback.rb
      lib/workspace/commands/pull_request.rb
      lib/workspace/ticket_source.rb
    ]
  }.freeze

  ALLOW_FILE = "spec/support/boundary_allow.yml"

  # root: repo root. paths: repo-relative files (default lib/**/*.rb).
  # Returns violations sorted by key, one per rule, file and constant.
  def self.violations(root, paths: nil)
    paths ||= Dir.glob("lib/**/*.rb", base: root).sort
    scan = BoundaryScan.new(root, paths: paths)
    all = core_references_nothing(scan) + commands_below_commands(scan) + run_file_parse(root, paths) +
      process_outside_adapter(root, paths)
    all.uniq(&:key).sort_by(&:key)
  end

  def self.core_references_nothing(scan)
    scan.references_from(CORE).filter_map do |ref|
      outside = ref.target_files.reject { |f| BoundaryScan.under?(f, CORE) }
      next if outside.empty?

      Violation.new(rule: "core_references_nothing", file: ref.file, line: ref.line, constant: ref.constant,
        message: "core references #{ref.constant} (#{outside.join(", ")}); core references nothing outside core/")
    end
  end

  def self.commands_below_commands(scan)
    scan.references.filter_map do |ref|
      next if exempt_from_commands_rule?(ref.file)

      inside = ref.target_files.select { |f| BoundaryScan.under?(f, COMMANDS) }
      next if inside.empty?

      Violation.new(rule: "commands_below_commands", file: ref.file, line: ref.line, constant: ref.constant,
        message: "#{ref.constant} is defined in #{inside.join(", ")}; only commands/ and the cli reference commands")
    end
  end

  def self.exempt_from_commands_rule?(file)
    file == COMPOSITION_ROOT ||
      BoundaryScan.under?(file, COMMANDS) ||
      CLI_LOCATIONS.any? { |location| BoundaryScan.under?(file, location) }
  end

  def self.run_file_parse(root, paths)
    paths.filter_map do |file|
      next if RUN_FILE_READERS.include?(file)

      raw = File.read(File.join(root, file), encoding: "UTF-8")
      next unless RUN_DIR_PATTERN.match?(raw)

      stripped = BoundaryScan.strip(raw)
      index = stripped.lines.index { |l| JSON_PARSE_PATTERN.match?(l) }
      next unless index

      Violation.new(rule: "run_file_parse", file: file, line: index + 1, constant: "JSON.parse",
        message: "parses JSON in a file that names a workflow run directory; only the run store and run_liveness read run files")
    end
  end

  def self.process_outside_adapter(root, paths)
    paths.flat_map do |file|
      literals = BoundaryScan.process_literals(File.read(File.join(root, file), encoding: "UTF-8"))
      literals.filter_map do |literal|
        next if PROCESS_ADAPTERS.fetch(literal.tool).include?(file)

        Violation.new(rule: "process_outside_adapter", file: file, line: literal.line, constant: literal.tool,
          message: "runs #{literal.tool} outside #{PROCESS_ADAPTERS.fetch(literal.tool).join(", ")} (#{literal.form} form)")
      end
    end
  end

  # The allow-list as {key => entry}. Raises on a malformed file.
  def self.allow_list(path)
    return {} unless File.exist?(path)

    data = YAML.safe_load_file(path) || {}
    raise "#{path} must be a mapping of key => {reason: ...}" unless data.is_a?(Hash)

    data
  end
end
