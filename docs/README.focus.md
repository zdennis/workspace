# workspace focus

Bring a project's iTerm window to the front and shake it.

## Usage

```sh
workspace focus <project>
```

## Details

Finds the iTerm window for the specified project and brings it to the front. The window shakes briefly to draw your attention to it.

First checks for a saved window ID in the state file. If the saved window has disappeared, searches all iTerm windows by title and pane/session names.

## Example

```sh
workspace focus my-notes
```
