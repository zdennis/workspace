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
| `--prompt PROMPT` | Send an initial prompt to the coding agent in each project, once it is ready (up to 60s); exits 1 if it can't be sent |

## Details

Launches one or more tmuxinator projects, each in its own iTerm2 window. Windows are arranged left-to-right with slight overlap on the active display.

Reuses existing launcher panes when available instead of creating new windows.

You can pass either a project name (matching an existing tmuxinator config) or a directory path (which will auto-create a config).

Also starts the [session-monitoring agent daemon](README.agent.md) for each launched project, unless one is already running for it. This is what powers [`workspace sessions`](README.sessions.md); run `workspace doctor` to check whether it's set up correctly for the current project.

If a project's [pipeline config](README.pipeline.md) has an invalid `timeout:`, the daemon would otherwise exit right after starting with nothing visible on your screen. `launch` checks the config first and, if it's invalid, skips starting that project's daemon and prints a warning on stderr naming the bad key and the daemon's log path, without aborting the rest of the launch. Once the config is fixed, start the daemon with `workspace agent --name <project>` rather than relaunching the whole window.

**Prompts** — with `--prompt`, `launch` waits for each project's coding agent before typing anything. An agent counts as ready once its process is running in any window of the session (not just window 0), in one of its panes (Claude Code first, then Codex, OpenCode and Pi, then the lowest window and pane), and its screen has stayed the same for 2 seconds. All projects share one 60-second wait, since their agents start at the same time. The prompt is then pasted and submitted, and `launch` reads the pane back to check it arrived (see [`workspace run`](README.run.md) for how). A paste that never shows up in the pane is tried again, up to three times in all. A paste that shows up but may not have been submitted is not sent again, so it can't be typed twice. A paste that shows up only after a retry already sent a fresh copy is submitted with Enter instead ("The prompt to `<project>` arrived late; submitting it...") rather than pasted a second time.

If a prompt can't be sent, `launch` still finishes the launch and runs `post_launch` hooks. It then prints `Error: prompt not sent to <project>: <reason>` on stderr for each project and exits 1. The reason names the actual paste failure — for example "...it may not have arrived" for an unverified delivery — rather than reporting that the agent is still starting up when a retry simply ran out of time.

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

# Launch with a prompt for the coding agent
workspace launch --prompt "Review the README" my-project
```
