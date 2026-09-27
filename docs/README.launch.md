# workspace launch

Launch tmuxinator projects in iTerm2 windows.

## Usage

```sh
workspace launch [options] <project1> [project2] ...
```

## Options

| Option | Description |
|--------|-------------|
| `--reattach` | Reattach to existing tmux sessions, preserving session state |
| `--prompt PROMPT` | Send an initial prompt to Claude in each project |

## Details

Launches one or more tmuxinator projects, each in its own iTerm2 window. Windows are arranged left-to-right with slight overlap on the active display.

Reuses existing launcher panes when available instead of creating new windows.

You can pass either a project name (matching an existing tmuxinator config) or a directory path (which will auto-create a config).

Also starts the [session-monitoring agent daemon](README.agent.md) for each launched project, unless one is already running for it. This is what powers [`workspace sessions`](README.sessions.md); run `workspace doctor` to check whether it's set up correctly for the current project.

If a project's [pipeline config](README.pipeline.md) has an invalid `timeout:`, the daemon would otherwise exit right after starting with nothing visible on your screen. `launch` checks the config first and, if it's invalid, skips starting that project's daemon and prints a warning on stderr naming the bad key and the daemon's log path, without aborting the rest of the launch. Once the config is fixed, start the daemon with `workspace agent --name <project>` rather than relaunching the whole window.

## Notes

`--reattach` uses `tmux -CC attach` which may trigger an iTerm dialog. To suppress it, set iTerm > Settings > General > tmux > "When attaching, restore windows" to "Always".

## Examples

```sh
# Launch a single project
workspace launch my-project

# Launch multiple projects
workspace launch my-notes work-notes billing

# Reattach to existing sessions
workspace launch --reattach my-project

# Launch from a directory path
workspace launch ~/Code/my-project

# Launch with a prompt for Claude
workspace launch --prompt "Review the README" my-project
```
