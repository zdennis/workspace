# workspace resize

Resize tmux panes for a running workspace project.

## Usage

```sh
workspace resize [project] <pane-spec>
```

## Details

The pane spec is a comma-separated list of sizes, one per pane:

| Format | Meaning |
|--------|---------|
| `10` or `10h` | Absolute row count |
| `50%` | Percentage of window height |
| _(empty)_ | Leave pane as-is |

Auto-saves the current layout as `_before_resize` before applying changes, so you can undo with `workspace layout restore <project> _before_resize`.

Auto-detects the project from the current directory if only a pane spec is provided.

## Examples

```sh
# Resize with project name
workspace resize myproject 15%,,35%

# Resize from within the project directory
workspace resize 10h,80%,20%

# Equal thirds
workspace resize myproject 33%,33%,33%
```
