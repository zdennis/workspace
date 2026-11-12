require "rbconfig"
require "stringio"
require "tmpdir"

# Help pages by argv (without --help): the one list `cli_help_examples_spec` checks
# and the golden fixture records.
module HelpExamplesSpec
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
    "go", "goal", "goal show", "goal list",
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
    "promote", "prune", "push", "reactivate", "rebase", "relaunch", "remove", "rename", "repair", "resize", "restore",
    "run", "run-and-report", "report-run-status", "session-event", "sessions", "set-command", "shell-init", "snapshot",
    "review", "review show", "review list",
    "skills", "skills install", "skills uninstall",
    "spine", "spine show", "spine init", "spine set", "spine check", "spine verify", "spine start", "spine goal",
    "spine goal set",
    "start", "status", "statusline", "step", "step done", "step status", "stop",
    "template", "template list", "template show", "template path", "template variables", "template render", "template validate", "template diff",
    "ticket", "ticket show", "ticket list", "tile", "tmux", "tmux show",
    "ui", "ui open", "ui open task", "ui open notes", "ui open inbox", "ui status",
    "wait-until-content", "whereis",
    "workflow", "workflow list", "workflow show", "workflow validate", "workflow add", "workflow update", "workflow remove", "workflow install", "workflow uninstall",
    "workflow run", "workflow render", "workflow check", "workflow simulate", "workflow start", "workflow status", "workflow events", "workflow files", "workflow attempts", "workflow audit", "workflow stats", "workflow compare", "workflow sweep", "workflow resume",
    "workflow cancel", "workflow approve", "workflow reject", "workflow advance"
  ].freeze

  # Each alias must print the page of the command it names.
  ALIASES = {
    "journey" => "spine",
    "lib" => "library",
    "add-project" => "add",
    "list-projects" => "list"
  }.freeze
end

# The CLI golden fixture (S8 T39): what the real CLI prints for every help page, every verb's
# usage error and the reviewed no-argument verbs, recorded by `script/record-cli-golden` into
# spec/fixtures/cli_golden/ and compared by `spec/system/workspace/cli_golden_spec.rb`.
#
# Each case runs the CLI from `Workspace.build_cli` in a throwaway HOME and working directory,
# with empty input, every other variable (XDG_*, TMUX) dropped, PATH holding only Ruby's
# directory, and osascript runners that answer as if osascript were missing, so no real
# state is read or written and no tmux, git, gh or osascript is found.
module CliGolden
  Result = Struct.new(:stdout, :stderr, :status, keyword_init: true)

  # What a missing osascript answers (`OsascriptRunner#call` on `SystemCallError`).
  NO_OSASCRIPT = ->(_script) { Workspace::OsascriptRunner::Result.new("", false, false) }

  # The verbs whose no-argument run is not recorded, each with the reason (the review of
  # T39). Every other verb was run bare in the throwaway HOME and prints a usage error or
  # reads only that HOME.
  NO_ARGUMENT_LEFT_OUT = {
    "agentd" => "serves a daemon until stopped",
    "session-event" => "reads the hook event from the process stdin",
    "statusline" => "reads the status-line JSON from the process stdin",
    "doctor" => "probes the machine with which, so the answer depends on PATH",
    "projects" => "lists projects through git in the working directory",
    "go" => "reads the working directory through git",
    "ui" => "hands a link to open",
    "init" => "writes the tmuxinator templates and installs hooks"
  }.freeze

  FIXTURE_DIR = File.join(PROJECT_ROOT, "spec", "fixtures", "cli_golden")

  module_function

  # Every top-level verb, aliases too: the first word of each help page (which
  # `cli_help_examples_spec` holds to cover `CLI::SUBCOMMANDS`) and each alias. Each gets a
  # `--bogus` and a `--bogus --json` case; `session-event` and `statusline` read stdin, and
  # both raise their parse error before reading it, so they keep theirs (R3-16).
  #
  # @return [Array<String>]
  def verbs
    (HelpExamplesSpec::PAGES.map { |page| page.split.first }.compact + HelpExamplesSpec::ALIASES.keys).uniq
  end

  # @return [Hash{String => Array<Array<String>>}] fixture file name to the argvs it records, in order
  def cases
    groups = Hash.new { |h, k| h[k] = [] }
    HelpExamplesSpec::PAGES.each do |page|
      argv = page.split
      groups[file_for(argv)] << argv + ["--help"]
      groups[file_for(argv)] << argv + ["--help", "--json"]
    end
    groups["_main"] << ["--bogus"]
    groups["_main"] << ["--bogus", "--json"]
    groups["_main"] << ["no-such-verb"]
    groups["_main"] << ["no-such-verb", "--json"]
    verbs.each do |verb|
      groups[file_for([verb])] << [verb, "--bogus"]
      groups[file_for([verb])] << [verb, "--bogus", "--json"]
    end
    (verbs - NO_ARGUMENT_LEFT_OUT.keys).each { |verb| groups[file_for([verb])] << [verb] }
    groups.sort.to_h
  end

  def file_for(argv)
    argv.empty? ? "_main" : argv.first
  end

  # @param argvs [Array<Array<String>>] the cases of one fixture file
  # @return [String] the file's text, recorded now
  def render(argvs)
    argvs.map { |argv| block(argv, run(argv)) }.join
  end

  def block(argv, result)
    "### workspace #{argv.join(" ")}\n" \
      "--- exit #{result.status}\n" \
      "--- stdout\n#{result.stdout}" \
      "--- stderr\n#{result.stderr}" \
      "--- end\n"
  end

  def fixture_path(name)
    File.join(FIXTURE_DIR, "#{name}.txt")
  end

  # Runs the real CLI once.
  #
  # @param argv [Array<String>]
  # @return [Result] stdout and stderr with the throwaway HOME, working directory, checkout and
  #   version written `$HOME`, `$CWD`, `$ROOT` and `$VERSION`
  def run(argv)
    out = StringIO.new
    err = StringIO.new
    status = 0
    Dir.mktmpdir("workspace-golden") do |root|
      # Fixed names under the temp root, so a command that prints a directory's own name
      # (`parent`) prints the same name every run.
      home = File.join(root, "home")
      cwd = File.join(root, "cwd")
      Dir.mkdir(home)
      Dir.mkdir(cwd)
      saved = ENV.to_h
      begin
        ENV.replace("HOME" => home, "PATH" => File.dirname(RbConfig.ruby))
        Dir.chdir(cwd) do
          config = Workspace::Config.new
          [Dir.home, config.event_log_file, config.state_file, config.state_dir].each do |path|
            raise "#{path} is outside the throwaway HOME" unless path.start_with?(home)
          end
          cli = Workspace.build_cli(output: out, error_output: err, input: StringIO.new, env: {},
            osascript: NO_OSASCRIPT, ui_osascript: NO_OSASCRIPT)
          # OptionParser's own --help writes to $stdout, so only the run itself swaps the streams.
          saved_streams = [$stdout, $stderr]
          begin
            $stdout = out
            $stderr = err
            cli.run(argv)
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
      Result.new(stdout: scrub(out.string, root), stderr: scrub(err.string, root), status: status)
    end
  end

  def scrub(text, root)
    [[File.join(root, "cwd"), "$CWD"], [File.join(root, "home"), "$HOME"]].each do |path, name|
      [File.realpath(path), path].uniq.each { |form| text = text.gsub(form, name) }
    end
    text.gsub(PROJECT_ROOT, "$ROOT").gsub(Workspace::VERSION, "$VERSION")
  end
end
