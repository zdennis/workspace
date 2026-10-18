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
   "root":"/Users/me/Code/my-project","config_path":"/Users/me/.config/tmuxinator/workspace.my-project.yml","notes_dir":null}],
 "warnings":[]}
```

- `outcome` is `created` (a config was written) or `exists` (one was already there, even under a mixed-case name; `workspace` is then its own name and nothing is changed).
- `notes_dir` is the notes directory set up for a new `.worktrees/` config, else `null`; problems setting it up are `warnings`.
- A path that is not a directory is the `not_a_directory` error envelope (`details.path`), checked for every path first, so nothing is added.
- A name refused by `workspace_name_case_conflict` is a `failed` row with that `reason` and `details`; the other paths are still added and the status is `partial` (or `failed` if none were).

Feature `add_json` in [`capabilities`](README.capabilities.md).

## Details

Creates a tmuxinator config for each specified directory. The project name is derived from the directory name. For paths inside a `.worktrees/` directory, the repo name is prepended to avoid collisions across repositories (e.g. `repo/.worktrees/MYJIRA-123` → `repo-MYJIRA-123`). Does nothing if a config already exists for that project.

New workspace names are lowercase (`~/Code/MyApp` becomes `myapp`; a branch's worktree is `myapp.worktree-proj-123`). If a config already exists whose name differs only in case, a different workspace (another directory) is refused with `workspace_name_case_conflict`, naming the existing workspace; it is renamed to lowercase the next time its agentd starts. The same workspace (same directory) written earlier with mixed case, such as `~/Notes` for an existing `Notes`, is reused under its own name.

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
