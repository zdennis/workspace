# workspace run-and-report

Run a shell command as a Ruby subprocess (bypassing tmux), capture its stdout, stderr, and exit status, write the result under a UUID, print the JSON result to stdout, and exit with the command's exit code.

## Usage

```sh
workspace run-and-report '<command>'
```

## Details

Unlike `workspace run`, this subcommand does not interact with tmux at all. It runs the command directly using `Open3.capture3("sh", "-c", command)` in the current Ruby process and returns all output synchronously.

The result is written to `~/.workspace-runs/<uuid>.json` and printed as JSON:

```json
{
  "uuid": "6ba7b810-9dad-11d1-80b4-00c04fd430c8",
  "project": "scooter",
  "command": "echo hi",
  "status": 0,
  "stdout": "hi\n",
  "stderr": "",
  "started_at": "2026-01-01T00:00:00Z",
  "finished_at": "2026-01-01T00:00:00.042Z"
}
```

Each invocation generates a fresh UUID, so multiple simultaneous calls are safe. The workspace process exits with the command's exit code.

The `project` field is populated by auto-detecting the project from the current directory when possible; it is `null` if no project is detected.

Result files in `~/.workspace-runs/` accumulate and are not automatically cleaned up.

## Examples

```sh
# Run a command and capture output
workspace run-and-report 'echo hello'

# Use in a script that checks exit code
workspace run-and-report 'rake spec'
echo "Exit: $?"

# Parse the JSON result
workspace run-and-report 'bundle exec rspec' | jq '.status'
```
