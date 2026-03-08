# workspace config

Show project or global workspace configuration.

## Usage

```sh
workspace config [options] [project]
```

## Options

| Option | Description |
|--------|-------------|
| `--global` | Show global configuration instead of project config |

## Details

Displays the YAML configuration for a project or the global workspace config. Auto-detects the project from the current directory if not specified.

## Examples

```sh
# Show config for a specific project
workspace config myproject

# Show config for the current directory's project
workspace config

# Show global configuration
workspace config --global
```
