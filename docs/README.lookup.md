# workspace lookup

Find a workspace project by worktree path, branch name, or project key.

## Usage

```sh
workspace lookup <path|branch|project>
```

## Details

Searches for a workspace project using one of these methods, in order:

1. **Project root directory** — Match a directory path to a project's root, or any subdirectory of it. A path under a configured project's root resolves to that project — a worktree under `<root>/.worktrees/` included, even when the worktree has its own config
   - Example: `~/Documents/Obsidian-LocalOnly/Zendesk` → finds `work-notes`
   - Also works with subdirectories: `~/Documents/Obsidian-LocalOnly/Zendesk/Engineering` → finds `work-notes`

2. **Worktree directory path** — When no configured root contains the path, extract the worktree name from its basename and find the corresponding project
   - Example: `/path/to/.worktrees/pr-123` → finds `project.worktree-pr-123`

3. **Branch name or project key** — Find a project by its branch name or project name
   - Example: `PUFFINS-1876-use-lock-version` → finds `growth-engine.worktree-PUFFINS-1876-use-lock-version`
   - Also handles fuzzy matching for branch names with special characters

## Examples

```sh
# Find the project whose root contains a path (a worktree path included)
$ workspace lookup ~/Code/zendesk/growth-engine/.worktrees/growth-engine-kick-test
growth-engine

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
