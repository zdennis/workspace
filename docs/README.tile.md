# workspace tile

Tile all active windows for a project across the screen.

## Usage

```sh
workspace tile [options] [project]
```

## Options

| Flag | Description |
|------|-------------|
| `--all` | Tile all active workspace projects |

## Details

Arranges all windows matching the project as equal-width columns filling the full screen. Matches the base project and all its worktree sessions (e.g., `myproject` and `myproject.worktree-*`).

Auto-detects the project from the current directory if not specified.

With `--all`, tiles every active workspace window regardless of project.

## Examples

```sh
# Tile all windows for a project
workspace tile my-project

# Tile from within the project directory
workspace tile

# Tile all active workspace windows
workspace tile --all
```
