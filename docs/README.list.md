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
| `--with-url` | Include the git origin URL alongside each project name |

## Details

By default, shows which projects are currently running by checking the state file against live iTerm sessions. Only projects with active launcher panes are listed. Dead sessions are automatically pruned.

With `--all`, lists all workspace tmuxinator configs found in `~/.config/tmuxinator/`. Template files are excluded from the listing.

`list-projects` is a hidden alias for `list --all`.

`--with-url` reads the `origin` remote URL from the project's git repository (no network call). Projects with no configured root or no `origin` remote show a blank URL column. Combine with `--all` to see URLs for every available project. When combined with `--json`, each object gains a `"url"` key.

## Examples

```sh
$ workspace list
billing
my-notes

$ workspace list --all
billing
my-notes
work-notes

$ workspace list --with-url
billing        https://github.com/zendesk/billing
my-notes       git@github.com:zdennis/my-notes.git

$ workspace list --all --with-url
billing        https://github.com/zendesk/billing
my-notes       git@github.com:zdennis/my-notes.git
work-notes     https://github.com/zendesk/work-notes

$ workspace list --json
["billing","my-notes"]

$ workspace list --all --json
["billing","my-notes","work-notes"]

$ workspace list --json --with-url
[{"name":"billing","directory":"/path/to/billing","url":"https://github.com/zendesk/billing"},...]

$ workspace list --all --json --with-url
[{"name":"billing","directory":"/path/to/billing","url":"https://github.com/zendesk/billing"},...]
```
