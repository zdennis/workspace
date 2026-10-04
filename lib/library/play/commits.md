---
description: Cohesive commits, tests and lint first, no attribution, no push
---
- Make each commit one cohesive change, with its tests. Unrelated changes go in their own commits.
- Run the project's tests and lint before every commit, and commit only when both pass. The project's commands are listed below when it has set them with `workspace config set commands.test` and `commands.lint`; otherwise find them in the project's `CLAUDE.md` or README.
- Write the message about why the change was made. The diff already shows what changed.
- Add no attribution lines: no `Co-Authored-By`, no "Generated with".
- Stage the paths you changed by name. Don't use `git add -A` or `git add .`.
- Don't amend, rebase or force-push commits that exist on a remote, and don't skip hooks with `--no-verify`.
- Don't push, merge or open a pull request unless your instructions say to. When they name a merge policy, such as `--no-ff`, follow it; otherwise leave merging to the person.
