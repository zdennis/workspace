# workspace current

Print the workspace project name for the current directory.

## Usage

```sh
workspace current
```

## Details

Detects the project by first looking for `.workspace-project` marker files (used by worktree projects), then falling back to matching the current directory against active project roots (longest match wins).

Exits with an error if the current directory is not inside a workspace project.

## Examples

```sh
# Print the current project name
$ workspace current
myproject

# Bring this workspace's window to the front from a script
$ workspace current | xargs workspace focus

# The root directory of the workspace you are in
$ workspace current | xargs workspace dir
```
