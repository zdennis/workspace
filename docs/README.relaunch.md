# workspace relaunch

Stop workspace projects and relaunch them.

## Usage

```sh
workspace relaunch [--name WS | --all] [--json] [workspace ...]
```

## Details

Stops the selected workspaces and then relaunches them. With no name it acts on the workspace the current directory is in; `--all` relaunches every active workspace (what bare `workspace relaunch` did in earlier versions).

- No name: the workspace the current directory is in; outside any workspace, `not_in_workspace`.
- `--name WS` or positional names: those workspaces (both may be given together).
- `--all`: every active workspace. With a name it is a usage error.
- A name with no workspace config is `unknown_workspace`; one that isn't active is `workspace_not_active`. Both are refused before anything is stopped.
- Only the selected workspaces are stopped and relaunched.

[Headless](README.launch.md#headless) projects are relaunched headless; the others come back in iTerm2.

`--all` exits with a non-zero status if there are no active projects to relaunch.

## From inside the workspace

Stopping a workspace kills its tmux session, and tmux hangs up every process in it, so a relaunch run from one of its panes would end before anything was launched again. When the workspaces to relaunch include the one the command runs in, `relaunch` hands the whole relaunch to a background run and returns at once:

- The workspace it runs in is the one whose tmux session holds `$TMUX_PANE`, or is the session of the `$TMUX` client. Only tmux decides: a terminal outside the session whose working directory is in the workspace is not hung up by the stop, so there the relaunch runs in the foreground, as it does when tmux can't say.
- The background run is `workspace relaunch -- NAMES...` with the same workspaces named, started in a new session (`setsid`) so the hangup never reaches it, with stdin from `/dev/null`, `TMUX` and `TMUX_PANE` removed, and `WORKSPACE_RELAUNCH_DETACHED=1` set so it relaunches in the foreground and never hands off again. It deletes that variable from its environment before it stops or launches anything, so the sessions it starts never inherit it, and it counts only the value `1`.
- The program it runs is this install's `bin/workspace` (under Homebrew, the `opt` path, which `brew upgrade` keeps pointing at the current version). If that file is missing or not executable, the command fails with `relaunch_detach_failed` and nothing is stopped.
- Its output and a last line with its exit go to a log, `~/.local/state/workspace/.relaunch/<time>-<pid>.log` (under `$XDG_STATE_HOME` when set); the newest 20 logs are kept. The command prints the log's path; the window it ran in closes when the stop reaches it.
- `relaunch_scheduled` (the `--json` rows' outcome) means only that the background run started. Its result is the log's last line, `[time] exited N`; that line is absent when the run was killed.
- While it runs, each workspace it relaunches has a record, `.relaunch/<name>.pid` (the background run's pid, start time and log), removed when it finishes. Another `relaunch` of one of those workspaces is refused with `relaunch_in_progress` (`details.names`, `pid`, `log`) and stops nothing; a record whose process is gone is ignored.
- If the background run can't be started, the command fails with `relaunch_detach_failed` and nothing is stopped.

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

$ workspace relaunch    # from a pane of my-notes
Relaunching my-notes in the background: stopping the workspace this command runs in closes this window and its tmux session.
Log: /Users/me/.local/state/workspace/.relaunch/20261113T090807Z-4242.log

$ workspace relaunch --all
Will relaunch: my-notes, billing
Stopped 2 project(s): my-notes, billing
Creating 2 new launcher pane(s)...
Done! Launched 2 project(s).
```

## JSON output

`--json` prints an action document (see [README.json.md](README.json.md#actions)) with one row per project: `relaunched`, or `failed` as for `launch`. A relaunch handed to the background prints status `ok` with a `relaunch_scheduled` row per project and top-level `log` and `pid`. With `--all` and nothing active it prints the failure envelope. The text goes to stderr.
