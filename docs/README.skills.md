# workspace skills

Link the four workspace skills that ship in `lib/skills` into the skills directory of each coding agent on your machine, or remove those links. The skills teach an agent to use the `workspace` CLI: `workspace` (the router and ground rules), `workspace-agent-run`, `workspace-inbox` and `workspace-lifecycle`.

## Usage

```sh
workspace skills install [--install-all] [--dry-run] [--json] [--no-input]
workspace skills uninstall [--dry-run] [--json]
```

## Options

| Option | Description |
|--------|-------------|
| `--install-all` | `install` only. Install for every harness found, ask nothing, and clear the harnesses you declined earlier |
| `--dry-run` | Print what would happen and write nothing, not even the record of declined harnesses |
| `--json` | Print one JSON document ([below](#json-output)). The question, when there is one, goes to stderr so stdout holds only the document |
| `--no-input` | A global option (or `WORKSPACE_NO_INPUT`). `install` fails with `confirmation_required` when it would have to ask. Use `--install-all` to answer for it |

## Where the links go

Each skill is a link to its whole directory, never a copy and never a file inside it. A harness counts as found when its program is on `PATH` or its config directory exists.

| Key | Harness | Skills directory | Found by |
|-----|---------|------------------|----------|
| `claude` | Claude Code | `~/.claude/skills` | `claude`, or `~/.claude` |
| `codex` | Codex | `$CODEX_HOME/skills` (default `~/.codex/skills`) | `codex`, or the Codex home |
| `pi` | Pi | `~/.pi/agent/skills` | `pi`, or `~/.pi` |
| `opencode` | OpenCode | `~/.config/opencode/skills` | `opencode`, or `~/.config/opencode` |
| `agents` | Shared skills | `~/.agents/skills` | the directory exists |

`~/.agents/skills` is linked only when it already exists, and only when at least one harness is installed. `install` never creates it. A harness's own skills directory is created when it is linked.

Where the links point depends on how workspace is installed. Under Homebrew they point at the `opt` path (`/opt/homebrew/opt/workspace/libexec/lib/skills/<name>`), which `brew upgrade` re-points, so links survive an upgrade. From a checkout they point at that checkout's `lib/skills`.

## install

`install` asks once, on one screen, which of the harnesses found to install for. Answer with numbers or names, `all` (also an empty answer) or `none`. The harnesses you leave out are remembered as declined in `skills.json` in the state directory and are not asked about again. `--install-all` installs for all of them and clears the record. A harness whose four links are already ours is never asked about.

End of input at the question installs nothing new and records nothing, so an unattended run cannot opt every harness out. The exit code is 0 and `ok` is true, and the undecided harnesses read `skipped`: exit 0 does not mean installed. It prints how to run it again. When every harness found is declined, it also exits 0 with nothing to do.

In each directory it links all four skills or none. Nothing that is not our own link is ever replaced:

- A link of ours (named as one of the four, pointing at a `lib/skills/<name>` of this tool) is relinked to the current source. That is what a re-run does after a move or an upgrade.
- A real directory identical to the shipped one is moved to `skill-backups/<time>/` in the state directory and linked. The text report says where it went.
- A real directory with other content, a file, or someone else's link is refused. Nothing is linked in that directory, and the row carries the `mv` command that moves the path aside. Run it, then run `install` again.
- A skills directory that is, or holds, the skills source is refused, so the source can never be moved.

A failure while writing undoes what was done in that directory and reports `skill_link_failed`.

### Run it after each update

`install` is a consent step, and links only change when you run it. Run it again after each update: it relinks what moved, adds a skill a newer version ships, and says what changed (`Skills already current in N directories.` when nothing did). A re-run asks only about harnesses it has not seen, so it is safe in a script with `--install-all --no-input`. [`doctor`](README.doctor.md#skill-links) reports links that are missing or dangling and `doctor --fix` repairs them.

### From a linked worktree

`install` refuses from a linked git worktree with `skill_source_worktree`, because links into it would dangle once `finish` or `kill` removes it. Run it from the main checkout or a Homebrew install. This is read from the `.git` file alone, so `HOME`, `PATH` and git itself do not matter.

## uninstall

`uninstall` removes our links, dangling ones included, from every skills directory above that exists, found or not. It works from a linked worktree and ignores `--no-input`, since it never asks. A real directory or someone else's link at one of the four names stays, and the report counts it as left. It asks nothing and records no decline. It never fails because something was left.

## Exit codes

| Code | Meaning |
|------|---------|
| 0 | Done, or already current |
| 1 | A path was refused or a write failed; no harness found; `skill_source_worktree`; the install has no skills; or a question under `--no-input`. Also a usage error: a missing or unknown subcommand, an extra argument, or `--install-all` with `uninstall` |

`--dry-run` exits 1 when the real run would refuse.

## JSON output

`--json` prints one document on stdout. Failures that stop the command before any link is looked at (the codes below marked "error") use the usual [error envelope](README.json.md#failure).

```json
{"schema_version":1,"ok":true,"version":"0.75.0","source":"/opt/homebrew/opt/workspace/libexec/lib/skills","dry_run":false,
 "harnesses":[
  {"key":"claude","dir":"/Users/me/.claude/skills","status":"linked","skills":[
    {"name":"workspace","outcome":"linked","from":null,"to":"/opt/homebrew/opt/workspace/libexec/lib/skills/workspace","code":null},
    {"name":"workspace-inbox","outcome":"unchanged","from":"/opt/homebrew/opt/workspace/libexec/lib/skills/workspace-inbox","to":"/opt/homebrew/opt/workspace/libexec/lib/skills/workspace-inbox","code":null}]},
  {"key":"codex","dir":"/Users/me/.codex/skills","status":"declined","skills":[]},
  {"key":"pi","dir":"/Users/me/.pi/agent/skills","status":"skipped","skills":[]}],
 "warnings":[]}
```

- `ok` is false when any skill is `refused` or `failed`. The exit code is then 1 and the document is still printed.
- `source` is the directory the links point at; it is `null` for `uninstall`.
- `install` has a row per harness known (found ones first, then an `agents` row when `~/.agents/skills` was linked, then the ones not found). `status` is `linked` (done or already current), `refused`, `failed`, `declined` (left out now or before), or `skipped` (not found, or found and unanswered at end of input; nothing was written). `uninstall` has a row per skills directory that exists, with `status` `removed` or `skipped`; a failed removal shows only on its skill row (`outcome` `failed`, `ok` false, exit 1).
- Each skill row has `name`, `outcome`, `from` (what was at the path: a link target, `directory` or `file`, else `null`), `to` (the target to link) and `code`. Any row with a problem adds `message` (a refusal, a failure with the OS error, or an `uninstall` row left alone); a refusal also adds `mv`. An `adopted` row adds `backup`.
- `outcome` is `linked`, `relinked`, `adopted` (an identical real directory backed up and linked), `unchanged`, `skipped` (not written because another skill in the directory was refused; it has `code` null, so look at the `refused` row beside it), `refused`, `failed`, and for `uninstall` `removed` or `left`.
- `warnings` is a list of free-text strings, such as `<dir> is a link; writing through it to <real>`. A warning does not change `ok`.
- With `--dry-run`, outcomes say what the real run would do.

### Error codes

| Code | Where |
|------|-------|
| `skill_path_exists` | A skill row: a real directory with other content, a file, a skills directory that is a dead link or not a directory, or a directory that is or holds the source. Also an `uninstall` row left alone |
| `skill_link_foreign` | A skill row: the path is a link that is not ours |
| `skill_link_failed` | A skill row: the write or removal failed |
| `skill_source_worktree` | Error: run from a linked worktree. `details.path` |
| `skills_source_missing` | Error: the install lacks a skill under `lib/skills`. `details.path`, `details.missing` |
| `no_harness_found` | Error: none of the four harnesses is on `PATH` and none has a config directory |
| `confirmation_required` | Error: `install` would ask and `--no-input` is set. Pass `--install-all` |

The capability is `skills` in [`capabilities --json`](README.capabilities.md). The codes are listed in [`README.json.md`](README.json.md#error-codes).

## Examples

```sh
# Pick which coding agents to link
workspace skills install

# See which links would be made, and which paths would be refused, for every coding agent found: asks nothing, writes nothing
workspace skills install --install-all --dry-run

# After an update, or to take back a coding agent you left out: all of them, no question
workspace skills install --install-all

# Unattended: every coding agent found, one JSON document
workspace skills install --install-all --no-input --json

# See what an uninstall would remove
workspace skills uninstall --dry-run

# Stop offering the skills to your coding agents
workspace skills uninstall
```
