---
description: Read and write this workspace's working notes in its notes directory, never in the repo
---
Keep your working notes in this workspace's notes directory, not in the source tree.

Find it first. Run `workspace notes dir --create` in this checkout and use the path it prints. Do not guess a path, do not read `notes.dir` from a config file yourself, and do not reuse another workspace's directory. If the command is missing or fails, tell the person and stop; do not fall back to the repository root.

What belongs there: the plan (`IMPLEMENTATION_PLAN.md`), findings from research with the question each answers, decisions with their reasons, scratch lists, command output worth keeping, and open questions for the person. Code, tests, generated files the project ships, and secrets do not belong there.

Before you start, list the directory with `ls` and read what is there. Earlier notes are your memory: read the plan before you plan anything new.

Name files so they sort and say what they hold: lowercase words joined with hyphens, `.md`, and a date prefix for dated records, for example `2026-10-12-auth-findings.md`. Keep one file per topic and update it instead of adding a near copy. The plan is always `IMPLEMENTATION_PLAN.md`. A handoff to a fresh conversation is written to `HANDOFF.md` in the same directory; `workspace handoff check` names it for you. When the directory holds a plan, the plan is the handoff doc instead, and the command names that.

Write notes as you work, not at the end. When you stop, write what is done, what is next, and what is blocked.

Never commit the notes. Do not `git add` anything under the notes directory, copy it into the repository, or change `.gitignore` for it. The directory is kept out of git for you. If `git status` shows notes files, tell the person instead of committing them.

Refer to notes by path in your messages so the person can open them.
