# workspace alfred

Manage the Alfred workflow for workspace focus.

## Usage

```sh
workspace alfred <subcommand>
```

## Subcommands

| Subcommand | Description |
|------------|-------------|
| `install` | Install or update the Alfred workflow |
| `uninstall` | Remove the Alfred workflow |
| `info` | Show workflow installation status |

## Details

The workflow lets you type 'wf' in Alfred to list and focus active workspace projects. Assign a hotkey in Alfred Preferences > Workflows > Workspace Focus.

Requires Alfred to be installed with the workflows directory at its default location.

## Examples

```sh
# Install the workflow
workspace alfred install

# Check installation status
workspace alfred info

# Remove the workflow
workspace alfred uninstall
```
