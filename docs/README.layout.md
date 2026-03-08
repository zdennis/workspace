# workspace layout

Save, restore, and list tmux pane layouts for workspace projects.

## Usage

```sh
workspace layout <subcommand> [project] [name]
```

## Subcommands

| Subcommand | Description |
|------------|-------------|
| `save [project] [name]` | Save the current pane layout (default name: 'default') |
| `restore [project] [name]` | Restore a saved layout (default name: 'default') |
| `list [project]` | List saved layouts for a project |

## Details

Named layouts are stored in per-project config YAML. Ephemeral snapshots (like `_before_resize`) are stored in the state file.

Layouts are auto-saved as `_before_resize` whenever you run `workspace resize`, so you can always undo a resize.

Auto-detects the project from the current directory if not specified. When auto-detected with one argument, the argument is treated as the layout name rather than the project.

## Examples

```sh
# Save the current layout as 'default'
workspace layout save myproject

# Save with a custom name
workspace layout save myproject coding

# Restore the default layout
workspace layout restore myproject

# Undo a resize
workspace layout restore myproject _before_resize

# List saved layouts
workspace layout list myproject

# Save from within the project directory
workspace layout save
workspace layout save coding
```
