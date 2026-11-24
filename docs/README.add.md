# workspace add

Add a tmuxinator config for a project directory.

## Usage

```sh
workspace add [--json] <path> [path2] ...
```

`--json` prints one action document (see [JSON output](README.json.md)) instead of text, which goes to stderr. There is one row per path, in order:

```json
{"schema_version":1,"ok":true,"action":"add","status":"ok","results":[
  {"workspace":"my-project","outcome":"created","reason":null,"message":null,
   "root":"/Users/me/Code/my-project","config_path":"/Users/me/.config/tmuxinator/workspace.my-project.yml","notes_dir":null,"claude_trust":null}],
 "warnings":[]}
```

- `outcome` is `created` (a config was written) or `exists` (one was already there, even under a mixed-case name; `workspace` is then its own name and nothing is changed).
- `notes_dir` is the notes directory set up for a new `.worktrees/` config, else `null`; problems setting it up are `warnings`.
- `claude_trust` is what marking the checkout trusted for Claude Code came to when [`agent.claude.trust_checkout`](README.config.md#trusting-a-checkout-for-claude-code) is on and the agent is `claude`: `trusted`, `already`, `missing` (no `.claude.json`), `skipped` (the path did not resolve), `unparseable` or `unwritten` (both also warned on stderr); `null` when the key is off or the agent is another. It never fails the row.
- A new config also gets each coding agent's session hooks installed into the checkout's untracked `.claude/settings.local.json` (kept out of `git status`), as `start` does, so a later `launch` has them; nothing is written when they are current. A stale tracked `.claude/settings.json` is not rewritten and gets a Note. `codex.hooks.install` still governs `~/.codex/hooks.json`. The notes print as text, or are `warnings` under `--json`. An `exists` row installs nothing.
- A path that cannot be added is a `failed` row, never a whole-document error; the other paths are still added. `reason` is `not_a_directory` (`details.path`) or `workspace_name_case_conflict` (`details` as in [JSON output](README.json.md)), and `message` says why.
- The document is always printed. Exit status: 0 when no row failed (`status` `ok`), 3 when some rows failed (`partial`), 1 when every row failed (`failed`).

Without `--json`, a path that is not a directory or whose name is refused is skipped with an `Error:` line on stderr and the other paths are still added; the exit status follows the same rule: 0 when none was skipped, 3 when some were, 1 when all were.

Feature `add_json` in [`capabilities`](README.capabilities.md).

## Details

Creates a tmuxinator config for each specified directory. The project name is derived from the directory name. For paths inside a `.worktrees/` directory, the repo name is prepended to avoid collisions across repositories (e.g. `repo/.worktrees/MYJIRA-123` → `repo-MYJIRA-123`). Does nothing if a config already exists for that project.

New workspace names are lowercase (`~/Code/MyApp` becomes `myapp`; a branch's worktree is `myapp.worktree-proj-123`). If a config already exists whose name differs only in case, a different workspace (another directory) is refused with `workspace_name_case_conflict`, naming the existing workspace. The same workspace (same directory) written earlier with mixed case, such as `~/Notes` for an existing `Notes`, is reused under its own name.

The generated config uses the standard project template with 3 panes: a banner pane, a Claude pane, and a shell pane.

When the config is new and the path is inside a `.worktrees/` directory, `add` also sets up the workspace's notes directory the way [`start`](README.start.md#notes-directory) does and prints `Notes directory: <path>`. A problem there is a warning on stderr; the config is already made. A config that already exists is left as it is.

## Examples

```sh
# Add a project by path
workspace add ~/Code/my-project

# Add the current directory
workspace add .

# Add multiple projects
workspace add ~/Code/project-a ~/Code/project-b
```
