# workspace tmux

Show a workspace's tmuxinator file as session fields, windows and panes.

## Usage

```sh
workspace tmux show [--name NAME] [--json]
```

## Options

| Option | Description |
|--------|-------------|
| `--name NAME`, `--project NAME` | The workspace to show instead of the one inferred from cwd |
| `--json` | Print one JSON document (below) instead of a summary |

## Details

Reads `~/.config/tmuxinator/workspace.<name>.yml` and, when the session is running, asks tmux for each pane's id and start command. Nothing is written and no tmux option is changed. tmuxinator reads the file only when a session launches, so an edit applies on the next `launch` or `relaunch` (`applies` is always `relaunch`).

Pane commands and `on_project_start` are printed as written, and a command can carry a secret; unlike `config show --json`, nothing here is masked.

Without `--json` it prints the session, then each window and each pane's kind and first line of command.

## JSON output

```json
{"schema_version":1,"ok":true,"workspace":"api","file":"/Users/me/.config/tmuxinator/workspace.api.yml",
 "etag":"sha256:a0af...","erb":false,"parse_error":null,
 "session":{"name":"api","root":"/src/api","startup_pane":2,"tmux_options":"-CC","attach":false,
            "on_project_start":"tmux resize-pane -t api:0.0 -y 15%\n"},
 "windows":[{"index":0,"name":"workspace-api","layout":"even-vertical","panes":[
   {"index":0,"title":null,"command":"printf '\\033]2;workspace-api\\a' &&\nascii-banner \"api\"","kind":"banner","line":18,"live":null},
   {"index":1,"title":null,"command":"claude --continue || claude","kind":"claude","line":23,
    "flags":["--continue"],"live":{"pane_id":"%25","start_command":null}},
   {"index":2,"title":null,"command":null,"kind":"shell","line":24,"live":{"pane_id":"%26","start_command":null}}]}],
 "running":true,"applies":"relaunch"}
```

- `etag` is `sha256:` and the hash of the file's bytes. `erb` is true when the file contains `<%`; workspace doesn't render ERB, so a file that uses it may show a `parse_error` or panes that differ from what tmuxinator runs.
- `parse_error` is null, or `{"message", "line", "column"}` when the file can't be parsed. `session` is then null, `windows` is empty and `running` is null.
- `session.startup_pane` and the pane `index` values are 0-based, like every other `--pane`. `line` is the 1-based line of the pane's entry in the file.
- `command` is the pane's command text, null for a bare shell. A pane written as a one-pair hash (`title: command`) has `title` set; a list of commands is joined with newlines.
- `kind` is `claude` (a `claude` command word), `agentd`, `banner` (`ascii-banner` or `figlet`), `shell` (no command) or `command`. `flags` is present for `claude` panes and lists the `--flags` on its first `claude` invocation.
- `running` is true when a tmux session with the file's `name` exists, false when not, and null when tmux didn't answer. `live` is null unless the session is running; its `start_command` is what tmux started the pane with, which is null for a pane tmuxinator typed its command into (tmuxinator panes usually start a bare shell). Windows pair with tmux's by order, so a non-zero `base-index` doesn't matter.
- A workspace with no tmuxinator file is an error document with code `unknown_workspace`.

## Examples

```sh
workspace tmux show
workspace tmux show --name api --json | jq '.windows[0].panes[] | {index, kind}'
```
