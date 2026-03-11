# workspace config

Show project or global workspace configuration.

## Usage

```sh
workspace config [options] [project]
```

## Options

| Option | Description |
|--------|-------------|
| `--global` | Show global configuration instead of project config |

## Details

Displays the YAML configuration for a project or the global workspace config. Auto-detects the project from the current directory if not specified.

Config files are edited directly — there is no `set` subcommand.

### Config file locations

- **Global:** `~/.config/workspace/config.yml`
- **Project:** `~/.config/workspace/projects/<name>.yml`

### Global settings

| Setting | Description |
|---------|-------------|
| `hooks` | Global hooks applied to all projects |
| `layouts` | Default tmux pane layouts |
| `claude.mcp_servers` | MCP servers passed to Claude via `--mcp-servers` |
| `event_log_compact_threshold` | Size warning threshold (e.g., "10kb", "1mb"). Default: 10kb |

### Project settings

| Setting | Description |
|---------|-------------|
| `hooks` | Project-specific hooks (e.g., `post_launch`) |
| `layouts` | Project-specific tmux pane layouts |
| `worktree_hooks` | Hooks seeded into new worktrees created from this project |
| `claude.mcp_servers` | MCP servers for this project (overrides global) |

## Examples

```sh
# Show config for a specific project
workspace config myproject

# Show config for the current directory's project
workspace config

# Show global configuration
workspace config --global

# Edit config files directly
$EDITOR ~/.config/workspace/config.yml
$EDITOR ~/.config/workspace/projects/myproject.yml
```
