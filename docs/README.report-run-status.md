# workspace report-run-status

Internal command called by the `workspace run --wait` shell wrapper. Reads the stdout and stderr side-car files for a given UUID, writes the complete JSON result to `~/.workspace-runs/<uuid>.json`, and exits 0.

## Usage

```sh
workspace report-run-status <uuid> <exit_code>
```

## Details

This subcommand is not intended for direct use. It is called automatically by the shell wrapper that `workspace run --wait` injects into the tmux pane:

```sh
(<command>) > '~/.workspace-runs/<uuid>.stdout' 2>'~/.workspace-runs/<uuid>.stderr'
workspace report-run-status <uuid> $?
```

When called, it:

1. Reads `~/.workspace-runs/<uuid>.stdout` (empty string if absent)
2. Reads `~/.workspace-runs/<uuid>.stderr` (empty string if absent)
3. Writes `~/.workspace-runs/<uuid>.json` atomically (via tmp-then-rename)
4. Exits 0

The parent `workspace run --wait` process polls for the `.json` file and reads it once it appears.

**UUID format** — the UUID argument must be a standard RFC 4122 UUID (`8-4-4-4-12` hex). Non-UUID values are rejected to prevent path traversal outside `~/.workspace-runs/`.

**Exit code** — must be an integer. Non-integer values are rejected with a usage error.
