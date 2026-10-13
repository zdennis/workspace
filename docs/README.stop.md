# workspace stop

Stop workspace projects and their tmux sessions.

## Usage

```sh
workspace stop [project1] [project2] ...
```

## Details

Stops the specified projects' tmux sessions and cleans up their iTerm launcher windows. If no projects are specified, stops all active workspace projects.

Launcher windows are only closed when all tracked projects within them have been stopped. If other projects still share the window, it is preserved.

Projects can be restarted with `workspace launch`.

iTerm2 gets 5 seconds to answer each question `stop` asks it (which windows exist, and closing one). If it does not answer, `stop` stops waiting and ends that `osascript` call. It still removes the entries from the state file and kills the tmux sessions; the launcher windows are left open, and a warning says so: `iTerm did not answer in 5s; the window for api was left open.` Close the window by hand. If iTerm answers the lookups but then fails or times out closing a window, the warning is `iTerm did not close launcher window <id>; it was left open.`

A project whose tmuxinator config selects a custom tmux socket (`-L` or `-S` in `tmux_options`) has its session killed on that socket.

## Examples

```sh
# Stop all active projects
workspace stop

# Stop a specific project
workspace stop my-notes

# Stop multiple specific projects
workspace stop my-notes billing
```

## JSON output

`--json` prints an action document (see [README.json.md](README.json.md#actions)) with one row per project: `stopped`, or `not_running` for a named project that wasn't active (no stderr warning). The text goes to stderr. When iTerm2 did not answer, `warnings` holds the sentence above (one per project that had a window) and the rows and exit code are unchanged.
