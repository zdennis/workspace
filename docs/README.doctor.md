# workspace doctor

Check that all required dependencies are installed and configured.

## Usage

```sh
workspace doctor
```

## Details

Checks for all required tools (ruby, tmux, tmuxinator, iTerm2, window-tool, git) and optional tools (gh, ascii-banner). Reports version information and provides install instructions for anything missing.

Also verifies that tmuxinator templates are installed.

Exits with a non-zero status if any issues are found, so it can be used in scripts.

## Example

```sh
$ workspace doctor
workspace doctor

  ✓  ruby (3+)
  ✓  tmux (3+)
  ✓  tmuxinator (3+)
  ✓  iTerm2
  ✓  window-tool
  ✓  git (2+)
  ✓  gh (2+)
  ✓  ascii-banner
  ✓  templates installed

Everything looks good!
```
