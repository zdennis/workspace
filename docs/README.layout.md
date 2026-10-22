# workspace layout

Save, restore, and list tmux pane layouts for workspace projects.

## Usage

```sh
workspace layout <subcommand> [--name WS] [args]
```

## Subcommands

| Subcommand | Description |
|------------|-------------|
| `save [name]` / `save PROJECT NAME` | Save the current pane layout (default name: 'default') |
| `restore [name]` / `restore PROJECT NAME` | Restore a saved layout (default name: 'default') |
| `list [project]` | List saved layouts for a project |

## Details

Named layouts are stored in per-project config YAML. Ephemeral snapshots (like `_before_resize`) are stored in the state file.

Layouts are auto-saved as `_before_resize` whenever you run `workspace resize`, so you can always undo a resize with `workspace layout restore --name PROJECT _before_resize`. Note that `layout restore PROJECT _before_resize` still works, but `layout restore _before_resize` alone means the layout in the current directory's workspace.

The project is `--name WS`, else the one for the current directory (outside a workspace that is a usage error). With one argument, `save` and `restore` always read it as the layout name, never as a project (this changed: older versions read a single argument as the project); outside a workspace with no `--name` that is a usage error; give two arguments (`PROJECT NAME`) or `--name` to name the project. `--name` with two arguments is a usage error. `list` takes `[project]` positionally or `--name`.

## Examples

```sh
# Save the current layout as 'default'
workspace layout save --name myproject

# Save with a custom name
workspace layout save myproject coding

# Restore the default layout
workspace layout restore --name myproject

# Undo a resize (one argument is always the layout name, so name the project with --name)
workspace layout restore --name myproject _before_resize

# List saved layouts
workspace layout list myproject

# Save from within the project directory
workspace layout save
workspace layout save coding

# Restore a layout for a named project
workspace layout restore --name myproject coding
```
