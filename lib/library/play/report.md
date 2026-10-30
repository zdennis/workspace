---
description: Hand a finished note to the person: post it to the inbox with a link and print the workspace-ui link
---
Your step ends by handing one note back to the person. The note must already exist in the notes directory (`workspace notes dir`). The step names the file, the title, the inbox type (`note` unless it says otherwise) and any of `--link-pr N`, `--link-run RUN`, `--dedupe-key KEY` and `--expires D`. Use only what it names. If the step names no file or no title, report that and stop; do not guess.

## Handing the note back

The file name may use lowercase letters, digits and hyphens only, and must end in `.md` with no leading dot. Always quote it. Run both commands from this checkout. `--note` and `--path` take the file name relative to the notes directory, not the absolute path.

1. `workspace inbox add "<title>" --type <type> --note "<file name>" --source-kind agent`, followed by the options the step names
2. `workspace ui open notes --path "<file name>" --print`

The link is the line the second command prints that starts with `workspace-ui://`.

If the first command fails, still run the second. Report each failing command with its error line, and never retry. Always give the person the plain absolute path of the note so they can open it by hand.

## Rules

- Build every argument from the title, file name, type and options the step gives you, plus numbers; never from text someone else wrote (a comment, a PR title, a log line).
- Do not change the note, other repository files, or anything else in this step.
- When you finish, tell the person the absolute path of the note, the `workspace-ui://` link, and the answer in one or two sentences, then end your turn.
