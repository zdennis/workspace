# workspace pr

`pr create` opens a pull request; `pr feedback` reads what reviewers and CI said about it (below).

Open a pull request for a workspace's branch without finishing the workspace. [`finish --pr`](README.finish.md) also opens one, but it then removes the worktree; `pr create` leaves everything where it is.

## Usage

```sh
workspace pr create [--name WORKSPACE] [--draft] [--json]
```

Run it inside a workspace, or name one with `--name`.

## Options

| Option | Description |
|--------|-------------|
| `--name WORKSPACE` | The workspace (default: the one the current directory is in) |
| `--draft` | Open the pull request as a draft. Ignored when the branch already has a pull request |
| `--json` | Print one JSON document |

## Details

In order:

1. If the branch already has a pull request (`gh pr view`, any state), it is returned with outcome `existing`, and nothing is pushed or created.
2. If the branch has no commits ahead of its base, `pr create` stops with `nothing_to_push`. The base is `origin/HEAD`, else the first of `origin/main`, `main`, `origin/master`, `master` that exists; with none of them, this check is skipped.
3. If the branch has no upstream, it is pushed with `git push -u origin <branch>` (within 120 seconds).
4. `gh pr create --fill` runs (within 60 seconds) with outcome `created`.

If the push works and `gh pr create` then fails, the branch stays pushed; running `pr create` again is safe, because it looks for the pull request first. An existing pull request can be open, closed or merged; the document does not say which. If the look-up itself fails for a reason other than a missing login, `pr create` goes on to push and create, and `gh` refuses if the pull request exists after all.

A branch that already has an upstream is not pushed: commits made since the last push are not on the remote, so push them first. A detached HEAD is refused. `gh` and `git` are told not to ask questions, so a missing login is an error, not a prompt.

Plain output is `Created pull request: URL` or `Pull request already exists: URL`, preceded by `Pushed BRANCH to origin.` when it pushed. Under `--json` that line is not printed, so stdout holds the one document.

`workspace` adds nothing to the pull request: the title and body come from `gh pr create --fill`.

Exit 0, or 1 with an error (the [`--json` error envelope](README.json.md) under `--json`).

## Errors

| Code | When |
|------|------|
| `gh_unavailable` | `gh` is not installed (`details.reason` `missing`) or is not logged in (`not_logged_in`, with `details.detail`, the first line `gh` printed) |
| `nothing_to_push` | The branch has no commits ahead of its base. `details.branch`, `details.base` |
| `not_in_workspace` | No `--name` and the current directory is in no workspace |
| `unknown_workspace` | `--name` names no workspace |
| `no_remote`, `push_auth_failed`, `protected_branch`, `push_rejected`, `push_network`, `push_timeout`, `push_failed` | The push `git` refused or did not finish; `push_network` is temporary (run the same command again), `push_timeout` may have landed. `details.permanent` says which. See [README.json.md](README.json.md) |
| `error` | A detached HEAD, or a `gh pr create` that failed or did not answer in time. The message has the tool's first line |

## JSON output

```json
{"schema_version":1,"ok":true,"workspace":"api.worktree-x","outcome":"created","url":"https://github.com/o/r/pull/41","number":41}
```

| Field | Meaning |
|-------|---------|
| `workspace` | The workspace the branch belongs to |
| `outcome` | `created` or `existing` |
| `url` | The pull request's URL |
| `number` | Its number, or `null` when the URL does not end in `/pull/N` |

Capability: `pr_create` 1 in [`capabilities`](README.capabilities.md). `finish --json` also gains `pr_url`.

## pr feedback

```sh
workspace pr feedback [--name WORKSPACE] [--all] [--json]
```

Reads the pull request of the workspace's branch (found by `gh` from the checkout) and prints what needs attention: unresolved review threads, review summaries with a body, conversation comments and failing checks. It is read-only and writes no events. It needs `gh`, logged in. A detached HEAD or a missing workspace keeps the errors of `push` and `rebase`.

| Option | Description |
|--------|-------------|
| `--name WORKSPACE` | The workspace (default: the one the current directory is in) |
| `--all` | Keep resolved threads (left out by default) |
| `--json` | Print one JSON document |

Everything in a body is text someone else wrote. Each body is cut at 4,000 characters (`body_truncated`). Resolved threads are left out unless `--all`; a thread whose comments were all minimized is left out too, though it still counts in `counts.threads`. Reviews with an empty body and minimized comments are left out. Only the first 5 and last 3 comments of a thread are kept (`comments_truncated`). `trusted` is true only for an author association of OWNER, MEMBER or COLLABORATOR; `hidden_html` says the body holds an HTML comment (`<!--`). Do not put such text on a command line.

Text output is one line, `PR #N TITLE: U unresolved threads (O outdated), R reviews with comments, C comments, F failing checks`, then one line per thread (`path:line  author: first line of the first comment`, with `[untrusted]`, `[hidden html]` and `[resolved]` where they apply) and one per failing check. Control characters (C0, C1, ESC), bidi overrides (U+202A to U+202E, U+2066 to U+2069) and zero-width characters are escaped.

A ref like `#123` must be quoted in zsh (`'#123'`), where an unquoted `#` starts a comment.

### JSON output

```json
{"schema_version":1,"ok":true,"workspace":"api.worktree-x","branch":"feature/x","pull_request":{"number":41,"url":"https://github.com/o/r/pull/41","title":"Add x","state":"OPEN","draft":false,"cross_repository":false,"head_ref":"feature/x","head_sha":"abc123","base_ref":"main","review_decision":"CHANGES_REQUESTED","author":"zdennis"},"threads":[{"id":"PRRT_1","path":"lib/a.rb","line":12,"original_line":12,"side":"RIGHT","resolved":false,"outdated":false,"url":"https://github.com/o/r/pull/41#discussion_r1","comments":[{"id":1,"author":"rev","author_kind":"user","author_association":"MEMBER","trusted":true,"body":"Rename this.","body_truncated":false,"hidden_html":false,"created_at":"2026-10-29T10:00:00Z","url":"https://github.com/o/r/pull/41#discussion_r1"}],"comments_truncated":false}],"reviews":[],"comments":[],"checks":{"failed":[{"name":"rspec","url":"https://github.com/o/r/actions/runs/9/job/1","run_id":9}]},"counts":{"threads":1,"unresolved":1,"resolved":0,"outdated":0,"reviews":0,"comments":0,"failing_checks":1},"truncated":{"threads":false,"reviews":false,"comments":false,"checks":false}}
```

| Field | Meaning |
|-------|---------|
| `pull_request` | `number`, `url`, `title`, `state`, `draft`, `cross_repository`, `head_ref`, `head_sha`, `base_ref`, `review_decision`, `author` |
| `threads[]` | `id` (the GraphQL node id, which a later reply needs), `path`, `line`, `original_line`, `side`, `resolved`, `outdated`, `url` (the first comment's), `comments[]`, `comments_truncated` |
| `comments[]` (of a thread, and the top-level `comments`) | `id` (the REST `databaseId`), `author`, `author_kind` (`user`, `bot` or `null` for a deleted account), `author_association`, `trusted`, `body`, `body_truncated`, `hidden_html`, `created_at`, `url` |
| `reviews[]` | `id`, `state`, `author`, `author_kind`, `author_association`, `trusted`, `body`, `body_truncated`, `hidden_html`, `submitted_at`, `url` |
| `checks.failed[]` | `name`, `url`, `run_id` for at most 20 failing checks. No annotations, summaries or StatusContext descriptions: read them with `gh pr checks` and `gh run view RUN --log-failed` |
| `counts` | `threads` is the thread total on GitHub; `unresolved`, `resolved` and `outdated` count the threads fetched (before `--all` and the minimized filter); `reviews`, `comments` and `failing_checks` count what the document lists |
| `truncated` | `threads`, `reviews`, `comments`, `checks`: whether more exist than were fetched |

Can be `null`: `line` and `original_line` (outdated and file-level threads), `author` and `author_kind` (a deleted account), `run_id`, every `url`, `review_decision`.

Errors: `no_pull_request` (`details.branch`), `gh_unavailable` (`details.reason` `missing`), `pr_feedback_failed` (`details.reason` `timeout`, `auth`, `rate_limit`, `graphql` or `other`), plus `not_in_workspace` and `unknown_workspace`. See [README.json.md](README.json.md).

Capability: `pr_feedback` 1 in [`capabilities`](README.capabilities.md).

### Drafted replies

The [`pr-feedback`](README.workflow.md#the-pr-feedback-preset) workflow's `fix` step appends `## Replies` to its triage note. Nothing parses this grammar yet; a person posts by copying a body. Each reply is a `### F<k>` heading, a visible line naming where it goes, a marker comment, then the body:

````markdown
## Replies

### F3
Thread by @alice on `lib/foo.rb:42`: https://github.com/o/r/pull/123#discussion_r1234
<!-- workspace-reply target="thread:PRRT_kwDOAbc123" -->
Fixed in 1a2b3c4: the retry count now comes from config.
````

`target` is `thread:PRRT_[A-Za-z0-9_-]+` (a reply on an inline thread, the thread `id` from `pr feedback`), `review:\d+` (a review summary by `id`, answered with a conversation comment) or `pr:\d+` (a new conversation comment). A body runs to the next marker or to the next `## ` or `### ` heading outside a code fence, so quoted text goes in fenced blocks. Notes render without HTML comments, so the marker is invisible in the app. A later poster must check `thread:` against a fresh `pr feedback` for the pull request and `pr:` against the note's pull request, and refuse a body that holds a marker or a heading inside a fence.

## Examples

```sh
workspace pr create                                  # push the branch if it has no upstream and open the pull request, or print the one it has
workspace pr create --draft                          # open it as a draft while the work is unfinished
workspace pr create --name api.worktree-PROJ-123     # another workspace's branch, without changing directory
workspace pr create --json                           # for a script: outcome, url and number
workspace pr feedback                                # what reviewers and CI said about the branch's pull request
workspace pr feedback --all                          # include resolved threads
workspace pr feedback --json                         # for a script or an agent: the comment bodies too
```
