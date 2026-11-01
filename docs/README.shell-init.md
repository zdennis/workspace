# workspace shell-init

Print shell functions for your rc file: `wf` starts a workflow in one short command, `wfp` picks the workflow and the ref from a list, and tab completes `workspace` and `wf`.

## Usage

```sh
workspace shell-init zsh|bash
```

## Details

`shell-init` prints fixed text and nothing else. Load it from your rc file:

```sh
# ~/.zshrc, after compinit
eval "$(workspace shell-init zsh)"

# ~/.bashrc
eval "$(workspace shell-init bash)"
```

Bash completion needs nothing else. In zsh, put the line after `compinit`. Loaded before it, the completion is silently left off, while `wf` and `wfp` still work.

With no shell, or any shell but `zsh` and `bash`, it is a usage error. `$SHELL` names your login shell, not the one running, so pick the word yourself. Bash 3.2 (the macOS one) or later works. There is no `--json`.

The text is fixed. No workflow name, title or other value of yours is put into it, so loading it runs nothing of yours.

### wf

```sh
wf [-w ID] [--dry-run] [--] REF
wf [-w ID] [--dry-run] [--] TEXT...
```

`wf` runs `workspace workflow start ID ...`. The workflow is `rpiv`, or the value of `WORKSPACE_WF_DEFAULT` when it is set. `-w ID` picks another.

- One word is a REF, as `workflow start` reads it: a ticket key or URL, a pull request, an issue or a branch.
- Several words, or any whitespace, is `--prompt`, with the words joined by spaces. One word of text needs the full command: `workspace workflow start ID --prompt TEXT`.
- `-w ID`, `--dry-run`, `-h` and `--help` are the only options. The first word that is not an option ends them, so `wf fix -w foo` is text. Any other leading dash is a usage error that points at `--`. Put `--` before text that starts with a dash.
- Any other flag (`--branch`, `--input`, `--base`, `--note`, `--json`) needs the full command.
- `--dry-run` checks everything and makes nothing, as it does for `workflow start`.

`wf` needs a git checkout, as `workflow start` does.

`rpiv` and `explore` need a `task`. A ticket, pull request or issue supplies one, and a branch does not, so `wf my-branch` is refused with `Workflow rpiv needs input task`. Say what to do in several words instead (`wf fix the flaky test`), or use the full command: `workspace workflow start rpiv my-branch --input task="fix the flaky test"`.

Quote what the shell would read for itself. In zsh `?` and `*` are globs, and an unquoted `#123` is a comment in a script and in some setups. Write `'#123'` and `'what is this?'`.

### wfp

`wfp` takes no arguments. It asks for the workflow, then the ref or text, then starts it as `wf` would.

With fzf, the first list is the workflows. The second is the refs: your local branches and, when `gh` is installed, the 30 newest open pull requests (`gh` gets 5 seconds). In the second list, Enter takes the highlighted ref and Alt-Enter takes the text you typed, because a typed word that fuzzy-matches a branch would otherwise pick the branch. Esc starts nothing and returns 130.

Without fzf, `wfp` prints the workflows numbered, asks for a number, then reads a typed ref or text. It lists no refs.

A branch from `wfp` is refused the same way when the workflow needs a `task`, as `rpiv` and `explore` do. With those, pick a pull request, or type several words and press Alt-Enter.

`wfp` has no dry run. It starts real work once you answer.

### Completion

Tab completes top-level subcommands, `workflow` verbs, and workflow ids after `workflow start|show|run|update|remove` and after `wf -w`. Anywhere else it falls back to file completion.

A tab at a workflow id runs `workspace workflow show`, which takes about 0.6s.

`workspace shell-init` replaces any completion you already had for `workspace` and `wf`.

### An existing alias or command

An `alias wf` you already have wins over the function. `wf` and `wfp` shadow any command of those names on your PATH.

### Start-up cost

Each new shell pays about 0.6s of Ruby start-up for the `eval`. To avoid it, write the text to a file once and source that:

```sh
workspace shell-init zsh > ~/.workspace.zsh
# in ~/.zshrc, after compinit
source ~/.workspace.zsh
```

The file does not follow upgrades. Write it again after you upgrade workspace.

## Examples

```sh
# Load it (zsh, after compinit)
eval "$(workspace shell-init zsh)"

# Check what a ticket, pull request or issue would start, and start nothing
$ wf --dry-run -w explore '#1'
Would create the workspace for pr-1 in workspace and start explore at step survey.

# Several words are the prompt
$ wf --dry-run -w explore fix the flaky test
Would create the workspace for fix-the-flaky-test in workspace and start explore at step survey.

# Quote text with a question mark
$ wf --dry-run -w explore 'what is this?'
Would create the workspace for what-is-this in workspace and start explore at step survey.

# Text that starts with a dash needs --
$ wf --dry-run -w explore -- '-x fix'
Would create the workspace for x-fix in workspace and start explore at step survey.

# The default workflow, rpiv, wants a task; a branch does not give one
$ wf --dry-run main
Error: Workflow rpiv needs input task. Pass --input task=VALUE.

# Another default for this shell
export WORKSPACE_WF_DEFAULT=investigate

# Pick the workflow and the ref from a list
wfp

# Bash, and a file instead of eval
workspace shell-init bash > ~/.workspace.bash
```
