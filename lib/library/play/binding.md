---
description: How to work in a pane that workspace has bound to a run, a review or a play
---
workspace can bind this pane to one subject: a workflow run, a pull request review, or a play. `workspace binding show` prints the binding of the pane you are in, and the same lines reach you at the start of every session, including after `/clear` and after a compaction.

- The binding names an instructions file. Read it before you start. Read it again whenever it is no longer in your context.
- When the binding names an artifacts directory, write the files you are asked to produce there, under the names you were given.
- When a question blocks you, record it with `workspace ask "<question>" --default "<what you did instead>"`, take the default, and keep going. Don't wait for an answer.
- End your turn when the work is done and the files it should produce exist. The end of the turn is how workspace learns you have finished.
- In a workflow run, `workspace step status` prints the step you are on and whether the files it must leave exist. You may run `workspace step done --summary "<one line>"` before you end your turn; it is optional. If the step can't be finished, run `workspace step done --status fail --summary "<what is left>"` and end your turn: the step then fails instead of being checked.
- Don't start a new conversation with `workspace handoff new` unless your instructions tell you to.
