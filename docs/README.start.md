# workspace start

Create a git worktree and launch it as a workspace project.

## Usage

```sh
workspace start <jira-key|jira-url|pr-url|issue-url|branch>
```

## Accepted Inputs

| Input | Example | Behavior |
|-------|---------|----------|
| JIRA issue key | `PROJ-123` | Used as branch name |
| JIRA URL | `https://mycompany.atlassian.net/browse/PROJ-123` | Extracts issue key |
| GitHub PR URL | `https://github.com/owner/repo/pull/471` | Fetches branch name via `gh` |
| GitHub issue URL | `https://github.com/owner/repo/issues/123` | Creates branch `issue-123` |
| Branch name | `user/PROJ-123` | Used as-is |

## Details

Must be run from within a git repository. Creates a worktree in `.worktrees/` under the project root, generates a tmuxinator config, and launches it.

If the branch already exists (locally or remotely), it checks it out. If not, it prompts you to choose a base branch for creation.

If multiple remote branches match your input, you'll be prompted to select one or create a new branch.

## Examples

```sh
# Start from a JIRA key
workspace start PROJ-123

# Start from a GitHub PR
workspace start https://github.com/org/repo/pull/471

# Start from a GitHub issue
workspace start https://github.com/org/repo/issues/42

# Start from a branch name
workspace start feature/my-feature
```
