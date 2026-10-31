module Workspace
  # The help page of each verb of the commands that share one option parser.
  # Data only: a table per command, keyed by the verb (`"status"`, or two words
  # such as `"task add"`), each page a Hash of
  #
  #   usage:    ["plan status [--json]", ...]  lines after `workspace `
  #   summary:  one sentence without its period: the page's first line, and the overview's line for the verb
  #   about:    further paragraphs, as lines (may be empty)
  #   options:  [["--name NAME", "text"], ...] a metavar marks a flag that takes a value
  #   examples: [["workspace plan status", "what it is for"], ...]
  #
  # {render} is the only writer of a page and of the example separator;
  # {overview_usage} and {overview_verbs} build the bare command's page from
  # the same tables.
  module HelpPages
    EXAMPLE_SEPARATOR = "    # ".freeze

    JSON_OPT = ["--json", "Print one JSON document"].freeze

    # The --name option; +text+ says what it picks where the default wording does not fit.
    #
    # @param text [String]
    # @return [Array<String>] label and text
    def self.name_opt(text = "Workspace (default: detected from the current directory)")
      ["--name NAME", text].freeze
    end

    NAME_OPT = name_opt
    RUN_ID = "RUN is a workflow run id (see `workspace workflow status`).".freeze
    PANE_OPT = ["--pane PANE", "The pane to run in (%19 or 0.1) instead of the workspace's Claude pane"].freeze
    REVISION_OPT = ["--if-revision REV", "Refuse with stale_revision unless the plan's revision is REV"].freeze
    AGENT_KINDS = "claude, codex, opencode, pi".freeze

    PLAN = {
      "status" => {
        usage: ["plan status [--name WORKSPACE | --project [NAME] | --all | --file PATH | --group GROUP] [--json]"],
        summary: "Count the plan and report its state",
        about: [
          "A workspace with no plan is a row, not an error. With no scope flag it is the current workspace's row",
          "(outside any workspace: not_in_workspace). Give at most one of --name, --project, --all, --file and",
          "--group."
        ],
        options: [NAME_OPT,
          ["--project [NAME]", "Every workspace of a project (NAME, or the project of the current workspace)"],
          ["--all", "Every workspace"],
          ["--group GROUP", "Every workspace of every repository in a group (group:billing, billing or Billing; see projects group list)"],
          ["--file PATH", "Read any file, with no workspace and a state from the file alone"],
          JSON_OPT],
        examples: [
          ["workspace plan status", "the plan of the workspace you are in: state, counts and the current task"],
          ["workspace plan status --name api.worktree-x", "one workspace by name"],
          ["workspace plan status --project", "the plans of the main checkout and its worktrees, such as to see which one is stalled"],
          ["workspace plan status --all", "every workspace, one line each (no plan reads \"no plan\")"],
          ["workspace plan status --group billing", "every workspace of every repository in the billing group"],
          ["workspace plan status --file IMPLEMENTATION_PLAN.md", "a plan file in the current directory, with no workspace"],
          ["workspace plan status --json", "one JSON document, with the revision that --if-revision takes"]
        ]
      },
      "path" => {
        usage: ["plan path [--name WORKSPACE] [--json]"],
        summary: "Print where the plan is (or would be)",
        about: [],
        options: [NAME_OPT, JSON_OPT],
        examples: [
          ["workspace plan path", "where the plan of the workspace you are in is, whether or not the file exists"],
          ["workspace plan path --name api.worktree-x", "the same for one workspace by name"],
          ["workspace plan path --json", "adds exists (is the file there?) and notes_dir"]
        ]
      },
      "show" => {
        usage: ["plan show [--name WORKSPACE]"],
        summary: "Print the plan file",
        about: ["Exits 1 with an error when there is no plan."],
        options: [NAME_OPT],
        examples: [
          ["workspace plan show", "print the plan of the workspace you are in"],
          ["workspace plan show --name api.worktree-x", "print the plan of one workspace by name"],
          ["workspace plan show --name api.worktree-x | grep '\\[!\\]'", "list the blocked tasks of that plan"]
        ]
      },
      "init" => {
        usage: ["plan init [--name WORKSPACE] [--title TITLE] [--from FILE] [--force] [--json]"],
        summary: "Write a new plan, or import an existing document with --from",
        about: ["Writes the plan file for real. A plan that is already there is an error (exit 1, plan_exists) unless --force replaces it."],
        options: [NAME_OPT,
          ["--title TITLE", "The plan's title (default: the workspace task's title)"],
          ["--from FILE", "Import this document as the plan"],
          ["--force", "Replace a plan that is already there"],
          JSON_OPT],
        examples: [
          ["workspace plan init", "write a new plan, titled after the workspace's task if it has one, in the notes directory (it makes the directory)"],
          ["workspace plan init --title \"Auth rewrite\"", "write a new plan with your own title"],
          ["workspace plan init --from design.md", "import design.md (read from the current directory) as the plan"],
          ["workspace plan init --from design.md --force", "replace the plan that is already there with design.md (the old plan is overwritten)"],
          ["workspace plan init --name api.worktree-x --json", "write the plan of another workspace; with a plan there and no --force it exits 1 with plan_exists"]
        ]
      },
      "start" => {
        usage: ["plan start [--name WORKSPACE] [--task ID [--pane PANE | --spawn KIND]] [--json]"],
        summary: "Set status: active, then launch the workspace or send its agent the plan",
        about: [
          "Launches the workspace with the implementation-plan play, or sends the main agent pane the play",
          "and \"Continue the plan.\" (a working pane is left alone).",
          "",
          "With --task, sends that one task to --pane, a new agent pane (--spawn), the task's owner, or the",
          "main agent pane; the pane is written onto the task line as its owner."
        ],
        options: [NAME_OPT,
          ["--task ID", "Send only this task (its id, such as T3)"],
          ["--pane PANE", "With --task: the pane to send it to, a pane id (%19) or window.pane (0.1)"],
          ["--spawn KIND", "With --task: start a new agent pane for it (#{AGENT_KINDS})"],
          JSON_OPT],
        examples: [
          ["workspace plan start", "set the plan active, then launch the workspace or type the play into its main agent pane"],
          ["workspace plan start --name api.worktree-x --json", "the same for one workspace by name, with a JSON action document"],
          ["workspace plan start --task T4", "type task T4 into the task's owner pane, else the main agent pane, and write the pane onto the task"],
          ["workspace plan start --task T4 --pane %23", "type task T4 into pane %23 of the workspace's session"],
          ["workspace plan start --task T5 --spawn claude", "split a new pane, start Claude Code in it and type task T5 there"]
        ]
      },
      "pause" => {
        usage: ["plan pause [--name WORKSPACE] [--interrupt] [--json]"],
        summary: "Set status: paused; the agent stops before its next task",
        about: ["Writes status: paused into the plan file for real. --interrupt also presses the agent's interrupt key (Escape for Claude Code and Codex) in each owner pane that works."],
        options: [NAME_OPT, ["--interrupt", "Interrupt the owner panes that are working"], JSON_OPT],
        examples: [
          ["workspace plan pause", "set status: paused; the agent stops before its next task and nothing is interrupted"],
          ["workspace plan pause --interrupt", "also press the interrupt key in each owner pane that is working"],
          ["workspace plan pause --name api.worktree-x --json", "pause one workspace by name, with a JSON action document"]
        ]
      },
      "delete" => {
        usage: ["plan delete [--name WORKSPACE] --yes [--json]"],
        summary: "Rename the plan to IMPLEMENTATION_PLAN.md.deleted-<time>",
        about: ["Needs --yes, and then renames the plan file for real; the session and worktree stay."],
        options: [NAME_OPT, ["--yes", "Confirm the delete"], JSON_OPT],
        examples: [
          ["workspace plan delete --yes", "rename the plan of the workspace you are in to IMPLEMENTATION_PLAN.md.deleted-<time> for real"],
          ["workspace plan delete --name api.worktree-x --yes", "the same for one workspace by name"],
          ["workspace plan delete --yes --json", "the same, with a JSON action document; with a plan there and no --yes it exits 1 with confirmation_required (no plan: no_plan)"]
        ]
      },
      "task add" => {
        usage: ["plan task add --title TEXT [--id ID] [--state STATE] [--reason TEXT] [--phase NAME | --after ID] [--if-revision REV] [--name WORKSPACE] [--json]"],
        summary: "Add one task line to the plan",
        about: ["Writes one task line into the plan file for real. Blocked and skipped tasks need --reason."],
        options: [NAME_OPT,
          ["--title TITLE", "The new task's title"],
          ["--id ID", "The new task's id (default: the next number after the plan's last id)"],
          ["--state STATE", "The task's state: done, in_progress, skipped, blocked or todo (default: todo)"],
          ["--reason TEXT", "Why a task is blocked or skipped"],
          ["--phase NAME", "The ### heading to add under"],
          ["--after ID", "Place the task after this task"],
          REVISION_OPT,
          JSON_OPT],
        examples: [
          ["workspace plan task add --title \"Write the docs\"", "add a to-do task with the next free id to the plan of this workspace"],
          ["workspace plan task add --title \"Write the docs\" --phase Docs", "add it under the ### Docs heading"],
          ["workspace plan task add --title \"Add the index\" --id T7 --after T3", "give it the id T7 and put it after task T3"],
          ["workspace plan task add --title \"Wait for CI\" --state blocked --reason \"CI is down\"", "add a blocked task; blocked and skipped need --reason"],
          ["workspace plan task add --title \"Write the docs\" --if-revision 9f8e7d6c --json", "refuse with stale_revision unless the plan is still at that revision (from plan status --json)"]
        ]
      },
      "task set-state" => {
        usage: ["plan task set-state --task ID --state STATE [--reason TEXT] [--if-revision REV] [--name WORKSPACE] [--json]"],
        summary: "Set one task's state",
        about: ["Rewrites one task line of the plan file for real. Blocked and skipped tasks need --reason."],
        options: [NAME_OPT,
          ["--task ID", "The task (its id, such as T3)"],
          ["--state STATE", "The new state: done, in_progress, skipped, blocked or todo"],
          ["--reason TEXT", "Why a task is blocked or skipped"],
          REVISION_OPT,
          JSON_OPT],
        examples: [
          ["workspace plan task set-state --task T3 --state done", "mark task T3 done in the plan of this workspace"],
          ["workspace plan task set-state --task T3 --state in_progress", "mark it in progress"],
          ["workspace plan task set-state --task T3 --state blocked --reason \"needs the dev database\"", "block it; blocked and skipped need --reason"],
          ["workspace plan task set-state --task T3 --state done --if-revision 9f8e7d6c --json", "refuse with stale_revision unless the plan is still at that revision (from plan status --json)"]
        ]
      },
      "task set-title" => {
        usage: ["plan task set-title --task ID --title TEXT [--if-revision REV] [--name WORKSPACE] [--json]"],
        summary: "Change one task's title",
        about: ["Rewrites one task line of the plan file for real."],
        options: [NAME_OPT,
          ["--task ID", "The task (its id, such as T3)"],
          ["--title TITLE", "The new title"],
          REVISION_OPT,
          JSON_OPT],
        examples: [
          ["workspace plan task set-title --task T3 --title \"Write the token store docs\"", "change the title of task T3; its id, state and place stay"],
          ["workspace plan task set-title --name api.worktree-x --task T3 --title \"Write the docs\"", "the same in the plan of one workspace by name"],
          ["workspace plan task set-title --task T3 --title \"Write the docs\" --if-revision 9f8e7d6c --json", "refuse with stale_revision unless the plan is still at that revision (from plan status --json)"]
        ]
      },
      "task move" => {
        usage: ["plan task move --task ID (--after ID | --before ID | --phase NAME) [--if-revision REV] [--name WORKSPACE] [--json]"],
        summary: "Move one task line",
        about: ["Moves it after or before another task, or to the end of a phase, in the plan file for real."],
        options: [NAME_OPT,
          ["--task ID", "The task (its id, such as T3)"],
          ["--after ID", "Place the task after this task"],
          ["--before ID", "Place the task before this task"],
          ["--phase NAME", "Move to the end of this phase"],
          REVISION_OPT,
          JSON_OPT],
        examples: [
          ["workspace plan task move --task T5 --after T1", "move task T5 to just after task T1"],
          ["workspace plan task move --task T5 --before T2", "move task T5 to just before task T2"],
          ["workspace plan task move --task T5 --phase Docs", "move task T5 to the end of the ### Docs phase"],
          ["workspace plan task move --task T5 --after T1 --if-revision 9f8e7d6c --json", "refuse with stale_revision unless the plan is still at that revision (from plan status --json)"]
        ]
      }
    }.freeze

    DAEMON_NAME = name_opt("Same as the WORKSPACE argument (default: the project detected from the current directory)")

    DAEMON = {
      "status" => {
        usage: ["daemon status [WORKSPACE] [--name NAME] [--json]"],
        summary: "Say whether a workspace's agent daemon answers",
        about: [
          "The agent daemon (`workspace agentd`) watches a workspace's panes. This shows whether it answers on",
          "its socket, its pid, and its socket and log paths."
        ],
        options: [DAEMON_NAME, JSON_OPT],
        examples: [
          ["workspace daemon status", "is the daemon of the project in the current directory answering"],
          ["workspace daemon status my-app", "the same for a named workspace; not running is an answer (exit 0)"],
          ["workspace daemon status --name my-app --json", "one JSON document with running, pid, socket and log"]
        ]
      },
      "restart" => {
        usage: ["daemon restart [WORKSPACE] [--name NAME] [--wc-socket PATH] [--json]", "daemon restart --all [--json]"],
        summary: "Stop a workspace's agent daemon and start a new one in the background",
        about: [
          "The agent daemon (`workspace agentd`) watches a workspace's panes. Restart stops the daemon holding",
          "the socket (SIGTERM, even a hung one) and starts a new one in the background; a daemon run in a",
          "terminal is replaced by a detached one. With none running, it just starts one.",
          "",
          "--all restarts every running daemon, one after another, so each runs the code that is installed",
          "now; one that fails does not stop the rest, and the exit status is non-zero if any failed. It takes",
          "no workspace, --name or --wc-socket."
        ],
        options: [DAEMON_NAME,
          ["--wc-socket PATH", "Work-coordinator socket for the new daemon (default: the old daemon's)"],
          ["--all", "Restart every running daemon instead of one workspace"],
          JSON_OPT],
        examples: [
          ["workspace daemon restart", "SIGTERM this project's daemon, then start a new one in the background (just start one if none runs)"],
          ["workspace daemon restart my-app --wc-socket /tmp/wc-dev.sock", "the new daemon uses another coordinator socket"],
          ["workspace daemon restart --all", "SIGTERM each running daemon and start it again, so each runs the installed version"],
          ["workspace daemon restart my-app --json", "one JSON action document; exits 1 if the restart failed"]
        ]
      },
      "log" => {
        usage: ["daemon log [WORKSPACE] [--name NAME] [--lines N] [--json]"],
        summary: "Show the last lines of a workspace's agent daemon log",
        about: ["Only a background daemon writes this log; a daemon run in a terminal logs to that terminal instead."],
        options: [DAEMON_NAME, ["--lines N", "How many trailing lines, 1 to 10000 (default: 40)"], JSON_OPT],
        examples: [
          ["workspace daemon log", "the last 40 lines for the project in the current directory"],
          ["workspace daemon log my-app --lines 100", "more of a named workspace's log"],
          ["workspace daemon log --name my-app --json", "the lines, the log's path and whether the file exists, as JSON"]
        ]
      },
      "list" => {
        usage: ["daemon list [--json]"],
        summary: "List every running agent daemon",
        about: ["Shows each daemon's workspace, pid, start time and socket. It takes no workspace."],
        options: [JSON_OPT],
        examples: [
          ["workspace daemon list", "every running daemon; prints a message and exits 0 when none run"],
          ["workspace daemon list --json", "one JSON document with a row per daemon"],
          ["workspace daemon list --json | jq -r '.daemons[].workspace'", "the workspaces that have a daemon running"]
        ]
      }
    }.freeze

    WORKFLOW_NOTE = ["--note TEXT", "Added to the next attempt's instructions"].freeze

    WORKFLOW = {
      "show" => {
        usage: ["workflow show [ID] [--source] [--json]"],
        summary: "List the workflow definitions, or print one (inputs, steps)",
        about: [
          "--source gives the file's text, its sha256 and its problems even when it is invalid (exit 0), for",
          "an editor.",
          "",
          "Definitions are YAML files: ~/.config/workspace/workflows/ID.yml, then the presets that ship with",
          "workspace (rpiv, rpiv-auto-approve, pr-feedback, investigate). See docs/README.workflow.md."
        ],
        options: [["--source", "The file's text, sha256 of its bytes and problems, valid or not (needs ID)"], JSON_OPT],
        examples: [
          ["workspace workflow show", "list the workflows you can run"],
          ["workspace workflow show rpiv", "see the inputs and steps of one before running it"],
          ["workspace workflow show rpiv --source", "read the file's text, to start your own copy"],
          ["workspace workflow show rpiv --source --json", "the text and its sha256 as one document, for a script"],
          ["workspace workflow show --json", "every definition as one document, for a script"]
        ]
      },
      "validate" => {
        usage: ["workflow validate PATH|- [--id ID] [--json]"],
        summary: "Check a definition's text and list every problem",
        about: [
          "Checks a definition (a file, or - for stdin) the way a definition on disk is checked, listing every",
          "problem at once; writes nothing. The id is --id, else its id: key, else the file's name (stdin:",
          "\"stdin\"); a relative prompt_file: is read from the file's directory (stdin: the current directory)."
        ],
        options: [["--id ID", "Check the text as this workflow id"], JSON_OPT],
        examples: [
          ["workspace workflow validate draft.yml", "check a definition you are writing: prints valid, or exits 1 with an error listing every problem"],
          ["workspace workflow validate - < draft.yml", "check text read from stdin"],
          ["workspace workflow validate draft.yml --id ship", "check it as the workflow \"ship\" when the file is named otherwise"],
          ["workspace workflow validate draft.yml --json", "the checked definition as one document, or an error document with the problems"]
        ]
      },
      "add" => {
        usage: ["workflow add ID PATH|- [--dry-run] [--json]"],
        summary: "Save a definition as ID.yml",
        about: [
          "Saves a definition (a file, or - for stdin) as ID.yml in ~/.config/workspace/workflows/, after the",
          "checks `workflow validate` makes; refused with workflow_exists when that file is there. A preset of",
          "the same id is left alone and the copy shadows it. A relative prompt_file: is read from that directory.",
          "Without --dry-run it writes that file."
        ],
        options: [["--dry-run", "Check, and write no definition (the lock file may be created)"], JSON_OPT],
        examples: [
          ["workspace workflow add ship draft.yml", "save draft.yml as your workflow \"ship\""],
          ["workspace workflow add ship draft.yml --dry-run", "check it and see where it would go, saving nothing"],
          ["workspace workflow add ship - < draft.yml", "save text read from stdin"],
          ["workspace workflow add rpiv draft.yml", "keep your own rpiv that shadows the preset"],
          ["workspace workflow add ship draft.yml --json", "report the saved path and sha256 as one document, for a script"]
        ]
      },
      "update" => {
        usage: ["workflow update ID PATH|- --if-sha256 SHA [--dry-run] [--json]"],
        summary: "Replace your ID.yml if it is unchanged since you read it",
        about: [
          "Replaces your ID.yml (a file, or - for stdin) after the same checks as `workflow add`, only if the",
          "file's raw bytes still hash to --if-sha256 (from `workflow show ID --source`; a broken file can be",
          "replaced). Refused with stale_workflow when it changed, builtin_workflow for a preset with no file",
          "of yours. Without --dry-run it overwrites that file."
        ],
        options: [["--if-sha256 SHA", "The sha256 of the file's raw bytes you read; refuse with stale_workflow unless it still matches"],
          ["--dry-run", "Check, and write no definition (the lock file may be created)"], JSON_OPT],
        examples: [
          ["workspace workflow update ship draft.yml --if-sha256 SHA", "replace your ship.yml; SHA is the sha256 that `workflow show ship --source --json` gave"],
          ["workspace workflow update ship draft.yml --if-sha256 SHA --dry-run", "check the replacement and write nothing"],
          ["workspace workflow update ship - --if-sha256 SHA < draft.yml", "replace it with text read from stdin"],
          ["workspace workflow update ship draft.yml --if-sha256 SHA --json", "report the new sha256 as one document, for a script"]
        ]
      },
      "remove" => {
        usage: ["workflow remove ID [--yes] [--dry-run] [--json]"],
        summary: "Delete your ID.yml",
        about: [
          "Deletes your ID.yml (a link itself, never its target). Asks first unless --yes or --dry-run, and",
          "refuses with confirmation_required under --no-input. A preset of the same id is then in effect",
          "again; unknown_workflow when you have no file, builtin_workflow for a preset alone."
        ],
        options: [["--yes", "Do not ask before deleting the file"], ["--dry-run", "Check and delete nothing"], JSON_OPT],
        examples: [
          ["workspace workflow remove ship", "delete your ship.yml after a y/N question"],
          ["workspace workflow remove ship --dry-run", "see which file would be deleted, deleting nothing"],
          ["workspace workflow remove ship --yes", "delete it without asking, for a script"],
          ["workspace workflow remove ship --yes --json", "delete it and report one document (--json never asks, so it needs --yes)"]
        ]
      },
      "run" => {
        usage: ["workflow run ID [--name WORKSPACE] [--input KEY=VALUE]... [--note TEXT] [--pane PANE] [--dry-run] [--json]"],
        summary: "Start a run of a workflow in a workspace",
        about: [
          "A run is an ordered list of steps, each done by the agent in the workspace's Claude pane. --dry-run",
          "checks the inputs, the project's commands and the pane, and starts nothing.",
          "",
          "Without --dry-run this really starts the run: the first step is typed into the pane, and the",
          "workspace's agent daemon is started if it is not running. Run from the pane it would type into, it",
          "parks like `workflow resume`: the answer is `parked`, and the caller should end its turn."
        ],
        options: [name_opt("The workspace to run in (default: detected from the current directory)"),
          ["--input KEY=VALUE", "A value for one of the workflow's inputs (repeatable)"],
          ["--note TEXT", "Added to every step's instructions"],
          PANE_OPT,
          ["--dry-run", "Report what would start and start nothing"], JSON_OPT],
        examples: [
          ["workspace workflow run rpiv --input task=\"PROJ-101 invoice PDF export\"", "start rpiv in this workspace; its first step is typed into the Claude pane"],
          ["workspace workflow run rpiv --input task=\"PROJ-101 invoice PDF export\" --dry-run", "check the inputs and the pane first and start nothing"],
          ["workspace workflow run rpiv --name my-app --input task=\"PROJ-101 invoice PDF export\"", "run in another workspace than the one you are standing in"],
          ["workspace workflow run rpiv --input task=\"PROJ-101 invoice PDF export\" --note \"Keep the change small.\"", "tell every step something extra"],
          ["workspace workflow run rpiv --input task=\"PROJ-101 invoice PDF export\" --pane %19", "run in a pane other than the workspace's Claude pane"]
        ]
      },
      "start" => {
        usage: ["workflow start ID [REF | --prompt TEXT] [--branch BRANCH] [--slug] [--base REF] [--input KEY=VALUE]... [--note TEXT] [--agent-kind KIND] [--[no-]headless] [--prompt-timeout DURATION] [--dry-run] [--json]"],
        summary: "Make a workspace from a ticket, pull request or prompt and run a workflow in it",
        about: [
          "Run it inside the project's git checkout; the main agent must be Claude Code.",
          "",
          "REF is a JIRA key or URL, a pull request, an issue or a branch. Waits for the workspace's agent, then",
          "runs ID in it. A fork's pull request, or a branch tracking another repository, is refused with",
          "fork_pull_request before anything is made.",
          "",
          "Without --dry-run this makes things for real: a worktree and its workspace (as `workspace start`",
          "does), then the first step is typed into the new workspace's agent pane."
        ],
        options: [["--prompt TEXT", "The task as free text (the workflow's task input, and the branch's name when there is no REF)"],
          ["--branch BRANCH", "The branch for a --prompt (default: the prompt's words); refused with a REF"],
          ["--slug", "Add the ticket title's words to a JIRA or issue branch, as `workspace start --slug`"],
          ["--base REF", "The branch or ref a new branch starts from"],
          ["--input KEY=VALUE", "A value for one of the workflow's inputs (repeatable)"],
          ["--note TEXT", "Added to every step's instructions"],
          ["--agent-kind KIND", "The coding agent the main agent pane runs: #{AGENT_KINDS}"],
          ["--[no-]headless", "Start the session in plain tmux, as `workspace start --headless`"],
          ["--prompt-timeout DURATION", "How long to wait for the coding agent to be ready (default 60s)"],
          ["--dry-run", "Check everything and make nothing"], JSON_OPT],
        examples: [
          ["workspace workflow start rpiv PROJ-101", "make a workspace for the ticket and run rpiv in it"],
          ["workspace workflow start rpiv PROJ-101 --dry-run", "read the ticket and check everything, making nothing"],
          ["workspace workflow start rpiv --prompt \"add a hello script\"", "no ticket: start from a sentence, with the branch named from its words"],
          ["workspace workflow start rpiv --prompt \"add a hello script\" --branch hello-script", "choose the branch's name yourself"],
          ["workspace workflow start pr-feedback '#123'", "work through the review feedback on pull request 123 (needs gh)"],
          ["workspace workflow start rpiv PROJ-101 --note \"Keep the change small.\"", "tell every step something extra"],
          ["workspace workflow start rpiv PROJ-101 --headless", "run in plain tmux, with no iTerm window"],
          ["workspace workflow start rpiv-auto-approve --prompt \"add a hello script\"", "a run no person watches: three reviewer sub-agents approve the plan in place of the gate"]
        ]
      },
      "status" => {
        usage: ["workflow status [RUN | --name WORKSPACE | --project [NAME] | --all] [--table] [--json]"],
        summary: "Show the runs still going, each with its step and why it is stuck",
        about: [
          RUN_ID + " With RUN, shows that one run.",
          "RUN names its own workspace, so it takes no --name, --project or --all. Without RUN, give at most one of",
          "them: no flag shows this workspace's runs still going, --name another workspace's, --project the main",
          "checkout's and its worktrees' runs, finished ones too, and --all every workspace's, finished ones too.",
          "",
          "A run that is not moving says why: waiting_lock, waiting_you, turn_ended_incomplete, failed_check or",
          "pane_gone, with the commands that resolve it. A parked resume shows as the flag `parked`.",
          "",
          "--table shows one row per run, finished ones too at every scope, with its workspace as it is now: live, stopped",
          "or gone, and whether its config, tmux session, worktree and state directory exist (? when that could not be read).",
          "Stopped keeps its config with no tmux session; gone has no config left."
        ],
        options: [name_opt("Only this workspace's runs (default: the current workspace)"), ["--project [NAME]", "All runs of a project, finished too (NAME, or the project of the current workspace)"], ["--all", "Every workspace's runs, finished too"], ["--table", "One row per run with its workspace's status and what still exists, finished runs too"], JSON_OPT],
        examples: [
          ["workspace workflow status", "the runs still going in this workspace, each with its step and why it is stuck"],
          ["workspace workflow status RUN", "one run, going or finished"],
          ["workspace workflow status --name my-app", "only the runs of one workspace"],
          ["workspace workflow status --project", "the main checkout's and its worktrees' runs, finished too"],
          ["workspace workflow status --all", "every workspace's runs, finished too"],
          ["workspace workflow status --all --table", "each run beside whether its workspace is live, stopped or gone"],
          ["workspace workflow status --json", "for a script: each run's state, reason and the commands that resolve it"]
        ]
      },
      "events" => {
        usage: ["workflow events RUN [--since N] [--json]"],
        summary: "Show a run's history, one line per event",
        about: [
          RUN_ID,
          "",
          "A going or finished run: n (its line number), ts, type and the rest; oldest first, at most 1000 after",
          "--since N. --json adds truncated and next_since to continue from."
        ],
        options: [["--since N", "Only events after line N of the history (default 0)"], JSON_OPT],
        examples: [
          ["workspace workflow events RUN", "a run's history, oldest first"],
          ["workspace workflow events RUN --since 40", "only what happened after line 40"],
          ["workspace workflow events RUN --json", "as one document, for a script"],
          ["workspace workflow events RUN --since 40 --json", "poll for news: pass the document's next_since as --since next time"]
        ]
      },
      "files" => {
        usage: ["workflow files RUN [--json]"],
        summary: "List the files a run keeps",
        about: [
          RUN_ID,
          "",
          "Each attempt's prompt and check log, and each step's produces entries, with whether each exists and",
          "its size (a link is reported, never followed)."
        ],
        options: [JSON_OPT],
        examples: [
          ["workspace workflow files RUN", "what a run kept: prompts, check logs and the files each step writes, with sizes"],
          ["workspace workflow files RUN", "a step ended without its files: the ones shown as missing are what it still owes"],
          ["workspace workflow files RUN --json", "for a script: artifacts_dir and one row per file"]
        ]
      },
      "resume" => {
        usage: ["workflow resume RUN [--from STEP] [--note TEXT] [--pane PANE] [--json]"],
        summary: "Get a run going again",
        about: [
          RUN_ID,
          "",
          "Asks for its lock again, runs a failed or undelivered step again, looks again at a step whose files",
          "were missing, or moves it to the workspace's Claude pane when its own is gone. --from at a waiting",
          "gate is refused from a pane a run is bound to.",
          "",
          "A run waiting at a gate is approved or rejected instead; resume needs --from there. It types the",
          "step into the run's pane again unless an agent is still working on it, or its check is running (then",
          "it does nothing and says so). Use it for a run `workflow status` shows as stuck.",
          "",
          "Run from the pane it would type into (an agent resuming its own run) it types nothing: the answer is",
          "`parked`, exit 0, and the caller should end its turn. The agent daemon carries it out once the turn",
          "is over, within 1 hour, else the run reads waiting_you / parked_timeout. It needs a daemon started",
          "after the upgrade (workspace daemon restart) and a pane in window 0. A draft in a Claude pane's",
          "input box holds a type-in back (pane_busy, input_not_empty)."
        ],
        options: [["--from STEP", "Start again at this step"], WORKFLOW_NOTE, PANE_OPT, JSON_OPT],
        examples: [
          ["workspace workflow resume RUN", "pick a stuck run up again: its lock is asked for again, a failed step runs again"],
          ["workspace workflow resume RUN --from implement", "start again at the implement step of rpiv"],
          ["workspace workflow resume RUN --note \"The migration is already applied.\"", "tell the next attempt something"],
          ["workspace workflow resume RUN --pane %19", "the run's pane is gone: carry on in another pane of the workspace"]
        ]
      },
      "cancel" => {
        usage: ["workflow cancel RUN [--json]"],
        summary: "End a run and release the locks it holds",
        about: [RUN_ID, "", "It does not type into the pane: the agent there is left as it is. A run that has ended is refused."],
        options: [JSON_OPT],
        examples: [
          ["workspace workflow cancel RUN", "give up on a run that is going wrong; its locks are released"],
          ["workspace workflow cancel RUN", "end a run that waits at a gate you will not pass or for a lock you no longer need"],
          ["workspace workflow cancel RUN --json", "for a script: one action document"]
        ]
      },
      "approve" => {
        usage: ["workflow approve RUN [--step STEP [--attempt N]] [--note-sha256 HEX] [--note TEXT] [--json]"],
        summary: "Pass a run's gate",
        about: [
          RUN_ID,
          "",
          "Refused from a pane a run is bound to and from a process under the run's own pane, so an agent",
          "doesn't pass its own plan by mistake. When the gated step's first file starts with `note: FILE`, the",
          "note's sha256 is recorded and given to the next step. With --step (and --attempt) it is refused with",
          "gate_not_waiting unless the run waits at that step's gate."
        ],
        options: [["--step STEP", "The gated step you saw (current.step in status --json); refused unless the run waits there"],
          ["--attempt N", "That step's attempt you saw (current.attempt); needs --step"],
          ["--note-sha256 HEX", "The sha256 of the gate's note you read (gate_file.sha256); refused with stale_revision when it changed"],
          WORKFLOW_NOTE, JSON_OPT],
        examples: [
          ["workspace workflow approve RUN", "pass the gate a run waits at (`workflow status` shows it as waiting_you)"],
          ["workspace workflow approve RUN --note \"Skip the migration.\"", "pass it and tell the next step something"],
          ["workspace workflow approve RUN --step plan --attempt 2", "pass it only if the run still waits at the plan step, attempt 2"],
          ["workspace workflow approve RUN --step plan --attempt 2 --note-sha256 HEX", "pass it only if the plan note is still the one you read (HEX is gate_file.sha256)"]
        ]
      },
      "reject" => {
        usage: ["workflow reject RUN --note TEXT [--step STEP [--attempt N]] [--to STEP] [--json]"],
        summary: "Turn a run's gate down",
        about: [
          RUN_ID,
          "",
          "The gated step (or --to an earlier one) runs again with the note. Refused from a pane a run is bound",
          "to and from a process under the run's own pane, as approve is."
        ],
        options: [["--note TEXT", "Why; given to the next attempt"],
          ["--to STEP", "The step to run again (the gated step, or one before it)"],
          ["--step STEP", "The gated step you saw (current.step in status --json); refused unless the run waits there"],
          ["--attempt N", "That step's attempt you saw (current.attempt); needs --step"], JSON_OPT],
        examples: [
          ["workspace workflow reject RUN --note \"Too big; split it.\"", "send the gated step back; it runs again with the note"],
          ["workspace workflow reject RUN --note \"Research the API first.\" --to research", "go back to an earlier step of rpiv instead"],
          ["workspace workflow reject RUN --note \"Too big; split it.\" --step plan --attempt 2", "turn it down only if the run still waits at the plan step, attempt 2"]
        ]
      },
      "advance" => {
        hidden: true,
        usage: ["workflow advance RUN [--turn-ended --pane ID [--turn-started AT] [--stopped-at AT] [--background-task TYPE:ID]...]"],
        summary: "Move a run on; the agent daemon runs this when a turn ends",
        about: ["It is not meant to be typed. #{RUN_ID} It prints nothing.", "",
          "Typed by hand it decides the run's step as the daemon would, so use `workflow resume` instead."],
        options: [["--turn-ended", "A turn ended in the run's pane"],
          ["--pane PANE", "The run's pane"],
          ["--turn-started AT", "When that turn began (ISO 8601)"],
          ["--stopped-at AT", "When the daemon saw that turn end (ISO 8601)"],
          ["--background-task TYPE:ID", "A background task still going when the turn ended (repeatable)"]],
        examples: [
          ["workspace workflow advance RUN", "nudge a stuck run: it waits on a lock, or its check never finished; it moves on if it can"],
          ["workspace workflow advance RUN --turn-ended --pane %19", "what the agent daemon runs when the agent in pane %19 finishes answering, so the run can go to its next step"],
          ["workspace workflow advance RUN --turn-ended --pane %19 --turn-started \"$(date -u +%Y-%m-%dT%H:%M:%SZ)\"", "the same, saying when that answer began"]
        ]
      }
    }.freeze

    PIPELINE_ABOUT = "This command will be removed in a later release; use `workspace workflow`.".freeze
    PIPELINE_WORK_ITEM = ["--work-item REF", "Work item reference (e.g. WC-42)"].freeze

    PIPELINE = {
      "start" => {
        usage: ["pipeline start PROJECT --work-item REF [--body TEXT] [--json]"],
        summary: "Send a work item into a project's pipeline",
        about: [
          PIPELINE_ABOUT,
          "",
          "Sends the item to the project's running agent daemon (no_daemon when none runs), which takes it",
          "from there. This changes the project's pipeline state for real."
        ],
        options: [PIPELINE_WORK_ITEM,
          ["--body TEXT", "The message to send (default: \"Begin work on REF.\")"],
          ["--json", "Print one action document (see docs/README.json.md) instead of text"]],
        examples: [
          ["workspace pipeline start myapp --work-item WC-42", "hand WC-42 to myapp's agent with the default message"],
          ["workspace pipeline start myapp --work-item WC-42 --body \"/build add OAuth support\"", "say what the first stage should do"],
          ["workspace pipeline start myapp --work-item WC-42 --json", "for a script: one action document, with an error document and code when no agent runs"]
        ]
      },
      "advance" => {
        usage: ["pipeline advance PROJECT --work-item REF [--body TEXT] [--json]"],
        summary: "Mark a work item's running stage complete and move on",
        about: [
          PIPELINE_ABOUT,
          "",
          "Interrupts whatever the stage's pane is doing (Ctrl-C), then types the completion sentinel, even if",
          "the stage has not finished. Needs the project's agent daemon and a stage running for REF."
        ],
        options: [PIPELINE_WORK_ITEM,
          ["--body TEXT", "The text after the sentinel (default: \"manual advance\")"],
          ["--json", "Print one action document (see docs/README.json.md) instead of text"]],
        examples: [
          ["workspace pipeline advance myapp --work-item WC-42", "push WC-42 past a stage that is done but did not say so"],
          ["workspace pipeline advance myapp --work-item WC-42 --body \"done by hand\"", "record why you pushed it on, e.g. a stage you finished by hand"],
          ["workspace pipeline advance myapp --work-item WC-42 --json", "for a script: one action document"]
        ]
      },
      "status" => {
        usage: ["pipeline status PROJECT [--json]"],
        summary: "Show what a project has in flight",
        about: [
          PIPELINE_ABOUT,
          "",
          "Reads the project's saved pipeline state, so it works with no agent running. A project with nothing",
          "in flight says so and exits 0."
        ],
        options: [["--json", "Print JSON ({schema_version, ok, entries}; failures print {schema_version, ok: false, error, code}) instead of a table"]],
        examples: [
          ["workspace pipeline status myapp", "what is myapp working on, and when is each stage due"],
          ["workspace pipeline status myapp --json", "the same as one document, for a script"],
          ["workspace pipeline status api", "a project with nothing in flight says so and exits 0"]
        ]
      },
      "reset" => {
        usage: ["pipeline reset PROJECT [--json]"],
        summary: "Clear a stopped project's pipeline state",
        about: [
          PIPELINE_ABOUT,
          "",
          "Deletes the project's saved pipeline state. Refused while its agent daemon is running."
        ],
        options: [["--json", "Print one action document (see docs/README.json.md) instead of text"]],
        examples: [
          ["workspace pipeline reset myapp", "clear leftover state after stopping myapp's agent"],
          ["workspace pipeline reset myapp --json", "for a script: one action document, an error document if the agent still runs"],
          ["workspace pipeline reset api", "a project with no saved state succeeds too, printing the same line"]
        ]
      }
    }.freeze

    LIBRARY_SCOPES = [
      ["--global", "Only the global store"],
      ["--builtin", "Only the entries that ship with workspace"],
      ["--project [NAME]", "The project's store (NAME, or the project of the current directory)"]
    ].freeze
    LIBRARY_PROJECT = ["--project [NAME]", "The project's store (NAME, or the project of the current directory)"].freeze
    LIBRARY_WORKSPACE = name_opt("The workspace to act on (default: the one of the current directory)")
    LIBRARY_DRY_RUN = ["--dry-run", "Report what would happen and write nothing"].freeze

    LIBRARY = {
      "list" => {
        usage: ["library list [--kind KIND] [--global | --builtin | --project [NAME]] [--json]"],
        summary: "List every library entry visible from here, sorted by kind then name",
        about: [
          "Entries are global unless a project narrows them; a project entry hides a global one of the same",
          "name. `workspace library` alone lists."
        ],
        options: [["--kind KIND", "Only this kind: agent, play, prompt, recipe, skill or spine"], *LIBRARY_SCOPES, JSON_OPT],
        examples: [
          ["workspace library list", "see everything you can use from here: your project's entries, the global ones and the built-in packs"],
          ["workspace library list --kind skill --global", "only the skills in the global store, e.g. before installing one"],
          ["workspace library list --builtin --kind play", "the packs that ship with workspace and that instructions compose can name"],
          ["workspace library list --kind prompt --json", "for a script: the same rows as one JSON document"]
        ]
      },
      "show" => {
        usage: ["library show REF [--global | --builtin | --project [NAME]] [--json]"],
        summary: "Print a library entry's body",
        about: [
          "REF is kind/name, or a bare name when one kind has it. The body is printed as it is, so you can pass",
          "it on, e.g. workspace start BRANCH --prompt \"$(workspace library show prompt/kickoff)\"."
        ],
        options: [*LIBRARY_SCOPES, JSON_OPT],
        examples: [
          ["workspace library show prompt/kickoff", "read back a prompt you saved, exactly as it will be sent"],
          ["workspace library show kickoff", "the same with a bare name, when only one kind has an entry called kickoff"],
          ["workspace library show play/commits --builtin", "read a pack that ships with workspace before you rely on it"],
          ["workspace library show kickoff --json", "for a script: the entry and its body as one JSON document; a name nothing has exits 1 with unknown_library_entry"]
        ]
      },
      "info" => {
        usage: ["library info REF [--global | --builtin | --project [NAME]] [--json]"],
        summary: "Show a library entry's kind, scope, path, link target, description and modified time",
        about: [
          "REF is kind/name, or a bare name when one kind has it. effective says whether this entry is the one",
          "`library show` prints; it is false when a project entry of the same name hides a global one."
        ],
        options: [*LIBRARY_SCOPES, JSON_OPT],
        examples: [
          ["workspace library info kickoff", "find out where an entry lives and whether it is a link, and whether it is the one `library show` prints"],
          ["workspace library info play/commits --builtin", "see the path and description of a built-in pack"],
          ["workspace library info skill/write-tests --global --json", "for a script: the global copy's details as one JSON document"]
        ]
      },
      "add" => {
        usage: ["library add PATH|- --kind KIND [--as NAME] [--link] [--force] [--project [NAME]] [--dry-run] [--json]"],
        summary: "Copy a file or directory into the library",
        about: [
          "Copies PATH in (or links it with --link, or reads - from stdin with --as NAME). The name defaults to",
          "the file name in kebab case; identical content is a no-op, different content under the same name",
          "needs --force.",
          "",
          "--kind recipe takes a YAML file of plays, packs, agents, skills, agent_kind and prompt (for 'start",
          "--recipe'); --kind skill takes a directory holding SKILL.md; --kind spine takes a folder of",
          "plan-spine stage files (a template for 'spine init').",
          "",
          "This writes to the library for real (the global store, or the project's with --project); --dry-run",
          "says what would happen and writes nothing."
        ],
        options: [["--kind KIND", "agent, play, prompt, recipe, skill or spine (required)"],
          ["--as NAME", "The entry name (lowercase letters, digits and hyphens)"],
          ["--link", "Store a symlink to PATH instead of a copy"],
          ["--force", "Replace an entry that has different content"],
          ["--project [NAME]", "Add to the project's store (NAME, or the project of the current directory)"],
          LIBRARY_DRY_RUN, JSON_OPT],
        examples: [
          ["workspace library add kickoff.md --kind prompt", "save a file as the global prompt kickoff, named after the file"],
          ["workspace library add kickoff.md --kind prompt --dry-run", "check first: it reports added, unchanged or the refusal and writes nothing"],
          ["workspace library add kickoff.md --kind prompt --project", "keep it for the project of the current directory only"],
          ["workspace library add ~/Notes/playbook.md --kind play --link", "link a note, so edits to the note show up in the library at once"],
          ["workspace library add ~/Notes/spine-template --kind spine --as team --link", "keep a folder of stage files as a template for 'spine init'"],
          ["workspace library add - --kind prompt --as resume-note < resume.txt", "save text from stdin, which needs --as for the name"],
          ["workspace library add kickoff.md --kind prompt --force", "replace kickoff after you changed the file; without --force a different file under that name exits 1 with an error"]
        ]
      },
      "update" => {
        usage: ["library update REF PATH|- [--link] [--project [NAME]] [--dry-run] [--json]"],
        summary: "Replace a library entry's content, or repoint its link",
        about: [
          "REF is kind/name, or a bare name when one kind has it. The entry must already exist in the global",
          "store, or in the project's with --project; this writes it for real unless --dry-run."
        ],
        options: [["--link", "Store a symlink to PATH instead of a copy"], LIBRARY_PROJECT, LIBRARY_DRY_RUN, JSON_OPT],
        examples: [
          ["workspace library update prompt/kickoff kickoff.md", "replace the global prompt with the edited file"],
          ["workspace library update prompt/kickoff kickoff.md --dry-run", "see whether the file differs from the stored prompt: updated or unchanged, nothing written"],
          ["workspace library update kickoff kickoff.md --project", "replace the project's copy only, by bare name"],
          ["workspace library update play/playbook ~/Notes/new-playbook.md --link", "point a linked play at another note"]
        ]
      },
      "remove" => {
        usage: ["library remove REF [--yes] [--project [NAME]] [--dry-run] [--json]"],
        summary: "Delete a library entry or its link",
        about: [
          "Deletes the entry or its link from the global store, or the project's with --project, for real; the",
          "source file is never touched. It asks first on a terminal. With --json it never asks, so pass --yes",
          "or --dry-run."
        ],
        options: [["--yes", "Don't ask"], LIBRARY_PROJECT, LIBRARY_DRY_RUN, JSON_OPT],
        examples: [
          ["workspace library remove prompt/kickoff", "delete a global entry, answering the question on the terminal"],
          ["workspace library remove prompt/kickoff --dry-run", "see what would go before anything does"],
          ["workspace library remove play/playbook --yes", "delete a linked play without being asked, as a script must; the note it linked stays"],
          ["workspace library remove kickoff --project --yes", "delete the project's copy and let the global one show through again"]
        ]
      },
      "install" => {
        usage: ["library install REF [--name WS | --user] [--from global|project] [--force] [--dry-run] [--json]"],
        summary: "Copy a library skill or agent into a workspace's checkout",
        about: [
          "Copies to .claude/skills/NAME/ or .claude/agents/NAME.md unless library.install.skills_dir or",
          "agents_dir says otherwise, as start --skill/--agent does for a new workspace: identical content is",
          "unchanged, different content needs --force, a path the repo tracks is never overwritten; the copy is",
          "listed in info/exclude. --user copies to your home-level directory instead",
          "(library.install.user_skills_dir, user_agents_dir; ~/.claude/... by default). This writes files for",
          "real; --dry-run reports what it would do and writes nothing."
        ],
        options: [LIBRARY_WORKSPACE,
          ["--user", "Copy to the user-level directory instead of a workspace"],
          ["--from STORE", "Copy the entry of this store, global or project (default: the project's, else global)"],
          ["--force", "Replace a copy that has different content"],
          LIBRARY_DRY_RUN, JSON_OPT],
        examples: [
          ["workspace library install skill/write-tests", "give the workspace you are in a skill from the library"],
          ["workspace library install skill/write-tests --dry-run", "check what would be copied into this workspace's checkout and write nothing"],
          ["workspace library install agent/reviewer --name my-app", "give another workspace a subagent without leaving your directory"],
          ["workspace library install skill/write-tests --user", "make a skill available in every project, from your home directory"],
          ["workspace library install skill/write-tests --from global --force", "replace a copy you edited with the global entry, even where the project has its own"],
          ["workspace library install skill/write-tests --name my-app --json", "for a script: the outcome (installed or unchanged) as one JSON document"]
        ]
      },
      "uninstall" => {
        usage: ["library uninstall REF [--name WS | --user] [--force] [--dry-run] [--json]"],
        summary: "Delete the copy of a library entry that `library install` made",
        about: [
          "Deletes the copy of REF that `library install` made in a workspace's checkout, or with --user from",
          "the home-level directory. A copy that differs from the library entry needs --force; the library entry",
          "and the info/exclude line stay. This deletes files for real; --dry-run reports and deletes nothing."
        ],
        options: [LIBRARY_WORKSPACE,
          ["--user", "Remove the user-level copy"],
          ["--force", "Remove a copy that differs from the library entry"],
          LIBRARY_DRY_RUN, JSON_OPT],
        examples: [
          ["workspace library uninstall skill/write-tests", "take a skill back out of the workspace you are in"],
          ["workspace library uninstall skill/write-tests --dry-run", "see which copy would be deleted from this workspace's checkout"],
          ["workspace library uninstall agent/reviewer --name my-app", "take a subagent out of another workspace"],
          ["workspace library uninstall skill/write-tests --force", "delete a copy you edited, which would otherwise be refused"],
          ["workspace library uninstall agent/reviewer --user", "remove the copy from your home directory"]
        ]
      },
      "installed" => {
        usage: ["library installed [--name WS | --user] [--kind skill|agent] [--json]"],
        summary: "List the skills and agents installed from the library into a workspace's checkout or your home directory",
        about: [
          "Reads a workspace's checkout (--name WS, default: the current directory's) or the user level",
          "(--user); writes nothing. A copy counts when its name is a library entry's or the repo's",
          "info/exclude lists it; modified = differs from that entry."
        ],
        options: [LIBRARY_WORKSPACE,
          ["--user", "List the user-level copies"],
          ["--kind KIND", "Only skills or only agents"], JSON_OPT],
        examples: [
          ["workspace library installed", "see which skills and agents the workspace you are in got from the library, and which you edited"],
          ["workspace library installed --name my-app --kind skill", "only the skills of another workspace"],
          ["workspace library installed --user --json", "for a script: the copies in your home directory as one JSON document"]
        ]
      }
    }.freeze

    SPINE_IF_REVISION = ["--if-revision REV", "Refuse with stale_revision unless the stage file's revision (from show) is REV"].freeze
    SPINE_BY = ["--by LABEL", "The updated_by label (default: the agent and pane id of $TMUX_PANE, else person)"].freeze

    SPINE = {
      "show" => {
        usage: ["spine show [WORKSPACE] [--name WORKSPACE] [--stage STAGE-PATH] [--body] [--evaluate] [--json]"],
        summary: "Read a workspace's stages",
        about: [
          "The stages are the Markdown files in spine/ of the workspace's notes directory, one per stage",
          "(10-research.md, 20-plan.md, ...), with sub-stages in a folder named like a stage file without .md.",
          "Statuses are read as one of not_started, in_progress, blocked, completed, skipped or unknown. A bad",
          "file is a warning in the answer, never an error, and nothing is written, created or followed through",
          "a link."
        ],
        options: [NAME_OPT,
          ["--stage STAGE-PATH", "Only that stage (with its sub-stages); unknown_stage when there is none"],
          ["--body", "Add the text after the frontmatter (16 KB at most) to the stage, or to the goal without --stage"],
          ["--evaluate", "Judge each stage against the plan, git, the pull request, the review agent and the panes (reads gh and the agent daemon, up to about 5s; an unreadable source leaves its gates unchecked)"],
          JSON_OPT],
        examples: [
          ["workspace spine show", "the stages of the workspace you are in"],
          ["workspace spine show api.worktree-login", "the stages of one workspace by name"],
          ["workspace spine show --stage implement/api --body", "one stage and its sub-stages, with the text after the frontmatter"],
          ["workspace spine show --evaluate", "judge each stage against the plan, git, the pull request and the panes (may take up to about 5s)"],
          ["workspace spine show --json", "one JSON document, with each stage file's revision for --if-revision"]
        ]
      },
      "set" => {
        usage: ["spine set [WORKSPACE] STAGE-PATH [--status VALUE] [--note TEXT] [--owner VALUE] [--if-revision REV] [--recursive] [--by LABEL] [--json]"],
        summary: "Change one stage's status, note or owner",
        about: [
          "Give at least one of --status, --note and --owner. STAGE-PATH is the ids joined with /, as show",
          "reports `path`, such as verify or implement/api. Only the status, note, owner, updated and",
          "updated_by lines of the stage file are rewritten, and a spine_changed event is written. Writers of a",
          "workspace take turns."
        ],
        options: [NAME_OPT,
          ["--status VALUE", "not_started, in_progress, blocked, completed or skipped (or an alias such as done)"],
          ["--note TEXT", "One line of at most 300 characters; alone it changes only the note (empty clears it). With a new status and no --note the note is cleared"],
          ["--owner VALUE", "Who works the stage: a pane id such as %6, you, or an agent label; one line of at most 64 characters (empty clears it). Not with --recursive"],
          SPINE_IF_REVISION,
          ["--recursive", "Also set every sub-stage that is not completed or skipped"],
          SPINE_BY, JSON_OPT],
        examples: [
          ["workspace spine set verify --status in_progress", "mark the verify stage of the workspace you are in as started"],
          ["workspace spine set verify --owner %6 --note \"waiting on CI\"", "record who works the stage and a one-line note, leaving the status alone"],
          ["workspace spine set api.worktree-login review --status completed --note \"2 nits, fixed\"", "mark a stage of one workspace by name completed, with a note"],
          ["workspace spine set implement --status completed --recursive", "complete the stage and every sub-stage that is not completed or skipped"],
          ["workspace spine set verify --status blocked --if-revision 9f8e7d6c --json", "refuse with stale_revision unless the stage file is still at that revision (from spine show --json)"]
        ]
      },
      "check" => {
        usage: ["spine check [WORKSPACE] STAGE-PATH --item N [--item N ...] (--done | --undone) [--if-revision REV] [--by LABEL] [--json]"],
        summary: "Tick or untick items of a stage's Done when checklist",
        about: [
          "N is the item's 1-based position in the stage's '## Done when' checklist, as show lists them. Only",
          "the [ ] or [x] on that item's line changes, not the frontmatter. An item already in the asked state",
          "is left alone. A spine_changed event with change done_when is written. Refuses an item that is not",
          "there (unknown_item)."
        ],
        options: [NAME_OPT,
          ["--item N", "The checklist item, 1-based; repeat for several"],
          ["--done", "Tick the items"],
          ["--undone", "Untick the items"],
          SPINE_IF_REVISION, SPINE_BY, JSON_OPT],
        examples: [
          ["workspace spine check verify --item 2 --done", "tick item 2 of the verify stage's Done when list"],
          ["workspace spine check implement/api --item 1 --item 3 --done", "tick items 1 and 3 of a sub-stage"],
          ["workspace spine check api.worktree-login verify --item 2 --undone", "untick item 2 in one workspace by name"],
          ["workspace spine check verify --item 2 --done --if-revision 9f8e7d6c --json", "refuse with stale_revision unless the stage file is still at that revision (from spine show --json)"]
        ]
      },
      "verify" => {
        usage: ["spine verify [WORKSPACE] STAGE-PATH (--pass | --fail) --note TEXT [--by LABEL] [--if-revision REV] [--json]"],
        summary: "Record a separate check of a completed stage",
        about: [
          "Writes check (passed with --pass, failed with --fail), checked_by, checked_at and check_note, and no",
          "other line. A stage opts in with a check: line in its file (check: required); 'set --status",
          "completed' then makes it check: pending, and any other status resets it to required. Refuses a stage",
          "that has not opted in (check_not_required) and one that is not completed (stage_not_completed). A",
          "spine_changed event with change check is written. The verdict is the checker's: run it from a",
          "different pane or sub-agent than the one that did the stage, never on your own stage (nothing",
          "enforces this)."
        ],
        options: [NAME_OPT,
          ["--pass", "The stage passed its check"],
          ["--fail", "The stage failed its check"],
          ["--note TEXT", "The verdict's note, required, 300 characters at most"],
          ["--by LABEL", "The checked_by label (default: the agent and pane id of $TMUX_PANE, else person)"],
          SPINE_IF_REVISION, JSON_OPT],
        examples: [
          ["workspace spine verify implement --pass --note \"CI green, all 4 items met\"", "record that the completed implement stage passed its check"],
          ["workspace spine verify implement --fail --note \"item 2 is not in the diff\"", "record that it failed its check; the note says why"],
          ["workspace spine verify api.worktree-login review --pass --note \"2 nits, fixed\" --by \"claude %27\"", "check a stage of one workspace by name, under your own label"],
          ["workspace spine verify implement --pass --note \"CI green\" --if-revision 9f8e7d6c --json", "refuse with stale_revision unless the stage file is still at that revision (from spine show --json)"]
        ]
      },
      "goal set" => {
        usage: ["spine goal set [WORKSPACE] TEXT [--if-revision REV] [--by LABEL] [--json]"],
        summary: "Write the goal's title",
        about: [
          "Writes title: in spine/goal.md (one line, at most 120 characters), keeping the rest of an existing",
          "file, and makes the file (spine: 1, title, a '# TEXT' heading) when it is missing. Refuses a",
          "workspace with no spine/ (no_spine). A spine_changed event with change goal is written."
        ],
        options: [NAME_OPT,
          ["--if-revision REV", "Refuse with stale_revision unless goal.md's revision (from show) is REV"],
          SPINE_BY, JSON_OPT],
        examples: [
          ["workspace spine goal set \"Fix the OAuth refresh race\"", "write the goal's title in spine/goal.md of the workspace you are in"],
          ["workspace spine goal set api.worktree-login \"Fix the OAuth refresh race\"", "the same for one workspace by name"],
          ["workspace spine goal set \"Fix the OAuth refresh race\" --if-revision 9f8e7d6c --json", "refuse with stale_revision unless goal.md is still at that revision"]
        ]
      },
      "start" => {
        usage: ["spine start [WORKSPACE] STAGE-PATH [--pane PANE | --spawn KIND] [--play REF] [--if-revision REV] [--json]",
          "spine start [WORKSPACE] STAGE-PATH --fan-out [--spawn KIND] [--max N] [--json]"],
        summary: "Get an agent working on one stage",
        about: [
          "Uses the pane named, a new one (--spawn), the stage's owner when it is a live agent pane, else the",
          "main Claude Code or Codex pane; a workspace with no session is launched. It first sets the stage",
          "in_progress with that pane as its owner, then types the brief (the play, the spine pack, and the",
          "stage's path and file), then binds the pane. Refuses a stage that is completed or skipped",
          "(stage_done) or whose depends_on stages are not (stage_waiting), and a pane that is busy (pane_busy).",
          "",
          "--fan-out starts every sub-stage of STAGE-PATH (the folder named like its file) that is not started",
          "and has no unmet depends_on, each in its own new pane (--spawn, default the main agent's kind), at",
          "most --max; the rest are skipped. It cannot be combined with --pane, --play or --if-revision. One",
          "result per sub-stage: spawned, refused or skipped. Exit status 1 only when nothing was spawned and",
          "something was refused."
        ],
        options: [NAME_OPT,
          ["--pane PANE", "The pane to send the stage to, a pane id (%21) or window.pane (0.1) of the workspace's session"],
          ["--spawn KIND", "Split a new pane and start that agent in it (#{AGENT_KINDS})"],
          ["--play REF", "The play to send (default: the stage's play:, else research, implementation-plan or review by its kind)"],
          ["--fan-out", "Start every startable sub-stage of STAGE-PATH, each in a new pane"],
          ["--max N", "With --fan-out: spawn at most N panes (default 3)"],
          SPINE_IF_REVISION, JSON_OPT],
        examples: [
          ["workspace spine start verify", "set the verify stage in_progress and type its brief into the stage's owner pane, else the main agent pane"],
          ["workspace spine start api.worktree-login implement/api --spawn codex", "split a new pane, start Codex in it and type the brief there"],
          ["workspace spine start research --pane %21 --play review", "type the brief into pane %21 with the review play instead of the research one"],
          ["workspace spine start implement --fan-out --max 2", "start up to two ready sub-stages, each in a new pane"],
          ["workspace spine start verify --if-revision 9f8e7d6c --json", "refuse with stale_revision unless the stage file is still at that revision (from spine show --json)"]
        ]
      },
      "init" => {
        usage: ["spine init [WORKSPACE] [--name WORKSPACE] [--template NAME] [--dry-run] [--json]"],
        summary: "Create the spine/ folder from a template",
        about: [
          "Creates spine/ in the workspace's notes directory from a spine template (a library entry of kind",
          "spine; the built-in 'default' has the stages research to ship, and a main checkout gets no ship",
          "stage). {{WORKSPACE}}, {{BRANCH}} and {{TITLE}} in the template are filled in. Nothing is overwritten:",
          "when spine/ exists the answer is 'exists' and nothing is written. The notes directory is made if",
          "needed, as 'notes dir --create' does."
        ],
        options: [NAME_OPT,
          ["--template NAME", "The spine template (default: the spine.template config, else default). See: workspace library list --kind spine"],
          ["--dry-run", "Say what would be written and write nothing"], JSON_OPT],
        examples: [
          ["workspace spine init --dry-run", "preview the files for the workspace you are in; nothing is written"],
          ["workspace spine init", "write spine/ from the default template for real, unless spine/ exists (then it says exists)"],
          ["workspace spine init api.worktree-login --template team", "write it for one workspace by name from your spine template named team (workspace library list --kind spine shows them)"],
          ["workspace spine init --json", "the same as one JSON document"]
        ]
      }
    }.freeze

    BINDING_PANE = ["--pane PANE", "Pane id (%19); defaults to $TMUX_PANE, the pane the command runs in"].freeze
    BINDING_JSON = ["--json", "Print one JSON action document"].freeze
    BINDING_ABOUT = "A binding ties a tmux pane to a workflow run, a PR review or a library play, so session-event can remind the agent in it of its subject.".freeze

    BINDING = {
      "set" => {
        usage: ["binding set [WORKSPACE] [--pane PANE] --kind run|review|play --id ID [--step STEP] [--attempt N] [--focus TEXT] [--instructions PATH] [--artifacts PATH] [--pack NAME]... [--name NAME] [--json]"],
        summary: "Bind a pane to a workflow run, a PR review or a library play",
        about: [
          "When the agent in a bound pane starts a session (startup, /clear, resume or compact), session-event",
          "reminds it of its subject, so it survives a lost context. Nothing is typed into the pane. A pane is",
          "stored by its tmux pane id (%19) and only counts in the tmux session it was bound in. Setting a",
          "binding replaces the whole earlier one, its packs included. This records the binding for real, in",
          "bindings.json; there is no dry run."
        ],
        options: [name_opt("Workspace name (default: the project detected from the current directory)"),
          ["--pane PANE", "Pane id (%19) or window.pane (0.1) of the workspace's own session; defaults to $TMUX_PANE"],
          ["--kind KIND", "run, review or play"],
          ["--id ID", "Run id, review id such as acme/api#835, or play/NAME"],
          ["--step STEP", "Step name"],
          ["--attempt N", "Step attempt, 1 or more"],
          ["--focus TEXT", "Review focus, e.g. security"],
          ["--instructions PATH", "File holding the pane's instructions; stored as an absolute path"],
          ["--artifacts PATH", "Directory holding the subject's artifacts; stored as an absolute path"],
          ["--pack NAME", "Library pack the agent is also reminded of (repeatable; replaces the stored list; see `workspace instructions --help`)"],
          BINDING_JSON],
        examples: [
          ["workspace binding set --kind play --id play/orchestrator", "from inside the agent's own pane: remind it of a play after a /clear"],
          ["workspace binding set my-app --pane %5 --kind run --id wr_01 --step implement --attempt 2", "bind the pane of a workflow run's second implement attempt"],
          ["workspace binding set my-app --pane 0.1 --kind review --id acme/api#835 --focus security", "bind a review pane by window.pane, with the focus the reviewer was given"],
          ["workspace binding set --pane %5 --kind play --id play/research --pack commits --pack notes", "also remind the agent of two packs, which replaces any packs stored before"],
          ["workspace binding set --pane %5 --kind run --id wr_01 --json", "for a script: the stored binding as one JSON action document"]
        ]
      },
      "show" => {
        usage: ["binding show [--pane %ID] [--json]"],
        summary: "Print a pane's binding",
        about: [BINDING_ABOUT, "It is marked stale when the pane is no longer in the tmux session and slot it was bound in; a stale binding is not announced."],
        options: [BINDING_PANE, BINDING_JSON],
        examples: [
          ["workspace binding show", "from inside an agent's pane: what it is reminded of after a /clear"],
          ["workspace binding show --pane %5", "check a pane after a restore: is its binding stale?"],
          ["workspace binding show --pane %5 --json", "for a script: stale, packs and plays as fields; a pane with no binding exits 1 with not_bound"]
        ]
      },
      "clear" => {
        usage: ["binding clear [--pane %ID] [--json]"],
        summary: "Remove a pane's binding",
        about: [BINDING_ABOUT, "This removes the pane's entry from bindings.json for real; nothing is typed into the pane."],
        options: [BINDING_PANE, BINDING_JSON],
        examples: [
          ["workspace binding clear", "from inside the agent's pane: stop reminding it once its work is done"],
          ["workspace binding clear --pane %5", "unbind another pane, e.g. one whose run was cancelled"],
          ["workspace binding clear --pane %5 --json", "for a script: the removed binding as one JSON action document; a pane with no binding exits 1 with not_bound"]
        ]
      }
    }.freeze

    STEP = {
      "done" => {
        usage: ["step done [--status pass|fail] [--summary TEXT] [--code WORD] [--json]"],
        summary: "Record what you say about a workflow step, then end your turn",
        about: [
          "For the agent working on a workflow step, run from the pane the run is bound to. --status fail fails",
          "the step at the turn's end without running its check. It is not required: a step is decided when the",
          "agent's turn ends, from the files it was told to leave and the step's check (see `workspace",
          "workflow --help`)."
        ],
        options: [["--status STATUS", "pass (default) or fail"],
          ["--summary TEXT", "One line about what was done, or what is left"],
          ["--code WORD", "A word for why, kept with a failed step: starts with a lowercase letter, then lowercase letters, digits, _ (at most 40); not one the engine uses (e.g. check_failed, head_moved)"],
          JSON_OPT],
        examples: [
          ["workspace step done", "record a pass for the step your pane is on; then end your turn"],
          ["workspace step done --summary \"Plan written; three commits.\"", "record a pass with one line on what was done"],
          ["workspace step done --status fail --summary \"Two specs still fail in billing.\"", "fail the step when the turn ends, without running its check"],
          ["workspace step done --status fail --code not_reproduced --summary \"The failure did not happen locally.\"", "fail it with a word for why, kept with the failed step"],
          ["workspace step done --summary \"Docs written\" --json", "the same as one JSON document; outside a run's pane it exits 1 with not_bound"]
        ]
      },
      "status" => {
        usage: ["step status [--json]"],
        summary: "Show which workflow run, step and attempt this pane is on",
        about: [
          "Also shows where the step's instructions are, and whether the files the step must leave exist. Run",
          "from the pane the run is bound to."
        ],
        options: [JSON_OPT],
        examples: [
          ["workspace step status", "which workflow run, step and attempt this pane is on, and the files the step must leave"],
          ["workspace step status --json", "the same as one JSON document, with whether each file is there (produces); outside a run's pane it exits 1 with not_bound"],
          ["workspace step status --json | jq '.step.produces'", "list the files the step must leave, and whether each was written this attempt (current)"]
        ]
      }
    }.freeze

    REVIEW = {
      "show" => {
        usage: ["review show [WORKSPACE | --name WS] [--patch [--max-bytes N]] [--json]"],
        summary: "Show one workspace's review summary; the default when no verb is given",
        about: [
          "The summary has the agent state, task, diffstat and commits against the base, the pull request and",
          "its checks (read with `gh pr view`), open questions, session count and the agent's last message.",
          "WORKSPACE defaults to the one for the current directory. A workspace named \"list\" is reviewed with",
          "`review show list`. A stopped workspace is judged by its agent's last recorded state. Reads only; a",
          "source that can't answer (no agent daemon, git or gh failing or too slow) is reported as",
          "unavailable, never as clean."
        ],
        options: [name_opt("The workspace, as an option (same as the positional WORKSPACE)"),
          ["--patch", "Include the unified patch of the diffstat's range (git.patch in --json)"],
          ["--max-bytes N", "With --patch: most patch bytes to return, 1 to 5242880 (default 200000)"],
          ["--json", "Print schema-versioned JSON (see docs/README.review.md)"]],
        examples: [
          ["workspace review show", "the review packet of the workspace in the current directory"],
          ["workspace review show my-app.worktree-fix-login", "the packet of one workspace by name"],
          ["workspace review show --name my-app.worktree-fix-login --json", "the same, with the workspace as an option and one JSON document"],
          ["workspace review show --patch", "include the unified patch of the branch (cut at 200000 bytes)"],
          ["workspace review show --patch --max-bytes 50000 --json", "the patch cut at 50000 bytes, in git.patch of the JSON document"]
        ]
      },
      "list" => {
        usage: ["review list [PROJECT] [--json]"],
        summary: "List the project's workspaces that are ready for review",
        about: [
          "A workspace is ready when its agent is done (the Stop hook fired and no pane is working or waiting)",
          "and its branch has commits its base branch (origin's default branch) lacks. PROJECT is a project",
          "name, a member workspace name or a path; it defaults to the current directory's. Runs git only for",
          "workspaces whose agent is done, and never calls gh. Reads only."
        ],
        options: [["--json", "Print schema-versioned JSON (see docs/README.review.md)"]],
        examples: [
          ["workspace review list", "the workspaces of the current directory's project that are ready for review"],
          ["workspace review list my-app", "the same for the project my-app"],
          ["workspace review list my-app --json", "one JSON document, for a script that picks the next workspace to review"]
        ]
      }
    }.freeze

    PR = {
      "create" => {
        usage: ["pr create [--name WORKSPACE] [--draft] [--json]"],
        summary: "Open a pull request for a workspace's branch",
        about: [
          "Leaves the workspace alone but acts on origin and GitHub. In order: a branch that already has a pull",
          "request (any state) gets it returned and nothing else happens; a branch with no commits ahead of its",
          "base is refused; a branch with no upstream is pushed to origin with -u; then 'gh pr create --fill'",
          "opens a real pull request. A branch that already has an upstream is not pushed, so push new commits",
          "first (`workspace push`). Needs 'gh', logged in. Exits 1 with an error when it refuses; --json prints",
          "the code (nothing_to_push, gh_unavailable, a push code)."
        ],
        options: [name_opt("The workspace (default: the one the current directory is in)"),
          ["--draft", "Open the pull request as a draft (ignored when one exists)"], JSON_OPT],
        examples: [
          ["workspace pr create", "the branch is ready for review: push it if it has no upstream and open the pull request, or print the one it already has"],
          ["workspace pr create --draft", "open it as a draft while the work is unfinished"],
          ["workspace pr create --name api.worktree-PROJ-123", "open the pull request of another workspace's branch without changing directory"],
          ["workspace pr create --json", "for a script: one document with outcome created or existing, the url and the number"]
        ]
      },
      "feedback" => {
        usage: ["pr feedback [--name WORKSPACE] [--all] [--json]"],
        summary: "Read the feedback on the branch's pull request",
        about: [
          "Reads unresolved review threads, review summaries, conversation comments and failing checks. It is",
          "read-only. Comment text is written by other people. The text output lists the threads and failing",
          "checks and only counts the reviews and conversation comments (it escapes control characters); --json",
          "carries their bodies, unescaped. Needs 'gh', logged in. Exits 1 with an error when the branch has no",
          "pull request; --json prints the code (no_pull_request, gh_unavailable)."
        ],
        options: [name_opt("The workspace (default: the one the current directory is in)"),
          ["--all", "Keep resolved review threads"], JSON_OPT],
        examples: [
          ["workspace pr feedback", "see what reviewers and CI said about this branch's pull request: unresolved threads and failing checks"],
          ["workspace pr feedback --all", "a reviewer says a point was already dealt with: include the resolved threads to check what was settled"],
          ["workspace pr feedback --name api.worktree-PROJ-123", "read another workspace's pull request without changing directory"],
          ["workspace pr feedback --json", "for a script or an agent: the comment bodies too, as text other people wrote"]
        ]
      }
    }.freeze

    TICKET_NAME = name_opt("Look in this workspace's project instead of the one detected from the current directory")

    TICKET = {
      "show" => {
        usage: ["ticket show REF [--name WORKSPACE] [--json]"],
        summary: "Read a ticket and say whether a worktree for it exists",
        about: [
          "Reads the ticket the way 'workspace start' reads its argument. REF is a JIRA key or URL, a pull",
          "request URL or #n, a GitHub issue URL, or a branch name. Title and body come from gh (pull requests",
          "and issues) or jira (JIRA keys); a plain branch has none. Writes nothing, creates nothing, fetches",
          "nothing from git. A ticket that does not exist, or a gh or jira that is missing, slow or signed out,",
          "exits 1 with an error; --json prints the code (ticket_not_found, ticket_source_unavailable)."
        ],
        options: [TICKET_NAME, JSON_OPT],
        examples: [
          ["workspace ticket show PROJ-123", "read a JIRA ticket's title and body before starting work, and see whether a worktree for it exists"],
          ["workspace ticket show https://github.com/acme/api/pull/41 --json", "a pull request's title, body and branch as one JSON document, for a script"],
          ["workspace ticket show '#41'", "a pull request or issue number in this repository (quote it: zsh starts a comment at an unquoted #)"],
          ["workspace ticket show feature/login --name api", "a branch has no title or body; the answer is whether a workspace exists, looked up in the project of workspace api"]
        ]
      },
      "list" => {
        usage: ["ticket list [--assigned|--recent] [--source gh|jira] [--limit N] [--name WORKSPACE] [--json]"],
        summary: "List tickets to pick from, newest change first",
        about: [
          "Open GitHub issues and pull requests (gh) and JIRA issues (jira), assigned to you (the default) or",
          "changed lately. A tool that is missing, slow or signed out is a warning, and the other still answers.",
          "Each row says whether a workspace exists."
        ],
        options: [TICKET_NAME,
          ["--assigned", "Open tickets assigned to you (the default)"],
          ["--recent", "Open tickets changed lately, whoever they are assigned to"],
          ["--source SOURCE", "Ask only gh or jira (repeatable; default both)"],
          ["--limit N", "At most N tickets, 1 to 100 (default 20)"], JSON_OPT],
        examples: [
          ["workspace ticket list", "pick what to work on next: your open tickets and pull requests, marked when a workspace exists"],
          ["workspace ticket list --recent", "see what changed lately, whoever it is assigned to"],
          ["workspace ticket list --source gh --limit 10", "the list is long or JIRA is slow: look only at GitHub and keep the 10 with the newest change"],
          ["workspace ticket list --json", "for a script: each ticket's ref (give it to `workspace start`) and a warning for each source that failed"]
        ]
      }
    }.freeze

    GOAL = {
      "show" => {
        usage: ["goal show [REF] [--json]"],
        summary: "Show where a goal is at each level and what it waits for",
        about: [
          "The levels are the goal, its journey stage, its workflow step, the agent's turn and the tool call;",
          "it also says on whom the goal waits and the next expected event. A goal is a workspace. REF is a",
          "workspace name, a workflow run id, a task id, a ticket key or URL, or a branch; with none, the",
          "workspace of the current directory. Reads only: nothing is written and 'gh' is not run."
        ],
        options: [JSON_OPT],
        examples: [
          ["workspace goal show", "where the goal of the workspace you are in is, level by level"],
          ["workspace goal show my-app.worktree-fix-login", "the same for one workspace by name"],
          ["workspace goal show LAB-1", "the goal for a ticket key (a branch, task id or run id works too)"],
          ["workspace goal show --json", "one JSON document, for a script"]
        ]
      },
      "list" => {
        usage: ["goal list [--all] [--json]"],
        summary: "List goals, one line each",
        about: ["Each line has the workspace, state, stage, step and agent state."],
        options: [["--all", "Include workspaces with no plan, run or spine (state none)"], JSON_OPT],
        examples: [
          ["workspace goal list", "one line per goal"],
          ["workspace goal list --all", "also the workspaces with no plan, run or spine (state none)"],
          ["workspace goal list --json", "one JSON document, for a script"]
        ]
      }
    }.freeze

    NOTES = {
      "dir" => {
        usage: ["notes dir [--name WORKSPACE] [--create] [--json]"],
        summary: "Print where a workspace's notes are kept",
        about: [
          "Notes are the working files an agent or a person keeps for a workspace (plans, findings, handoffs),",
          "outside the source tree.",
          "",
          "Prints the absolute path alone, so \"$(workspace notes dir)\" works. The workspace is the one detected",
          "from the current directory unless --name picks another.",
          "",
          "The path is the workspace's own notes.dir (a worktree's own, or the project's for a main checkout),",
          "else the project's notes.default_dir rule, else tmp/workspace-notes in the checkout. Nothing is",
          "written to config."
        ],
        options: [name_opt("Workspace to answer for instead of the one detected from the current directory"),
          ["--create", "Make the directory; inside the checkout, also keep it out of git (info/exclude)"],
          JSON_OPT],
        examples: [
          ["workspace notes dir", "where do this workspace's notes live"],
          ["workspace notes dir --create", "first note of a new worktree: make the directory and keep it out of git"],
          ["workspace notes dir --name api.worktree-login", "ask from outside the checkout, such as a script run from another workspace"],
          ["workspace notes dir --json", "also learn where the path came from and whether the directory exists yet"]
        ]
      }
    }.freeze

    INSTRUCTIONS = {
      "compose" => {
        usage: ["instructions compose [--pack NAME]... [--pane %ID] [--name WORKSPACE] [--json]",
          "instructions compose --start [--pack NAME]... [--no-packs] [--name WORKSPACE] [--json]"],
        summary: "Print the instructions an agent is given, built from library packs",
        about: [
          "A pack is a library play. The built-in ones are binding (how to work in a bound pane), orchestrator",
          "(delegate to sub-agents), commits (how to commit), review (review a diff with reviewer sub-agents),",
          "notes (where working notes go), handoff (run 'workspace handoff check' after every task), dev (queue",
          "for the shared dev environment before testing, release it when done), implementation-plan (keep",
          "the counted task list in IMPLEMENTATION_PLAN.md), plan-review (review the plan with reviewer",
          "sub-agents and post a verdict) and report (post a finished note to the inbox);",
          "`workspace library list --builtin` lists them all.",
          "With no --pack, binding, orchestrator and commits are composed, in that order, unless the config key",
          "workflows.defaults.include lists others. Each pack is printed under a heading that names where it",
          "came from.",
          "",
          "Any other library play can be named as a pack too: the project's library is searched, then global.",
          "A play named like a built-in pack never takes its place here; give your own another name.",
          "`workspace library show NAME --builtin` prints a built-in one.",
          "",
          "Two packs get lines for the caller. binding is followed by the binding of --pane when that pane is",
          "bound, and commits by the project's commands.test and commands.lint when they are set (workspace",
          "config set commands.test ...). --pane defaults to $TMUX_PANE, the pane the command runs in, unless",
          "--name is given. Text composed for another pane, as in start --prompt \"$(...)\", would carry this",
          "pane's binding: name the packs and leave binding out, or bind that pane first. Nothing is written or",
          "sent: the text is printed."
        ],
        options: [["--pack NAME", "A pack to compose (repeatable, composed in the order given)"],
          ["--pane PANE", "Pane id (%19) whose binding follows the binding pack (default $TMUX_PANE without --name)"],
          ["--name WORKSPACE", "Compose for this workspace instead of the current directory"],
          ["--start", "Print what start and launch send with the first prompt, and send nothing: the automatic packs (notes, unless notes.instructions is false) then each --pack"],
          ["--no-packs", "With --start: leave out the automatic packs (cannot be combined with --pack)"],
          JSON_OPT],
        examples: [
          ["workspace instructions compose", "print the default packs for the project of this directory, to read or to paste"],
          ["workspace instructions compose --pack commits --pack review", "only these two packs, in this order"],
          ["workspace instructions compose --pane %5", "the default packs with the binding of pane %5 after the binding pack"],
          ["workspace instructions compose --start --name my-app", "see what start or launch would send my-app with its first prompt; nothing is sent"],
          ["workspace instructions compose --pack orchestrator --name my-app --json", "for a script: the packs and the text as one JSON document, composed for my-app"],
          ["workspace instructions compose --pack nonesuch --json", "a pack that is not in any library exits 1 with unknown_library_entry"]
        ]
      }
    }.freeze

    UI = {
      "open" => {
        usage: ["ui open task|review|plan [WORKSPACE] [--print] [--json]",
          "ui open notes [WORKSPACE] [--path REL] [--print] [--json]",
          "ui open pane [WORKSPACE] PANE [--print] [--json]",
          "ui open inbox [--print] [--json]"],
        summary: "Open a view of the workspace UI through its workspace-ui:// link",
        about: [
          "The views:",
          "  task WORKSPACE     workspace-ui://task/WORKSPACE",
          "  review WORKSPACE   workspace-ui://review/WORKSPACE",
          "  notes WORKSPACE    workspace-ui://notes/WORKSPACE, or .../REL when --path REL is given (an existing .md note in the notes directory)",
          "  plan WORKSPACE     workspace-ui://plan/WORKSPACE",
          "  pane WORKSPACE PANE  workspace-ui://pane/WORKSPACE/PANE",
          "                     (PANE is a tmux pane id such as %19; WORKSPACE may be left out as for the others)",
          "  inbox              workspace-ui://inbox",
          "",
          "Without --print this opens the link for the person, so the UI app comes to the front on that view.",
          "A link only opens a view; it never starts an agent or runs a command. WORKSPACE (or --name)",
          "defaults to the project detected from the current directory. Opening needs the UI app installed,",
          "since it registers the scheme; without it `open` fails, the exit status is 1, and --print still",
          "shows the link.",
          "",
          "Run `workspace ui open VIEW --help` for the task, notes and inbox views."
        ],
        options: [name_opt("Workspace name (every view but inbox)"),
          ["--path REL", "Note to open, relative to the notes directory (notes view only)"],
          ["--print", "Print the link and open nothing"],
          ["--json", "Print one JSON action document (see docs/README.ui.md)"]],
        examples: [
          ["workspace ui open task my-app", "send the person to my-app's task view (opens the UI app)"],
          ["workspace ui open review my-app.worktree-fix-login", "point the person at the review of one worktree's change"],
          ["workspace ui open plan --print", "learn the plan link of the workspace you are in, and open nothing"],
          ["workspace ui open pane my-app %19", "show the person the pane an agent is stuck in"],
          ["workspace ui open task my-app --json", "open from a script; on failure exits 1 with reason open_failed or open_unavailable"]
        ]
      },
      "open task" => {
        usage: ["ui open task [WORKSPACE] [--print] [--json]"],
        summary: "Open a workspace's task view in the workspace UI",
        about: [
          "Opens workspace-ui://task/WORKSPACE for the person: the UI app comes to the front on that workspace's",
          "task. Nothing else happens; the link never starts an agent or runs a command. WORKSPACE (or --name)",
          "defaults to the project detected from the current directory; from anywhere else a usage error asks for",
          "one. The workspace is not checked to exist: the UI validates the link it receives. Without the UI app",
          "installed `open` fails and the exit status is 1; --print still shows the link."
        ],
        hidden: true,
        options: [name_opt("Workspace name"),
          ["--print", "Print the link and open nothing"],
          ["--json", "Print one JSON action document (see docs/README.ui.md)"]],
        examples: [
          ["workspace ui open task my-app", "send the person to my-app's task view (opens the UI app)"],
          ["workspace ui open task", "from inside a project, open the task view of the workspace you are in"],
          ["workspace ui open task my-app --print", "put the link in a message or a note, and open nothing"],
          ["workspace ui open task --name my-app.worktree-fix-login", "open a worktree's task from outside its checkout"],
          ["workspace ui open task my-app --json", "open from a script; on failure exits 1 with reason open_failed or open_unavailable"]
        ]
      },
      "open notes" => {
        usage: ["ui open notes [WORKSPACE] [--path REL] [--print] [--json]"],
        summary: "Open a workspace's notes in the workspace UI, or one note",
        about: [
          "Opens workspace-ui://notes/WORKSPACE for the person, or .../REL with --path REL: the UI app comes to",
          "the front on the Notes view or on that note. WORKSPACE (or --name) defaults to the project detected",
          "from the current directory.",
          "",
          "REL is the note's path inside the workspace's notes directory (`workspace notes dir` prints it):",
          "an existing .md or .markdown file of at most 4 path segments, with no symlink on the way. Each segment",
          "uses only the characters A-Z a-z 0-9 . _ - (no space), does not start with a dot and is not node_modules,",
          "so `My Note.md` cannot be linked until it is renamed. The file is checked first; a path that fails the",
          "check is refused as invalid_note_path, exits 1 with an error, and nothing opens. With --path the",
          "workspace must exist: an unknown one is refused as unknown_workspace before the path is looked at.",
          "Without the UI app installed `open` fails and the exit status is 1; --print still shows the link."
        ],
        hidden: true,
        options: [name_opt("Workspace name"),
          ["--path REL", "Note to open, relative to the notes directory"],
          ["--print", "Print the link and open nothing"],
          ["--json", "Print one JSON action document (see docs/README.ui.md)"]],
        examples: [
          ["workspace ui open notes my-app", "send the person to the notes of my-app (opens the UI app)"],
          ["workspace ui open notes my-app --path payment-retries.md", "show the person the one note you just wrote"],
          ["workspace ui open notes --path research/findings.md --print", "in the workspace of the current directory, print the link to a note in a folder, to quote in a reply"],
          ["workspace ui open notes my-app --path payment-retries.md --json", "open from a script; for a known workspace, a missing note is invalid_note_path in the error document"]
        ]
      },
      "open inbox" => {
        usage: ["ui open inbox [--print] [--json]"],
        summary: "Open the inbox in the workspace UI",
        about: [
          "Opens workspace-ui://inbox for the person: the UI app comes to the front on the inbox. The inbox is",
          "not tied to a workspace, so a workspace or --name is a usage error. Without the UI app installed",
          "`open` fails and the exit status is 1; --print still shows the link."
        ],
        hidden: true,
        options: [["--print", "Print the link and open nothing"],
          ["--json", "Print one JSON action document (see docs/README.ui.md)"]],
        examples: [
          ["workspace ui open inbox", "tell the person something waits for them (opens the UI app)"],
          ["workspace ui open inbox --print", "learn the inbox link and open nothing"],
          ["workspace ui open inbox --json", "open from a script; on failure exits 1 with reason open_failed or open_unavailable"]
        ]
      }
    }.freeze

    EVENT_LOG = {
      "show" => {
        usage: ["event-log show [--project NAME] [--type TYPE]... [--limit N] [--json]"],
        summary: "Print event log entries, oldest first",
        about: [
          "Reads the event log only; nothing is changed. Each line is `timestamp  project  type  key=value ...`;",
          "a value with a space or `=` is quoted, and control characters are replaced by spaces. Scripts should",
          "use --json rather than parse the lines. --project matches an event's project or, for a lock event",
          "from a worktree, that worktree's workspace name. A --type no event has is not an error: a warning on",
          "stderr lists the types the log does have. The filters apply first and --limit then keeps the last N",
          "of what matched. Hook-rate activity (tool calls, sessions) is not in this log: see `workspace events`.",
          "A usage error exits 1; with --json it is an error document on stdout."
        ],
        options: [["--project NAME", "Only events for this project"],
          ["--type TYPE", "Only events of this type (repeatable, or comma-separated)"],
          ["--limit N", "Only the last N matching events (N above 0)"],
          ["--json", "Print {schema_version, ok, events} instead of lines"]],
        examples: [
          ["workspace event-log show", "read the whole log, oldest first"],
          ["workspace event-log show --project myapp --limit 20", "what happened lately to one project"],
          ["workspace event-log show --type stage_failed,stage_timed_out", "why a pipeline stage stopped"],
          ["workspace event-log show --type lock_wait_started,lock_takeover --project myapp", "who waited for a lock, and who took one over"],
          ["workspace event-log show --json --limit 1", "the newest event as JSON, for a script"]
        ]
      },
      "compact" => {
        usage: ["event-log compact"],
        summary: "Rewrite the event log with the current state only",
        about: [
          "Rewrites the event log in place. It keeps one `compacted` event per active project and the latest",
          "state of each agent pane that still has an agent, and drops the rest of the history (dispatches, stage",
          "results, lock waits and takeovers, earlier pane states). A pane whose last change is older than 7 days,",
          "or whose project is gone, is dropped too. The idle and waiting alerts of the panes kept stay. The",
          "dropped history cannot be brought back.",
          "Workspace suggests it when the log passes 1MB, and rotates the log by itself past 10MB.",
          "Prints `Compacted event log: BEFORE -> AFTER bytes (N project(s))`.",
          "There is no dry run. Any extra flag or word is ignored, and the log is still compacted."
        ],
        options: [],
        examples: [
          ["workspace event-log compact", "the log has grown past 1MB and the history in it is no longer needed"],
          ["workspace event-log compact && workspace event-log show --type compacted", "check what was kept: one compacted event per active project"],
          ["workspace event-log compact && workspace event-log show --type agent_state --limit 10", "check that each pane with an agent kept its latest state"]
        ]
      }
    }.freeze

    PROJECTS_JSON = ["--json", "Print schema-versioned JSON (see docs/README.projects.md)"].freeze
    PROJECTS_NAME = [
      "NAME is a project name, a member workspace name or a path (use a path when two projects share a",
      "name); it defaults to the project containing the current directory."
    ].freeze
    PROJECTS_GROUP = "A group: id is refused with group_not_supported (exit 1); name a repository's project instead.".freeze

    PROJECTS = {
      "list" => {
        usage: ["projects list [--running] [--git] [--json]"],
        summary: "List projects, one row each, with their workspaces and how many are running",
        about: ["A project is a repository's main checkout plus its linked git worktrees. `workspace projects` alone lists."],
        options: [["--running", "Only projects with at least one running workspace"],
          ["--git", "Add an UNSAVED column (runs git in every checkout, and counts worktrees with no workspace config)"],
          PROJECTS_JSON],
        examples: [
          ["workspace projects list", "see every repository you have workspaces for, how many workspaces each has and how many are running"],
          ["workspace projects list --running", "before stopping for the day: which projects still have a running session"],
          ["workspace projects list --git", "check for unsaved work before cleaning up: adds an UNSAVED column, and is slower because it runs git in every checkout"],
          ["workspace projects list --running --json", "for a script: the running projects as one schema-versioned JSON document"]
        ]
      },
      "show" => {
        usage: ["projects show [NAME|PATH] [--json] [--no-agents] [--no-git] [--timeout SECONDS]"],
        summary: "Show one project in detail",
        about: [
          "Its workspaces (running, headless, agent states, open asks, pipeline entries, branch and unsaved work),",
          "worktrees with no workspace config, the repo-wide locks and the dev environment.",
          *PROJECTS_NAME,
          "Changes no workspace (reading the lock store creates its empty directory and locks.json when they are",
          "missing). A daemon that is down or doesn't answer in time shows as unavailable, and a checkout git can't",
          "answer for shows as unknown (treated as unsaved); the command still exits 0. An unknown or ambiguous",
          "NAME, or a directory in no project, exits 1 with an error.",
          PROJECTS_GROUP
        ],
        options: [PROJECTS_JSON,
          ["--no-agents", "Don't ask the agent daemons for agent states"],
          ["--no-git", "Don't run git (no branch or unsaved work, no unconfigured worktrees)"],
          ["--timeout SECONDS", "Seconds to wait for each running workspace's agent daemon (default 1) and for all the git reads (default 5)"]],
        examples: [
          ["workspace projects show", "see the state of the project you are standing in: each workspace's session, agents, open asks and unsaved work, and the repo-wide locks"],
          ["workspace projects show app", "the same for the project named app"],
          ["workspace projects show ~/src/app --json", "pick one of two clones that share a name by its path, as one JSON document for a script"],
          ["workspace projects show --no-agents --no-git", "the fastest read, when only the sessions and locks matter: no agent sockets and no git commands"],
          ["workspace projects show --timeout 0.5", "give up on a slow agent daemon or checkout after half a second; it reads unavailable or unknown and the command still exits 0"]
        ]
      },
      "members" => {
        usage: ["projects members [NAME|PATH] [--path] [--all] [--timeout SECONDS] [--json]"],
        summary: "List a project's member workspaces, one per line, main checkout first",
        about: [
          *PROJECTS_NAME,
          "Without --all no git runs. Members whose checkout is gone are still listed. Names only: with --all",
          "the unconfigured worktrees are omitted (a note goes to stderr) unless --path or --json is given.",
          "An empty result prints a note to stderr and nothing to stdout, so loop over the output",
          "(for/while read -r) rather than pass it unquoted to a command that acts on every workspace",
          "when given no argument. An unknown or ambiguous NAME exits 1 with an error.",
          PROJECTS_GROUP
        ],
        options: [["--path", "Print each checkout's path instead of its workspace name (not with --json)"],
          ["--all", "Also list worktrees that have no workspace config, shown only with --path or --json (runs git)"],
          ["--timeout SECONDS", "Seconds to wait for the worktree listing under --all (default 5)"],
          PROJECTS_JSON],
        examples: [
          ["workspace projects members", "list the workspaces of the project you are in, one name per line, main checkout first"],
          ["workspace projects members app | while read -r ws; do workspace plan status --name \"$ws\"; done", "read the plan state of each workspace of app in turn (read-only); read -r keeps a name with spaces whole"],
          ["workspace projects members --path", "you need the directories, for example to run git in each checkout of the project you are in"],
          ["workspace projects members --all --json", "include the worktrees that have no workspace config too (runs git); they read workspace null and configured false"]
        ]
      },
      "stop" => {
        usage: ["projects stop [NAME|PATH] [--dry-run] [--json]"],
        summary: "Stop every running workspace of a project and end their tmux sessions",
        about: [
          "Stops the project's main checkout and its worktrees in one step, for real.",
          *PROJECTS_NAME,
          "There is no prompt and no unsaved-work check, like 'workspace stop'. If you run this from inside",
          "one of the project's sessions, that session is stopped last, after the result is printed.",
          "Exit status: 0 stopped or nothing running, 3 some stopped and some failed, 1 nothing stopped or",
          "a usage error.",
          PROJECTS_GROUP
        ],
        options: [["--dry-run", "List the workspaces that would be stopped and stop nothing"],
          ["--json", "Print one schema-versioned result object (see docs/README.projects.md)"]],
        examples: [
          ["workspace projects stop", "end of the day: stop every running workspace of the project you are in, with no prompt"],
          ["workspace projects stop --dry-run", "before ending the day, check what is still running in the project you are in; nothing stops"],
          ["workspace projects stop app --dry-run", "from another directory, see what stopping the project named app would do; nothing stops"],
          ["workspace projects stop ~/src/app --json", "stop by path, for a script: one result object, and exit 3 when only some workspaces stopped"]
        ]
      },
      "kill" => {
        usage: ["projects kill NAME|PATH [--dry-run] [--yes] [--force] [--discard-unsaved] [--timeout DURATION] [--json]"],
        summary: "Remove every worktree workspace of a project",
        about: [
          "Deletes for real, each the way 'workspace kill' does: tmux session, git worktree, tmuxinator config,",
          "project settings, state entry. The main checkout is never removed, and worktrees with no workspace",
          "config are not touched. NAME is required: a project name, a member workspace name or a path.",
          "",
          "Every worktree is checked before anything is removed. If any has unsaved work (uncommitted",
          "changes to tracked files or unpushed commits), can't be checked, has a checkout that is gone,",
          "or is running the dev environment, nothing is removed and each problem is listed. --force",
          "overrides only a gone checkout or a failed check; unsaved work needs --discard-unsaved. A",
          "running dev environment is never overridden: run 'workspace dev down' first.",
          "",
          "It asks first. --force does not skip the prompt; --yes does. Without a terminal, or with --json, pass --yes",
          "(or --dry-run). If you run this from one of the worktrees, it is removed last.",
          "Exit status: 0 removed, nothing to remove, cancelled or a dry run that would proceed;",
          "1 refused, nothing removed, or a usage error; 3 some removed and some failed.",
          PROJECTS_GROUP
        ],
        options: [["--dry-run", "Run the checks and show what would be removed; remove nothing"],
          ["--yes", "Don't ask for confirmation (every check still runs)"],
          ["--force", "Let worktrees whose checkout is gone or that git can't check past preflight (kill still re-checks for unsaved work, so an unknown one can fail)"],
          ["--discard-unsaved", "Also remove worktrees that have unsaved work, losing it"],
          ["--timeout DURATION", "Time all the unsaved-work checks may take together, e.g. 10 or 30s (default 5s); a worktree not checked in time can't be checked"],
          ["--json", "Print one schema-versioned result object (see docs/README.projects.md); needs --yes or --dry-run"]],
        examples: [
          ["workspace projects kill app", "once the work has landed: remove every worktree workspace of app, sessions and worktrees included, after one confirmation; the main checkout stays"],
          ["workspace projects kill app --dry-run", "run every check and show what would be removed or what refuses, removing nothing"],
          ["workspace projects kill app --yes --json", "for a script or without a terminal: no prompt, one result object"],
          ["workspace projects kill ~/src/app --force --yes", "also remove worktrees whose checkout is gone or that git could not check; unsaved work still refuses"],
          ["workspace projects kill app --discard-unsaved --yes", "remove worktrees that have unsaved work too, losing their uncommitted changes and unpushed commits"]
        ]
      }
    }.freeze

    GROUP_JSON = ["--json", "Print schema-versioned JSON (see docs/README.projects.md)"].freeze

    GROUPS = {
      "create" => {
        usage: ["projects group create NAME [--json]"],
        summary: "Make an empty group of repositories",
        about: [
          "Its id is group:<slug> (the slug is NAME in lowercase with dashes). The group is a file at",
          "~/.config/workspace/groups/<slug>.yml that you may edit by hand. A name with no letter or digit,",
          "or a slug that already has a file, exits 1 with an error; --json prints the code (invalid_group_name,",
          "group_exists)."
        ],
        options: [GROUP_JSON],
        examples: [
          ["workspace projects group create Billing", "start a group for repositories that belong together; this writes groups/billing.yml with no repositories yet"],
          ["workspace projects group create \"Payments Platform\"", "a name with spaces gets the slug payments-platform, so its id is group:payments-platform"],
          ["workspace projects group create Billing --json", "for a script: one document with the group's id and the path of its file"]
        ]
      },
      "add" => {
        usage: ["projects group add GROUP PATH [--json]"],
        summary: "Add the repository containing PATH to a group",
        about: [
          "PATH is a main checkout or a worktree. GROUP is an id, a slug or a name. A repository in another",
          "group is refused; adding it again to the same group does nothing. Each repository is kept by the",
          "realpath of its git common dir, so a moved checkout stays in its group. Rewrites the group's file."
        ],
        options: [GROUP_JSON],
        examples: [
          ["workspace projects group add billing ~/src/api", "put the api repository in the billing group (a worktree of it works too)"],
          ["workspace projects group add group:billing ~/src/web", "the group by its id instead of its slug"],
          ["workspace projects group add billing ~/src/api --json", "for a script: outcome is added, or already_member when it was in the group already"]
        ]
      },
      "list" => {
        usage: ["projects group list [--json]"],
        summary: "List every group with its repositories",
        about: [
          "A repository that is gone reads exists: false. A group file that can't be read is named in",
          "\"warnings\" (--json) or on stderr. Changes nothing."
        ],
        options: [GROUP_JSON],
        examples: [
          ["workspace projects group list", "see which repositories belong to which group before adding another"],
          ["workspace projects group list --json", "for a script: every group with its repositories, and a warning for each file that could not be read"],
          ["workspace projects group list 2>/dev/null", "hide the stderr warnings about group files that could not be read, and keep the table"]
        ]
      },
      "show" => {
        usage: ["projects group show GROUP [--json] [--no-agents] [--no-git] [--timeout SECONDS]"],
        summary: "Show each repository of a group as 'projects show' shows it",
        about: [
          "GROUP is an id, a slug or a name. A repository whose directory is gone, or that has no workspace",
          "config, is listed without a project. Changes nothing."
        ],
        options: [["--no-agents", "Skip the agent daemons (no sockets are read)"],
          ["--no-git", "Skip git (no branch or unsaved work, no unconfigured worktrees)"],
          ["--timeout SECONDS", "How long to wait for each agent daemon (default 1) and for all the git reads (default 5)"],
          GROUP_JSON],
        examples: [
          ["workspace projects group show billing", "see the state of every repository in the billing group in one place"],
          ["workspace projects group show billing --no-agents --no-git", "the fastest read, when only sessions and locks matter"],
          ["workspace projects group show billing --json", "for a script: one document with a projects show document for each repository"]
        ]
      }
    }.freeze

    # The overview's verb list, one line per verb. Defined here, not with the other readers below, because
    # the bare `config` page (the `show` page) lists its own table's verbs while that table is built.
    #
    # @param table [Hash]
    # @return [Array<String>]
    def self.overview_verbs(table)
      shown = table.reject { |_, page| page[:hidden] }
      width = shown.keys.map(&:length).max
      shown.map { |key, page| "  #{key.ljust(width)}  #{page[:summary]}" }
    end

    CONFIG_PAGES = {
      "show" => {
        usage: ["config show [--scope SCOPE | --global] [--name NAME] [--json] [KEY]"],
        summary: "Show project or global workspace configuration",
        about: [
          "Read-only. `workspace config` alone is the same as `config show`. With no key, text mode prints the",
          "config file of the workspace (its path, then its YAML); --json gives every key with its effective value,",
          "source layer and files.",
          "",
          "With a key, prints that key's effective value (layering and defaults included, unlike `workspace",
          "config get`, which reads one file). A key with no value prints a note on stderr and exits 1. A sensitive",
          "key (dev.up, dev.ready, alerts.notify, ...) prints only whether it is set, never its value.",
          "",
          "With --scope, shows one layer: the file of that scope (text) or, in --json, each row's",
          "value/source_file/line/column from that file alone, with effective, source and layers covering global",
          "up to that scope (project: global < project).",
          "",
          "Config files: global is ~/.config/workspace/config.yml, project is ~/.config/workspace/projects/<name>.yml.",
          "Layers, highest wins: workspace (a worktree's own file) > project (the main checkout's file) > global >",
          "the built-in default. `workspace config keys` describes each key; docs/README.config.md has the table.",
          "Hooks and layouts are edited by hand (`config edit`).",
          "",
          "Verbs (`workspace config VERB --help` for each):",
          :verbs,
          "",
          "The verb names are reserved as the first argument, so a key or workspace named like one is reached with",
          "--name."
        ],
        options: [["--scope SCOPE", "Show one layer: global, project or workspace (worktree is the same). In a main checkout workspace is the project's file"],
          ["--global", "Same as --scope global"],
          name_opt("Workspace to show instead of the one inferred from cwd"),
          ["--json", "Print the show document as JSON: every key with its effective value, source layer and files, or with a key just that key's row (see docs/README.config.md)"]],
        examples: [
          ["workspace config show", "print the config file of the workspace you are in, to see what it sets (`workspace config` is the same)"],
          ["workspace config show dev.ready_timeout", "see how long `dev up` really waits, from whichever layer sets it or the default"],
          ["workspace config show notes.dir", "find where this workspace's notes go"],
          ["workspace config show --global", "print the machine-wide config file"],
          ["workspace config show --name myproject", "look at another workspace's file from any directory"],
          ["workspace config show --scope project --name myapp.worktree-fix", "see the project file a worktree inherits, not the worktree's own"],
          ["workspace config show --json", "read every key with its value and source layer in a script"],
          ["workspace config show handoff.auto --json", "read one key's row of the show document"],
          ["workspace config show --scope project --json dev.ready_timeout", "see what the project file has for a key and what resolves up to it"]
        ]
      },
      "set" => {
        usage: ["config set [--scope SCOPE] [--name WS] [--json] [WS] KEY [--] VALUE"],
        summary: "Set a config key in one layer's file",
        about: [
          "Writes for real. With no --scope the highest layer the key allows at or below the workspace is written:",
          "the workspace's own file for a key a worktree may override (dev.ready_timeout, notes.dir), else the",
          "project's file, and the global file for a global-only key. The workspace is inferred from cwd; WS or",
          "--name picks it from anywhere. Outside any workspace a project or workspace write fails with",
          "not_in_workspace (a global key still works). `workspace config show --json` lists the layers each key",
          "allows (overridable_in).",
          "",
          "Allowed keys are the ones `workspace config keys --settable` lists; any other key fails with",
          "unknown_config_key, and a bad value is refused before anything is written.",
          "",
          "This rewrites the whole YAML file, so comments already in it are not kept. The old file is copied to a",
          ".workspace-backup-* file first; when it had a comment, a note on stderr names the backup and the --json",
          "row has comments_preserved: false. A file that isn't valid YAML is left untouched and the command fails.",
          "",
          "Precedence: workspace > project > global > default. Global is the machine-wide file, project is the main",
          "checkout's file and workspace is the workspace's own file; in a main checkout workspace writes the",
          "project file. The --json row reports scope, layer (global, project or worktree), file and the key's",
          "effective value after the write. statusline.command, context.source, context.pattern and",
          "launch.headless are global (one per machine), not per project.",
          "",
          "A value that starts with a dash goes after --:  workspace config set dev.up -- -x"
        ],
        options: [["--name NAME, --project NAME", "Workspace to configure instead of the one inferred from cwd (--name is the same)"],
          ["--scope SCOPE", "Layer to write: global, project or workspace (worktree is the same). A key that doesn't allow it fails with code scope_not_allowed"],
          ["--json", "Print one action document (see docs/README.json.md) instead of text, which goes to stderr"]],
        examples: [
          ["workspace config set dev.up \"./start-dev\"", "tell the workspace you are in how to start its dev environment"],
          ["workspace config set --scope project handoff.auto true", "turn on automatic handoff for the whole project, worktrees included"],
          ["workspace config set --scope workspace dev.ready_timeout 90s", "give this worktree its own wait for the dev readiness check"],
          ["workspace config set dev.stop_timeout 20s", "let a stopping dev environment have 20 seconds before it is force-stopped"],
          ["workspace config set locks.idle_grace 10m", "let an idle agent keep a lock for 10 minutes before a waiter takes it over"],
          ["workspace config set alerts.notify 'say \"$WORKSPACE_ALERT_TEXT\"'", "speak an alert when an agent pane starts waiting or sits idle"],
          ["workspace config set notes.dir /Users/me/notes/myapp-fix --name myapp.worktree-fix", "keep one worktree's notes outside its repository"],
          ["workspace config set myapp dev.up \"bin/dev\"", "configure a workspace from any directory by naming it first"],
          ["workspace config set --scope global launch.headless true", "run launch, start and doctor headless on this machine"],
          ["workspace config set --json handoff.auto false", "change a key from a script and read the layer, file and effective value as JSON"]
        ]
      },
      "get" => {
        usage: ["config get [--scope SCOPE] [--name WS] [WS] KEY"],
        summary: "Read a config key from one layer's file",
        about: [
          "Reads one layer's file, not the layered result (`workspace config KEY` gives that). With no --scope it",
          "reads the file `config set` would write: the workspace's own for a key a worktree may override, else the",
          "project's, else the global file. The workspace is WS or --name, else the one cwd is in; outside any",
          "workspace a project or workspace file read fails with not_in_workspace. When the key is unset there but",
          "another layer sets it, a note on stderr says what the layered result resolves to, or where a sensitive",
          "key is set.",
          "",
          "Prints the value on stdout and exits 0. If the key has no value, prints nothing on stdout, a note on",
          "stderr, and exits 1. Read-only."
        ],
        options: [["--name NAME, --project NAME", "Workspace to read instead of the one inferred from cwd (--name is the same)"],
          ["--scope SCOPE", "Layer whose file to read: global, project or workspace (worktree is the same); scope_not_allowed when the key can't live there"]],
        examples: [
          ["workspace config get dev.up", "read the command this workspace's file stores for starting its dev environment"],
          ["workspace config get --scope project handoff.auto --name myapp.worktree-fix", "read what the project file says for a worktree, ignoring the worktree's own file"],
          ["workspace config get myapp dev.up", "read from any directory by naming the workspace first"],
          ["workspace config get --scope project locks.idle_grace", "check whether the project file sets it: no output and exit 1 when it does not"]
        ]
      },
      "unset" => {
        usage: ["config unset [--scope SCOPE] [--name WS] [--json] [WS] KEY"],
        summary: "Remove a config key from one layer's file",
        about: [
          "Writes for real. Removes a key from one layer's file (the one `config set` would write, unless --scope",
          "names another). The layers below it then apply again. Like `set`, it rewrites the file, keeps a",
          ".workspace-backup-* copy and drops comments. A key that was not set there changes nothing (outcome",
          "noop in --json). The workspace is WS or --name, else the one cwd is in (not_in_workspace outside any)."
        ],
        options: [["--name NAME, --project NAME", "Workspace to configure instead of the one inferred from cwd (--name is the same)"],
          ["--scope SCOPE", "Layer to remove it from: global, project or workspace (worktree is the same); scope_not_allowed when the key can't live there"],
          ["--json", "Print one action document (see docs/README.json.md) instead of text, which goes to stderr"]],
        examples: [
          ["workspace config unset dev.ready", "drop the readiness probe from the file `config set` would write"],
          ["workspace config unset --scope workspace dev.ready_timeout --name myapp.worktree-fix --json", "give a worktree back the project's wait, and read the outcome as JSON"],
          ["workspace config unset myapp dev.ready", "unset from any directory by naming the workspace first"],
          ["workspace config unset --scope global launch.headless", "let launch, start and doctor choose headless by themselves again"]
        ]
      },
      "edit" => {
        usage: ["config edit [--scope SCOPE] [--name WS] [--json] [WS]"],
        summary: "Open one layer's config file in your editor",
        about: [
          "Opens one layer's config file in $VISUAL or $EDITOR (run without a shell, so the command is split into",
          "words and the path is passed as its last argument). A file that doesn't exist yet is created first with a",
          "comment header. With no --scope the workspace's own file is opened (the project's file in a main",
          "checkout). The workspace is WS or --name, else the one cwd is in; outside any workspace only --scope",
          "global works (not_in_workspace otherwise).",
          "",
          "Unlike `config set`, editing by hand keeps comments, but nothing checks the keys or values; run",
          "`workspace config validate` afterwards.",
          "",
          "An editor path containing spaces must be quoted in $EDITOR. With no $VISUAL or $EDITOR set (or blank),",
          "under --no-input, or when stdin or stdout is not a terminal, the path is printed, nothing is opened and",
          "the exit is 0. With --json nothing is opened either: one action document gives the path. Every form,",
          "--json and the printed path included, first creates a missing file (`created: true` in the JSON)."
        ],
        options: [["--name NAME, --project NAME", "Workspace to edit instead of the one inferred from cwd (--name is the same)"],
          ["--scope SCOPE", "File to edit: global, project or workspace (worktree is the same)"],
          ["--json", "Print one action document (see docs/README.json.md); open no editor"]],
        examples: [
          ["workspace config edit", "hand-edit the workspace's own config file, keeping its comments"],
          ["workspace config edit --scope global", "hand-edit the machine-wide file, for hooks or layouts that `config set` cannot write"],
          ["workspace config edit --scope project --name myapp.worktree-fix --json", "get the path of a worktree's project file as JSON, for a script (no editor opens; a missing file is created)"],
          ["workspace config edit myapp.worktree-fix", "edit another workspace's file by naming it first"],
          ["EDITOR=cat workspace config edit --scope global", "on a terminal, show the global file with cat instead of opening an editor (VISUAL wins if set; off a terminal only the path prints)"]
        ]
      },
      "keys" => {
        usage: ["config keys [QUERY] [--settable] [--json]"],
        summary: "Describe the config keys",
        about: [
          "Describes the config keys: type, default, the layers that may hold each, whether `config set` accepts it,",
          "when a change applies, and example values. Reads no config file and prints no stored value (see",
          "`workspace config` for those).",
          "",
          "With no QUERY, lists every key on one line. A QUERY equal to a key name prints that key in full. Any",
          "other QUERY keeps the keys whose name or description text contains it as a substring, ignoring case;",
          "with no match it fails with unknown_config_key."
        ],
        options: [["--settable", "Only the keys `config set` accepts"],
          ["--json", "Print one document with a `keys` array (see docs/README.config.md)"]],
        examples: [
          ["workspace config keys", "list every key, one line each"],
          ["workspace config keys timeout", "find the keys whose name or description mentions timeout"],
          ["workspace config keys dev.up", "read one key in full, with example values"],
          ["workspace config keys --settable --json", "list the keys `config set` accepts as JSON, for a script or completion"]
        ]
      },
      "validate" => {
        usage: ["config validate [--name WS] [--json]"],
        summary: "Check the config files a workspace reads",
        about: [
          "Read-only. Checks the config files a workspace reads (its own, its parent project's when it is a",
          "worktree, and the global one): YAML syntax, key types and values, and keys nothing reads. A file that",
          "can't be parsed is reported with its line and column rather than failing the command. Exits 0 when there",
          "are no errors, 1 otherwise; warnings and notes don't change the exit status."
        ],
        options: [["--name NAME, --project NAME", "Workspace to check instead of the one inferred from cwd"],
          ["--json", "Print one document with a `valid` flag and the problems (see docs/README.config.md)"]],
        examples: [
          ["workspace config validate", "check the workspace you are in after a hand edit; exits 1 when a file has an error"],
          ["workspace config validate --name myproject", "check another workspace's files from any directory"],
          ["workspace config validate --name myproject.worktree-PROJ-123 --json", "read the problems of a worktree, with line and column, as JSON"]
        ]
      }
    }.freeze

    # CONFIG_PAGES with the :verbs marker in the bare page's about replaced by the verb list.
    CONFIG = CONFIG_PAGES.merge(
      "show" => CONFIG_PAGES.fetch("show").merge(
        about: CONFIG_PAGES.fetch("show")[:about].flat_map { |line| (line == :verbs) ? overview_verbs(CONFIG_PAGES) : [line] }.freeze
      ).freeze
    ).freeze

    LAYOUT_NAME_OPT = ["--name WS", "The project, instead of the current directory's; then give only NAME. One argument is always the layout name"].freeze
    LAYOUT_OUTSIDE = "Outside a workspace it is a usage error unless you give --name or PROJECT NAME.".freeze

    LAYOUT = {
      "save" => {
        usage: ["layout save [--name WS] [NAME]", "layout save PROJECT NAME"],
        summary: "Save the project's current tmux pane layout under NAME (default: 'default')",
        about: ["The project's tmux session must be running. A layout saved under an existing name is replaced.", LAYOUT_OUTSIDE],
        options: [LAYOUT_NAME_OPT],
        examples: [
          ["workspace layout save", "save the current directory's project as 'default'"],
          ["workspace layout save coding", "save the current directory's project as 'coding'"],
          ["workspace layout save --name myproject", "save a named project as 'default'"],
          ["workspace layout save myproject coding", "PROJECT NAME: save a named project as 'coding'"]
        ]
      },
      "restore" => {
        usage: ["layout restore [--name WS] [NAME]", "layout restore PROJECT NAME"],
        summary: "Apply a saved tmux pane layout to the project's running session (default NAME: 'default')",
        about: ["`workspace resize` saves the layout it found as '_before_resize'.", LAYOUT_OUTSIDE],
        options: [LAYOUT_NAME_OPT],
        examples: [
          ["workspace layout restore", "restore 'default' for the current directory's project"],
          ["workspace layout restore coding", "restore 'coding' for the current directory's project"],
          ["workspace layout restore --name myproject", "restore 'default' for a named project"],
          ["workspace layout restore --name myproject _before_resize", "undo the last resize"],
          ["workspace layout restore myproject coding", "PROJECT NAME: restore 'coding' for a named project"]
        ]
      },
      "list" => {
        usage: ["layout list [--name WS | PROJECT]"],
        summary: "List the names of the project's saved layouts",
        about: ["'_before_resize' is listed once a resize has run.", "Outside a workspace it is a usage error unless you give PROJECT or --name."],
        options: [["--name WS", "The project, instead of PROJECT or the current directory's"]],
        examples: [
          ["workspace layout list", "layouts saved for the current directory's project"],
          ["workspace layout list myproject", "layouts saved for a named project"],
          ["workspace layout list --name myproject", "the same, named with --name"]
        ]
      }
    }.freeze

    ASK_WS = "WS is a workspace name; without it (or --name) the workspace of the current directory is used.".freeze
    ASK_JSON = ["--json", "Print the documented JSON document instead of a message"].freeze

    ASK = {
      "list" => {
        usage: ["ask list [WS] [--all] [--json]"],
        summary: "Show the open questions of a workspace",
        about: [ASK_WS, "Without --all only open questions are shown; a workspace with none prints a line saying so."],
        options: [NAME_OPT, ["--all", "Also list answered and withdrawn questions, with their status"], ASK_JSON],
        examples: [
          ["workspace ask list", "open questions of the workspace of the current directory"],
          ["workspace ask list myapp", "another workspace's open questions"],
          ["workspace ask list --all", "answered and withdrawn questions too, with a STATUS column"],
          ["workspace ask list --json", "one JSON document, for a script"]
        ]
      },
      "answer" => {
        usage: ["ask answer [WS] ID \"ANSWER\" [--deliver] [--json]"],
        summary: "Answer an open question (alias: resolve)",
        about: [
          ASK_WS,
          "The answer is saved on the question, which then leaves the open list; a question already answered",
          "or withdrawn is refused (exit 1). End options with -- to give an answer that starts with a dash."
        ],
        options: [NAME_OPT,
          ["--deliver", "Also type the answer and Enter into the pane that asked (it must be a pane of this workspace's tmux session; the question must have been asked from tmux)"],
          ASK_JSON],
        examples: [
          ["workspace ask answer a1b2c3 \"Use postgres instead\"", "answer a question of this workspace"],
          ["workspace ask answer myapp a1b2c3 \"Use postgres instead\"", "answer a question of another workspace"],
          ["workspace ask answer --deliver a1b2c3 \"yes\"", "also type the answer into the pane that asked"],
          ["workspace ask answer a1b2c3 -- \"-1\"", "an answer that starts with a dash"],
          ["workspace ask answer a1b2c3 \"yes\" --json", "print the answered question as JSON"]
        ]
      },
      "deliver" => {
        usage: ["ask deliver [WS] ID [--pane PANE] [--json]"],
        summary: "Type an answered question's answer, then Enter, into its pane again",
        about: [
          ASK_WS,
          "The retry for when `ask answer --deliver` saved the answer but could not type it. Nothing is saved;",
          "the pane is typed into for real, so check it first: the answer goes in again even if the first try landed.",
          "A question that is still open or withdrawn has no answer to deliver (exit 1)."
        ],
        options: [NAME_OPT,
          ["--pane PANE", "Type into this pane (an id such as %19, or window.pane) of the workspace's own session instead of the pane that asked"],
          ASK_JSON],
        examples: [
          ["workspace ask deliver a1b2c3", "retype the answer into the pane that asked"],
          ["workspace ask deliver myapp a1b2c3", "the same for another workspace's question"],
          ["workspace ask deliver a1b2c3 --pane %19", "type it into another pane of the workspace's session"],
          ["workspace ask deliver a1b2c3 --json", "print the question and the pane typed into as JSON"]
        ]
      },
      "withdraw" => {
        usage: ["ask withdraw [WS] ID [--json]"],
        summary: "Close an open question nobody needs answered any more",
        about: [
          ASK_WS,
          "The question is marked withdrawn: it leaves `ask list` and the inbox and can't be answered. Only an",
          "open question can be withdrawn (exit 1 otherwise)."
        ],
        options: [NAME_OPT, ASK_JSON],
        examples: [
          ["workspace ask withdraw a1b2c3", "the asker no longer needs an answer"],
          ["workspace ask withdraw myapp a1b2c3", "withdraw a question of another workspace"],
          ["workspace ask withdraw a1b2c3 --json", "print the withdrawn question as JSON"]
        ]
      }
    }.freeze

    INBOX_SCOPE = [
      ["--name NAME", "The workspace NAME instead of the one detected from the current directory"],
      ["--project NAME", "The project NAME (or a path in it): the list its worktrees share"],
      ["--global", "The global list"]
    ].freeze
    INBOX_JSON = ["--json", "Print one JSON document (see docs/README.inbox.md) instead of text, which goes to stderr"].freeze
    INBOX_WRITES = "It changes the inbox for real.".freeze
    INBOX_LINKS = [
      ["--link-pane PANE", "A tmux pane the item is about"],
      ["--link-plan-task ID", "A plan task id"],
      ["--link-pr N", "A pull request number"],
      ["--link-run ID", "A workflow run id"]
    ].freeze

    INBOX = {
      "add" => {
        usage: ["inbox add TITLE [--type TYPE] [--body TEXT | --body-file PATH|-] [options] [--name WS | --project NAME | --global] [--json]",
          "inbox add --from-json PATH|- [--json]"],
        summary: "Add an item to the inbox",
        about: [
          "Adds a todo unless --type says otherwise, to the workspace of the current directory unless a scope",
          "flag picks another list; outside any workspace that fails with not_in_workspace. #{INBOX_WRITES}",
          "Titles and bodies are data, never run; one with a control character is refused.",
          "",
          "--from-json takes the whole item from one JSON object (64 KB at most) and nothing else but --json."
        ],
        options: INBOX_SCOPE + [
          ["--type TYPE", "todo (default), alert, note or review_request"],
          ["--body TEXT", "Longer text, up to 8192 characters"],
          ["--body-file PATH", "Read the body from PATH, or - for stdin (64 KB at most)"],
          ["--source-kind KIND", "jira, github_pr, github_check, session, agent, cli or user"],
          ["--source-ref REF", "A reference in that source (200 characters at most)"],
          ["--source-url URL", "An https:// URL"],
          ["--dedupe-key KEY", "Add once per key and scope: an open or snoozed item with it is updated, a resolved one is left alone"],
          ["--reopen", "With --dedupe-key, reopen a resolved item instead of leaving it"],
          ["--note REL", "A Markdown note that exists in the workspace's notes directory (needs a workspace scope)"],
          ["--expires WHEN", "A duration (2h) or an ISO 8601 time; after it the item counts as dismissed"],
          *INBOX_LINKS,
          ["--as-user", "Record the item as made by a person"],
          ["--from-json PATH", "Read the whole item from a JSON object in PATH, or - for stdin"],
          INBOX_JSON
        ],
        examples: [
          ["workspace inbox add \"Check the deploy\"", "a to-do on this workspace's list"],
          ["workspace inbox add \"CI failed\" --type alert --global", "an alert on the global list"],
          ["workspace inbox add \"Upgrade Rails\" --project api", "on a project's list, shared by its worktrees"],
          ["workspace inbox add \"Check the deploy\" --body \"Roll back if p95 stays above 2s\" --expires 2h", "with longer text, gone after two hours"],
          ["workspace inbox add \"CI failed\" --type alert --source-kind github_check --source-url https://github.com/org/api/actions/runs/1 --global", "record where it came from"],
          ["workspace inbox add \"Deploy notes ready\" --type note --note deploy.md", "point at a note that exists in the notes directory"],
          ["workspace inbox add \"Review the fix\" --link-pr 412 --link-pane %5", "tie it to a pull request and a pane"],
          ["workspace inbox add \"CI failed\" --dedupe-key github_check:org/api:rspec:9f3c2e1 --global", "add once; a repeat updates the open item"],
          ["workspace inbox add --from-json item.json", "take the whole item from a JSON file (- reads stdin)"],
          ["workspace inbox add \"Check the deploy\" --json", "read the new item's id in a script"]
        ]
      },
      "list" => {
        usage: ["inbox list [--state S[,S]] [--type TYPE] [--all] [--include-derived] [--name WS | --project NAME | --global] [--json]"],
        summary: "List the items of the inbox",
        about: [
          "Without a scope flag: the open items of this workspace, its project and the global list (outside a",
          "workspace, the global list). --all reads every scope that has items, or with --name that workspace, its",
          "project and the global list; --all with --project or --global is refused."
        ],
        options: INBOX_SCOPE + [
          ["--state S[,S]", "open (default), snoozed, done or dismissed; comma-separated"],
          ["--type TYPE", "Only items of this type"],
          ["--all", "Every scope that has items"],
          ["--include-derived", "Add what needs you now, worked out from workspace state and never stored: open questions, waiting agent panes, blocked or stalled plans, workflow gates, stuck locks"],
          ["--json", "Print one JSON document (see docs/README.inbox.md) instead of a table"]
        ],
        examples: [
          ["workspace inbox list", "open items of this workspace, its project and the global list"],
          ["workspace inbox list --state open,snoozed", "snoozed items too"],
          ["workspace inbox list --state done", "items already done"],
          ["workspace inbox list --type alert", "only alerts"],
          ["workspace inbox list --all", "every scope that has items"],
          ["workspace inbox list --all --name api", "workspace api, its project and the global list"],
          ["workspace inbox list --project api", "one project's list alone"],
          ["workspace inbox list --include-derived", "plus what needs you now"],
          ["workspace inbox list --all --include-derived --json", "everything, as one JSON document"]
        ]
      },
      "show" => {
        usage: ["inbox show ID [--name WS | --project NAME | --global] [--json]"],
        summary: "Show one item, in any state",
        about: ["Without a scope flag every scope is searched; an id found in more than one is refused as ambiguous, so pass a scope flag."],
        options: INBOX_SCOPE + [["--json", "Print one JSON document (see docs/README.inbox.md) instead of text"]],
        examples: [
          ["workspace inbox show a1b2c3d4e5", "search every scope for the id"],
          ["workspace inbox show a1b2c3d4e5 --global", "look only in the global list"],
          ["workspace inbox show a1b2c3d4e5 --name api", "look only in workspace api"],
          ["workspace inbox show a1b2c3d4e5 --json", "one JSON document"]
        ]
      },
      "edit" => {
        usage: ["inbox edit ID [--title TEXT] [--body TEXT | --body-file PATH|-] [--expires WHEN | --no-expires] [--link-* VALUE] [--json]"],
        summary: "Change an item's title, body, expiry or links",
        about: [
          "Works on an item in any state and leaves its state as it is. Pass at least one change; values the item",
          "already holds are reported unchanged. An empty value clears a body or a link. #{INBOX_WRITES}"
        ],
        options: INBOX_SCOPE + [
          ["--title TEXT", "A new title"],
          ["--body TEXT", "A new body; an empty one clears it"],
          ["--body-file PATH", "Read the body from PATH, or - for stdin (64 KB at most)"],
          ["--expires WHEN", "A new expiry: a duration (2h) or an ISO 8601 time"],
          ["--no-expires", "Drop the expiry"],
          ["--link-pane PANE", "A tmux pane the item is about; an empty one clears it"],
          ["--link-plan-task ID", "A plan task id; an empty one clears it"],
          ["--link-pr N", "A pull request number; an empty one clears it"],
          ["--link-run ID", "A workflow run id; an empty one clears it"],
          INBOX_JSON
        ],
        examples: [
          ["workspace inbox edit a1b2c3d4e5 --title \"Check the deploy again\"", "rename an item"],
          ["workspace inbox edit a1b2c3d4e5 --body \"Roll back if p95 stays above 2s\"", "replace its body"],
          ["workspace inbox edit a1b2c3d4e5 --body \"\"", "clear the body"],
          ["workspace inbox edit a1b2c3d4e5 --body-file notes.txt --global", "take the body from a file, in the global list"],
          ["workspace inbox edit a1b2c3d4e5 --expires 2h", "expire it in two hours"],
          ["workspace inbox edit a1b2c3d4e5 --no-expires", "keep it until someone resolves it"],
          ["workspace inbox edit a1b2c3d4e5 --link-pr 412", "tie it to a pull request"],
          ["workspace inbox edit a1b2c3d4e5 --link-pr \"\"", "clear that link"],
          ["workspace inbox edit a1b2c3d4e5 --title \"Done soon\" --json", "read the result in a script"]
        ]
      },
      "done" => {
        usage: ["inbox done ID... [--name WS | --project NAME | --global] [--json]", "inbox done --dedupe-key KEY [--name WS | --project NAME | --global] [--json]"],
        summary: "Mark items done",
        about: [
          "One already done is reported unchanged. Each id is searched in every scope unless a scope flag is given;",
          "exits 0 when every id worked, 3 when some failed, 1 when all did. #{INBOX_WRITES}"
        ],
        options: INBOX_SCOPE + [
          ["--dedupe-key KEY", "Resolve the item holding KEY in the scope (the one `add` uses) instead of ids; none is unchanged"],
          INBOX_JSON
        ],
        examples: [
          ["workspace inbox done a1b2c3d4e5", "mark one item done"],
          ["workspace inbox done a1b2c3d4e5 f6a7b8c9d0", "mark several done"],
          ["workspace inbox done a1b2c3d4e5 --name api", "look for the id only in workspace api"],
          ["workspace inbox done --dedupe-key github_check:org/api:rspec:9f3c2e1 --global", "clear the alert a poster added with that key"],
          ["workspace inbox done a1b2c3d4e5 --json", "check in a script which ids worked"]
        ]
      },
      "dismiss" => {
        usage: ["inbox dismiss ID... [--name WS | --project NAME | --global] [--json]", "inbox dismiss --dedupe-key KEY [--name WS | --project NAME | --global] [--json]"],
        summary: "Mark items dismissed (nobody will act on them)",
        about: [
          "One already dismissed is reported unchanged. Each id is searched in every scope unless a scope flag is",
          "given; exits 0 when every id worked, 3 when some failed, 1 when all did. #{INBOX_WRITES}"
        ],
        options: INBOX_SCOPE + [
          ["--dedupe-key KEY", "Resolve the item holding KEY in the scope (the one `add` uses) instead of ids; none is unchanged"],
          INBOX_JSON
        ],
        examples: [
          ["workspace inbox dismiss a1b2c3d4e5", "dismiss one item"],
          ["workspace inbox dismiss a1b2c3d4e5 f6a7b8c9d0", "dismiss several"],
          ["workspace inbox dismiss a1b2c3d4e5 --global", "look for the id only in the global list"],
          ["workspace inbox dismiss --dedupe-key github_check:org/api:rspec:9f3c2e1 --global", "dismiss the alert added with that key"],
          ["workspace inbox dismiss a1b2c3d4e5 --json", "check in a script which ids worked"]
        ]
      },
      "reopen" => {
        usage: ["inbox reopen ID... [--name WS | --project NAME | --global] [--json]"],
        summary: "Move done, dismissed or snoozed items back to open",
        about: [
          "An item already open is reported unchanged. Each id is searched in every scope unless a scope flag is",
          "given; exits 0 when every id worked, 3 when some failed, 1 when all did. #{INBOX_WRITES}"
        ],
        options: INBOX_SCOPE + [INBOX_JSON],
        examples: [
          ["workspace inbox reopen a1b2c3d4e5", "reopen one item"],
          ["workspace inbox reopen a1b2c3d4e5 f6a7b8c9d0", "reopen several"],
          ["workspace inbox reopen a1b2c3d4e5 --name api", "look for the id only in workspace api"],
          ["workspace inbox reopen a1b2c3d4e5 --json", "check in a script which ids worked"]
        ]
      },
      "snooze" => {
        usage: ["inbox snooze ID... (--until ISO | --for DURATION) [--name WS | --project NAME | --global] [--json]"],
        summary: "Hide open items until a time",
        about: [
          "They read open again after it. A done or dismissed item is refused (reopen it first). A derived id (from",
          "`inbox list --include-derived`) is hidden until then, or until it changes; without a scope flag every",
          "workspace and project is read to find it. #{INBOX_WRITES}"
        ],
        options: INBOX_SCOPE + [
          ["--until ISO", "Wake at this ISO 8601 time; it must be in the future"],
          ["--for DURATION", "Wake after this long from now (30m, 2h)"],
          INBOX_JSON
        ],
        examples: [
          ["workspace inbox snooze a1b2c3d4e5 --for 2h", "hide an item for two hours"],
          ["workspace inbox snooze a1b2c3d4e5 f6a7b8c9d0 --for 30m", "hide several"],
          ["workspace inbox snooze a1b2c3d4e5 --until 2099-01-01T09:00:00Z", "wake at a set time (it must be in the future)"],
          ["workspace inbox snooze 'pane:waiting:api.fix:%5' --for 1h", "hide a derived row until then or until it changes"],
          ["workspace inbox snooze a1b2c3d4e5 --for 2h --json", "check in a script which ids worked"]
        ]
      },
      "ack" => {
        usage: ["inbox ack DERIVED_ID... [--name WS | --project NAME | --global] [--json]"],
        summary: "Hide derived rows until they change",
        about: [
          "Derived rows are the ones `inbox list --include-derived` adds; take their ids from there. An acked row",
          "shows again when it changes (a new wait, plan state or lock holder) or after 30 days. A question is",
          "answered, not acked. Without a scope flag every workspace and project is read to find the row.",
          INBOX_WRITES
        ],
        options: INBOX_SCOPE + [INBOX_JSON],
        examples: [
          ["workspace inbox ack plan:blocked:api.fix", "hide one derived row"],
          ["workspace inbox ack plan:blocked:api.fix 'pane:waiting:api.fix:%5'", "hide several"],
          ["workspace inbox ack plan:blocked:api.fix --name api", "read only workspace api to find the row"],
          ["workspace inbox ack plan:blocked:api.fix --json", "check in a script which rows were hidden"]
        ]
      }
    }.freeze

    AGENT_RUN_NAME_OPT = NAME_OPT
    AGENT_RUN_SENDS = "Prints the message, sends it to the workspace's agent daemon and prints the reply. Without --dry-run the message is really sent; with no daemon running it exits 1 with an error.".freeze
    AGENT_RUN_PANE_NOTE = "The pane is a pane id (%19) or window.pane (0.1) of the workspace's own tmux session.".freeze

    AGENT_RUN = {
      "command" => {
        usage: ["agent-run command [--name NAME] [--work-item REF] [--body TEXT] [--dry-run]"],
        summary: "Send a \"command\" message that delivers work to the first pipeline stage",
        about: [AGENT_RUN_SENDS, "A --body that parses as JSON is compacted to one line first.",
          "A reply with ok:false (not_delivered, for one) still exits 0: a script must read the reply."],
        options: [AGENT_RUN_NAME_OPT,
          ["--work-item REF", "Work item reference, e.g. WC-42 (default: a random UUID)"],
          ["--body TEXT", "Text to type into the first pipeline pane (default: \"Begin work.\")"],
          ["--dry-run", "Print the message without sending it"]],
        examples: [
          ["workspace agent-run command --body \"Add OAuth support\"", "send a task to the current directory's workspace, under a generated work item"],
          ["workspace agent-run command --work-item WC-42 --body \"Add OAuth support\"", "send it under a work item reference you choose"],
          ["workspace agent-run command --name myapp --work-item WC-42 --body \"Add OAuth support\" --dry-run", "see the message for a named workspace and send nothing"],
          ["workspace agent-run command --name myapp", "send the default body, \"Begin work.\", from any directory"]
        ]
      },
      "inject" => {
        usage: ["agent-run inject [--name NAME] --work-item REF --body TEXT [--interrupt] [--dry-run]"],
        summary: "Send an \"inject\" message that steers a running work item",
        about: [AGENT_RUN_SENDS, "A --body that parses as JSON is compacted to one line first.",
          "Without --interrupt the text is held for the next stage (the reply is ok:true with queued_for_pane);",
          "it is not typed now. A reply with ok:false (no_active_pipeline, no_next_stage, stale_token) still",
          "exits 0: a script must read the reply."],
        options: [AGENT_RUN_NAME_OPT,
          ["--work-item REF", "Work item reference (required)"],
          ["--body TEXT", "Text to inject into the pane (required)"],
          ["--interrupt", "Interrupt the running stage first (sends Ctrl-C)"],
          ["--dry-run", "Print the message without sending it"]],
        examples: [
          ["workspace agent-run inject --work-item WC-42 --body \"Use Postgres, not SQLite\"", "queue a steer for the next stage of a work item in the current directory's workspace"],
          ["workspace agent-run inject --work-item WC-42 --body \"Stop and pivot to the auth approach\" --interrupt", "stop the running stage first, then redirect"],
          ["workspace agent-run inject --name myapp --work-item WC-42 --body \"Use Postgres, not SQLite\" --dry-run", "see the message for a named workspace and send nothing"]
        ]
      },
      "restart" => {
        usage: ["agent-run restart --pane PANE --prompt TEXT [--name NAME] [--force] [--wait] [--timeout DURATION] [--json]"],
        summary: "Clear the coding agent in one pane and give it a fresh prompt",
        about: [
          "This restarts the pane for real. The agent daemon first waits up to 120s (fixed, not bounded by",
          "--timeout) for the pane to go quiet, types /clear, then waits until the new session's first",
          "status-line render confirms the clear, then types the prompt. --timeout only bounds that confirm",
          "step. A draft in a Claude pane's input box refuses it (pane_busy, reason input_not_empty; Claude's",
          "grey suggestion is not a draft), and so does a running turn (turn_started). A screen that keeps",
          "moving after the agent went idle is accepted once the turn is proven over for 5s, with a warning",
          "that background work may be lost. A sub-agent still running (seen by hooks) when /clear is typed",
          "gets its own warning; a background shell is not detected. Both are warnings only. Without --wait a",
          "refusal shows only in the daemon's log.",
          "If the clear can't be confirmed, the prompt is not typed. An agent can run this on its own",
          "pane and end its turn: the daemon types from outside the pane. Only Claude panes are accepted",
          "(other agents fail with code unsupported_agent). Needs context readings, so `workspace statusline`",
          "must be installed as Claude's statusLine."
        ],
        options: [AGENT_RUN_NAME_OPT,
          ["--pane PANE", "Pane to restart: a pane id (%12), window.pane (0.1), session:window.pane, or a pane index in window 0 (required)"],
          ["--prompt TEXT", "Text typed once /clear is confirmed (required)"],
          ["--force", "Restart even when a pipeline stage is running on the pane"],
          ["--wait", "Wait for the restart to finish and report how it went"],
          ["--timeout DURATION", "Longest wait for context usage to drop after /clear (e.g. \"45s\", or seconds); default 30s, at most 600s"],
          ["--json", "Print the result as JSON; errors as {\"schema_version\":1,\"ok\":false,\"error\":...}"]],
        examples: [
          ["workspace agent-run restart --pane %18 --prompt \"Resume from HANDOFF.md\"", "restart pane %18 of the current directory's workspace; returns once the restart has started"],
          ["workspace agent-run restart --name myapp --pane 0.1 --prompt \"Read HANDOFF.md and follow it.\" --wait", "restart a named workspace's pane and wait for the outcome"],
          ["workspace agent-run restart --pane %18 --prompt \"Resume from HANDOFF.md\" --json", "the result as a JSON document, for a script"],
          ["workspace agent-run restart --pane %18 --prompt \"Resume from HANDOFF.md\" --wait --timeout 45s", "allow 45 seconds for context usage to drop after /clear"],
          ["workspace agent-run restart --pane %18 --prompt \"Start over from HANDOFF.md\" --force", "restart even though a pipeline stage is running on the pane"]
        ]
      },
      "send" => {
        usage: ["agent-run send --pane PANE (--body TEXT | --keys KEYS) [--name NAME] [--no-enter] [--when-idle] [--clear-first] [--interrupt] [--json]"],
        summary: "Type text or tmux keys into one pane of a workspace's tmux session",
        about: [
          "Goes straight through tmux (no agent daemon) unless --when-idle, --clear-first or --interrupt is given.",
          "The pane is always named: a pane id (%19, from `workspace sessions --json`) or window.pane (0.1). It is",
          "checked against the workspace's own tmux session first, so a wrong or stale pane is an error, never a",
          "different pane.",
          "",
          "  --body TEXT  pastes TEXT literally (no key names are interpreted), then presses Enter.",
          "  --keys KEYS  sends tmux key names, never text and never an implicit Enter: add Enter",
          "               yourself (\"Escape\", \"Up Up Enter\", \"C-c\", \"y\"). Anything that isn't a key",
          "               name is refused before the first key is sent.",
          "",
          "  --when-idle  hands --body to the workspace's agent daemon instead: typed now if the agent's",
          "               turn has ended, else queued and typed (paste, then Enter) when it ends, one",
          "               prompt per turn end, in order. Claude Code panes only; a pane waiting on a",
          "               person is refused (pane_waiting), and so is a 9th queued prompt (queue_full).",
          "  --clear-first  types the agent's clear (/clear) first and waits up to 15s for its hooks to report",
          "               the new conversation (SessionStart, source clear), then the text. Claude Code panes",
          "               with hooks only (else clear_unsupported). With --when-idle it waits for the turn to",
          "               end; without, a pane mid-turn, with a draft or with prompts queued is refused",
          "               (pane_busy). Not confirmed: nothing more",
          "               is typed (clear_unconfirmed, exit 75, details.clear_typed).",
          "  --interrupt  with --body, in one call: presses the agent's interrupt key (Escape), waits up to 15s",
          "               for its prompt to come back, then types the text. The agent daemon does all three",
          "               under its delivery lock, so no other writer types in between. Claude Code panes",
          "               only (unsupported_agent, no_interrupt_key); prompt not back in time: not_ready,",
          "               nothing typed. Not with --keys, --no-enter, --when-idle or --clear-first.",
          "",
          "Exit codes: 0 delivered (or, with --when-idle, queued); 1 not delivered (safe to resend), refused or",
          "  bad input, except --when-idle's connection_failed with details.maybe_delivered (check first);",
          "  2 text landed but wasn't confirmed submitted (check the pane before resending);",
          "  75 --clear-first typed the clear but it wasn't confirmed, so the text wasn't typed (check, then retry)."
        ],
        options: [AGENT_RUN_NAME_OPT,
          ["--pane PANE", "Pane id (%19) or window.pane (0.1)  (required)"],
          ["--body TEXT", "Literal text to paste, then Enter"],
          ["--keys KEYS", "Space-separated tmux key names"],
          ["--no-enter", "With --body, paste the text without pressing Enter"],
          ["--when-idle", "With --body, type it once the agent's turn ends (queued by the agent daemon)"],
          ["--clear-first", "With --body, clear the conversation and confirm it before typing (agent daemon)"],
          ["--interrupt", "With --body, interrupt the agent, wait for its prompt, then type (agent daemon)"],
          ["--json", "Print the result as JSON; errors as {\"schema_version\":1,\"ok\":false,\"error\":...}"]],
        examples: [
          ["workspace agent-run send --pane %19 --body \"yes\"", "answer pane %19 of the current directory's workspace and press Enter"],
          ["workspace agent-run send --pane 0.1 --keys \"Up Enter\"", "press keys, not text: Up, then Enter"],
          ["workspace agent-run send --name api --pane %19 --keys Escape --json", "interrupt a named workspace's pane; the result as JSON"],
          ["workspace agent-run send --pane %19 --body \"Fix the typo in\" --no-enter", "leave a draft in the pane without submitting it"],
          ["workspace agent-run send --name api --pane %19 --body \"Now run the specs\" --when-idle --json", "queue the prompt for when the agent's turn ends"],
          ["workspace agent-run send --name api --pane %19 --body \"Start on the docs\" --when-idle --clear-first --json", "queue it, and start from a cleared conversation"],
          ["workspace agent-run send --name api --pane %19 --body \"Stop; do this instead\" --interrupt --json", "interrupt a working agent and redirect it in one call"]
        ]
      },
      "queue" => {
        usage: ["agent-run queue list [--name NAME] [--pane PANE] [--json]", "agent-run queue cancel --id ID [--name NAME] [--json]"],
        summary: "List or cancel the prompts `agent-run send --when-idle` has queued, and see why each waits",
        about: [
          "Both read the queue file directly, so they work with no agent daemon running.",
          "",
          "list    One row per queued prompt: pane_id, position (from 1, within the pane), state",
          "        (queued or delivering), queued_at, clear_first, a 200-character preview and the",
          "        full length, and waiting_reason, waiting_message and waiting_since (null unless the",
          "        pane refused the text at its last try, e.g. input_not_empty for a draft). Rows come",
          "        grouped by pane, the pane with the oldest entry first.",
          "cancel  Removes a queued prompt and answers its full text. See `queue cancel --help`."
        ],
        options: [],
        examples: [
          ["workspace agent-run queue list", "what is queued in the current directory's workspace"],
          ["workspace agent-run queue list --name api --pane %19 --json", "one pane of a named workspace, for a script"],
          ["workspace agent-run queue cancel --id 3f9a2c41d07b5e88", "take a queued prompt back"]
        ]
      },
      "queue list" => {
        usage: ["agent-run queue list [--name NAME] [--pane PANE] [--json]"],
        summary: "List the prompts `agent-run send --when-idle` has queued, per pane",
        about: [
          "Reads the queue file directly, so it works with no agent daemon running. One row per queued",
          "prompt: pane_id, position (from 1, within the pane), state (queued or delivering), queued_at,",
          "clear_first, a 200-character preview and the full length, and waiting_reason, waiting_message and",
          "waiting_since (null unless the pane refused the text at its last try, e.g. input_not_empty for a",
          "draft). Rows come grouped by pane, the pane with the oldest entry first. --pane takes a pane id (%19, matched as given, no tmux call) or window.pane",
          "(0.1, looked up in the workspace's tmux session). Writes nothing."
        ],
        hidden: true,
        options: [AGENT_RUN_NAME_OPT,
          ["--pane PANE", "Only this pane: a pane id (%19) or window.pane (0.1)"],
          ["--json", "Print {\"entries\":[...]} as JSON; errors as {\"schema_version\":1,\"ok\":false,\"error\":...}"]],
        examples: [
          ["workspace agent-run queue list", "what is queued in the current directory's workspace"],
          ["workspace agent-run queue list --name api --pane %19", "only one pane of a named workspace"],
          ["workspace agent-run queue list --name api --json", "every queued prompt of a named workspace, for a script"]
        ]
      },
      "queue cancel" => {
        usage: ["agent-run queue cancel --id ID [--name NAME] [--json]"],
        summary: "Take a queued prompt back and print its text",
        about: [
          "Removes the prompt from the queue file for real, with no agent daemon needed, and records a",
          "prompt_dequeued event. A prompt the daemon has claimed but not started to paste is stopped before",
          "anything is typed. One already being typed, already typed, or unknown is refused as unknown_id",
          "(details.state \"delivering\" when it is being typed). The id is the one `send --when-idle` answered,",
          "or `queue list` shows. Without --name every workspace's queue is searched."
        ],
        hidden: true,
        options: [["--id ID", "The id `send --when-idle` answered  (required)"],
          name_opt("Workspace name (default: look through every workspace's queue)"),
          ["--json", "Print {\"cancelled\":true,\"id\",\"pane_id\",\"text\"} as JSON; errors as {\"schema_version\":1,\"ok\":false,\"error\":...}"]],
        examples: [
          ["workspace agent-run queue cancel --id 3f9a2c41d07b5e88", "take a prompt back, whichever workspace queued it"],
          ["workspace agent-run queue cancel --id 3f9a2c41d07b5e88 --name api", "look only in one workspace's queue"],
          ["workspace agent-run queue cancel --id 3f9a2c41d07b5e88 --json", "the cancelled prompt's text as JSON, for a script"]
        ]
      },
      "examples" => {
        usage: ["agent-run examples"],
        summary: "Print all stock example messages without sending anything",
        about: ["Each example shows the command to run and the JSONL it sends, for the workspace of the current",
          "directory (or \"workspace\" outside one). Takes no options; nothing is sent."],
        options: [],
        examples: [
          ["workspace agent-run examples", "print every stock message"],
          ["workspace agent-run examples | less", "page through them"],
          ["workspace agent-run examples | grep 'Run it:'", "list only the commands to copy"]
        ]
      }
    }.freeze

    HANDOFF_NAME = name_opt("The workspace, as an option (same as the positional NAME; default: the current directory's)")
    HANDOFF_PANE = ["--pane PANE", "tmux pane id ('%19'; \"$TMUX_PANE\" inside the pane), window.pane (1.0), or a pane index in window 0; " \
      "must be a pane of NAME's own tmux session (default: the first Claude Code pane, else the first Codex pane; `workspace sessions NAME` lists panes)"].freeze
    HANDOFF_PROMPT = ["--handoff-prompt TEXT", "Prompt sent verbatim instead of a doc (not with --handoff-doc)"].freeze
    HANDOFF_DEFAULT_DOC = [
      "With neither --handoff-doc nor --handoff-prompt, the doc is the workspace's plan (IMPLEMENTATION_PLAN.md) when its notes",
      "directory has one, else HANDOFF.md there. Needs the workspace's agent daemon (`workspace agentd --ensure`)."
    ].freeze

    HANDOFF = {
      "check" => {
        usage: ["handoff check [NAME] [--name WS] [--pane PANE] [--threshold PCT] [--context-pct N] [--handoff-doc PATH | --handoff-prompt TEXT] [--json]"],
        summary: "Tell a coding agent to save its state once its context usage crosses a threshold",
        about: [
          "Reads one Claude Code or Codex pane's context usage from the agent daemon. Under the threshold it prints the usage and",
          "does nothing. At or over it, it types a save-state prompt into that pane for real: the agent writes the doc, then runs",
          "`workspace handoff new` on itself, which clears its conversation and resumes from the doc.",
          "",
          "NAME defaults to the workspace detected from the current directory.",
          *HANDOFF_DEFAULT_DOC,
          "When the notes directory can't be worked out, the agent picks a path; when it is over the threshold, check makes the",
          "notes directory first.",
          "",
          "A Claude Code pane in hook mode is then watched by its agent daemon: if the agent goes quiet without running",
          "`handoff new`, a follow-up prompt is typed (handoff.followup_interval, handoff.followup_max and",
          "handoff.followup_prompt tune or turn that off). A prompt of your own, a /clear or a paused plan ends the",
          "watch. No watch starts (the result says `watching: false` and why) when the follow-ups are turned off, for a",
          "pane bound to a run or review, when the prompt text is too long, or when the daemon is old or does not",
          "answer; the save-state prompt is sent anyway. See docs/README.handoff.md.",
          "",
          "Exit codes: 0 under the threshold, 1 at or over it (a save-state prompt was sent) or when the run was refused or failed,",
          "2 when context usage can't be determined (nothing was sent)."
        ],
        options: [HANDOFF_NAME, HANDOFF_PANE,
          ["--threshold PCT", "Context usage percent that triggers a handoff, 1-100 (default: handoff.threshold, or 11)"],
          ["--context-pct N", "Skip detection and use this value (0-100); the pane list is still read from the daemon, and the prompt is sent for real when N is at or over the threshold"],
          ["--handoff-doc PATH", "Doc the agent updates and resumes from (default: the plan, else HANDOFF.md, in the notes directory); a relative PATH is relative to the current directory, not the notes directory"],
          HANDOFF_PROMPT,
          ["--json", "Print the result as JSON, with \"next\" (continue, handoff or unknown) and \"doc\""]],
        examples: [
          ["workspace handoff check", "this project's agent: a save-state prompt only if it is over the threshold"],
          ["workspace handoff check myapp --threshold 20", "a named workspace, handing off at 20% instead of the configured threshold"],
          ["workspace handoff check myapp --pane \"$TMUX_PANE\"", "an agent checking its own pane"],
          ["workspace handoff check myapp --handoff-doc \"$(workspace notes dir --name myapp)/HANDOFF.md\"", "name the doc the agent saves its state in"],
          ["workspace handoff check myapp --handoff-prompt \"Continue with the failing specs\"", "resume with this text instead of a doc"],
          ["workspace handoff check myapp --context-pct 5", "use a reading of 5%: under the default threshold, so nothing is sent and it exits 0"],
          ["workspace handoff check myapp --json", "for a script: read \"next\", or the exit code (0, 1 or 2)"]
        ]
      },
      "new" => {
        usage: ["handoff new [NAME] [--name WS] [--pane PANE] [--handoff-doc PATH | --handoff-prompt TEXT] [--wait] [--json]"],
        summary: "Clear a coding agent's conversation and resume it from a doc",
        about: [
          "Clears one Claude Code or Codex pane's conversation and types the resume prompt, the same flow as",
          "`workspace agent-run restart`. It returns once the restart has started; --wait waits for it to finish.",
          "Any conversation not saved in the doc is lost. If /clear is typed but no new conversation shows within 30s,",
          "it stops with clear_not_confirmed and types no resume prompt.",
          "",
          "Without --pane it restarts the first Claude Code pane the daemon lists, else the first Codex pane, which may not be",
          "yours: to restart your own pane, pass --pane \"$TMUX_PANE\".",
          "",
          "Exit codes: 0 the restart started (with --wait, finished), 1 refused or failed. Without --wait, 0 does not mean the",
          "restart worked: a later failure shows only in the agent daemon's log (`workspace daemon log`).",
          "",
          "NAME defaults to the workspace detected from the current directory.",
          *HANDOFF_DEFAULT_DOC,
          "The pane is also bound to the implementation-plan play when the plan is the doc. When the notes directory can't be",
          "worked out, it fails with notes_dir_unresolved: pass --handoff-doc then."
        ],
        options: [HANDOFF_NAME, HANDOFF_PANE,
          ["--handoff-doc PATH", "Doc the agent reads and resumes from (default: the plan, else HANDOFF.md, in the notes directory); a relative PATH is relative to the current directory, not the notes directory, and is passed to the agent as written"],
          HANDOFF_PROMPT,
          ["--wait", "Wait for the restart to finish and report how it went (don't use this from the agent being restarted); without it a refusal (a draft in the input box: pane_busy, input_not_empty) shows only in the daemon's log"],
          ["--json", "Print the result as JSON"]],
        examples: [
          ["workspace handoff new", "restart this project's coding agent in a fresh conversation (it loses the current one, so save its state first); it picks the first Claude Code pane, else Codex, which may not be yours"],
          ["workspace handoff new myapp --pane \"$TMUX_PANE\"", "an agent restarting its own pane"],
          ["workspace handoff new myapp --pane 0.1 --handoff-doc /tmp/myapp-handoff.md", "one pane as window.pane, resuming from this doc"],
          ["workspace handoff new myapp --handoff-prompt \"Continue with the failing specs\"", "resume with this text instead of a doc"],
          ["workspace handoff new myapp --wait", "from outside the pane: wait until the restart has finished"],
          ["workspace handoff new myapp --json", "for a script: the result as JSON"]
        ]
      }
    }.freeze

    LOCK_NAME_OPT = name_opt("Act on this workspace's repository instead of the one detected from the current directory")
    LOCK_JSON_ACTION = ["--json", "Print one action document (see docs/README.json.md) instead of text, which goes to stderr"].freeze
    LOCK_JSON_REPORT = ["--json", "Print the documented JSON (see docs/README.lock.md) instead of text"].freeze

    LOCK = {
      "acquire" => {
        usage: ["lock acquire NAME [--name WS] [--task TEXT] [--wait] [--poll DURATION] [--max-wait DURATION]"],
        summary: "Take a lock, or wait in line for it",
        about: [
          "Takes lock NAME for the calling coding agent, for real. NAME is any label you choose; `edit` is the one",
          "the edit-guard hook enforces, denying other agents' Edit and Write calls while it is held. The hold",
          "lasts until `lock release`, the agent's SessionEnd or the agent process dying. Run it inside an agent's session, which names the holder: from a",
          "plain shell it exits 1 with an error. Locks are shared by every worktree of a repository.",
          "",
          "Without --wait a busy lock exits 1 with an error. With --wait (or --max-wait) it queues and polls until it",
          "is promoted, which can take a long time: run it in the background and read its exit code, not its text.",
          "--max-wait is when to stop polling, not a hard deadline: a promotion at that instant still exits 0.",
          "A holder idle for locks.idle_grace (default 5m) is taken over by the first waiter.",
          "",
          "Exit codes:",
          "  0   acquired",
          "  1   held by someone else (no --wait), or the agent could not be identified",
          "  4   cleared by someone else while waiting",
          "  5   this agent already holds or waits for a different lock (release it first)",
          "  75  gave up after --max-wait; no longer queued, run it again to queue",
          "  130 interrupted by SIGINT while waiting; the wait is withdrawn",
          "  143 interrupted by SIGTERM while waiting; the wait is withdrawn"
        ],
        options: [LOCK_NAME_OPT,
          ["--task TEXT", "Free-text description shown to other waiters"],
          ["--wait", "Queue and poll instead of exiting 1 when busy"],
          ["--poll DURATION", "Time between polls while waiting, e.g. \"5s\" (a plain number is seconds; default: 5)"],
          ["--max-wait DURATION", "Stop waiting after DURATION, e.g. \"9m\" (a plain number is seconds); exits 75; implies --wait"]],
        examples: [
          ["workspace lock acquire edit", "take the edit lock, or exit 1 with an error if another agent holds it"],
          ["workspace lock acquire edit --wait --task \"PROJ-12 fix login\"", "queue behind the holder and show the task to waiters; blocks, so run it in the background"],
          ["workspace lock acquire edit --max-wait 9m", "queue, but give up after 9 minutes with exit 75 (no longer queued; run it again to queue)"],
          ["workspace lock acquire edit --wait --poll 10s", "check the queue every 10 seconds instead of every 5"],
          ["workspace lock acquire edit --name api-fix", "take the lock of the repository that workspace api-fix belongs to"]
        ]
      },
      "release" => {
        usage: ["lock release [NAME | --all] [--name WS] [--json]"],
        summary: "Release a lock this agent holds",
        about: [
          "Gives the lock back, for real, so the first waiter is promoted. Like acquire it runs inside an agent's",
          "session. A lock this agent does not hold is a message and exit 0; release exits 3 when it reports that",
          "this agent's hold was taken over while it was idle. Give NAME or --all, not both."
        ],
        options: [LOCK_NAME_OPT,
          ["--all", "Release every lock this agent holds"],
          LOCK_JSON_ACTION],
        examples: [
          ["workspace lock release edit", "give the edit lock back when the edits are done"],
          ["workspace lock release --all", "give back every lock this agent holds"],
          ["workspace lock release edit --name api-fix", "release in the repository that workspace api-fix belongs to"],
          ["workspace lock release edit --json", "one action document on stdout, for a script"]
        ]
      },
      "status" => {
        usage: ["lock status [NAME] [--name WS] [--json]"],
        summary: "Show who holds each lock and who is queued",
        about: [
          "Read-only: it changes nothing and needs no agent session. A holder whose process is gone is marked",
          "STALE, an idle one IDLE. Every lock of the repository is listed without NAME. Locks are also logged in",
          "locks.jsonl next to locks.json (see docs/README.lock.md)."
        ],
        options: [LOCK_NAME_OPT, LOCK_JSON_REPORT],
        examples: [
          ["workspace lock status", "every lock of this repository, with its holder and queue"],
          ["workspace lock status edit", "only the edit lock; \"edit lock is free\" when no one holds it"],
          ["workspace lock status --json", "holders and queues as JSON, for a script"],
          ["workspace lock status edit --name api-fix", "the edit lock of the repository that workspace api-fix belongs to"]
        ]
      },
      "clear" => {
        usage: ["lock clear [NAME | --all] [--name WS] [--json]"],
        summary: "Force-remove a lock's holder and queue",
        about: [
          "Meant for the person: it removes the holder and every waiter for real, so an agent that holds the lock",
          "loses it. Agents release their own lock instead.",
          "",
          "For devenv it also stops the dev environment's process group (SIGTERM, then SIGKILL after",
          "dev.stop_timeout) and keeps the lock until that group is stopped. Ordinary waiters are removed once the",
          "lock is cleared, but stay queued if a kept devenv holder cannot be stopped; a queued `dev up --force` is",
          "kept either way.",
          "",
          "Exits 0 even when nothing was held. Exits 1 when it keeps the devenv lock because the process group",
          "could not be stopped (owned by another user, or still running after SIGKILL) or because another",
          "`lock clear` is already stopping it; check with `workspace lock status NAME`."
        ],
        options: [LOCK_NAME_OPT,
          ["--all", "Clear every lock in this repository"],
          LOCK_JSON_REPORT],
        examples: [
          ["workspace lock clear edit", "free the edit lock after its holder was lost; its waiters are removed"],
          ["workspace lock clear devenv", "stop the dev environment's processes and free the devenv lock (`dev down` is the normal way)"],
          ["workspace lock clear --all", "reset every lock in this repository"],
          ["workspace lock clear edit --json", "the result of the clear as JSON, for a script"]
        ]
      },
      "instructions" => {
        usage: ["lock instructions [NAME]"],
        summary: "Print the prompt block that tells a coding agent how to use a lock",
        about: [
          "Prints text and nothing else, for pasting into an agent's instructions. NAME defaults to edit. The block",
          "tells the agent to acquire the lock in the background with --wait, wait for \"Acquired\", and release it",
          "when its edits are done."
        ],
        options: [],
        examples: [
          ["workspace lock instructions", "the block for the edit lock, to paste into an agent's instructions"],
          ["workspace lock instructions edit | pbcopy", "copy the edit lock's block to the clipboard"],
          ["workspace lock instructions migrations", "the same block for a lock named migrations"]
        ]
      }
    }.freeze

    DEV_NAME_OPT = name_opt("Same as the WS argument (default: the workspace of the current directory)")
    DEV_JSON_ACTION = LOCK_JSON_ACTION
    DEV_WS = "WS defaults to the current directory's workspace (not_in_workspace outside one)."

    DEV = {
      "up" => {
        usage: ["dev up [WS] [--wait | --queue] [--force] [--no-ready] [--max-wait DURATION] [--json]"],
        summary: "Start this worktree's dev environment in a devenv tmux window",
        about: [
          "Starts the project's dev.up command for real, in a `devenv` window of the workspace's tmux session, then",
          "waits until it runs and dev.ready passes. It needs dev.up set (`workspace config set dev.up \"...\"`) and",
          "a tmux session. One dev environment runs per repository, held by the devenv lock; `up` from the worktree",
          "that already holds it does nothing (exit 0). " + DEV_WS,
          "",
          "When another worktree holds it, plain `up` exits 1. --wait queues behind it and blocks until its turn:",
          "run it in the background, or use --queue and then `dev wait`. --force stops the other worktree's dev",
          "environment for real (SIGTERM, then SIGKILL after dev.stop_timeout) and starts this one.",
          "While a workflow run holds the lock, only the pane bound to that run can start it; --force never takes",
          "the lock from a run.",
          "",
          "Exit codes:",
          "  0   running (or already running for this worktree), or in line with --queue",
          "  1   running for another worktree (without --wait/--force), failed to start, or a --force whose target",
          "      is already being stopped by another `lock clear`, `dev down` or `dev up --force`",
          "  4   the devenv lock was cleared while waiting",
          "  6   the ready check failed (the environment is stopped; the lock is released, or stays with its run)",
          "  75  gave up after --max-wait; the queued wrapper was stopped, so this worktree is no longer in line"
        ],
        options: [DEV_NAME_OPT,
          ["--wait", "Queue behind another worktree's dev environment"],
          ["--queue", "Like --wait but return at once (exit 0) once running or in line; follow with `dev wait`. Not with --force or --max-wait"],
          ["--force, --takeover", "Stop another worktree's dev environment, then start this one (unrelated to `down --force`)"],
          ["--no-ready", "Do not wait for the dev.ready check"],
          ["--max-wait DURATION", "Give up after DURATION, e.g. \"9m\" (a plain number is seconds); exits 75; implies --wait. With --force it limits the wait to get ahead in line"],
          DEV_JSON_ACTION],
        examples: [
          ["workspace dev up", "start this worktree's dev environment and wait until it is ready"],
          ["workspace dev up --queue", "start it, or get in line behind another worktree's, and return at once"],
          ["workspace dev up --max-wait 10m", "wait in line for another worktree's environment, giving up after 10 minutes with exit 75 (the queued wrapper is stopped, so you are no longer in line)"],
          ["workspace dev up --force", "stop another worktree's environment and start this one"],
          ["workspace dev up --no-ready", "return once the process runs, without waiting for dev.ready"],
          ["workspace dev up api-fix --json", "start the environment of workspace api-fix and print one action document"]
        ]
      },
      "down" => {
        usage: ["dev down [WS] [--force] [--json]"],
        summary: "Stop this worktree's dev environment",
        about: [
          "Stops the running dev environment for real: SIGTERM to its process group, SIGKILL after",
          "dev.stop_timeout, and the lock is released. With nothing running it says so and exits 0. " + DEV_WS,
          "",
          "When another worktree holds the lock, `down` refuses with the error code dev_held_by (exit 1) unless",
          "--force is given. A dev environment a workflow run started is stopped too, and the lock stays with the run.",
          "Exits 1 when the process group could not be stopped or another `lock clear`, `dev down` or",
          "`dev up --force` is already stopping it."
        ],
        options: [DEV_NAME_OPT,
          ["--force", "Stop a dev environment another worktree holds, and kill a process group left behind by a dead wrapper"],
          DEV_JSON_ACTION],
        examples: [
          ["workspace dev down", "stop this worktree's dev environment"],
          ["workspace dev down api-fix", "stop the dev environment of workspace api-fix"],
          ["workspace dev down --force", "stop another worktree's environment, or the processes a dead wrapper left behind"],
          ["workspace dev down --json", "stop it and print one action document, for a script"]
        ]
      },
      "status" => {
        usage: ["dev status [WS] [--json]"],
        summary: "Show the dev environment's holder, uptime, pane, readiness and queue",
        about: [
          "Changes nothing, but while the environment runs it runs the dev.ready check to report readiness. " + DEV_WS,
          "It describes the repository's one dev environment, so any workspace of the repository shows the same",
          "holder and queue. The --json document is described in docs/README.dev.md."
        ],
        options: [DEV_NAME_OPT,
          ["--json", "Print the documented JSON (see docs/README.dev.md) instead of text"]],
        examples: [
          ["workspace dev status", "who holds the dev environment, for how long, and who is queued"],
          ["workspace dev status api-fix", "the same, asked for workspace api-fix"],
          ["workspace dev status --json", "holder, readiness and queue as JSON, for a script"]
        ]
      },
      "wait" => {
        usage: ["dev wait [WS] [--no-ready] [--max-wait DURATION] [--json]"],
        summary: "Block until this worktree holds the dev environment and it is ready",
        about: [
          "Follows up `dev up --queue`: this worktree must already hold the devenv lock or be in line for it, or",
          "it exits 4 with a message. Blocks until its turn comes, so run it in the background or give --max-wait.",
          "A --max-wait that passes leaves the worktree queued until `dev leave`. " + DEV_WS,
          "",
          "Exit codes:",
          "  0   this worktree holds the dev environment and it is ready",
          "  1   the queued wrapper exited",
          "  4   the lock was cleared while waiting, or this worktree is not queued",
          "  6   the ready check failed",
          "  75  still queued after --max-wait"
        ],
        options: [DEV_NAME_OPT,
          ["--no-ready", "Do not wait for the dev.ready check"],
          ["--max-wait DURATION", "Give up after DURATION, e.g. \"9m\" (a plain number is seconds); exits 75 and stays queued"],
          DEV_JSON_ACTION],
        examples: [
          ["workspace dev wait", "after `dev up --queue`, block until this worktree runs the environment and it is ready; it blocks, so run it in the background"],
          ["workspace dev wait --max-wait 10m", "give up after 10 minutes with exit 75; the worktree stays in line"],
          ["workspace dev wait --no-ready", "return as soon as this worktree holds the lock"],
          ["workspace dev wait api-fix --json", "wait for workspace api-fix and print one action document"]
        ]
      },
      "leave" => {
        usage: ["dev leave [WS] [--json]"],
        summary: "Take this worktree out of the line for the dev environment",
        about: [
          "Stops this worktree's queued wrapper and closes its tmux window, for real. A worktree that is not in line",
          "is left as it is (exit 0): one that already runs the environment is stopped with `dev down`, not this. " + DEV_WS
        ],
        options: [DEV_NAME_OPT, DEV_JSON_ACTION],
        examples: [
          ["workspace dev leave", "stop waiting after `dev up --queue` or `dev up --wait` and give up the place in line"],
          ["workspace dev leave api-fix", "take workspace api-fix out of the line"],
          ["workspace dev leave --json", "leave and print one action document (left or not_queued)"]
        ]
      },
      "__run" => {
        usage: ["dev __run [--wait]"],
        summary: "Run the dev command under the devenv lock (internal: what `dev up` starts)",
        about: [
          "Internal. `dev up` runs this in the devenv tmux window. Running it yourself starts dev.up for real in this",
          "terminal; without dev.up set it exits 1 with an error. It holds the devenv lock for exactly as long as",
          "the project's dev.up command runs in the foreground of this terminal, then releases it. It must lead its",
          "own process group (start it from `dev up` or an interactive shell). Without --wait, a lock held by",
          "someone else exits 1 with an error. The environment WORKSPACE_DEV_TAKEOVER=1 queues it ahead of everyone",
          "(what `dev up --force` sets). Its exit status is the dev command's."
        ],
        hidden: true,
        options: [["--wait", "Queue for the devenv lock instead of failing when it is held"]],
        examples: [
          ["workspace dev __run", "run the dev command in this terminal, failing if the lock is held"],
          ["workspace dev __run --wait", "queue for the lock, then run (what `dev up --wait` opens)"],
          ["WORKSPACE_DEV_TAKEOVER=1 workspace dev __run --wait", "queue ahead of everyone (what `dev up --force` opens)"]
        ]
      }
    }.freeze

    SKILLS_DRY_RUN = ["--dry-run", "Print what would happen; write nothing"].freeze

    SKILLS = {
      "install" => {
        usage: ["skills install [--install-all] [--dry-run] [--json] [--no-input]"],
        summary: "Link the four workspace skills into your coding agents' skill directories",
        about: [
          "Links the four workspace skills (workspace, workspace-agent-run, workspace-inbox, workspace-lifecycle),",
          "each as a link to its whole directory, into the skills directory of the coding agents found on this",
          "machine (Claude Code ~/.claude/skills, Codex ~/.codex/skills, Pi ~/.pi/agent/skills, OpenCode",
          "~/.config/opencode/skills) and into ~/.agents/skills when it exists.",
          "",
          "It asks once which of the harnesses found to install for; the ones left out are remembered and not",
          "asked again (end of input installs nothing and records nothing). All four skills are linked in a directory, or none: a path",
          "already there that is not our link (a real directory with other content, a file, someone else's link)",
          "is never replaced, it is refused and the mv to clear it is printed. A real directory identical to ours",
          "is moved to the state directory's skill-backups and linked. A re-run refreshes links and says what",
          "changed.",
          "",
          "From a linked git worktree it refuses (skill_source_worktree): run it from the main checkout or a",
          "Homebrew install. Exit status: 0 done or already current; 1 something was refused or failed, no harness",
          "found, or the install has no skills; a usage error exits 1 too. Without --install-all it fails with confirmation_required",
          "under --no-input (or WORKSPACE_NO_INPUT) when it would have to ask."
        ],
        options: [["--install-all", "Every harness found, no question; clears recorded declines"],
          SKILLS_DRY_RUN,
          ["--json", "Print one JSON document (see docs/README.skills.md); questions go to stderr"]],
        examples: [
          ["workspace skills install", "first time on this machine: link the skills for the coding agents found, after asking which to include"],
          ["workspace skills install --install-all --dry-run", "see which links would be made and which paths would be refused for every coding agent found, asking nothing and writing nothing"],
          ["workspace skills install --install-all", "after an update, or to take back an agent you left out before: all of them, no question"],
          ["workspace skills install --install-all --no-input --json", "from a script that cannot answer: no question, one JSON document, exit 1 when a path was refused"]
        ]
      },
      "uninstall" => {
        usage: ["skills uninstall [--dry-run] [--json]"],
        summary: "Remove the links skills install made",
        about: [
          "Removes our links (one of the four names, pointing at a lib/skills/<name> of this tool, dangling ones",
          "too) from every known skills directory. Real directories and other links stay and are reported. It",
          "records no decline, works from a linked worktree and never asks."
        ],
        options: [SKILLS_DRY_RUN, ["--json", "Print one JSON document (see docs/README.skills.md)"]],
        examples: [
          ["workspace skills uninstall --dry-run", "see which links would go, and which paths are not ours and stay, before removing any"],
          ["workspace skills uninstall", "stop offering the skills to your coding agents, such as before removing this tool"],
          ["workspace skills uninstall --json", "for a script: each directory's links and what was left, as one JSON document"]
        ]
      }
    }.freeze

    # The tables by command; the specs and the routing tests read them.
    COMMANDS = {
      "plan" => PLAN, "daemon" => DAEMON, "workflow" => WORKFLOW, "library" => LIBRARY, "spine" => SPINE,
      "binding" => BINDING, "step" => STEP, "review" => REVIEW, "pr" => PR, "ticket" => TICKET, "goal" => GOAL,
      "notes" => NOTES, "instructions" => INSTRUCTIONS, "ui" => UI, "event-log" => EVENT_LOG, "projects" => PROJECTS,
      "projects group" => GROUPS, "config" => CONFIG, "layout" => LAYOUT, "ask" => ASK, "inbox" => INBOX,
      "agent-run" => AGENT_RUN, "handoff" => HANDOFF, "lock" => LOCK, "dev" => DEV, "pipeline" => PIPELINE,
      "skills" => SKILLS
    }.freeze

    # The page for the leading verb words of +args+, longest match first; failing that, the one
    # two-word verb the first word leads (`spine goal` shows `goal set`).
    #
    # @param table [Hash] one of the tables above
    # @param args [Array<String>] the command's arguments
    # @return [Array(String, Hash), nil] the key and page, nil when no verb leads
    def self.lookup(table, args)
      words = args.first(2).take_while { |a| !a.start_with?("-") }
      words.length.downto(1) do |n|
        key = words.first(n).join(" ")
        return [key, table[key]] if table.key?(key)
      end
      # A word that leads exactly one two-word verb (`spine goal` for `goal set`) shows that verb's page.
      return nil if words.empty?
      led = table.keys.select { |key| key.start_with?("#{words.first} ") }
      (led.length == 1) ? [led.first, table[led.first]] : nil
    end

    # The flags of a page that take a value (a metavar, not an optional `[NAME]`), so a
    # literal `--help` after one is its value. Every word of a label counts: `-n, --name NAME`
    # registers both `-n` and `--name`.
    #
    # @param page [Hash]
    # @return [Array<String>]
    def self.value_flags(page)
      page[:options].flat_map do |label, _|
        words = label.split(", ")
        takes_value = words.any? { |w| w.include?(" ") && !w.include?("[") }
        takes_value ? words.map { |w| w.split.first } : []
      end
    end

    # The whole page as text: Usage, the summary, further paragraphs, Options, then Examples last.
    #
    # @param page [Hash]
    # @return [Array<String>] lines without newlines
    def self.render(page)
      lines = usage_lines(page[:usage])
      lines += ["", "#{page[:summary]}."]
      lines += ["", *page[:about]] unless page[:about].empty?
      lines += ["", "Options:"]
      (page[:options] + [["-h, --help", "Show this help"]]).each do |label, text|
        lines << ((label.length > 28) ? "    #{label} #{text}" : "    #{label.ljust(28)} #{text}")
      end
      unless page[:examples].empty?
        lines += ["", "Examples:"]
        page[:examples].each { |command, scenario| lines << "  #{command}#{EXAMPLE_SEPARATOR}#{scenario}" }
      end
      lines
    end

    # The banner of a command's overview: every verb's usage lines.
    #
    # @param table [Hash]
    # @return [String]
    def self.overview_usage(table)
      usage_lines(table.values.reject { |page| page[:hidden] }.flat_map { |page| page[:usage] }).join("\n")
    end

    # The overview's example lines: the first +per_verb+ examples of each verb, written as a verb page writes them.
    #
    # @param table [Hash]
    # @param per_verb [Integer]
    # @return [Array<String>]
    def self.overview_examples(table, per_verb: 1)
      table.reject { |_, page| page[:hidden] }.values.flat_map { |page| page[:examples].first(per_verb) }
        .map { |command, scenario| "  #{command}#{EXAMPLE_SEPARATOR}#{scenario}" }
    end

    def self.usage_lines(usage)
      usage.each_with_index.map { |u, i| "#{i.zero? ? "Usage:" : "      "} workspace #{u}" }
    end
  end
end
