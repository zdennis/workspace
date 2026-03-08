# workspace focus

Bring a project's iTerm window to the front.

## Usage

```sh
workspace focus [options] [project]
```

## Options

| Option | Description |
|--------|-------------|
| `--shake` | Shake the window after focusing to draw attention |
| `--highlight` | Highlight the window after focusing |
| `--color COLOR` | Color for highlight (default: green). Colors: red, green, blue, yellow, orange, purple, white, cyan, magenta, random |

## Details

Finds the iTerm window for the specified project using its stored window ID and brings it to the front via `window-tool`.

Auto-detects the project from the current directory if not specified, using `.workspace-project` marker files or matching active project roots.

## Examples

```sh
# Focus a project window
workspace focus my-notes

# Focus the current directory's project
workspace focus

# Focus and shake the window
workspace focus --shake my-notes

# Focus and highlight the window in green
workspace focus --highlight my-notes

# Focus and highlight in a specific color
workspace focus --highlight --color blue my-notes
```
