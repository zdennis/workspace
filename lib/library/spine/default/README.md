---
description: Research, plan, implement, verify, review and ship, one file per stage
---

# Plan spine for {{WORKSPACE}}

This folder is the stage level of the workspace's plan. Each numbered file is one stage, and `goal.md` says what the work is for.

- A stage file starts with a block between two `---` lines. Its `status` is one of `not_started`, `in_progress`, `blocked`, `completed` or `skipped`.
- `depends_on` names the stages that come first. `gates` names the checks a reader can run: `plan`, `checklist`, `pushed`, `pr`, `ci`, `merged` or `review`.
- The `## Done when` list at the end of a stage is its checklist. Tick a line as it becomes true.
- The numbers are in tens, so a stage can be added between two others. A folder named like a stage file without `.md` holds that stage's sub-stages.
- Read the whole folder with `workspace spine show`.
