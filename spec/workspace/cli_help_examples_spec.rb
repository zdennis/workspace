require "stringio"
require "tmpdir"

# Every help page must end with an `Examples:` section of 3 to 10 commented
# examples. PAGES is the one list of pages; KNOWN_GAPS holds the pages that
# fail today. A page in KNOWN_GAPS must still fail, so fixing one forces its
# removal and the list only shrinks.
#
# The real CLI is built and run in a throwaway HOME, in a throwaway working
# directory, with PATH holding only Ruby's directory, so tmux, git, osascript
# and gh are not found and no real state is read or written.
module HelpExamplesSpec
  # Help pages by argv (without --help).
  PAGES = [
    "", "version", "help",
    "add", "agent", "agent run", "agent status", "agent status request", "agent status post", "agent executables",
    "agentd", "agentd restart",
    "agent-run", "agent-run command", "agent-run inject", "agent-run restart", "agent-run send",
    "agent-run queue", "agent-run queue list", "agent-run queue cancel", "agent-run examples",
    "alfred", "alfred install", "alfred uninstall", "alfred info",
    "ask", "ask list", "ask answer", "ask deliver", "ask withdraw",
    "binding", "binding set", "binding show", "binding clear",
    "capabilities", "capture", "cleanup", "current", "deactivate", "dir", "doctor",
    "config", "config show", "config set", "config get", "config unset", "config edit", "config keys", "config validate",
    "daemon", "daemon status", "daemon restart", "daemon log", "daemon list",
    "dev", "dev up", "dev down", "dev status", "dev wait", "dev leave", "dev __run",
    "event-log", "event-log show", "event-log compact",
    "events", "finish", "focus",
    "goal", "goal show", "goal list",
    "handoff", "handoff check", "handoff new",
    "hooks", "hooks uninstall",
    "inbox", "inbox add", "inbox list", "inbox show", "inbox edit", "inbox done", "inbox dismiss", "inbox reopen",
    "inbox snooze", "inbox ack",
    "init",
    "instructions", "instructions compose",
    "kill", "launch",
    "layout", "layout save", "layout restore", "layout list",
    "library", "library list", "library show", "library info", "library add", "library update", "library remove",
    "library install", "library uninstall", "library installed",
    "list", "lock", "lock acquire", "lock release", "lock status", "lock clear", "lock instructions",
    "lookup", "notes", "notes dir", "parent",
    "pipeline", "pipeline start", "pipeline advance", "pipeline status", "pipeline reset",
    "plan", "plan status", "plan path", "plan show", "plan init", "plan start", "plan pause", "plan delete",
    "plan task add", "plan task set-state", "plan task set-title", "plan task move",
    "pr", "pr create", "pr feedback",
    "projects", "projects list", "projects show", "projects members", "projects stop", "projects kill",
    "projects group", "projects group create", "projects group add", "projects group list", "projects group show",
    "promote", "prune", "push", "reactivate", "rebase", "relaunch", "remove", "repair", "resize", "restore",
    "run", "run-and-report", "report-run-status", "session-event", "sessions", "set-command", "snapshot",
    "review", "review show", "review list",
    "spine", "spine show", "spine init", "spine set", "spine check", "spine verify", "spine start", "spine goal",
    "spine goal set",
    "start", "status", "statusline", "step", "step done", "step status", "stop",
    "ticket", "ticket show", "ticket list", "tile", "tmux", "tmux show",
    "ui", "ui open", "ui open task", "ui open notes", "ui open inbox",
    "wait-until-content", "whereis",
    "workflow", "workflow show", "workflow validate", "workflow add", "workflow update", "workflow remove",
    "workflow run", "workflow start", "workflow status", "workflow events", "workflow files", "workflow resume",
    "workflow cancel", "workflow approve", "workflow reject", "workflow advance"
  ].freeze

  # Each alias must print the page of the command it names.
  ALIASES = {
    "journey" => "spine",
    "lib" => "library",
    "add-project" => "add",
    "list-projects" => "list"
  }.freeze

  # Pages that fail today, grouped by the plan task that fixes them: a task
  # deletes its block. Each must still fail, so a fixed page cannot stay here.
  KNOWN_GAPS = [
    # T2: verbs that ignore or mangle --help
    "event-log compact",

    # T3 gave these a page of their own; their examples come with the group tasks
    "binding clear",
    "binding set",
    "binding show",
    "config show",
    "instructions compose",
    "library add",
    "library info",
    "library install",
    "library installed",
    "library list",
    "library remove",
    "library show",
    "library uninstall",
    "library update",
    "pr create",
    "pr feedback",
    "projects group",
    "projects group add",
    "projects group create",
    "projects group list",
    "projects group show",
    "projects kill",
    "projects list",
    "projects members",
    "projects show",
    "projects stop",
    "ticket list",
    "ticket show",
    "ui open",
    "ui open inbox",
    "ui open notes",
    "ui open task",
    "workflow add",
    "workflow advance",
    "workflow approve",
    "workflow cancel",
    "workflow events",
    "workflow files",
    "workflow reject",
    "workflow remove",
    "workflow resume",
    "workflow run",
    "workflow show",
    "workflow start",
    "workflow status",
    "workflow update",
    "workflow validate",

    # T16: workflows
    "pipeline",
    "pipeline advance",
    "pipeline reset",
    "pipeline start",
    "pipeline status",
    "workflow",

    # T17: library and packs
    "binding",
    "instructions",
    "library",

    # T18: configuration
    "config",
    "config edit",
    "config get",
    "config keys",
    "config set",
    "config unset",
    "config validate",

    # T19: repositories
    "pr",
    "projects",
    "push",
    "rebase",
    "ticket",

    # T20: events and links
    "event-log",
    "event-log show",
    "events",
    "ui"
  ].freeze
end

RSpec.describe "help pages end with examples" do
  pages = HelpExamplesSpec::PAGES
  aliases = HelpExamplesSpec::ALIASES
  known_gaps = HelpExamplesSpec::KNOWN_GAPS
  def run_help(argv)
    out = StringIO.new
    err = StringIO.new
    status = 0
    text = nil
    combined = nil
    Dir.mktmpdir("workspace-help-home") do |home|
      Dir.mktmpdir("workspace-help-cwd") do |cwd|
        saved = ENV.to_h
        begin
          # Fakes are not used: cli_spec.rb's builder is local to that file and leaves most
          # commands nil, and the help of library, config and the like reads real Config paths.
          # Instead HOME is a temp directory and every other variable (XDG_*, TMUX) is dropped.
          ENV.replace("HOME" => home, "PATH" => File.dirname(RbConfig.ruby))
          Dir.chdir(cwd) do
            config = Workspace::Config.new
            [Dir.home, config.event_log_file, config.state_file, config.state_dir].each do |path|
              raise "#{path} is outside the throwaway HOME" unless path.start_with?(home)
            end
            cli = Workspace.build_cli(output: out, error_output: err, input: StringIO.new, env: {})
            # OptionParser's own --help writes to $stdout, so only the run itself swaps the streams.
            saved_streams = [$stdout, $stderr]
            begin
              $stdout = out
              $stderr = err
              cli.run(argv + ["--help"])
            rescue SystemExit => e
              status = e.status
            rescue Workspace::Error => e
              status = 1
              err.puts e.message
            ensure
              $stdout, $stderr = saved_streams
            end
          end
        ensure
          ENV.replace(saved)
        end
        text = out.string.gsub(home, "$HOME")
        combined = text + err.string
      end
    end
    [text, status, combined]
  end

  def problems(argv)
    text, status, = run_help(argv)
    # 'workspace help' prints the root page, whose examples start with plain 'workspace'
    command = (argv == ["help"]) ? "" : argv.join(" ")
    found = []
    found << "exit #{status}" unless status == 0
    lines = text.lines.map(&:chomp)
    prefix = ["Usage: workspace", command].reject(&:empty?).join(" ")
    found << "first line is #{lines.first.inspect}" unless lines.first.to_s.match?(/\A#{Regexp.escape(prefix)}(\s|\[|\z)/)
    heading = lines.rindex { |l| l.match?(/\A\S.*:\z/) }
    if heading.nil? || lines[heading] != "Examples:"
      found << "last section is #{heading && lines[heading].inspect}, not \"Examples:\""
      return found
    end
    examples = lines[(heading + 1)..].reject { |l| l.strip.empty? }
    found << "#{examples.size} examples, want 3 to 10" unless (3..10).cover?(examples.size)
    start = /\A\s+(?:[A-Z_]+=\S+ )*#{Regexp.escape(["workspace", command].reject(&:empty?).join(" "))}(?:\s|\z)/
    examples.reject { |l| l.match?(start) }.each { |l| found << "example does not start with #{["workspace", command].reject(&:empty?).join(" ")}: #{l.strip}" }
    examples.reject { |l| l.include?(" #") }.each { |l| found << "example has no # comment: #{l.strip}" }
    found
  end

  def argv_for(page)
    page.split
  end

  it "lists each page once" do
    expect(pages.uniq).to eq(pages)
  end

  it "keeps known gaps to listed pages" do
    expect(known_gaps - pages).to eq([])
  end

  it "covers every subcommand and every verb table, so a new command cannot skip it" do
    # Commands with no verb constant (inbox, plan, lock...) have their verbs listed by hand above.
    missing = Workspace::CLI::SUBCOMMANDS - aliases.keys - pages
    expect(missing).to eq([])

    {
      "daemon" => Workspace::CLI::DAEMON_SUBCOMMANDS,
      "library" => Workspace::CLI::LIBRARY_SUBCOMMANDS,
      "workflow" => Workspace::CLI::WORKFLOW_SUBCOMMANDS
    }.each do |command, verbs|
      expect(verbs - pages.filter_map { |p| p.delete_prefix("#{command} ") if p.start_with?("#{command} ") }).to eq([])
    end
  end

  pages.each do |page|
    gap = known_gaps.include?(page)
    it "#{gap ? "still lacks" : "has"} a good page for 'workspace #{page} --help'" do
      found = problems(argv_for(page))
      if gap
        expect(found).not_to be_empty, "now passes: remove #{page.inspect} from known_gaps"
        expect(run_help(argv_for(page)).last).not_to be_empty, "#{page.inspect} printed nothing"
      else
        expect(found).to eq([])
      end
    end
  end

  aliases.each do |name, target|
    it "'workspace #{name} --help' shows the page of #{target}" do
      text, status, = run_help([name])
      target_text, target_status, = run_help([target])
      expect(text).to eq(target_text)
      expect(status).to eq(target_status)
    end
  end
end
