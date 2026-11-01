# workspace ui

Open a view of the workspace UI from a script, an agent or a notification, through its `workspace-ui://` link.

## Usage

```sh
workspace ui open [task] [WORKSPACE] [--print] [--json]
workspace ui open review [WORKSPACE] [--print] [--json]
workspace ui open notes [WORKSPACE] [--path REL] [--print] [--json]
workspace ui open plan [WORKSPACE] [--print] [--json]
workspace ui open pane [WORKSPACE] PANE [--print] [--json]
workspace ui open inbox [--print] [--json]
workspace ui status [--json]
```

| View | Link |
|------|------|
| `task WORKSPACE` | `workspace-ui://task/WORKSPACE` |
| `review WORKSPACE` | `workspace-ui://review/WORKSPACE` |
| `notes WORKSPACE` | `workspace-ui://notes/WORKSPACE` |
| `notes WORKSPACE --path REL` | `workspace-ui://notes/WORKSPACE/REL` |
| `plan WORKSPACE` | `workspace-ui://plan/WORKSPACE` |
| `pane WORKSPACE PANE` | `workspace-ui://pane/WORKSPACE/PANE` |
| `inbox` | `workspace-ui://inbox` |

`WORKSPACE` (or `--name WORKSPACE`) defaults to the project detected from the current directory. `inbox` takes no workspace. `PANE` is a tmux pane id such as `%19`, percent-encoded in the link (`%2519`); anything else is a usage error. With `--name` or a workspace detected from the current directory, `workspace ui open pane %19` is enough. The pane is not checked against tmux: the UI validates it. The name is percent-encoded, so `my-app.worktree-fix` stays as written and a `/` becomes `%2F`; a name with control characters or over 255 characters is a usage error. With no view, `ui open` opens the `task` view, and `ui open WORKSPACE` does too when WORKSPACE is not a view but has a config (ignoring case; the on-disk spelling is used); any other word, or a non-view word together with `--name`, is a usage error and nothing opens. A workspace named like a view stays reachable as `ui open task NAME`. With a view given, the command does not check that the workspace exists: the UI validates the target it receives.

| Option | Description |
|--------|-------------|
| `--name NAME` | Same as the positional workspace |
| `--path REL` | Open one note of the workspace's notes directory (`notes` view only) |
| `--print` | Print the link and open nothing |
| `--json` | Print one action document |

`--path` names a note by its path inside the workspace's notes directory (`workspace notes dir`). Workspace checks it first: up to 4 segments of ASCII letters, digits, dot, hyphen and underscore (no space, no leading dot, no `node_modules`), ending in `.md` or `.markdown`, no symlink along the way, and the file must exist with exactly that case. A note with a space or a non-ASCII character in its name cannot be linked until you rename it. The UI accepts more than this and checks again when it opens the note. Nothing is encoded, since every allowed character is plain in a link. A refused path is an `invalid_note_path` error (exit 1; `details.workspace`, `details.path` cut to 200 characters, `details.reason`); `--path` on any other view is a usage error.

A link only opens a view. It never starts an agent or runs a command, so nothing in `workspace ui open` changes workspace state.

## Opening

The link is passed to the system `open` as a single argument (no shell). The workspace UI app registers the `workspace-ui` scheme, so it must be installed. Without a handler `open` fails (for example `LSOpenURLsWithRole() failed with error -10814`); the message (with a reminder to install the UI app, and that `--print` shows the link without opening it) goes to stderr and the exit status is 1. A missing `open` executable is reported the same way.

## --json

`--json` prints the action document (see [README.json.md](README.json.md)); text goes to stderr. `--print` with `--json` reports `printed` and opens nothing.

```json
{"schema_version":1,"ok":true,"action":"ui open","status":"ok",
 "results":[{"workspace":"api","outcome":"opened","reason":null,"message":null,
   "view":"task","url":"workspace-ui://task/api"}],
 "warnings":[],"summary":{"opened":1}}
```

`action` is `ui open`, like `dev up` and `lock release`. `reason` is the stable machine field; `message` is for people and its text may change. `outcome` is `opened`, `printed` or `failed`. `reason` on a failure is `open_failed` (`open` exited non-zero; `message` is its first line of stderr, with a reminder to use `--print` appended) or `open_unavailable` (`open` could not be run). `workspace` is `null` for `inbox`. A `pane` row also carries `pane`, and a row opened with `--path` carries `path`. These are `usage` errors: an unknown view, a missing workspace, a workspace given to `inbox`, a pane given to any view but `pane`, and a missing or malformed pane id (exit 1; with `--json` the error envelope).

Run `workspace ui open VIEW --help` for the task, notes and inbox views, each with its own page and examples.

## status

```sh
workspace ui status [--json]
```

Asks macOS which app would take a `workspace-ui://` link, and which copies of the UI app run. It is read-only: nothing is opened or launched, no `open` is run, and no link is built. It takes `--json` only; a positional, `--name`, `--path` or `--print` is a usage error (the error envelope under `--json`). It always exits 0 once it parses: not getting an answer from macOS is data, not an error.

Text output is three lines:

```
running: yes (pid 4121)
handler: /Applications/Workspace UI.app (com.zdennis.workspace-ui 0.30.1)
links: revision 2
```

`--json` prints one read document (a read document, not an action: `schema_version`, `ok`, no `results`):

```json
{"schema_version":1,"ok":true,"running":false,"pids":[],
 "handler":{"path":"/Applications/Workspace UI.app","id":"com.zdennis.workspace-ui","version":"0.30.1"},
 "links":{"revision":null,"reason":"not_declared"},
 "probe":null,"warnings":[]}
```

| Field | Meaning |
|-------|---------|
| `running`, `pids` | Whether a copy of the app (bundle id `com.zdennis.workspace-ui`) runs, and its process ids. Null when the probe could not answer |
| `handler` | The app macOS would hand a link to: `path`, `id`, `version`. Null when none is registered, or when the probe could not answer |
| `links.revision` | An integer only when the app that would take a link is the bundle that declares it (`WorkspaceUILinkRevision` in its `Info.plist`). Otherwise null. The CLI never derives it from the app's version |
| `links.reason` | Null when `revision` is a number, else the first that applies: `probe_failed`, `no_handler`, `foreign_handler` (the handler's id is not ours), `handler_unreadable` (its path is missing, or its real path or `Info.plist` cannot be read, for example the bundle was removed), `handler_differs` (a running copy has a different real path from the handler's, or no path, or is gone), `launch_unknown` (a running copy has no launch time to compare), `app_older_than_bundle` (a running copy started before the handler's `Info.plist` was last changed), `not_declared` (the bundle declares no revision). With nothing running, the launch checks do not apply |
| `probe` | Null, or `timed_out`, `unavailable` or `bad_answer` when macOS could not be asked (5 seconds) |
| `warnings` | An array, empty unless there is something to report |

The rule for an agent: `handler: null`, or a `foreign_handler` reason, means no UI app would take the link, so print it (`ui open ... --print`) instead of opening it. `running: false` does not mean that, since macOS launches the app to take a link.

Known limit of `app_older_than_bundle`: it compares a running copy's launch time with the modification time of the handler's `Info.plist`. A Finder or `cp -p` install keeps the `Info.plist` time of the build, so an old app launched after that build but before the install can still report the new revision. A harmless copy can also read as older; that only gives a null revision.

Values read from macOS (a bundle path or version) are escaped in the text output.


## Examples

```sh
# Send the person to my-app's task view (opens the UI app)
workspace ui open task my-app

# Point the person at the review of one worktree's change
workspace ui open review my-app.worktree-fix-login

# Show the person the notes of my-app, or the one note you just wrote
workspace ui open notes my-app
workspace ui open notes my-app --path payment-retries.md

# Learn the plan link of the workspace you are in, and open nothing
workspace ui open plan --print

# Show the person the pane an agent is stuck in
workspace ui open pane my-app %19
workspace ui open pane %19 --print   # workspace from the current directory

# Tell the person something waits for them, or only learn the inbox link
workspace ui open inbox
workspace ui open inbox --print
```
