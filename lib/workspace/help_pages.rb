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
        about: ["A workspace with no plan is a row, not an error."],
        options: [NAME_OPT,
          ["--project [NAME]", "Every workspace of a project (NAME, or the project of the current workspace)"],
          ["--all", "Every workspace"],
          ["--group GROUP", "Every workspace of every repository in a group (group:billing, billing or Billing; see projects group list)"],
          ["--file PATH", "Read any file, with no workspace and a state from the file alone"],
          JSON_OPT],
        examples: []
      },
      "path" => {
        usage: ["plan path [--name WORKSPACE] [--json]"],
        summary: "Print where the plan is (or would be)",
        about: [],
        options: [NAME_OPT, JSON_OPT],
        examples: []
      },
      "show" => {
        usage: ["plan show [--name WORKSPACE]"],
        summary: "Print the plan file",
        about: [],
        options: [NAME_OPT],
        examples: []
      },
      "init" => {
        usage: ["plan init [--name WORKSPACE] [--title TITLE] [--from FILE] [--force] [--json]"],
        summary: "Write a new plan, or import an existing document with --from",
        about: [],
        options: [NAME_OPT,
          ["--title TITLE", "The plan's title (default: the workspace task's title)"],
          ["--from FILE", "Import this document as the plan"],
          ["--force", "Replace a plan that is already there"],
          JSON_OPT],
        examples: []
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
        examples: []
      },
      "pause" => {
        usage: ["plan pause [--name WORKSPACE] [--interrupt] [--json]"],
        summary: "Set status: paused; the agent stops before its next task",
        about: ["--interrupt also presses the agent's interrupt key (Escape for Claude Code and Codex) in each owner pane that works."],
        options: [NAME_OPT, ["--interrupt", "Interrupt the owner panes that are working"], JSON_OPT],
        examples: []
      },
      "delete" => {
        usage: ["plan delete [--name WORKSPACE] --yes [--json]"],
        summary: "Rename the plan to IMPLEMENTATION_PLAN.md.deleted-<time>",
        about: ["Needs --yes; the session and worktree stay."],
        options: [NAME_OPT, ["--yes", "Confirm the delete"], JSON_OPT],
        examples: []
      },
      "task add" => {
        usage: ["plan task add --title TEXT [--id ID] [--state STATE] [--reason TEXT] [--phase NAME | --after ID] [--if-revision REV] [--name WORKSPACE] [--json]"],
        summary: "Add one task line to the plan",
        about: ["Blocked and skipped tasks need --reason."],
        options: [NAME_OPT,
          ["--title TITLE", "The new task's title"],
          ["--id ID", "The new task's id (default: the next number after the plan's last id)"],
          ["--state STATE", "The task's state: done, in_progress, skipped, blocked or todo (default: todo)"],
          ["--reason TEXT", "Why a task is blocked or skipped"],
          ["--phase NAME", "The ### heading to add under"],
          ["--after ID", "Place the task after this task"],
          REVISION_OPT,
          JSON_OPT],
        examples: []
      },
      "task set-state" => {
        usage: ["plan task set-state --task ID --state STATE [--reason TEXT] [--if-revision REV] [--name WORKSPACE] [--json]"],
        summary: "Set one task's state",
        about: ["Blocked and skipped tasks need --reason."],
        options: [NAME_OPT,
          ["--task ID", "The task (its id, such as T3)"],
          ["--state STATE", "The new state: done, in_progress, skipped, blocked or todo"],
          ["--reason TEXT", "Why a task is blocked or skipped"],
          REVISION_OPT,
          JSON_OPT],
        examples: []
      },
      "task set-title" => {
        usage: ["plan task set-title --task ID --title TEXT [--if-revision REV] [--name WORKSPACE] [--json]"],
        summary: "Change one task's title",
        about: [],
        options: [NAME_OPT,
          ["--task ID", "The task (its id, such as T3)"],
          ["--title TITLE", "The new title"],
          REVISION_OPT,
          JSON_OPT],
        examples: []
      },
      "task move" => {
        usage: ["plan task move --task ID (--after ID | --before ID | --phase NAME) [--if-revision REV] [--name WORKSPACE] [--json]"],
        summary: "Move one task line",
        about: ["Moves it after or before another task, or to the end of a phase."],
        options: [NAME_OPT,
          ["--task ID", "The task (its id, such as T3)"],
          ["--after ID", "Place the task after this task"],
          ["--before ID", "Place the task before this task"],
          ["--phase NAME", "Move to the end of this phase"],
          REVISION_OPT,
          JSON_OPT],
        examples: []
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
        examples: []
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
        examples: []
      },
      "add" => {
        usage: ["workflow add ID PATH|- [--dry-run] [--json]"],
        summary: "Save a definition as ID.yml",
        about: [
          "Saves a definition (a file, or - for stdin) as ID.yml in ~/.config/workspace/workflows/, after the",
          "checks `workflow validate` makes; refused with workflow_exists when that file is there. A preset of",
          "the same id is left alone and the copy shadows it. A relative prompt_file: is read from that directory."
        ],
        options: [["--dry-run", "Check, and write no definition (the lock file may be created)"], JSON_OPT],
        examples: []
      },
      "update" => {
        usage: ["workflow update ID PATH|- --if-sha256 SHA [--dry-run] [--json]"],
        summary: "Replace your ID.yml if it is unchanged since you read it",
        about: [
          "Replaces your ID.yml (a file, or - for stdin) after the same checks as `workflow add`, only if the",
          "file's raw bytes still hash to --if-sha256 (from `workflow show ID --source`; a broken file can be",
          "replaced). Refused with stale_workflow when it changed, builtin_workflow for a preset with no file",
          "of yours."
        ],
        options: [["--if-sha256 SHA", "The sha256 of the file's raw bytes you read; refuse with stale_workflow unless it still matches"],
          ["--dry-run", "Check, and write no definition (the lock file may be created)"], JSON_OPT],
        examples: []
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
        examples: []
      },
      "run" => {
        usage: ["workflow run ID [--name WORKSPACE] [--input KEY=VALUE]... [--note TEXT] [--pane PANE] [--dry-run] [--json]"],
        summary: "Start a run of a workflow in a workspace",
        about: [
          "A run is an ordered list of steps, each done by the agent in the workspace's Claude pane. --dry-run",
          "checks the inputs, the project's commands and the pane, and starts nothing."
        ],
        options: [name_opt("The workspace to run in (default: detected from the current directory)"),
          ["--input KEY=VALUE", "A value for one of the workflow's inputs (repeatable)"],
          ["--note TEXT", "Added to every step's instructions"],
          PANE_OPT,
          ["--dry-run", "Report what would start and start nothing"], JSON_OPT],
        examples: []
      },
      "start" => {
        usage: ["workflow start ID [REF | --prompt TEXT] [--branch BRANCH] [--slug] [--base REF] [--input KEY=VALUE]... [--note TEXT] [--agent-kind KIND] [--[no-]headless] [--prompt-timeout DURATION] [--dry-run] [--json]"],
        summary: "Make a workspace from a ticket, pull request or prompt and run a workflow in it",
        about: [
          "REF is a JIRA key or URL, a pull request, an issue or a branch. Waits for the workspace's agent, then",
          "runs ID in it. A fork's pull request, or a branch tracking another repository, is refused with",
          "fork_pull_request before anything is made."
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
        examples: []
      },
      "status" => {
        usage: ["workflow status [RUN | --name WORKSPACE | --project [NAME] | --all] [--json]"],
        summary: "Show the runs still going, each with its step and why it is stuck",
        about: [
          RUN_ID + " With RUN, shows that one run.",
          "Without RUN: this workspace's runs still going; --name another workspace's; --project the main checkout and its worktrees, finished runs too; --all every workspace, finished runs too.",
          "",
          "A run that is not moving says why: waiting_lock, waiting_you, turn_ended_incomplete, failed_check or",
          "pane_gone, with the commands that resolve it."
        ],
        options: [name_opt("Only this workspace's runs (default: the current workspace)"), ["--project [NAME]", "All runs of a project, finished too (NAME, or the project of the current workspace)"], ["--all", "Every workspace's runs, finished too"], JSON_OPT],
        examples: []
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
        examples: []
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
        examples: []
      },
      "resume" => {
        usage: ["workflow resume RUN [--from STEP] [--note TEXT] [--pane PANE] [--json]"],
        summary: "Get a run going again",
        about: [
          RUN_ID,
          "",
          "Asks for its lock again, runs a failed or undelivered step again, looks again at a step whose files",
          "were missing, or moves it to the workspace's Claude pane when its own is gone. --from at a waiting",
          "gate is refused from a pane a run is bound to."
        ],
        options: [["--from STEP", "Start again at this step"], WORKFLOW_NOTE, PANE_OPT, JSON_OPT],
        examples: []
      },
      "cancel" => {
        usage: ["workflow cancel RUN [--json]"],
        summary: "End a run and release the locks it holds",
        about: [RUN_ID],
        options: [JSON_OPT],
        examples: []
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
        examples: []
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
        examples: []
      },
      "advance" => {
        hidden: true,
        usage: ["workflow advance RUN [--turn-ended --pane ID [--turn-started AT] [--background-task TYPE:ID]...]"],
        summary: "Move a run on; the agent daemon runs this when a turn ends",
        about: ["It is not meant to be typed. #{RUN_ID}"],
        options: [["--turn-ended", "A turn ended in the run's pane"],
          ["--pane PANE", "The run's pane"],
          ["--turn-started AT", "When that turn began (ISO 8601)"],
          ["--background-task TYPE:ID", "A background task still going when the turn ended (repeatable)"]],
        examples: []
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
        examples: []
      },
      "show" => {
        usage: ["library show REF [--global | --builtin | --project [NAME]] [--json]"],
        summary: "Print a library entry's body",
        about: [
          "REF is kind/name, or a bare name when one kind has it. The body is printed as it is, so you can pass",
          "it on, e.g. workspace start BRANCH --prompt \"$(workspace library show prompt/kickoff)\"."
        ],
        options: [*LIBRARY_SCOPES, JSON_OPT],
        examples: []
      },
      "info" => {
        usage: ["library info REF [--global | --builtin | --project [NAME]] [--json]"],
        summary: "Show a library entry's kind, scope, path, link target, description and modified time",
        about: [
          "REF is kind/name, or a bare name when one kind has it. effective says whether this entry is the one",
          "`library show` prints; it is false when a project entry of the same name hides a global one."
        ],
        options: [*LIBRARY_SCOPES, JSON_OPT],
        examples: []
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
          "plan-spine stage files (a template for 'spine init')."
        ],
        options: [["--kind KIND", "agent, play, prompt, recipe, skill or spine (required)"],
          ["--as NAME", "The entry name (lowercase letters, digits and hyphens)"],
          ["--link", "Store a symlink to PATH instead of a copy"],
          ["--force", "Replace an entry that has different content"],
          ["--project [NAME]", "Add to the project's store (NAME, or the project of the current directory)"],
          LIBRARY_DRY_RUN, JSON_OPT],
        examples: []
      },
      "update" => {
        usage: ["library update REF PATH|- [--link] [--project [NAME]] [--dry-run] [--json]"],
        summary: "Replace a library entry's content, or repoint its link",
        about: ["REF is kind/name, or a bare name when one kind has it."],
        options: [["--link", "Store a symlink to PATH instead of a copy"], LIBRARY_PROJECT, LIBRARY_DRY_RUN, JSON_OPT],
        examples: []
      },
      "remove" => {
        usage: ["library remove REF [--yes] [--project [NAME]] [--dry-run] [--json]"],
        summary: "Delete a library entry or its link",
        about: ["Deletes the entry or its link from the library; the source file is never touched."],
        options: [["--yes", "Don't ask"], LIBRARY_PROJECT, LIBRARY_DRY_RUN, JSON_OPT],
        examples: []
      },
      "install" => {
        usage: ["library install REF [--name WS | --user] [--from global|project] [--force] [--dry-run] [--json]"],
        summary: "Copy a library skill or agent into a workspace's checkout",
        about: [
          "Copies to .claude/skills/NAME/ or .claude/agents/NAME.md unless library.install.skills_dir or",
          "agents_dir says otherwise, as start --skill/--agent does for a new workspace: identical content is",
          "unchanged, different content needs --force, a path the repo tracks is never overwritten; the copy is",
          "listed in info/exclude. --user copies to your home-level directory instead",
          "(library.install.user_skills_dir, user_agents_dir; ~/.claude/... by default)."
        ],
        options: [LIBRARY_WORKSPACE,
          ["--user", "Copy to the user-level directory instead of a workspace"],
          ["--from STORE", "Copy the entry of this store, global or project (default: the project's, else global)"],
          ["--force", "Replace a copy that has different content"],
          LIBRARY_DRY_RUN, JSON_OPT],
        examples: []
      },
      "uninstall" => {
        usage: ["library uninstall REF [--name WS | --user] [--force] [--dry-run] [--json]"],
        summary: "Delete the copy of a library entry that `library install` made",
        about: [
          "Deletes the copy of REF that `library install` made in a workspace's checkout, or with --user from",
          "the home-level directory. A copy that differs from the library entry needs --force; the library entry",
          "and the info/exclude line stay."
        ],
        options: [LIBRARY_WORKSPACE,
          ["--user", "Remove the user-level copy"],
          ["--force", "Remove a copy that differs from the library entry"],
          LIBRARY_DRY_RUN, JSON_OPT],
        examples: []
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
        examples: []
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
        examples: []
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
        examples: []
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
        examples: []
      },
      "verify" => {
        usage: ["spine verify [WORKSPACE] STAGE-PATH (--pass | --fail) --note TEXT [--by LABEL] [--if-revision REV] [--json]"],
        summary: "Record a separate check of a completed stage",
        about: [
          "Writes check (passed with --pass, failed with --fail), checked_by, checked_at and check_note, and no",
          "other line. A stage opts in with a check: line in its file (check: required); 'set --status",
          "completed' then makes it check: pending, and any other status resets it to required. Refuses a stage",
          "that has not opted in (check_not_required) and one that is not completed (stage_not_completed). A",
          "spine_changed event with change check is written."
        ],
        options: [NAME_OPT,
          ["--pass", "The stage passed its check"],
          ["--fail", "The stage failed its check"],
          ["--note TEXT", "The verdict's note, required, 300 characters at most"],
          ["--by LABEL", "The checked_by label (default: the agent and pane id of $TMUX_PANE, else person)"],
          SPINE_IF_REVISION, JSON_OPT],
        examples: []
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
        examples: []
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
        examples: []
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
        examples: []
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
          "binding replaces the whole earlier one, its packs included."
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
        examples: []
      },
      "show" => {
        usage: ["binding show [--pane %ID] [--json]"],
        summary: "Print a pane's binding",
        about: [BINDING_ABOUT, "It is marked stale when the pane is no longer in the tmux session and slot it was bound in; a stale binding is not announced."],
        options: [BINDING_PANE, BINDING_JSON],
        examples: []
      },
      "clear" => {
        usage: ["binding clear [--pane %ID] [--json]"],
        summary: "Remove a pane's binding",
        about: [BINDING_ABOUT],
        options: [BINDING_PANE, BINDING_JSON],
        examples: []
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
        examples: []
      },
      "status" => {
        usage: ["step status [--json]"],
        summary: "Show which workflow run, step and attempt this pane is on",
        about: [
          "Also shows where the step's instructions are, and whether the files the step must leave exist. Run",
          "from the pane the run is bound to."
        ],
        options: [JSON_OPT],
        examples: []
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
        examples: []
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
        examples: []
      }
    }.freeze

    PR = {
      "create" => {
        usage: ["pr create [--name WORKSPACE] [--draft] [--json]"],
        summary: "Open a pull request for a workspace's branch",
        about: [
          "Leaves the workspace alone. When the branch already has a pull request, it is returned and nothing",
          "else happens. Otherwise the branch is pushed to origin if it has no upstream, and 'gh pr create",
          "--fill' runs. Refuses a branch with no commits ahead of its base. Needs 'gh', logged in."
        ],
        options: [name_opt("The workspace (default: the one the current directory is in)"),
          ["--draft", "Open the pull request as a draft"], JSON_OPT],
        examples: []
      },
      "feedback" => {
        usage: ["pr feedback [--name WORKSPACE] [--all] [--json]"],
        summary: "Read the feedback on the branch's pull request",
        about: [
          "Reads unresolved review threads, review summaries, conversation comments and failing checks. It is",
          "read-only. Comment text is written by other people. The text output lists the threads and failing",
          "checks and only counts the reviews and conversation comments (it escapes control characters); --json",
          "carries their bodies, unescaped. Needs 'gh', logged in."
        ],
        options: [name_opt("The workspace (default: the one the current directory is in)"),
          ["--all", "Keep resolved review threads"], JSON_OPT],
        examples: []
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
          "nothing from git."
        ],
        options: [TICKET_NAME, JSON_OPT],
        examples: []
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
        examples: []
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
        examples: []
      },
      "list" => {
        usage: ["goal list [--all] [--json]"],
        summary: "List goals, one line each",
        about: ["Each line has the workspace, state, stage, step and agent state."],
        options: [["--all", "Include workspaces with no plan, run or spine (state none)"], JSON_OPT],
        examples: []
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
          "for the shared dev environment before testing, release it when done) and implementation-plan (keep",
          "the counted task list in IMPLEMENTATION_PLAN.md); `workspace library list --builtin` lists them all.",
          "With no --pack, binding, orchestrator and commits are composed, in that order. Each pack is printed",
          "under a heading that names where it came from.",
          "",
          "Any other library play can be named as a pack too: the project's library is searched, then global.",
          "A play named like a built-in pack never takes its place here; give your own another name.",
          "`workspace library show NAME --builtin` prints a built-in one.",
          "",
          "Two packs get lines for the caller. binding is followed by the binding of --pane when that pane is",
          "bound, and commits by the project's commands.test and commands.lint when they are set (workspace",
          "config set commands.test ...). --pane defaults to $TMUX_PANE, the pane the command runs in, unless",
          "--name is given. Text composed for another pane, as in start --prompt \"$(...)\", would carry this",
          "pane's binding: name the packs and leave binding out, or bind that pane first."
        ],
        options: [["--pack NAME", "A pack to compose (repeatable, composed in the order given)"],
          ["--pane PANE", "Pane id (%19) whose binding follows the binding pack (default $TMUX_PANE without --name)"],
          ["--name WORKSPACE", "Compose for this workspace instead of the current directory"],
          ["--start", "Print what start and launch send with the first prompt, and send nothing: the automatic packs (notes, unless notes.instructions is false) then each --pack"],
          ["--no-packs", "With --start: leave out the automatic packs (cannot be combined with --pack)"],
          JSON_OPT],
        examples: []
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
          "A link only opens a view; it never starts an agent or runs a command. WORKSPACE (or --name)",
          "defaults to the project detected from the current directory. Opening needs the UI app installed,",
          "since it registers the scheme; without it `open` fails, the exit status is 1, and --print still",
          "shows the link."
        ],
        options: [name_opt("Workspace name (every view but inbox)"),
          ["--path REL", "Note to open, relative to the notes directory (notes view only)"],
          ["--print", "Print the link and open nothing"],
          ["--json", "Print one JSON action document (see docs/README.ui.md)"]],
        examples: []
      }
    }.freeze

    PROJECTS = {
      "list" => {
        usage: ["projects list [--running] [--git] [--json]"],
        summary: "List projects, one row each, with their workspaces and how many are running",
        about: ["A project is a repository's main checkout plus its linked git worktrees. `workspace projects` alone lists."],
        options: [["--running", "Only projects with at least one running workspace"],
          ["--git", "Add an UNSAVED column (runs git in every checkout, and counts worktrees with no workspace config)"],
          ["--json", "Print schema-versioned JSON (see docs/README.projects.md)"]],
        examples: []
      }
    }.freeze

    GROUP_JSON = ["--json", "Print schema-versioned JSON (see docs/README.projects.md)"].freeze

    GROUPS = {
      "create" => {
        usage: ["projects group create NAME [--json]"],
        summary: "Make an empty group of repositories",
        about: [
          "Its id is group:<slug> (the slug is NAME in lowercase with dashes). The group is a file at",
          "~/.config/workspace/groups/<slug>.yml that you may edit by hand."
        ],
        options: [GROUP_JSON],
        examples: []
      },
      "add" => {
        usage: ["projects group add GROUP PATH [--json]"],
        summary: "Add the repository containing PATH to a group",
        about: [
          "PATH is a main checkout or a worktree. GROUP is an id, a slug or a name. A repository in another",
          "group is refused; adding it again to the same group does nothing. Each repository is kept by the",
          "realpath of its git common dir, so a moved checkout stays in its group."
        ],
        options: [GROUP_JSON],
        examples: []
      },
      "list" => {
        usage: ["projects group list [--json]"],
        summary: "List every group with its repositories",
        about: [
          "A repository that is gone reads exists: false. A group file that can't be read is named in",
          "\"warnings\" (--json) or on stderr."
        ],
        options: [GROUP_JSON],
        examples: []
      },
      "show" => {
        usage: ["projects group show GROUP [--json] [--no-agents] [--no-git] [--timeout SECONDS]"],
        summary: "Show each repository of a group as 'projects show' shows it",
        about: [],
        options: [["--no-agents", "Skip the agent daemons (no sockets are read)"],
          ["--no-git", "Skip git (no branch or unsaved work, no unconfigured worktrees)"],
          ["--timeout SECONDS", "How long to wait for each agent daemon (default 1) and for all the git reads (default 5)"],
          GROUP_JSON],
        examples: []
      }
    }.freeze

    CONFIG = {
      "show" => {
        usage: ["config show [--scope SCOPE | --global] [--name NAME] [--json] [KEY]"],
        summary: "Show project or global workspace configuration",
        about: [
          "With a key, prints that key's effective value (layering and defaults included, unlike 'workspace",
          "config get', which reads one file).",
          "",
          "With --scope, shows one layer: the file of that scope (text) or, in --json, each row's",
          "value/source_file/line/column from that file alone, with effective, source and layers covering global",
          "up to that scope (project: global < project). `workspace config` alone is the same as show."
        ],
        options: [["--scope SCOPE", "Show one layer: global, project or workspace (worktree is the same). In a main checkout workspace is the project's file"],
          ["--global", "Same as --scope global"],
          name_opt("Workspace to show instead of the one inferred from cwd"),
          ["--json", "Print the show document as JSON: every key with its effective value, source layer and files, or with a key just that key's row (see docs/README.config.md)"]],
        examples: []
      }
    }.freeze

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
          "step. If the clear can't be confirmed, the prompt is not typed. An agent can run this on its own",
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
        summary: "List or cancel the prompts `agent-run send --when-idle` has queued",
        about: [
          "Both read the queue file directly, so they work with no agent daemon running.",
          "",
          "list    One row per queued prompt: pane_id, position (from 1, within the pane), state",
          "        (queued or delivering), queued_at, clear_first, a 200-character preview and the",
          "        full length. Rows come grouped by pane, the pane with the oldest entry first.",
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
          "clear_first, a 200-character preview and the full length. Rows come grouped by pane, the pane with",
          "the oldest entry first. --pane takes a pane id (%19, matched as given, no tmux call) or window.pane",
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
          "Any conversation not saved in the doc is lost.",
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
          ["--wait", "Wait for the restart to finish and report how it went (don't use this from the agent being restarted)"],
          ["--json", "Print the result as JSON"]],
        examples: [
          ["workspace handoff new", "restart the first Claude Code pane (else Codex) of this project, which may not be yours"],
          ["workspace handoff new myapp --pane \"$TMUX_PANE\"", "an agent restarting its own pane"],
          ["workspace handoff new myapp --pane 0.1 --handoff-doc /tmp/myapp-handoff.md", "one pane as window.pane, resuming from this doc"],
          ["workspace handoff new myapp --handoff-prompt \"Continue with the failing specs\"", "resume with this text instead of a doc"],
          ["workspace handoff new myapp --wait", "from outside the pane: wait until the restart has finished"],
          ["workspace handoff new myapp --json", "for a script: the result as JSON"]
        ]
      }
    }.freeze

    # The tables by command; the specs and the routing tests read them.
    COMMANDS = {
      "plan" => PLAN, "daemon" => DAEMON, "workflow" => WORKFLOW, "library" => LIBRARY, "spine" => SPINE,
      "binding" => BINDING, "step" => STEP, "review" => REVIEW, "pr" => PR, "ticket" => TICKET, "goal" => GOAL,
      "notes" => NOTES, "instructions" => INSTRUCTIONS, "ui" => UI, "projects" => PROJECTS,
      "projects group" => GROUPS, "config" => CONFIG, "layout" => LAYOUT, "ask" => ASK, "inbox" => INBOX,
      "agent-run" => AGENT_RUN, "handoff" => HANDOFF
    }.freeze

    # The page for the leading verb words of +args+, longest match first.
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
      nil
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

    # The overview's verb list, one line per verb.
    #
    # @param table [Hash]
    # @return [Array<String>]
    def self.overview_verbs(table)
      shown = table.reject { |_, page| page[:hidden] }
      width = shown.keys.map(&:length).max
      shown.map { |key, page| "  #{key.ljust(width)}  #{page[:summary]}" }
    end

    def self.usage_lines(usage)
      usage.each_with_index.map { |u, i| "#{i.zero? ? "Usage:" : "      "} workspace #{u}" }
    end
  end
end
