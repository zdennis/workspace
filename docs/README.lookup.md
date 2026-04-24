# workspace lookup

Find a workspace project by worktree path, branch name, or project key.

## Usage

```sh
workspace lookup <path|branch|project>
```

## Details

Searches for a workspace project using one of three methods:

1. **Worktree directory path** — Extract the worktree name from a path and find the corresponding project
   - Example: `/path/to/.worktrees/pr-123` → finds `project.worktree-pr-123`

2. **Project root directory** — Match a directory path to a project's root
   - Example: `~/Documents/Obsidian-LocalOnly/Zendesk` → finds `work-notes`
   - Also works with subdirectories: `~/Documents/Obsidian-LocalOnly/Zendesk/Engineering` → finds `work-notes`

3. **Branch name or project key** — Find a project by its branch name or project name
   - Example: `PUFFINS-1876-use-lock-version` → finds `growth-engine.worktree-PUFFINS-1876-use-lock-version`
   - Also handles fuzzy matching for branch names with special characters

## Examples

```sh
# Find by worktree path
$ workspace lookup ~/Code/zendesk/growth-engine/.worktrees/growth-engine-kick-test
growth-engine.worktree-growth-engine-kick-test

# Find by branch name
$ workspace lookup PUFFINS-1876-use-lock-version
growth-engine.worktree-PUFFINS-1876-use-lock-version

# Find by project name
$ workspace lookup growth-engine
growth-engine

# Find by project root directory
$ workspace lookup ~/Documents/Obsidian-LocalOnly/Zendesk
work-notes

# Find by subdirectory of project root
$ workspace lookup ~/Documents/Obsidian-LocalOnly/Zendesk/Engineering
work-notes

# Error when not found
$ workspace lookup unknown-project
Error: No workspace project found for 'unknown-project'
```
