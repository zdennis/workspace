# workspace add

Add a tmuxinator config for a project directory.

## Usage

```sh
workspace add <path> [path2] ...
```

## Details

Creates a tmuxinator config for each specified directory. The project name is derived from the directory name. For paths inside a `.worktrees/` directory, the repo name is prepended to avoid collisions across repositories (e.g. `repo/.worktrees/MYJIRA-123` → `repo-MYJIRA-123`). Does nothing if a config already exists for that project.

The generated config uses the standard project template with 3 panes: a banner pane, a Claude pane, and a shell pane.

When the config is new and the path is inside a `.worktrees/` directory, `add` also sets up the workspace's notes directory the way [`start`](README.start.md#notes-directory) does and prints `Notes directory: <path>`. A problem there is a warning on stderr; the config is already made. A config that already exists is left as it is.

## Examples

```sh
# Add a project by path
workspace add ~/Code/my-project

# Add the current directory
workspace add .

# Add multiple projects
workspace add ~/Code/project-a ~/Code/project-b
```
