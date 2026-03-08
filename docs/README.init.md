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

## Details

Sets up workspace by:

1. Installing tmuxinator templates into `~/.config/tmuxinator/`
2. Creating `~/.config/workspace/` and `~/.config/workspace/projects/`
3. Installing a default `~/.config/workspace/config.yml` with empty hooks and layouts

Safe to run multiple times — skips files that are already up to date and won't overwrite modified templates unless `--force` is used. The global `config.yml` is never overwritten.

## Examples

```sh
# Install templates and create config directory
workspace init

# Preview what would happen
workspace init --dry-run

# Overwrite modified templates
workspace init --force
```
