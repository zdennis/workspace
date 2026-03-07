# workspace focus

Bring a project's iTerm window to the front.

## Usage

```sh
workspace focus [options] <project>
```

## Options

| Option | Description |
|--------|-------------|
| `--shake` | Shake the window after focusing to draw attention |

## Details

Finds the iTerm window for the specified project using its stored window ID and brings it to the front via `window-tool`.

## Examples

```sh
# Focus a project window
workspace focus my-notes

# Focus and shake the window
workspace focus --shake my-notes
```
