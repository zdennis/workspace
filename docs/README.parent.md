# workspace parent

Print the parent workspace of the current (or given) workspace.

## Usage

```sh
workspace parent [NAME] [--name NAME] [--path] [--json | --json-envelope]
```

## Options

| Option | Description |
|--------|-------------|
| `--name NAME` | The same as the `NAME` argument, for scripts that pass `--name` to every command. Giving both with different names is a usage error |
| `--path` | Print the parent's root directory instead of its name |
| `--json` | Print `name`, `path`, `git_common_dir`, `is_worktree`, `worktree` as JSON |
| `--json-envelope` | Print the same fields under a `parent` key in the standard envelope (implies `--json`): `{"schema_version":1,"ok":true,"parent":{...},"warnings":[]}`. See [`--json` output](README.json.md#success-output-without-the-envelope) |

## Details

Uses the same resolver as `lock`, `dev`, and `config set`, so they never disagree
about a workspace's parent. Resolution order:

1. The `.workspace-project` marker (written by `workspace start`), split on `.worktree-`
2. `git rev-parse --git-common-dir`; the parent directory of that path is the main checkout

In a non-worktree workspace, prints its own name, so scripts can always run
`$(workspace parent)`. `is_worktree` in `--json` output tells the two cases apart.

Without `NAME`, resolves from the current directory. With `NAME`, resolves the
named project's configured root directory instead.

Exits 1 with a message if nothing resolves (non-git directory, no marker) or if
`NAME` is not a known project.

`--path` and `--json` are mutually exclusive; combining them raises a usage error
instead of silently preferring one.

## Examples

```sh
$ workspace parent
app

$ workspace parent app.worktree-login
app

$ workspace parent --path
/Users/z/src/app

$ workspace parent --json
{"name":"app","path":"/Users/z/src/app","git_common_dir":"/Users/z/src/app/.git","is_worktree":true,"worktree":"app.worktree-login"}
```
