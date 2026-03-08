# workspace relaunch

Stop all active workspace projects and relaunch them.

## Usage

```sh
workspace relaunch
```

## Details

Convenience command that stops all active projects and then relaunches them. Useful when you want a fresh start without manually specifying which projects to launch.

Exits with a non-zero status if there are no active projects to relaunch.

## Example

```sh
$ workspace relaunch
Will relaunch: my-notes, billing
Stopped 2 project(s): my-notes, billing
Creating 2 new launcher pane(s)...
Done! Launched 2 project(s).
```
