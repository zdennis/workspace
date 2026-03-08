# workspace stop

Stop workspace projects and their tmux sessions.

## Usage

```sh
workspace stop [project1] [project2] ...
```

## Details

Stops the specified projects' tmux sessions and cleans up their iTerm launcher windows. If no projects are specified, stops all active workspace projects.

Launcher windows are only closed when all tracked projects within them have been stopped. If other projects still share the window, it is preserved.

Projects can be restarted with `workspace launch`.

## Examples

```sh
# Stop all active projects
workspace stop

# Stop a specific project
workspace stop my-notes

# Stop multiple specific projects
workspace stop my-notes billing
```
