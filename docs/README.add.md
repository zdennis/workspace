# workspace add

Add a tmuxinator config for a project directory.

## Usage

```sh
workspace add <path> [path2] ...
```

## Details

Creates a tmuxinator config for each specified directory, using the directory name as the project name. Does nothing if a config already exists for that project.

The generated config uses the standard project template with 3 panes: a banner pane, a Claude pane, and a shell pane.

## Examples

```sh
# Add a project by path
workspace add ~/Code/my-project

# Add the current directory
workspace add .

# Add multiple projects
workspace add ~/Code/project-a ~/Code/project-b
```
