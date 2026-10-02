# workspace relaunch

Stop all active workspace projects and relaunch them.

## Usage

```sh
workspace relaunch
```

## Details

Convenience command that stops all active projects and then relaunches them. Useful when you want a fresh start without manually specifying which projects to launch.

[Headless](README.launch.md#headless) projects are relaunched headless; the others come back in iTerm2.

Exits with a non-zero status if there are no active projects to relaunch.

## Example

```sh
$ workspace relaunch
Will relaunch: my-notes, billing
Stopped 2 project(s): my-notes, billing
Creating 2 new launcher pane(s)...
Done! Launched 2 project(s).
```

## JSON output

`--json` prints an action document (see [README.json.md](README.json.md#actions)) with one row per project: `relaunched`, or `failed` as for `launch`. With nothing active it prints the failure envelope. The text goes to stderr.
