---
name: finish-branch
description: Finish a topic branch: rebase onto origin/main, run the gate, merge to main with --no-ff, push, and release a minor version. Use when the person says the branch is done and should ship.
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

### 4. Gate

Run lint plus the specs the branch can reach, serial, and all must be green:

```
bundle exec standardrb lib/ spec/
bundle exec rspec <picked spec files>
```

Pick the specs from the branch's diff (`git diff --name-only origin/main...HEAD`):

1. The spec files changed on the branch, and the spec files covering every `lib/` file it changed.
2. The immediate neighbours: specs for the callers of the classes and methods changed, and any unit or integration specs whose collaborators the branch touches (shared fakes, helpers, or fixtures under `spec/support/` and `spec/fixtures/` count here).
3. Anything else the diff would obviously impact.

Serial is the gate, not `script/parallel-spec`. Run the whole serial suite only when the person asks for it.

On a failure, find out whether the rebase caused it: in a throwaway worktree on `origin/main` (`git worktree add --detach <tmp-dir> origin/main`, removed after with `git worktree remove --force`), run the failing example. If it fails there too, stop and tell the person. If not, fix it in a new commit and run the gate again.

When the gate passes, record the topic branch's HEAD SHA (`git rev-parse HEAD`). Step 5 merges only that commit.

### 5. Merge to main

A linked worktree cannot check out `main`. Find the main checkout with `git worktree list` (the entry on `[main]`). In it, with `git -C <main-checkout>`, do these in order, all before merging. Steps 1 to 3 change nothing, so a stop there has nothing to put back:

1. It is on `main`. Otherwise stop and ask the person.
2. `git fetch origin`.
3. Local `main` is `origin/main` or an ancestor of it. If it is ahead or diverged, stop and ask: never publish commits you did not make. Then `git merge-base --is-ancestor origin/main <topic-branch>` succeeds and the topic branch's HEAD equals the recorded SHA. Otherwise start again from step 1 of this skill (preconditions, rebase, gate), so nothing merges ungated.
4. If `git status --porcelain --untracked-files=no` is not empty, stash the tracked changes and leave untracked files alone. Shell state does not carry between calls, so stash and look up in one call: `tag="finish-branch-<topic-branch>-$(date +%s)"; git -C <main-checkout> stash push -m "$tag" && git -C <main-checkout> stash list --format="%H %gs" | grep -F "$tag"` (no `-u`; git stores the message as `On main: <message>`). Write the tag and the SHA in your reply so later steps have them. Then run the status check again: if it is still not empty, the stash failed; restore any entry it made (step 8) and stop and ask. The stash stack is shared with every worktree and session, so never use `git stash pop`.
5. If local `main` is behind `origin/main`, fast-forward it: `git -C <main-checkout> merge --ff-only origin/main`. If that fails, restore the stash (step 8), stop, and tell the person.

Then `git -C <main-checkout> merge --no-ff --no-edit <topic-branch>`. If the merge fails: `git merge --abort`, restore the stash (step 8), stop, and tell the person.

### 6. Push

`git -C <main-checkout> push origin main`. Never force.

If the push fails for any reason, do not go back to step 1: the merge commit is already on local `main`, unpushed. Leave the stash in place, because a reset would discard restored changes. Stop, tell the person local `main` holds an unpushed merge commit, report the stash entry's message and SHA, and ask whether to `git reset --hard origin/main`. Reset only after they confirm. Restore the stash (step 8) after the reset, or once they decide against one.

### 7. Release

Run `/release minor`. Every release command runs in the main checkout: use `cd <main-checkout> && ...` in the same shell call, or `git -C`, and absolute paths for `lib/workspace/version.rb` and the docs. The shell returns to the worktree between calls.

`/release` commits README and docs changes without a gate. If it changes anything outside docs and README, report it.

If the release fails after the push, the merge is already published. Do not undo it, do not re-run `/release` blindly, never reset or force. Inspect `git status`, `git log origin/main..main` and `git tag --list`, then go to step 8, then report the exact state and ask.

### 8. Restore stashed changes

If step 5.4 stashed anything, put it back after the release, and at every stop after step 5.4 except a failed push (step 6).

1. If `git -C <main-checkout> status --porcelain --untracked-files=no` is not empty (a failed release can leave edits), do not apply. Leave the entry stashed, and report the dirty files and the entry's message and SHA.
2. Otherwise `git -C <main-checkout> stash apply --index <recorded-sha>` (`--index` brings staged changes back staged).
3. If it applies clean, find the entry's current index with `git -C <main-checkout> stash list --format="%gd %H"` by the recorded SHA, and drop it: `git -C <main-checkout> stash drop 'stash@{n}'` (quoted for zsh).
4. If the apply conflicts (the merge or the release's docs commit may touch the same files) or refuses for any other reason, do not drop the entry, and leave the checkout as it is: no reset, checkout or restore over conflict markers. Tell the person the reason, the conflicted files, and the entry's message and SHA.

### 9. Report

Always report the merge SHA, even if the release failed. Also report the version released, whether stashed changes were restored, and anything skipped. Do not delete the branch or the worktree: ending a workspace is the person's choice.

## Error Handling

- In the topic worktree: detached HEAD, on `main`, a rebase or merge in progress, or tracked changes: tell the person and stop.
- A main checkout with tracked changes: stash them (step 5.4) and restore them (step 8) after the release and at every stop that follows the stash, except a failed push, where they stay stashed until the reset is decided. Untracked files are left alone.
- A main checkout off `main`, or ahead of or diverged from `origin/main`: stop and ask.
- A failure that also fails on `origin/main`: stop and tell the person.
- A failed fast-forward or merge: `git merge --abort` for the merge, restore the stash (step 8), then stop.
- A failed push: stop and report the unpushed merge commit and the stash entry; reset only after confirmation, then restore the stash.
- A failed release: restore the stash (step 8), report the state and ask; never undo the published merge.
- Never force-push `main`. The topic branch may be force-pushed with `--force-with-lease` (for example after the rebase in step 2). Never skip hooks. Stash only the main checkout's tracked changes, by a tagged entry, and apply it back by SHA.
