# workspace relaunch

Stop workspace projects and relaunch them.

## Usage

```sh
workspace relaunch [--name WS | --all] [--json] [workspace ...]
```

## Details

Stops the selected workspaces and then relaunches them. **Changed:** bare `workspace relaunch` used to relaunch every active workspace; it now acts on the workspace the current directory is in. Use `--all` for the old behaviour.

- No name: the workspace the current directory is in; outside any workspace, `not_in_workspace`.
- `--name WS` or positional names: those workspaces (both may be given together).
- `--all`: every active workspace. With a name it is a usage error.
- A name with no workspace config is `unknown_workspace`; one that isn't active is `workspace_not_active`. Both are refused before anything is stopped.
- Only the selected workspaces are stopped and relaunched.

[Headless](README.launch.md#headless) projects are relaunched headless; the others come back in iTerm2.

`--all` exits with a non-zero status if there are no active projects to relaunch.

## Examples

```sh
$ workspace relaunch
Will relaunch: my-notes
Stopped 1 project(s): my-notes
Creating 1 new launcher pane(s)...
Done! Launched 1 project(s).

$ workspace relaunch billing
Will relaunch: billing
Stopped 1 project(s): billing
Creating 1 new launcher pane(s)...
Done! Launched 1 project(s).

$ workspace relaunch --all
Will relaunch: my-notes, billing
Stopped 2 project(s): my-notes, billing
Creating 2 new launcher pane(s)...
Done! Launched 2 project(s).
```

## JSON output

`--json` prints an action document (see [README.json.md](README.json.md#actions)) with one row per project: `relaunched`, or `failed` as for `launch`. With `--all` and nothing active it prints the failure envelope. The text goes to stderr.
