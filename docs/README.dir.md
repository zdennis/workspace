# workspace dir

Print the root directory of a workspace project.

## Usage

```sh
workspace dir [--name WS] [project]
```

## Details

Outputs the full path to a workspace project's root directory as defined in its tmuxinator config file. Useful for scripting and integration with other tools that need to know where a project is located.

With no project (positionally or with `--name`), it prints the root of the workspace the working directory is in: a worktree's `.workspace-project` marker, else the active workspace whose root holds the directory. Outside any workspace it fails with `not_in_workspace`. A positional and a `--name` that differ are a usage error.

Paths are expanded (tilde `~` is resolved to the user's home directory).

## Examples

```sh
# The root of the workspace you are in
$ workspace dir

# Get the root directory of a project
$ workspace dir api
/Users/z/src/api

# Put the path on the clipboard
$ workspace dir api | pbcopy

# The checkout of one worktree workspace
$ workspace dir --name api.worktree-login
/Users/z/src/api/.worktrees/api-login

# Use the output in a script
$ cd $(workspace dir myproject)

# Error when project doesn't exist
$ workspace dir unknown
Error: Project 'unknown' not found or has no root directory configured
```
