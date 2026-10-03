# workspace ui

Open a view of the workspace UI from a script, an agent or a notification, through its `workspace-ui://` link.

## Usage

```sh
workspace ui open task [WORKSPACE] [--print] [--json]
workspace ui open review [WORKSPACE] [--print] [--json]
workspace ui open inbox [--print] [--json]
```

| View | Link |
|------|------|
| `task WORKSPACE` | `workspace-ui://task/WORKSPACE` |
| `review WORKSPACE` | `workspace-ui://review/WORKSPACE` |
| `inbox` | `workspace-ui://inbox` |

`WORKSPACE` (or `--name WORKSPACE`) defaults to the project detected from the current directory. `inbox` takes no workspace. The name is percent-encoded, so `my-app.worktree-fix` stays as written and a `/` becomes `%2F`; a name with control characters or over 255 characters is a usage error. The command does not check that the workspace exists: the UI validates the target it receives.

| Option | Description |
|--------|-------------|
| `--name NAME` | Same as the positional workspace |
| `--print` | Print the link and open nothing |
| `--json` | Print one action document |

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

`action` is `ui open`, like `dev up` and `lock release`. `reason` is the stable machine field; `message` is for people and its text may change. `outcome` is `opened`, `printed` or `failed`. `reason` on a failure is `open_failed` (`open` exited non-zero; `message` is its first line of stderr, with a reminder to use `--print` appended) or `open_unavailable` (`open` could not be run). `workspace` is `null` for `inbox`. An unknown view, a missing workspace, or a workspace given to `inbox` is a `usage` error (exit 1; with `--json` the error envelope).

## Examples

```sh
workspace ui open task my-app
workspace ui open review my-app.worktree-fix-login
workspace ui open inbox --print
```
