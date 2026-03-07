# workspace kill

Kill workspace projects and their tmux sessions.

## Usage

```sh
workspace kill [project1] [project2] ...
```

## Details

Kills the specified projects' tmux sessions and cleans up their iTerm launcher windows. If no projects are specified, kills all active workspace projects.

Launcher windows are only closed when all tracked projects within them have been killed. If other projects still share the window, it is preserved.

## Examples

```sh
# Kill all active projects
workspace kill

# Kill a specific project
workspace kill my-notes

# Kill multiple specific projects
workspace kill my-notes billing
```
