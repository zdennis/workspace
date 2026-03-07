# workspace init

Install tmuxinator templates and create the config directory.

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

Sets up workspace by installing tmuxinator templates into `~/.config/tmuxinator/` and creating the config directory if it doesn't exist.

Safe to run multiple times — skips files that are already up to date and won't overwrite modified templates unless `--force` is used.

## Examples

```sh
# Install templates
workspace init

# Preview what would happen
workspace init --dry-run

# Overwrite modified templates
workspace init --force
```
