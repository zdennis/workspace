# workspace tile

Tile all active windows for a project across the screen.

## Usage

```sh
workspace tile [project]
```

## Details

Arranges all windows matching the project as equal-width columns filling the full screen. Matches the base project and all its worktree sessions (e.g., `myproject` and `myproject.worktree-*`).

Auto-detects the project from the current directory if not specified.

## Examples

```sh
# Tile all windows for a project
workspace tile my-project

# Tile from within the project directory
workspace tile
```
