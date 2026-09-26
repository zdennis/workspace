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

## Details

Sets up workspace by:

1. Installing tmuxinator templates into `~/.config/tmuxinator/`
2. Creating `~/.config/workspace/` and `~/.config/workspace/projects/`
3. Installing a default `~/.config/workspace/config.yml` with empty hooks and layouts
4. Offering to install agent session hooks (see below)

Safe to run multiple times — skips files that are already up to date and won't overwrite modified templates unless `--force` is used. The global `config.yml` is never overwritten.

### Agent session hooks

For each detected coding agent that supports hooks (e.g. Claude Code), `init` reports whether it was found and shows a one-line summary of the hook events that would be added (e.g. `SessionStart, SessionEnd, ... hooks running \`workspace session-event\``).

You're then asked to **[v]iew** the full settings fragment before deciding, **[i]nstall** it, or do **[n]othing** (the default). Viewing re-prompts afterward so you can still install or decline.

Installing merges the hooks into the agent's own settings file (e.g. `.claude/settings.json`) rather than overwriting it, and is idempotent — hooks already present are left alone, so re-running `init` is always safe. `--install-hooks` skips the prompt and installs immediately; `--no-install-hooks` skips the phase entirely.

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
```
