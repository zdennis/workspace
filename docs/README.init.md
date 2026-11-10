# workspace init

Install tmuxinator templates and create the workspace config directory.

## Usage

```sh
workspace init [options]
```

## Options

| Option | Description |
|--------|-------------|
| `--dry-run` | Show what would be done without making changes |
| `-f`, `--force` | Overwrite existing templates even if they differ |
| `--install-hooks` | Install agent session hooks without asking |
| `--no-install-hooks` | Skip the agent session hooks step |
| `--workflow-sources VALUE` | Add `workflows.sources` entries to the global config (repeatable) |

## Details

Sets up workspace by:

1. Installing tmuxinator templates into `~/.config/tmuxinator/`
2. Creating `~/.config/workspace/` and `~/.config/workspace/projects/`
3. Installing a default `~/.config/workspace/config.yml` with empty hooks and layouts
4. Offering to install agent session hooks (see below)

Safe to run multiple times — skips files that are already up to date and won't overwrite modified templates unless `--force` is used. The global `config.yml` is never overwritten.

### Agent session hooks

An agent counts as detected when the program of its configured command is on `PATH`, read from the global config: with `agent.commands.claude` set to `claude-dev`, `init` looks for `claude-dev`, and reports `absent  Claude Code  (claude-dev not on PATH)` without it. For each detected coding agent that supports hooks (e.g. Claude Code), `init` reports whether it was found and shows a one-line summary of the hook events that would be added (e.g. `SessionStart, SessionEnd, ... hooks running \`workspace session-event\``).

You're then asked to **[v]iew** the full settings fragment before deciding, **[i]nstall** it, or do **[n]othing** (the default). Viewing re-prompts afterward so you can still install or decline.

Installing merges the hooks into the agent's own settings file (e.g. `.claude/settings.json`) rather than overwriting it, and is idempotent — hooks already present are left alone, so re-running `init` is always safe. The file is backed up first (`<file>.workspace-backup-<timestamp>`). Inside a git checkout, backups (the pattern `*.workspace-backup-*`) and a settings file workspace created are listed in the repository's `info/exclude`, so they don't show in `git status` or a review diff; a settings file git tracks is never listed, and a failure to write the exclude is ignored. `--install-hooks` skips the prompt and installs immediately; `--no-install-hooks` skips the phase entirely.

Claude Code's hooks include `StopFailure`, which the agent daemon needs to [recover an agent from an API error](README.agentd.md#recovering-from-an-api-error). A project whose hooks were installed before that existed doesn't have it: run `workspace init --install-hooks` or `workspace doctor --fix` there, and recovery starts working. The same goes for `PermissionRequest`, which fills in [`waiting_tool` and `waiting_input`](README.sessions.md#waiting-detail).

Codex's hooks are user-level: they go into `$CODEX_HOME/hooks.json` (default `~/.codex/hooks.json`) once, for every project, and run `if [ -n "$TMUX_PANE" ]; then workspace session-event --agent codex; else cat >/dev/null; fi`, so a Codex session outside tmux never starts Ruby. An install made before the guard is upgraded in place by the next `init`, `start` or `doctor --fix`, with no duplicate. Your own entries in that file are kept, and workspace's are added after them. Codex skips new or changed hooks until you trust them, so after an install `init` prints a note: run `/hooks` in Codex and trust the `workspace session-event --agent codex` entries, or take them out with `workspace hooks uninstall --agent codex` (see [`hooks`](README.hooks.md)). Until then a Codex pane is watched by pane activity only (`hook_mode: "scrape"` in [`sessions --json`](README.sessions.md#hook-mode), which also has a table of what each agent's hooks report).

### Workflow sources

`--workflow-sources VALUE` appends to the global `workflows.sources` ([the directories `workflow install` reads](README.workflow.md#installing-from-sources)). Repeat the flag, or separate several entries in one value with commas or newlines. Entries are appended in the order given and deduplicated against what is already listed, so re-running is safe. An entry that is not a usable source (for example a bare `owner/repo`) is reported as an error and left out; the rest still go in. `--dry-run` reports without writing.

The workflows of the sources it just added are installed right away, the way `workspace workflow install` does them (local sources are checked in place; GitHub sources are fetched and cached). A source that can't be installed — no `gh`, no network, a refused definition — is a warning; the entry stays listed and `workspace workflow install` can be re-run later. Entries already listed are not fetched again.

## Examples

```sh
# Install templates and create config directory
workspace init

# Preview what would happen
workspace init --dry-run

# Overwrite modified templates
workspace init --force

# Install agent session hooks without prompting
workspace init --install-hooks

# Skip the hooks step entirely
workspace init --no-install-hooks

# List a workflow source in the global config
workspace init --workflow-sources acme/workflows/presets
```
