---
name: finish-branch
description: Finish a topic branch: rebase onto origin/main, run the full gate, merge to main with --no-ff, push, and release a minor version. Use when the person says the branch is done and should ship.
argument-hint: (none)
---

# Finish Branch

Rebase the current topic branch onto origin/main, check it, merge it to main, push, and release.

## Usage

```
/finish-branch
```

## Instructions

Run from the topic branch, usually a linked worktree. Use plain `git` for the rebase: `workspace rebase` aborts a conflicted rebase, and step 3 has to stop inside one.

### 1. Preconditions

Tell the person and stop if any of these fails:

1. `git symbolic-ref -q HEAD` succeeds (a real branch, not a detached HEAD) and the branch is not `main`.
2. No rebase or merge is in progress.
3. `git status --porcelain --untracked-files=no` is empty.

Then `git fetch origin`.

### 2. Rebase

`git rebase origin/main`. If it finishes clean, go to step 4.

### 3. Conflicts

For each conflicted file:

1. Read both sides, and the commits that made them (`git log -p` on each side for that path) before editing.
2. Keep the intent of both. Never resolve by dropping a side wholesale.
3. If the intent cannot be determined, stop inside the rebase and ask the person.

Verify each resolution before `git rebase --continue`:

1. Review the resolved diff.
2. Run the specs for the touched files.
3. Where the behavior itself was in conflict, exercise it: run the command or add a test. Compiling is not proof.

After `git rebase --continue`, resolve any further conflicts the same way, then go to step 4.

### 4. Full gate

Run both, serial, and both must be green:

```
bundle exec rspec
bundle exec standardrb lib/ spec/
```

Serial is the gate, not `script/parallel-spec`.

On a failure, find out whether the rebase caused it: in a throwaway worktree on `origin/main` (`git worktree add --detach <tmp-dir> origin/main`, removed after with `git worktree remove --force`), run the failing example. If it fails there too, stop and tell the person. If not, fix it in a new commit and run the gate again.

When the gate passes, record the topic branch's HEAD SHA (`git rev-parse HEAD`). Step 5 merges only that commit.

### 5. Merge to main

A linked worktree cannot check out `main`. Find the main checkout with `git worktree list` (the entry on `[main]`). In it, with `git -C <main-checkout>`, do these in order, all before merging:

1. It is on `main` and `git status --porcelain --untracked-files=no` is empty. Otherwise stop and ask the person. Never stash someone else's work.
2. `git fetch origin`.
3. Local `main` equals `origin/main`. If it is behind (an ancestor of `origin/main`), fast-forward it with `git -C <main-checkout> merge --ff-only origin/main` and carry on. If it is ahead or diverged, stop and ask: never publish commits you did not make.
4. `git merge-base --is-ancestor origin/main <topic-branch>` succeeds and the topic branch's HEAD equals the recorded SHA. Otherwise go back to step 1, so nothing merges ungated.

Then `git -C <main-checkout> merge --no-ff --no-edit <topic-branch>`. If the merge fails: `git merge --abort`, stop, and tell the person.

### 6. Push

`git -C <main-checkout> push origin main`. Never force.

If it is rejected, do not go back to step 1: the merge commit is already on local `main`. Stop and tell the person local `main` holds an unpushed merge commit. Offer `git reset --hard origin/main` only after they confirm.

### 7. Release

Run `/release minor`. Every release command runs in the main checkout: use `cd <main-checkout> && ...` in the same shell call, or `git -C`, and absolute paths for `lib/workspace/version.rb` and the docs. The shell returns to the worktree between calls.

`/release` commits README and docs changes without a gate. If it changes anything outside docs and README, report it.

If the release fails after the push, the merge is already published. Do not undo it, do not re-run `/release` blindly, never reset or force. Inspect `git status`, `git log origin/main..main` and `git tag --list`, report the exact state, and ask.

### 8. Report

Always report the merge SHA, even if the release failed. Also report the version released and anything skipped. Do not delete the branch or the worktree: ending a workspace is the person's choice.

## Error Handling

- Detached HEAD, on `main`, a rebase or merge in progress, or a dirty tree: tell the person and stop.
- A main checkout that is dirty, off `main`, or ahead of or diverged from `origin/main`: stop and ask.
- A failure that also fails on `origin/main`: stop and tell the person.
- A failed merge: `git merge --abort`, then stop.
- A rejected push: stop and report the unpushed merge commit; reset only after confirmation.
- A failed release: report the state and ask; never undo the published merge.
- Never force-push, stash, or skip hooks.
