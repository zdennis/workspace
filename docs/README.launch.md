# workspace launch

Launch tmuxinator projects in iTerm2 windows, or headless in plain tmux.

## Usage

```sh
workspace launch [options] <project1> [project2] ...
```

## Options

| Option | Description |
|--------|-------------|
| `--reattach` | Reattach to an existing pane's tmux session instead of relaunching tmuxinator into it, preserving session state (a new pane already does this on its own when its session is running; `--reattach` matters for a pane `launch` is reusing) |
| `--headless` / `--no-headless` | Start each session in the background with plain tmux (no iTerm2, AppleScript or window-tool), or force iTerm2. See [Headless](#headless) for the default |
| `--prompt PROMPT` | Send an initial prompt to the coding agent in each project, once it is ready (up to 60s); exits 1 if it can't be sent |
| `--play NAME[,NAME...]` | Send each project's agent a line pointing at a [library](README.library.md) play, then any `--prompt` text; the play is looked up per project. Repeat the flag or separate names with commas to send several. See [Plays](#details) |
| `--pack NAME` | Also send the agent a library pack's text with the first prompt; repeatable. See [Packs](#packs) |
| `--no-packs` | Send no automatic packs; cannot be combined with `--pack` or `--handoff` |
| `--handoff` / `--no-handoff` | Send, or never send, the `handoff` pack for this run, whatever the `handoff.auto` key says. See [Packs](#packs) |
| `--arrange` | Tile the new windows and ignore the window positions saved when they were stopped. See [Window position](#window-position) |
| `--prompt-timeout DURATION` | How long to wait for the coding agent to be ready for `--prompt` (e.g. `90s`, `2m`, or a plain number of seconds); default 60s |

## Details

Launches one or more tmuxinator projects, each in its own iTerm2 window. Windows are arranged left-to-right with slight overlap on the active display.

Reuses existing launcher panes when available instead of creating new windows.

- A new pane whose project's tmux session is already running (left over from a headless launch, or from a window that was closed without killing the session) attaches to it instead of running tmuxinator into it again, the same way a headless launch reuses a running session; `launch` prints a one-line note that it's reusing the session.
- If the session is killed before the new pane attaches, the pane runs tmuxinator to start it instead.
- If the project was tracked as headless, its state entry loses the `headless` flag and gains the new iTerm window/pane ids.
- Launches of one project never start it twice, whether they are windowed, headless or a mix: each holds a per-project lock until the project's session exists (up to 30 seconds), so a second launch waits and then reuses that session. The state entry ends up as whichever launch recorded it last, never a mix of the two.

You can pass either a project name (matching an existing tmuxinator config) or a directory path (which will auto-create a config).

New workspace names are lowercase (`~/Code/MyApp` becomes `myapp`; a branch's worktree is `myapp.worktree-proj-123`). If a config already exists whose name differs only in case, a different workspace (another directory) is refused with `workspace_name_case_conflict`, naming the existing workspace; it is renamed to lowercase the next time its agentd starts. The same workspace (same directory) written earlier with mixed case, such as `~/Notes` for an existing `Notes`, is reused. `launch` renames a mixed-case workspace to lowercase before it starts the session, unless its agent is running (see [Renaming a mixed-case workspace](README.agentd.md#renaming-a-mixed-case-workspace)).

Also starts the [session-monitoring agent daemon](README.agentd.md) for each launched project, unless one is already running for it. This is what powers [`workspace sessions`](README.sessions.md); run `workspace doctor` to check whether it's set up correctly for the current project.

If a project's [pipeline config](README.pipeline.md) has an invalid `timeout:`, the daemon would otherwise exit right after starting with nothing visible on your screen. `launch` checks the config first and, if it's invalid, skips starting that project's daemon and prints a warning on stderr naming the bad key and the daemon's log path, without aborting the rest of the launch. Once the config is fixed, start the daemon with `workspace agentd --name <project>` rather than relaunching the whole window.

**Prompts** — with `--prompt`, `launch` waits for each project's coding agent before typing anything. An agent counts as ready once its process is running in any window of the session (not just window 0), in one of its panes (Claude Code first, then Codex, OpenCode and Pi, then the lowest window and pane), its screen has stayed the same for 2 seconds, and — for Claude Code specifically — that settled screen shows its input prompt box, not a startup dialog such as "Do you trust the files in this folder?". Agents without a recognized prompt box (Codex, OpenCode, Pi) still count as ready on a quiet screen alone. All projects share one wait (60s by default, or `--prompt-timeout`'s value), since their agents start at the same time. The prompt is then pasted and submitted, and `launch` reads the pane back to check it arrived (see [`workspace run`](README.run.md) for how). A paste that never shows up in the pane is tried again, up to three times in all. A paste that shows up but may not have been submitted is not sent again, so it can't be typed twice. A paste that shows up only after a retry already sent a fresh copy is submitted with Enter instead ("The prompt to `<project>` arrived late; submitting it...") rather than pasted a second time.

**Plays** — with `--play NAME`, each project's agent gets `Read "<path>" and follow it.`, then any `--prompt` text after a blank line, sent the way `--prompt` is. The play is looked up for each project on its own: that project's [library](README.library.md#scopes), then the global one, then the built-in plays. `--play` may repeat and take comma-separated lists (`--play a,b --play c`); the agent gets one `Read` line per play, in order, and repeats are sent once. A `--play` value that names no play (`--play ""`, `--play ,`) is a usage error, as are more than 20 plays, both before anything launches. Every project's plays are found and read before anything launches or a config is created, so one unknown name (`unknown_library_entry`) or unreadable file (`library_source_missing`) among them fails with nothing changed. A project whose session is already running gets the play typed into its agent, which may be in the middle of a task. The pane each play is delivered to is [bound](README.binding.md#plays) to it, replacing any earlier binding of that pane. See [`start`](README.start.md#plays) for the details they share.

**Packs** — `launch` also sends each project's agent the instruction packs that apply, so every entry point gives the agent the same starting instructions. The text is one send, in this order: the `--play` line, the packs (one `## From pack <name>` heading each, as [`instructions compose`](README.instructions.md) writes them), then the `--prompt` text. The automatic packs are `notes` (where working notes go), unless the project's `notes.instructions` key is `false` (`workspace config set notes.instructions false`); `--pack NAME` adds more (repeatable), and `--no-packs` drops the automatic ones for this run. `--no-packs` with `--pack` is a usage error. An automatic `spine` pack is sent after `notes` to a project whose notes directory has a `spine/` folder (a link named `spine` does not count; `--no-packs` drops it; see [`spine`](README.spine.md#telling-agents-the-convention)). Another automatic pack, `handoff`, is sent only when the project's `handoff.auto` key is `true` (it is `false` unless set) or `--handoff` is given, and only to a project whose main agent is Claude Code or Codex; `--no-handoff` leaves it out for this run, and `--handoff` with `--no-packs` is a usage error. With `handoff.auto` and another agent it is skipped with `Warning: the handoff pack was not sent to <project>: ...`, its `packs` row reads `delivered: false`, `pane: null`, `reason: "handoff_unsupported_agent"`, and the run goes on; with `--handoff` the same case fails with `handoff_unsupported_agent` (`details.kind`) before anything is created. A `--handoff` pack is required like `--pack`: a failed delivery is `prompt_not_sent`. See [Automatic handoff](README.handoff.md#automatic-handoff). Another, `dev`, is sent when the project sets `dev.up` and its `dev.instructions` key is not `false`: it tells the agent to run `workspace dev up --queue` and `workspace dev wait` before it implements, tests or verifies, and `workspace dev down` when it is done (see [`dev`](README.dev.md#instructions-for-agents)). `--no-packs` drops it for one run; a project with no `dev.up` gets nothing new. Every pack is read before anything launches or a config is created, so an unknown name fails with `unknown_library_entry` and changes nothing. When the prompt is nothing but automatic packs (no `--prompt`, `--play` or `--pack`), it is optional: a project with no coding agent after 5 seconds, or whose agent never becomes ready, is skipped with `Warning: the notes pack was not sent to <project>: <reason>` on stderr, the exit status is what it would be without packs, its `packs` row has `delivered: false` and `pane: null`, and `--json` adds the same sentence to `warnings`. With `--prompt`, `--play` or `--pack` the whole text is required and a failed delivery is `prompt_not_sent`, exit 1. `workspace instructions compose --start --name <project>` prints what would be sent and sends nothing. The pane each prompt is delivered to is [bound](README.binding.md#packs) to the packs it was sent, so they survive `/clear` and compaction; a pane that already has a live binding keeps it unless a play is sent. `relaunch` and `restore` send no packs.

If a prompt can't be sent, `launch` still finishes the launch and runs `post_launch` hooks. It then prints `Error: prompt not sent to <project>: <reason>` on stderr for each project and exits 1. The reason names the actual paste failure — for example "...it may not have arrived" for an unverified delivery — rather than reporting that the agent is still starting up when a retry simply ran out of time. The closing line is then `Launched N project(s), but the prompt was not sent.` instead of `Done! Launched N project(s).`

## Window position

[`stop`](README.stop.md) saves where each window sat, and `launch` puts a new window back there, so a workspace you stop and start again comes back where you left it. A window is moved back only when its title bar (the top 30 pixels) is still on a connected screen, as `window-tool screens --json` reports them. Windows without a usable saved position are tiled as above; saved and unsaved windows can mix in one launch.

- A window that was already open (a reused pane) is never moved to a saved position.
- `launch --arrange` tiles every window for this launch. The next `stop` saves the tiled position.
- `workspace config set launch.restore_window_position false` does the same on every launch; `stop` still saves positions.
- A saved position on no connected screen prints `Warning: saved_window_offscreen: ...` on stderr and the window is tiled. A `window.json` that cannot be read prints `Warning: window_position_unreadable: ...`, the window is tiled and the file is left alone. Under `--json` both are also in `warnings`.
- The position is kept in `~/.local/state/workspace/<name>/window.json`. `kill` removes it for a worktree workspace.

## Headless

`--headless` starts each project's tmux session in the background, for remote machines, SSH sessions and CI. It runs `tmuxinator start --no-attach` on a copy of the project's config with `tmux_options: -CC` left out (quoted or not), because iTerm2's control mode needs a terminal. Nothing is sent to iTerm2, and no window is positioned.

Without a flag, `launch` decides like this, and the first rule that applies wins:

1. `--headless` or `--no-headless`
2. the global `launch.headless` config key: `workspace config set launch.headless true` (or `false`)
3. headless when this isn't macOS, when `osascript` isn't on `PATH`, or when the `CI` environment variable is set (to anything but `false` or `0`)
4. otherwise iTerm2

A headless project whose tmux session is already running is reused as it is, not started again. Two headless launches of one project at once start it only once; the second reuses the session the first started. `launch` prints `Attach with: tmux attach -t <session>` for each project. `--reattach` has no effect headless.

The project is recorded as headless in the state file (`"headless": true`; a reused session that was launched in iTerm2 loses its window ids, and its old launcher window is closed), so `stop`, `kill`, `finish`, `list`, `status`, `cleanup` and `relaunch` work as usual, and `sessions`, `agent`, `pipeline`, `run`, `capture`, `resize` and `layout` target its tmux panes the same way. `relaunch` brings headless projects back headless. `focus` and `tile` have no window to act on, so they exit 1 with a message naming the tmux session to attach to.

`--headless` refuses a project whose `tmux_options` selects a custom tmux socket (`-L`/`-S`), with `Error: headless launch doesn't support custom tmux sockets (-L/-S in tmux_options) for <project>`, before running tmuxinator: every tmux call `launch` makes headless uses the default socket, so it would never see a session started on another one and would rerun tmuxinator into it. Windowed `launch` is unaffected.

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

# Point each project's agent at a library play
workspace launch --play kickoff my-project other-project

# Point it at two plays
workspace launch --play kickoff,review my-project

# Launch in the background with plain tmux (e.g. over SSH or in CI)
workspace launch --headless my-project
tmux attach -t my-project
```

## JSON output

`--json` prints an action document (see [README.json.md](README.json.md#actions)) with one row per project (each row has `position`: `restored` when the window went back to its saved position, `arranged` when it was tiled, `null` when headless or no window was found): `launched` or `reused` (a headless session that was already running) with `iterm_window_id` and `headless`, or `failed` with `reason` `session_not_started`, `not_launched` or `prompt_not_sent`. With `--play`, every row has a `play` object (`ref`, `scope`, `path`, `sha256`, `delivered`, `pane`) for the first play that project resolved, and a `plays` array of the same objects for all of them (both are absent without `--play`); see [`start`](README.start.md#--json-output). Every row also has `packs`, one object per pack sent (`name`, `source` `config` or `flag`, `delivered`, `pane`), empty when none applied; a pack that was left out has `delivered: false`, `pane: null` and a `reason` (`handoff_unsupported_agent`). Every row also has `prompt_sent` and `pane`: `prompt_sent` is `true` when the prompt (the `--prompt` text, the `--play` line or the packs) reached the agent, `false` when there was one and it did not (a failed row, or an optional pack that was skipped), and `null` when there was nothing to send; `pane` is the tmux id of the pane that got it (for example `%4`), or `null` when `prompt_sent` is not `true`. A caller can use `pane` directly with `agent-run send --pane` or `binding show --pane` without comparing two `sessions` reads. `relaunch` rows carry both as `null`; `restore` rows have neither key. The progress text goes to stderr. Exit 0, 3 when some projects failed, 1 when all did.
