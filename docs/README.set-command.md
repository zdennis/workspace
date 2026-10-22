# workspace set-command

Updates the shell command for a specific pane in a project's tmuxinator config file. Supports replacing an existing pane command or appending a new pane.

## Usage

```sh
workspace set-command [project] <command> --pane <N>
workspace set-command --name WS <command> --pane <N>
```

## Options

| Option | Description |
|--------|-------------|
| `--pane N` | Pane index to update (1-based, required) |
| `--name WS` | The project, as an option; then give only `<command>`. Same as the positional `[project]`; both with different names is a usage error |

With only `<command>` and no `--name`, give the command as one quoted argument (two arguments always mean `PROJECT COMMAND`); the project is the one for the current directory; outside a workspace that is a usage error.

## Details

Pane index `N` is 1-based: `--pane 1` is the first pane, `--pane 2` is the second, etc.

If `N` exceeds the number of existing panes, you will be prompted to confirm adding a new pane. The new pane is always appended at the next available index regardless of the value supplied.

After writing the config, the updated pane configuration is printed.

Commands containing shell metacharacters (`&&`, `||`, quotes, colons) are handled safely via YAML quoting.

## Examples

```sh
# Replace the second pane with a custom command
workspace set-command myproject 'vim .' --pane 2

# Replace the first pane (the banner pane)
workspace set-command scooter 'ascii-banner "scooter" --rainbow' --pane 1

# Add a fourth pane (will prompt if only 3 exist)
workspace set-command myproject 'htop' --pane 4
```
