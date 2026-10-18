---
description: Keep this workspace's plan spine current
---
This workspace has a plan spine: the stages of its work (research, plan, implement, verify, and so on), one Markdown file each, that the person and the workspace app read to see where the work stands. It is only useful if the files say what is true. Keep the stage you work on current.

Find it. The spine is the `spine/` folder inside this workspace's notes directory; run `workspace notes dir` and use the path it prints. A stage file is named `<number>-<id>.md` (`30-implement.md`), and `goal.md` holds the goal. A stage's sub-stages are in a folder named like its file without `.md` (`30-implement/`). `workspace spine show` lists the stages, their paths (`implement`, `implement/api`), statuses and `Done when` counts. Run commands from this checkout, or add `--name <workspace>`.

Use `workspace spine set` to change a status. Do not edit `status:` by hand; `spine set` changes only the status, note, `updated` and `updated_by` lines, and it is safe when someone else writes at the same time. Edit by hand only if `workspace spine set` does not exist in this version.

- When you start a stage, run `workspace spine set <stage-path> --status in_progress`. Read the stage file: if its `owner:` is empty, set it to your pane id (`$TMUX_PANE`) by hand. `spine set` does not write `owner:`, so this is the one line you edit yourself. Leave an owner that someone else set.
- When you are stuck and need the person or another stage, run `workspace spine set <stage-path> --status blocked --note "<why, one line>"`. When you are moving again, set it back to `in_progress`; that clears the note.
- Under `## Done when` in the stage file, change `- [ ]` to `- [x]` as each item is met, and only for an item you checked yourself.
- When every `Done when` item is met and checked, run `workspace spine set <stage-path> --status completed`. Never mark a stage completed that you did not verify, and never tick an item you did not check. If part of it is not done, leave it `in_progress` and say what is left in `--note`.
- Do the same for your own sub-stages, each on its own path. `--recursive` sets a stage and every unfinished sub-stage under it; use it only when all of them are really in that state.

Stay in your lane. Work only on the stage you were started on and its sub-stages. Do not change another stage's file, the numbers in file names, `gates`, or `depends_on`, and do not rename, move, add or delete stage files unless the person asked you to. If the stage is wrong or in your way, say so in your note or to the person.

Write what you find and make in the notes directory, not in the spine files, and list each file in the stage's `artifacts:` (a path relative to the notes directory, or an https URL).

If a command fails, read the error. `stale_revision` means the file changed since you read it: run `workspace spine show` again and decide from what it says now. `no_spine` means this workspace has no spine; stop using these commands and tell the person.
