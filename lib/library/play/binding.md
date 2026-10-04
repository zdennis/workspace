---
description: How to work in a pane that workspace has bound to a run, a review or a play
---
workspace can bind this pane to one subject: a workflow run, a pull request review, or a play. `workspace binding show` prints the binding of the pane you are in, and the same lines reach you at the start of every session, including after `/clear` and after a compaction.

- The binding names an instructions file. Read it before you start. Read it again whenever it is no longer in your context.
- When the binding names an artifacts directory, write the files you are asked to produce there, under the names you were given.
- When a question blocks you, record it with `workspace ask "<question>" --default "<what you did instead>"`, take the default, and keep going. Don't wait for an answer.
- End your turn when the work is done and the files it should produce exist. The end of the turn is how workspace learns you have finished.
- Don't start a new conversation with `workspace handoff new` unless your instructions tell you to.
