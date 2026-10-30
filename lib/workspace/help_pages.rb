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
        examples: []
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
        examples: []
      },
      "log" => {
        usage: ["daemon log [WORKSPACE] [--name NAME] [--lines N] [--json]"],
        summary: "Show the last lines of a workspace's agent daemon log",
        about: ["Only a background daemon writes this log; a daemon run in a terminal logs to that terminal instead."],
        options: [DAEMON_NAME, ["--lines N", "How many trailing lines (default: 40)"], JSON_OPT],
        examples: []
      },
      "list" => {
        usage: ["daemon list [--json]"],
        summary: "List every running agent daemon",
        about: ["Shows each daemon's workspace, pid, start time and socket. It takes no workspace."],
        options: [JSON_OPT],
        examples: []
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
        examples: []
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

    # The tables by command; the specs and the routing tests read them.
    COMMANDS = {
      "plan" => PLAN, "daemon" => DAEMON, "workflow" => WORKFLOW, "library" => LIBRARY, "spine" => SPINE,
      "binding" => BINDING, "step" => STEP, "review" => REVIEW, "pr" => PR, "ticket" => TICKET, "goal" => GOAL,
      "notes" => NOTES, "instructions" => INSTRUCTIONS, "ui" => UI, "projects" => PROJECTS,
      "projects group" => GROUPS, "config" => CONFIG
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
