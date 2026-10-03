# workspace list

List currently active (launched) projects.

See also: `workspace projects`, which groups workspaces by repository.

## Usage

```sh
workspace list [options]
```

## Options

| Flag | Description |
|------|-------------|
| `--all` | List all available projects (not just active ones) |
| `--json` | Output as JSON |
| `--show-urls` | Include the git origin URL alongside each project name |
| `--liveness` | Mark each active project `[alive]`, `[dead]`, or `[unknown]` from its tmux session |

## Details

By default, lists the projects in the state file, without checking whether they are still running (see `--liveness`). Nothing is pruned; `workspace cleanup` and `workspace prune` remove dead entries.

With `--all`, lists all workspace tmuxinator configs found in `~/.config/tmuxinator/`. Template files are excluded from the listing.

`list-projects` is a hidden alias for `list --all`.

`--show-urls` reads the `origin` remote URL from the project's git repository (no network call). Projects with no configured root or no `origin` remote show a blank URL column. Combine with `--all` to see URLs for every available project. When combined with `--json`, each object gains a `"url"` key.

`--liveness` checks each active project's tmux session (one `tmux list-sessions` call); it applies to active projects and can't be combined with `--all`. `[dead]` means the state file still lists the project but its tmux session is gone; `[unknown]` means tmux didn't answer or the project uses a custom tmux socket. Without `--json` the marker is the last column; with `--json` the output is an array of `{"name", "alive"}` objects (plus `directory` and `url` with `--show-urls`), where `alive` is `true`, `false`, or `null`. Plain `list` output is unchanged. `workspace status` always reports liveness.

## Examples

```sh
$ workspace list
billing
my-notes

$ workspace list --all
billing
my-notes
work-notes

$ workspace list --show-urls
billing        https://github.com/zendesk/billing
my-notes       git@github.com:zdennis/my-notes.git

$ workspace list --all --show-urls
billing        https://github.com/zendesk/billing
my-notes       git@github.com:zdennis/my-notes.git
work-notes     https://github.com/zendesk/work-notes

$ workspace list --liveness
billing   [alive]
my-notes  [dead]

$ workspace list --liveness --json
[{"name":"billing","alive":true},{"name":"my-notes","alive":false}]

$ workspace list --json
["billing","my-notes"]

$ workspace list --all --json
["billing","my-notes","work-notes"]

$ workspace list --json --show-urls
[{"name":"billing","directory":"/path/to/billing","url":"https://github.com/zendesk/billing"},...]

$ workspace list --all --json --show-urls
[{"name":"billing","directory":"/path/to/billing","url":"https://github.com/zendesk/billing"},...]
```
