---
description: Check context after every task and hand off to a fresh conversation before it runs out
---
This workspace uses automatic handoff. You run the check yourself; nobody reminds you.

Once per conversation, read your pane id with `echo "$TMUX_PANE"`. If it is empty you are not in a workspace pane: tell the person handoff is off for this session and carry on without it.

Work out the handoff doc once. It lives in the notes directory (`workspace notes dir --create` prints it): `IMPLEMENTATION_PLAN.md` there when that file exists, otherwise `HANDOFF.md` there. Call its full path DOC.

After each task you finish, and before you start the next, run `workspace handoff check --pane "$TMUX_PANE" --handoff-doc DOC` in this checkout. Do not pass a threshold; the command picks it.

- Exit 0: there is room. Continue.
- Exit 2: usage could not be read. Note the reason it prints and continue. After three in a row, treat it as exit 1.
- Exit 1: a save-state prompt arrives in this pane. Follow it: write what is done, what is in flight, and what comes next into DOC. Then run `workspace handoff new --pane "$TMUX_PANE" --handoff-doc DOC` once and end your turn. The pane is cleared and a fresh conversation resumes from DOC.

Never run `handoff new` from a sub-agent, twice in a row, or before DOC is written. If either command is refused, tell the person what it said and keep working.
