# workspace ui

Open a view of the workspace UI from a script, an agent or a notification, through its `workspace-ui://` link.

## Usage

```sh
workspace ui open task [WORKSPACE] [--print] [--json]
workspace ui open review [WORKSPACE] [--print] [--json]
workspace ui open notes [WORKSPACE] [--path REL] [--print] [--json]
workspace ui open plan [WORKSPACE] [--print] [--json]
workspace ui open pane [WORKSPACE] PANE [--print] [--json]
workspace ui open inbox [--print] [--json]
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

`WORKSPACE` (or `--name WORKSPACE`) defaults to the project detected from the current directory. `inbox` takes no workspace. `PANE` is a tmux pane id such as `%19`, percent-encoded in the link (`%2519`); anything else is a usage error. With `--name` or a workspace detected from the current directory, `workspace ui open pane %19` is enough. The pane is not checked against tmux: the UI validates it. The name is percent-encoded, so `my-app.worktree-fix` stays as written and a `/` becomes `%2F`; a name with control characters or over 255 characters is a usage error. The command does not check that the workspace exists: the UI validates the target it receives.

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

## Examples

```sh
workspace ui open task my-app
workspace ui open review my-app.worktree-fix-login
workspace ui open notes my-app
workspace ui open notes my-app --path payment-retries.md --print
workspace ui open plan my-app
workspace ui open pane my-app %19 --print
workspace ui open pane %19 --print   # workspace from the current directory
workspace ui open inbox --print
```
