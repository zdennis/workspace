# workspace list

List currently active (launched) projects.

## Usage

```sh
workspace list [options]
```

## Options

| Flag | Description |
|------|-------------|
| `--all` | List all available projects (not just active ones) |
| `--json` | Output as JSON |

## Details

By default, shows which projects are currently running by checking the state file against live iTerm sessions. Only projects with active launcher panes are listed. Dead sessions are automatically pruned.

With `--all`, lists all workspace tmuxinator configs found in `~/.config/tmuxinator/`. Template files are excluded from the listing.

`list-projects` is a hidden alias for `list --all`.

## Examples

```sh
$ workspace list
billing
my-notes

$ workspace list --all
billing
my-notes
work-notes

$ workspace list --json
["billing","my-notes"]

$ workspace list --all --json
["billing","my-notes","work-notes"]
```
