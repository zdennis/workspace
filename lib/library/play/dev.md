---
description: Queue for the project's shared dev environment before you implement, test or verify, and give it up when you are done
---
This project has one dev environment, shared by all its worktrees. Only one worktree runs it at a time.

Before you implement, test or verify anything that needs the running app, get the environment for this checkout. Run `workspace dev up --queue`, then `workspace dev wait --max-wait 90s`. `up --queue` returns at once with `started` (this worktree holds the environment) or `queued` (another worktree does, and you are in line). `wait` blocks until this worktree holds it and the ready check passes. Keep each `wait` short so your shell tool does not time out, and run it again when it says you are still queued.

What `wait` exits with:

- 0: this worktree holds the environment and it is ready. Go ahead.
- 75: still queued. Run `workspace dev status` to see which worktree holds it, tell the person, then run `wait` again or stop.
- 1: the queued wrapper exited before it took the lock. Report it and stop.
- 4: the queue was cleared, or this worktree was never in line. Run `up --queue` once more; if `wait` exits 4 again, report it and stop.
- 6: the ready check failed and the environment was stopped. Report it and stop.

If you stop waiting, run `workspace dev leave` so you do not hold a place in line.

Never test against another worktree's server, and do not pass `--force`: it stops the worktree that holds the environment.

`workspace dev status --json` shows `"running": true` and `"ready": null` when the project has no ready check. Then `wait` returns as soon as you hold the environment, so wait for the server's port to answer before you test.

When your work is done, or you stop to wait for the person, run `workspace dev down` so the next worktree can start. Run it only when `dev status` shows this worktree holds the environment: `down` from a worktree that does not hold it refuses with `dev_held_by`. If you hand off to a fresh conversation, leave the environment running; the next conversation keeps using it.
