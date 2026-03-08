# workspace status

Show detailed state of tracked launcher sessions.

## Usage

```sh
workspace status
```

## Details

Shows the internal state of all tracked workspace sessions, including their iTerm unique IDs and whether they are still alive or gone.

Dead sessions are automatically pruned before display, so only live sessions are shown.

Useful for debugging when sessions get out of sync.

## Example

```sh
$ workspace status
  my-notes: 8A3F2B1C-... [alive]
  billing: 7D4E6A9F-... [alive]
```
