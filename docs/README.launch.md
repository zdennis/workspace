# workspace launch

Launch tmuxinator projects in iTerm2 windows, or headless in plain tmux.

## Usage

```sh
workspace launch [options] <project1> [project2] ...
```

## Options

| Option | Description |
|--------|-------------|
| `--reattach` | Reattach to existing tmux sessions, preserving session state |
| `--headless` / `--no-headless` | Start each session in the background with plain tmux (no iTerm2, AppleScript or window-tool), or force iTerm2. See [Headless](#headless) for the default |
| `--prompt PROMPT` | Send an initial prompt to the coding agent in each project, once it is ready (up to 60s); exits 1 if it can't be sent |
| `--prompt-timeout DURATION` | How long to wait for the coding agent to be ready for `--prompt` (e.g. `90s`, `2m`, or a plain number of seconds); default 60s |

## Details

Launches one or more tmuxinator projects, each in its own iTerm2 window. Windows are arranged left-to-right with slight overlap on the active display.

Reuses existing launcher panes when available instead of creating new windows.

You can pass either a project name (matching an existing tmuxinator config) or a directory path (which will auto-create a config).

Also starts the [session-monitoring agent daemon](README.agent.md) for each launched project, unless one is already running for it. This is what powers [`workspace sessions`](README.sessions.md); run `workspace doctor` to check whether it's set up correctly for the current project.

If a project's [pipeline config](README.pipeline.md) has an invalid `timeout:`, the daemon would otherwise exit right after starting with nothing visible on your screen. `launch` checks the config first and, if it's invalid, skips starting that project's daemon and prints a warning on stderr naming the bad key and the daemon's log path, without aborting the rest of the launch. Once the config is fixed, start the daemon with `workspace agent --name <project>` rather than relaunching the whole window.

**Prompts** — with `--prompt`, `launch` waits for each project's coding agent before typing anything. An agent counts as ready once its process is running in any window of the session (not just window 0), in one of its panes (Claude Code first, then Codex, OpenCode and Pi, then the lowest window and pane), its screen has stayed the same for 2 seconds, and — for Claude Code specifically — that settled screen shows its input prompt box, not a startup dialog such as "Do you trust the files in this folder?". Agents without a recognized prompt box (Codex, OpenCode, Pi) still count as ready on a quiet screen alone. All projects share one wait (60s by default, or `--prompt-timeout`'s value), since their agents start at the same time. The prompt is then pasted and submitted, and `launch` reads the pane back to check it arrived (see [`workspace run`](README.run.md) for how). A paste that never shows up in the pane is tried again, up to three times in all. A paste that shows up but may not have been submitted is not sent again, so it can't be typed twice. A paste that shows up only after a retry already sent a fresh copy is submitted with Enter instead ("The prompt to `<project>` arrived late; submitting it...") rather than pasted a second time.

If a prompt can't be sent, `launch` still finishes the launch and runs `post_launch` hooks. It then prints `Error: prompt not sent to <project>: <reason>` on stderr for each project and exits 1. The reason names the actual paste failure — for example "...it may not have arrived" for an unverified delivery — rather than reporting that the agent is still starting up when a retry simply ran out of time.

## Headless

`--headless` starts each project's tmux session in the background, for remote machines, SSH sessions and CI. It runs `tmuxinator start --no-attach` on a copy of the project's config with `tmux_options: -CC` left out (quoted or not), because iTerm2's control mode needs a terminal. Nothing is sent to iTerm2, and no window is positioned.

Without a flag, `launch` decides like this, and the first rule that applies wins:

1. `--headless` or `--no-headless`
2. the global `launch.headless` config key: `workspace config set launch.headless true` (or `false`)
3. headless when this isn't macOS, when `osascript` isn't on `PATH`, or when the `CI` environment variable is set (to anything but `false` or `0`)
4. otherwise iTerm2

A headless project whose tmux session is already running is reused as it is, not started again. Two headless launches of one project at once start it only once; the second reuses the session the first started. `launch` prints `Attach with: tmux attach -t <session>` for each project. `--reattach` has no effect headless.

The project is recorded as headless in the state file (`"headless": true`; a reused session that was launched in iTerm2 loses its window ids), so `stop`, `kill`, `finish`, `list`, `status`, `cleanup` and `relaunch` work as usual, and `sessions`, `agent`, `pipeline`, `run`, `capture`, `resize` and `layout` target its tmux panes the same way. `relaunch` brings headless projects back headless. `focus` and `tile` have no window to act on, so they exit 1 with a message naming the tmux session to attach to.

`--prompt` works the same headless: the same readiness wait, paste and read-back.

A project fails to start, and `launch` exits 1 without recording it or starting its session monitor, when tmuxinator exits nonzero, is still running after 60 seconds (it is then stopped), or exits 0 but its tmux session hasn't appeared 5 seconds later. The other projects are launched as usual.

If tmuxinator can't start a project's session, `launch` prints `Error: could not start <project>: <reason>` on stderr, doesn't record the project, and exits 1 once the other projects are up.

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

# Launch in the background with plain tmux (e.g. over SSH or in CI)
workspace launch --headless my-project
tmux attach -t my-project
```
