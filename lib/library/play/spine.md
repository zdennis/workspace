---
description: Keep this workspace's stages current
---
This workspace has stages: the steps of its work (research, plan, implement, verify, and so on), one Markdown file each in `spine/`, that the person and the workspace app read to see where the work stands. They are only useful if the files say what is true. Keep the stage you work on current with `workspace spine`.

Find them. `spine/` is inside this workspace's notes directory; run `workspace notes dir` for the path. A stage file is named `<number>-<id>.md` (`30-implement.md`), and `goal.md` holds the goal. A stage's sub-stages are in a folder named like its file without `.md` (`30-implement/`). `workspace spine show` lists the stages with their paths (`implement`, `implement/api`), statuses and `Done when` counts; `--stage <stage-path> --body` reads one stage's text. Run commands from this checkout, or add `--name <workspace>`.

Change stages only with these commands, never by editing `status:`, `owner:` or the `Done when` boxes by hand. They change only their own lines and are safe when someone else writes at the same time.

- Starting a stage: `workspace spine set <stage-path> --status in_progress --owner "$TMUX_PANE"`. `--owner` replaces the owner, so read the stage first and leave off `--owner` when someone else owns it.
- Stuck and need the person or another stage: `workspace spine set <stage-path> --status blocked --note "<why, one line>"`. When moving again, set it back to `in_progress`; that clears the note.
- Each `## Done when` item you have met and checked yourself: `workspace spine check <stage-path> --item N --done`. Item numbers are the `n` of each item in `spine show --stage <stage-path> --json`. Never tick an item you did not check.
- Before you claim a stage done, run `workspace spine show --stage <stage-path> --evaluate --json`. If its `state` is `disputed`, a gate in `gate_results` fails, or `disputes` is not empty, the stage is not done: fix what it names, or leave the stage `in_progress` and say what is left in `--note`.
- Only when every `Done when` item is checked and the evaluation shows no failing gate and no dispute: `workspace spine set <stage-path> --status completed`. Never mark a stage completed that you did not verify.
- Do the same for your own sub-stages, each on its own path. `--recursive` sets a stage and every unfinished sub-stage under it; use it only when all of them are really in that state.

Stay in your lane. Work only on the stage you were started on and its sub-stages. Do not change another stage's file, the numbers in file names, `gates`, or `depends_on`, and do not rename, move, add or delete stage files unless the person asked you to. Do not run `spine start` for another stage; that is the person's call. If the stage is wrong or in your way, say so in your note or to the person.

Write what you find and make in the notes directory, not in the stage files, and list each file in the stage's `artifacts:` (a path relative to the notes directory, or an https URL).

If a command fails, read the error. `stale_revision` means the file changed since you read it: run `workspace spine show` again and decide from what it says now. `no_spine` means this workspace has no stages; stop using these commands and tell the person.
