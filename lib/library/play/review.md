---
description: Review a diff with reviewer sub-agents and write review.md
---
Review the change before it is committed or handed over.

- Run reviewer sub-agents over the diff, one Agent call per reviewer, all in one message. When the repository has reviewer definitions in `.claude/agents/`, pick up to three that fit the change. Without them, use three lenses: correctness, tests, and whether the change is more complex than it needs to be.
- Give each reviewer only the diff and the list of changed files. Tell it not to edit files, and to start its reply with PASS or BLOCKING.
- Tell each reviewer: "keep each Bash call to one plain command: no `$(...)`, backticks, arrays, `for`/`while` loops or pipes into loops. For more steps, write them to a script outside the checkout (the run's artifacts directory or a temp directory) and run it with one `bash <path>` call. A command the agent harness can't read safely stops at a permission dialog that nobody answers."
- Fix every finding, or answer it with the reason it doesn't apply. A finding is never dropped silently.
- After a fix, run the reviewer that raised the finding again on the new diff.
- Write `review.md` in the artifacts directory your binding names; with no artifacts directory, give the same content in your reply and write no file. List each reviewer, its verdict, each finding with its `file:line`, and what was done about it.
