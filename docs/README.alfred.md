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
# Add the 'wf' workflow to Alfred, or update it after upgrading workspace
workspace alfred install

# Install, then confirm where it went
workspace alfred install && workspace alfred info

# Print the line saying where it was installed
workspace alfred install | grep Installed

# See whether the workflow is installed, and where
workspace alfred info

# Find the workflow's folder to edit it by hand
workspace alfred info | grep Location

# Install it only when missing
workspace alfred info | grep -q 'is installed' || workspace alfred install

# Remove the workflow from Alfred, after confirming
workspace alfred uninstall

# Answer nothing: it cancels and removes nothing
workspace alfred uninstall </dev/null

# In an unattended script with the workflow installed: exits 1 with an error instead of waiting
WORKSPACE_NO_INPUT=1 workspace alfred uninstall
```
