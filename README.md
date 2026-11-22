# cxq

`cxq` is a work queue for coding agents — and the humans who review them.

Give an agent a task with a clear title, acceptance criteria, allowed
paths, and a verification command, and `cxq` tracks it from `inbox` to
`done`: claim it with a lease, work it, send it to `review`, and close it
only when a human accepts it. It is a SQLite queue with a small CLI, a
kanban board, and (since v0.4.0) a shared server — not a full project
manager or issue tracker, and deliberately not one.

By default the queue is repo-local (`.cxq/tasks.db`). Since v0.4.0 it can
also run **shared**: one small server owns the SQLite file and every agent
VM talks to it over HTTPS (`cxq serve` + `CXQ_REMOTE_URL`), so all agents
see the same board. The CLI, the dashboard, and the API all edit the same
tasks, with the same validation and the same event history.

## Quickstart (60 seconds)

~~~sh
git clone https://github.com/daniel-aranda/Agents-todo.git
cd Agents-todo
./install.sh                    # installs the global `cxq` command (macOS or Linux)

cd /path/to/your/project
cxq install                     # creates .cxq/tasks.db for this repo
cxq add "Fix flaky auth refresh test" --priority 80
cxq board                       # see the queue
cxq claim-next --lease 2h --format prompt
~~~

That last command hands the next task to your agent, with the full task
prompt. When the work is ready for a human, the agent moves it to `review`
— never straight to `done`. To share one queue between agent VMs instead,
see [Shared queue: server + remote mode](#shared-queue-server--remote-mode).

## What's new in 0.5.0

- **Trash, restore, and undo** — `cxq delete` moves a task to trash
  instead of removing it ([Trash, restore, and undo](#trash-restore-and-undo)):
  `cxq restore` brings it back, `cxq trash purge` permanently deletes
  trashed tasks older than 30 days, and `cxq undo` reverts the last edit.
- **Schema v5** — adds the `trashed` status plus `trashed_from_status` /
  `trashed_at` columns; v3 and v4 queues auto-migrate in place.
- **MCP server** — `mcp/cxq_mcp.py` ([MCP server](#mcp-server-stdio-json-rpc)):
  a stdio JSON-RPC server exposing the queue as 7 MCP tools
  (`list_tasks`, `add_task`, `claim_task`, `update_task`, `note`,
  `board`, `stats`), so an MCP client can work the queue directly.
- **Due dates and recurrence** — `cxq due` ([Due dates and
  recurrence](#due-dates-and-recurrence)): overdue, due today, and due
  tomorrow in one view, plus an overdue count badge on the dashboard.
  `--recurs daily|weekly|monthly` on `add`/`edit` makes a task recur:
  marking it done creates the next occurrence automatically.
- **Schema v6** — adds the `recurs` column; v3, v4, and v5 queues
  auto-migrate in place.

## What's new in 0.4.0

- **Edit tickets** — `cxq edit` ([Editing tasks](#editing-tasks)): title,
  priority, due date, tags, files, acceptance, and status, with a diff in
  the event history. `cxq delete` with guardrails.
- **See the queue** — `cxq board`, `cxq stats`, `cxq activity`
  ([Board, stats, and activity](#board-stats-and-activity)).
- **Shared queue** — `cxq serve` + remote mode
  ([Shared queue](#shared-queue-server--remote-mode)): one server owns the
  SQLite file; every agent VM sees the same board over HTTPS.
- **Linux support** — `install.sh` now works on macOS and Linux.

## Contents

- [What it looks like](#what-it-looks-like)
- [Requirements](#requirements)
- [Why cxq exists](#why-cxq-exists)
- [Project-local queues](#project-local-queues)
- [Command surface](#command-surface)
- [Example task](#example-task)
- [Editing tasks](#editing-tasks)
- [Due dates and recurrence](#due-dates-and-recurrence)
- [Trash, restore, and undo](#trash-restore-and-undo)
- [Board, stats, and activity](#board-stats-and-activity)
- [Shared queue: server + remote mode](#shared-queue-server--remote-mode)
- [MCP server (stdio JSON-RPC)](#mcp-server-stdio-json-rpc)
- [Schema versions and migration](#schema-versions-and-migration)
- [Dependencies](#dependencies)
- [Task statuses](#task-statuses)
- [Findings](#findings)
- [Agent contract](#agent-contract)
- [Development](#development)
- [Continuous integration](#continuous-integration)

<img width="1672" height="941" alt="cxq list output showing queued tasks" src="https://github.com/user-attachments/assets/174b46e1-0048-4f17-8514-e53256d0b6bd" />

*Above: `cxq list` in a project queue (screenshot from an earlier version;
the commands shown still work the same way).*

## What it looks like

~~~bash
$ cxq list

id  status  priority  title
--  ------  --------  ------------------------------------------------------------
1   ready   100       Scaffold Node.js TypeScript project foundation
2   ready   95        Create initial PostgreSQL schema migrations
3   ready   92        Implement local service setup and connectivity checks
4   ready   90        Build shared Polymarket API client foundation
5   ready   88        Implement Gamma active market catalog collector
6   ready   84        Implement candidate trader seeding jobs
7   ready   80        Implement wallet activity and position snapshot polling
8   ready   76        Implement position snapshot diff engine
9   ready   72        Implement trader scoring v0
10  ready   68        Implement liquidity checker and paper signal engine v0
11  ready   64        Implement paper signal evaluation and reporting
~~~

Then hand the next task to your agent:
~~~bash
cxq claim-next --lease 2h --format prompt
~~~

## Requirements

- macOS or Linux
- `bash`
- `git`
- `sqlite3`

No package manager or Node.js runtime is required. `python3` and `curl` are
only needed for the optional shared server (`cxq serve`) and remote mode
(`CXQ_REMOTE_URL`); the local queue still needs nothing but `bash` + `sqlite3`.

By default, `install.sh` installs to `$HOME/.local/bin`. If that directory is
not already on `PATH`, the installer prints the shell profile update needed for
your shell. You can choose a prefix explicitly:

~~~sh
PREFIX=/opt/homebrew ./install.sh
./install.sh --prefix "$HOME/.local"
~~~

## Why cxq exists

Agents are better workers when tasks are explicit.

A good agent task should include:

- a clear title
- acceptance criteria
- allowed file paths
- a verification command
- priority
- status
- claim and lease information
- notes and review summaries

Markdown TODO lists are easy to edit but easy to corrupt. Raw SQL is powerful
but too sharp as the day-to-day interface. `cxq` keeps SQLite as the source of
truth and exposes safe, predictable commands for humans and agents.

~~~text
SQLite      = state
cxq         = API
AGENTS.md   = agent protocol
Agent       = worker
Git         = project boundary
~~~

## Project-local queues

`cxq` uses one queue per repository.

The queue files live in `.cxq/` at the repo root. `cxq` is multi-agent,
and any agent can claim and work tasks through the CLI, whatever name it
claims with.

Queues created before v0.4.0 lived in `.codex/` instead. The first `cxq`
command in such a repo migrates the queue to `.cxq/` in place — database,
schema, prompt, and `.gitignore` entries — preserving every task and
event. A half-moved queue (template files already in `.cxq/`, database
still in `.codex/`) is finished the same way. Only a genuine conflict — a
database in *both* directories — is left alone with a warning, and
`.cxq/` wins then.

When you run:

~~~sh
cxq install
~~~

from the root of a Git project, it creates the local queue files needed for that
project.

`cxq install` is non-destructive. If `.cxq/tasks.schema.sql` or
`.cxq/prompts/task.md` already exists, it leaves the file unchanged and prints
a message saying so.

Expected project layout:

~~~text
your-project/
  AGENTS.md
  .gitignore
  .cxq/
    tasks.db
    tasks.schema.sql
    prompts/
      task.md
~~~

The SQLite database is local state and should not be committed:

~~~text
.cxq/tasks.db
.cxq/tasks.db-*
~~~

The schema and prompt templates can be committed so the project documents how
its queue works.

## Git project guardrail

`cxq install` only runs at the root of a Git project.

If you run it anywhere else, it exits without changing files and prints a clear
message:

~~~text
cxq install only runs at the root of a Git project.
~~~

This protects random directories from getting `.cxq` files and makes the
project boundary explicit.

## Command surface

The current version of `cxq` is intentionally focused — one queue, one
workflow, no extra concepts to learn:

~~~sh
cxq -v
cxq version --plain
cxq doctor
cxq install
cxq update
cxq update --status
cxq update --check
cxq version bump patch
cxq version set 0.4.1
cxq release prepare 0.4.1
cxq add "Fix flaky auth refresh test"
cxq list
cxq due [--format json|table|md]
cxq next
cxq show 42
cxq claim 42 --agent <name> --lease 2h
cxq claim-next --lease 2h --format prompt
cxq block 42 --by 17
cxq deps 42
cxq unblock 42 --by 17
cxq note 42 "Found race in token refresh path"
cxq prompt 42
cxq review 42 --summary "Implemented lock and added regression test"
cxq reopen 42 --reason "acceptance criteria 3 is still missing"
cxq followup 42 "Handle the error branch" --close
cxq finding add 42 --severity high --note "Retry loop is unbounded"
cxq finding list 42
cxq finding resolve 7
cxq list --needs-action
cxq list --questions
cxq review-stale --older-than 24h
cxq status-transitions
cxq done 42
cxq repo 42
cxq stale
cxq release 42
cxq edit 42 --title "New title" --priority 90 --due 2026-12-01
cxq undo 42
cxq delete 42 --force
cxq restore 42
cxq trash
cxq trash purge --all
cxq board
cxq stats
cxq activity --limit 20
cxq export-md
cxq export --format json
cxq watch --interval 5s
cxq migrate
cxq serve --port 8080 --generate-token
cxq remote status
~~~

`cxq doctor` is read-only. It reports the installed version, PATH resolution,
required tools, install metadata, update state, current repo queue setup, and
lightweight database diagnostics: schema version, task counts by status, and the
result of `PRAGMA integrity_check`.

The default workflow is:

~~~text
inbox -> ready -> claimed -> review -> done
~~~

Agents should normally stop at `review`. A human decides when a task is truly
`done`.

`cxq add` creates `ready` tasks by default so `cxq next` can immediately find
them.

## Example task

~~~sh
cxq add "Refactor billing webhook verifier" \
  --priority 70 \
  --tag security \
  --files "src/billing,tests/billing" \
  --acceptance "
- preserve existing behavior
- add tests for bad signatures
- run pnpm test billing
" \
  --verify "pnpm test billing"
~~~

Then an agent can claim and work the task:

~~~sh
cxq claim-next --lease 2h --format prompt
~~~

`cxq show 42` renders the current task fields and recent events.

`cxq prompt 42` renders a deterministic agent prompt with the task body, tags,
allowed paths, acceptance criteria, verification command, recent events, result
summary when present, and finishing instructions.

## Editing tasks

Tickets are editable — this was the biggest gap before v0.4.0:

~~~sh
cxq edit 42 --title "Refactor billing webhook verifier" --priority 80
cxq edit 42 --due 2026-12-01 --tags-add security --files-add "src/billing"
cxq edit 42 --acceptance "add tests for bad signatures" --verify "pnpm test billing"
cxq edit 42 --status ready --reason "acceptance criteria 3 is still missing"
cxq edit 42 --due-clear
~~~

Flags: `--title`, `--body`, `--priority`, `--acceptance`, `--verify`,
`--branch`, `--due YYYY-MM-DD` (validated as a real calendar date),
`--due-clear`, `--recurs daily|weekly|monthly|none` (see
[Due dates and recurrence](#due-dates-and-recurrence)), `--status`,
`--files` (set) / `--files-add` / `--files-remove`,
`--tags` (set) / `--tags-add` / `--tags-remove`, and `--reason`.
At least one change flag is required; an edit that changes nothing is an
error. Every edit logs **one** `edited` event with a human-readable diff
(`title: old -> new; priority: 50 -> 90`), and `cxq show 42` renders the
due date, age, lease remaining, and the full edit history.

`--status` is validated against the status-transitions table, so
`ready -> done` is still rejected; moving a task out of `review` or `done`
requires `--reason`. Use `cxq claim` to claim a task — `edit --status claimed`
is rejected because a claim needs an agent and a lease.

Deleting is deliberately guarded and reversible:

~~~sh
cxq delete 42 --force   # alias: cxq remove 42 --force
~~~

Without `--force`, a TTY asks for confirmation and a non-interactive run
refuses. Delete moves the task to trash instead of removing the row: its
events, findings, and dependencies are kept, so it can come back whole.
Trashed tasks do not appear in `cxq list` or `cxq board`, cannot be claimed
or edited, and do not block other tasks. A trashed task that was claimed
lands back on `ready` when restored, because its claim was cleared.

## Due dates and recurrence

Due dates exist to be noticed. `cxq due` shows what needs attention:

~~~sh
cxq due                          # overdue, due today, due tomorrow
cxq due --format json            # flat array with a due_group field
cxq due --format md
~~~

Boundaries are exact: overdue means due before today, today means due
today, tomorrow means due tomorrow. Tasks without a due date never
appear, and neither do `done`, `wontfix`, or trashed tasks. "Today" is
SQLite `date('now')` (UTC) for the local CLI; the server's
`/api/v1/due` endpoint and dashboard badge use the server-local date,
matching the server's own overdue counts.

Recurring tasks repeat themselves. Set the interval when creating or
editing a task:

~~~sh
cxq add "Water the plants" --due 2026-12-01 --recurs daily
cxq edit 42 --recurs weekly            # needs a due date already set
cxq edit 42 --recurs none              # stop recurring
~~~

Rules:

- `--recurs` accepts only `daily`, `weekly`, or `monthly`; anything
  else is an error.
- A recurring task must have a due date. Adding or editing one without
  `--due` fails, and `--due-clear` on a recurring task fails too.
- When a recurring task is marked done — via `cxq done`, via
  `cxq edit --status done`, or via `cxq followup --close` — the next
  occurrence is created automatically: same title, body, priority,
  tags, allowed paths, and acceptance criteria, status `ready`, same
  `recurs` value, and the due date advanced from the **old** due date
  (daily +1 day, weekly +7 days, monthly +1 calendar month, clamped
  to the last day of the target month: Jan 31 → Feb 28). The completed
  task gets a `recurrence` event naming the new task id. The new
  occurrence never inherits the claim, the dependencies, or the result
  summary. Marking the same task done twice creates exactly one next
  occurrence — only a real transition into done spawns one.
- Restoring a trashed task to `done` does not spawn an occurrence:
  restore is not a completion.

The dashboard shows an **Overdue: N** badge in the header (from
`/api/v1/stats`, refreshed with the board poll) and the task modal has
a Recurs field. There is no push or email digest: the server has no
scheduler by design — the badge is the digest. `cxq due` works in
remote mode too, through `GET /api/v1/due`.

Without `--due`, a task never recurs and never appears in `cxq due`.

## Trash, restore, and undo

~~~sh
cxq trash                  # list trashed tasks, with pre-trash status and trash date
cxq restore 42             # back to its pre-trash status
cxq trash purge            # permanently delete tasks trashed more than 30 days ago
cxq trash purge --days 7   # ... more than 7 days ago
cxq trash purge --all      # empty the trash regardless of age
cxq undo 42                # revert the most recent edit (title, priority, due date, status, ...)
~~~

`cxq list --status trashed` lists trashed tasks; `cxq stats` reports a
`status_trashed` count. Purging is permanent — purged tasks, their events,
findings, and dependencies are gone for real. Purging an empty trash
succeeds and reports `Purged 0 trashed task(s)`.

`cxq undo` reverts one edit at a time: a second `cxq undo` reverts the edit
before it. It restores the exact previous field values, including a cleared
due date and a changed status (with the claim that status change cleared).
It errors when there is nothing to undo, when the last edit predates undo
support, and on a trashed task — restore it first. `cxq edit` cannot move a
task to `trashed` directly; use `cxq delete`.

In remote mode, `restore`, `undo`, and `trash` are not supported yet — the
server has no trash/undo endpoints — and fail with a clear error instead of
touching a local database.

## Board, stats, and activity

~~~sh
cxq board                 # kanban grouped by status, with counts, OVERDUE and LEASE EXPIRED flags
cxq stats                 # counts by status, overdue, stale reviews, oldest ready, done last 7d, top blockers
cxq activity              # recent events across all tasks, newest first
cxq activity --limit 50
cxq export-md             # Markdown mirror of the board (stdout)
cxq export --format json  # full task export (stdout)
cxq export --format csv
cxq watch                 # re-render the board every 5s until Ctrl-C
cxq watch --interval 10s
~~~

`cxq list` also grew filters that compose:

~~~sh
cxq list --status review --tag security --agent <name>
cxq list --priority-min 80 --search "auth refresh" --overdue --due-before 2026-12-01
cxq list --format json
cxq list --format md
~~~

With no new flags, `cxq list` output is exactly the old table. `cxq show 42`
now renders the due date (with an `OVERDUE` marker), the task's age, the
lease remaining, and the edit history.

## Shared queue: server + remote mode

Local mode is one SQLite file per repo. Shared mode is one server owning
one SQLite file, with every agent connecting over HTTPS:

~~~sh
# On the machine that hosts the queue (a VM, Fly.io, ...):
cxq serve --port 8080 --generate-token
# prints the generated token once — save it; agents need it as CXQ_REMOTE_TOKEN

# On every agent VM:
export CXQ_REMOTE_URL="http://<host>:8080"
export CXQ_REMOTE_TOKEN="<the token>"
cxq remote status
cxq list            # same commands, now against the shared queue
cxq add "Fix flaky test" --priority 80
cxq edit 42 --title "New title"
cxq claim-next --lease 2h --format prompt
~~~

`cxq serve` runs in the foreground (Ctrl-C stops it; no daemon inside cxq).
It requires `CXQ_TOKEN` — set it, or pass `--generate-token` once. The
server is Python 3 standard library only (`server/cxq_server.py`, no pip
packages): it serves a single-file dashboard at `/` (kanban board, search
and filters, click a card to view and edit it, create/claim/review/done
buttons, dark mode, mobile-responsive, live refresh by polling every 5s)
and a JSON API under `/api/v1/` (`/tasks`, `/board`, `/stats`, `/activity`,
`/health`, …). All mutations validate exactly like the CLI — ids, statuses,
transitions, due dates — and log events identically. Only `/health` is
unauthenticated; everything else needs the Bearer token.

When `CXQ_REMOTE_URL` is set, `list/show/add/edit/claim/claim-next/next/
board/stats/activity/note/review/done/reopen/release/delete/block/deps/
unblock/finding/prompt/stale/export/export-md` go through the HTTP API
(requires `curl` + `python3` for JSON rendering). When it is unset, local
mode is completely unchanged.

**The server is the single writer.** Agents never point `sqlite3` at a
shared file over NFS/SSHFS. See `deploy/README.md` for the free deployment
options (Fly.io primary, Oracle Cloud Always Free VPS + Tailscale second),
backup instructions (`cxq export` + volume snapshots + `sqlite3 .backup`),
and token rotation.

## MCP server (stdio JSON-RPC)

`mcp/cxq_mcp.py` exposes the queue to MCP clients (Claude Code,
Claude Desktop, …) over stdio as 7 tools:

| Tool | Does |
| --- | --- |
| `list_tasks` | `cxq list --format json`, optional `status` filter |
| `add_task` | `cxq add <title>` (+ `body`, `priority`, `tags`) |
| `claim_task` | `cxq claim <id>` (`agent` defaults to `mcp`) |
| `update_task` | `cxq edit <id>` (`title`, `body`, `priority`, `status`) |
| `note` | `cxq note <id> <text>` |
| `board` | `cxq board` |
| `stats` | `cxq stats` |

Point a client at it (example for Claude Code, run from the repo whose
queue you want — the server inherits its working directory, and the
CLI finds the project-local queue from there):

~~~json
{
  "mcpServers": {
    "cxq": {
      "command": "python3",
      "args": ["/path/to/cxq/mcp/cxq_mcp.py"]
    }
  }
}
~~~

After `install.sh`, the installed copy lives at
`<prefix>/lib/cxq/cxq_mcp.py` and can be invoked by that path instead.

Design note: the server shells out to the `cxq` CLI (one invocation
per tool call) instead of talking to SQLite itself, so the CLI stays
the single owner of business rules, locking, and migrations. It finds
`bin/cxq` relative to the repo root (the `mcp/` directory sits next to
`bin/`), so it works from any working directory; set `CXQ_BIN` to point
it at an explicit CLI path. CLI failures surface as MCP tool errors
(`isError: true` with the CLI's stderr), never as crashes. Python 3
standard library only (`json`, `sys`, `os`, `subprocess`), same rule as
`server/cxq_server.py`; no network, no telemetry, no daemons. It exits
cleanly (code 0) on stdin EOF.

## Schema versions and migration

The queue schema is versioned in `cxq_meta.schema_version` (v6 in 0.5.0,
which adds the `recurs` column; v5 added the `trashed` status and the
`trashed_from_status` / `trashed_at` columns). `cxq install` creates v6
databases. A v3, v4, or v5 database is migrated in place, preserving all data:

~~~sh
cxq migrate        # explicit; also refreshes an old stock .cxq/tasks.schema.sql
cxq list           # any command auto-migrates a v3/v4/v5 queue on open, with a notice
cxq doctor         # reports repo_schema_version (expected 6) and remote mode
~~~

Databases older than v3 are not auto-migrated; they are reported by
`cxq doctor` / `cxq update --repo` instead.

## Dependencies

Tasks can be blocked by other tasks:

~~~sh
cxq block 42 --by 17
cxq deps 42
cxq unblock 42 --by 17
~~~

`cxq claim-next` and `cxq next` skip tasks with blockers that are not `done`.
Once every blocker is `done`, the dependent task becomes claimable again while
preserving normal priority ordering. Self-dependencies and cycles are rejected.

## Task statuses

`cxq` intentionally keeps status simple:

| Status | Meaning |
| --- | --- |
| `inbox` | Captured, but not ready for an agent |
| `ready` | Available to claim |
| `claimed` | Currently owned by a human or agent |
| `blocked` | Waiting on input, dependency, or decision |
| `review` | Implementation attempted; human review needed |
| `done` | Accepted |
| `wontfix` | Intentionally abandoned |

## Status transitions

Review is a real state, not a formality, so work can move backwards. Run:

~~~sh
cxq status-transitions
~~~

to print every supported movement and the command that performs it. The table is
the single source of truth: commands validate against it.

| From | To | Command |
| --- | --- | --- |
| `ready` | `claimed` | `cxq claim` or `cxq claim-next` |
| `claimed` | `ready` | `cxq release <id>` |
| `claimed` | `review` | `cxq review <id> --summary "..."` |
| `blocked` | `ready` | `cxq release <id>` |
| `review` | `ready` | `cxq reopen <id> --reason "..."` |
| `review` | `blocked` | `cxq reopen <id> --to blocked --reason "..."` |
| `review` | `done` | `cxq done <id>` |
| `done` | `ready` | `cxq reopen <id> --reason "..."` |

`cxq release <id>` returns a `claimed` or `blocked` task to `ready`.

## Reopening and follow-ups

A partially accepted review has two honest outcomes: send it back, or close it
and split off the leftover work.

~~~sh
cxq reopen 42 --reason "acceptance criteria 3 is still missing"
cxq reopen 42 --to blocked --reason "waiting on a product decision"
cxq followup 42 "Handle the error branch"
cxq followup 42 "Handle the error branch" --close
~~~

`cxq reopen` requires a reason, records it as an event, clears the claim fields,
and preserves the result summary and note history. `--to` accepts `ready`
(default), `inbox`, or `blocked`.

`cxq followup <id> <title>` (alias `cxq split`) creates a `ready` task that
inherits the original's allowed paths, tags, priority, and verification command
unless you override them. The follow-up is recorded as blocked by the original,
so it becomes claimable once the original is `done`. `--close` marks the original
`done` and notes the follow-up id in its result summary.

## Findings

Review outcomes are often "approve, with caveats". Findings make those caveats
first-class instead of free text buried in a summary:

~~~sh
cxq finding add 42 --severity high --note "Retry loop is unbounded"
cxq finding add 42 --severity low --status accepted --note "Naming nit"
cxq finding add 42 --severity medium --note "Edge case untested" --followup 51
cxq finding list 42
cxq finding resolve 7
cxq finding resolve 7 --status accepted
~~~

Severity is `low`, `medium`, `high`, or `critical`. Status is `open`, `accepted`,
or `resolved`. `cxq show` renders a `Findings` section when a task has any.

A task with open findings can still be approved, but `cxq done` will warn first.

## Operational views

Three read-only views cut the queue down to what needs a human:

~~~sh
cxq list --needs-action
cxq list --questions
cxq review-stale --older-than 24h
~~~

`--needs-action` shows `ready` and `blocked` tasks plus any `review` task
carrying open findings. `--questions` lists notes that start with `DUDA:` or
`BLOCKER:`, so agent questions do not get lost in the event log.
`cxq review-stale` lists reviews nobody has touched inside the window; it
defaults to `24h` and accepts the same `30m`/`2h`/`1d` syntax as leases.

## Closing tasks

`cxq done 42` accepts the task. It warns first when closing looks premature:

- the result summary still mentions pending or leftover work
- the task still has open findings

Interactive runs ask for confirmation. Non-interactive runs stop and tell you to
use `--force`. A clean close is never blocked.

~~~sh
cxq done 42 --summary "Implemented and verified"
cxq done 42 --summary "Main flow works, docs pending" --force
~~~

## Concurrency

Several agents and humans can use one queue at the same time. Both the project
queue and the global state database run in WAL mode, every SQLite call sets a
busy timeout, and transient `database is locked` failures are retried with a
short backoff. Non-lock SQLite errors still fail immediately.

Tuning is available but rarely needed:

~~~sh
CXQ_SQLITE_BUSY_TIMEOUT_MS=5000
CXQ_SQLITE_MAX_ATTEMPTS=5
~~~

## Leases

Claims should have leases:

~~~sh
cxq claim 42 --agent <name> --lease 2h
~~~

If an agent crashes, the task should not be stuck forever. Expired claims can be
shown as stale or made available again.

Use `cxq stale` to list expired claims and `cxq release 42` to return a claimed
task to `ready`.

## Updates

`cxq` keeps small global state in `~/.cxq/state.db`.

For normal queue commands, `cxq` checks whether an update is required before it
continues. Remote self-update checks use `git ls-remote` at most once per day.
If a newer stable `vMAJOR.MINOR.PATCH` tag is found, or if the current project
queue setup is missing required local files, normal commands are gated until
the update is handled.

Useful commands:

~~~sh
cxq update
cxq update --status
cxq update --check
cxq update --self
cxq update --repo
cxq update --all
~~~

`cxq update` is the normal path: it checks remote tags, updates `cxq` when a
newer stable version exists, reapplies safe repo setup when needed, and prints a
short status. Non-interactive updates that would modify files require
`--yes`.

`cxq update --self` only auto-updates when `install.sh` recorded a Git checkout
as the install source. It fetches tags, pulls with `--ff-only`, and reruns that
checkout's `install.sh`. `cxq update --repo` reapplies the safe project setup
without overwriting customized schema, prompt, or `AGENTS.md` files.

Escape hatches:

~~~sh
CXQ_NO_UPDATE_CHECK=1 cxq list
CXQ_ASSUME_YES=1 cxq claim-next --format prompt
~~~

`CXQ_NO_UPDATE_CHECK=1` skips the gate. `CXQ_ASSUME_YES=1` lets `cxq` attempt
`cxq update --yes` automatically when an update is required.

## Version And Release

Version and release commands are for this `cxq` source repo, not arbitrary user
projects.

~~~sh
cxq version --plain
cxq version bump patch
cxq version bump minor
cxq version bump major
cxq version set 0.4.1
~~~

Release preparation is explicit and local-first:

~~~sh
cxq release prepare 0.4.1
cxq release tag 0.4.1
cxq release publish 0.4.1
cxq release 0.4.1
~~~

`cxq release prepare` verifies the requested version and writes release notes to
`/tmp/cxq-release-vX.Y.Z.md`. The draft summarizes commits since the previous
stable `v*` tag; when no earlier tag exists it says so and treats the release as
the first draft. Review the generated highlights before publishing.

`cxq release tag` creates and pushes the Git tag. It must run from `main`, and
local `main` must be exactly in sync with its upstream: tagging is refused when
`main` is ahead (unpushed commits), behind, diverged, or has no upstream at all.
Push first, then tag.

`cxq release publish` requires `gh` and publishes the GitHub release. The full
`cxq release X.Y.Z` path asks before publishing interactively and requires
`--yes` when non-interactive. Use `--dry-run` to print actions without changing
Git or GitHub.

## Agent contract

`cxq install` should create or update an `AGENTS.md` section that tells agents how
to use the queue.

Recommended contract:

~~~md
## Local task queue

This repo uses a local agent task queue.

Use `cxq` to read and update tasks. Do not edit `.cxq/tasks.db` directly.

Before starting queued work:

1. Claim exactly one task with `cxq claim-next --lease 2h --format prompt`.
2. Work only on the claimed task.
3. Respect `allowed_paths` unless the task clearly requires more scope.
4. Run the task's `verify_command` when present.
5. Add notes with `cxq note <id> "..."`.
6. End by moving the task to `review`, with:
   - files changed
   - tests run
   - remaining risks
   - suggested next step

If `cxq` exits with update-required, run:
`cxq update --yes`
then retry the original command.

Prefix questions in notes with `DUDA:` or `BLOCKER:` so they show up in
`cxq list --questions`.

Record review caveats with `cxq finding add <id> --severity ... --note "..."`
instead of burying them in the summary.

Never mark a task `done` unless explicitly instructed.
~~~

## SQLite schema shape

The queue should use a mutable `tasks` table plus an append-only event log.

The row stores current state. The event log stores history.

Core fields:

- `title`
- `body`
- `status`
- `priority`
- `repo_path`
- `branch`
- `allowed_paths_json`
- `tags_json`
- `deps_json`
- `acceptance`
- `verify_command`
- `claimed_by`
- `claimed_at`
- `lease_until`
- `result_summary`
- `transcript_path`
- `due_date` (nullable `YYYY-MM-DD`, schema v4)
- timestamps

Task dependencies are stored in `task_dependencies`, not in the legacy
`deps_json` field.

SQLite WAL mode should be enabled so local reads and writes behave well when a
human, watcher, or agent touches the queue.

## Future direction

Useful additions for later (none of these changes the core workflow):

- `cxq run-next` to claim, render a prompt, call your agent's runner, and move the task
  to review
- branch naming like `agent/t42-auth-refresh-flake`
- git worktree support for parallel agent runs
- a global inbox that can move captured tasks into a repo-local queue
- an MCP wrapper once the CLI contract proves useful
- per-project queue namespacing on one server (today: one server = one queue)

## Design principle

Keep the system boring.

`cxq` should be easy to inspect, easy to script, and hard for an agent to misuse.
The database is the truth, the CLI is the boundary, and `AGENTS.md` is the
protocol.

## Development

Run the dependency-free test suite:

~~~sh
make test
~~~

The tests install `cxq` into a temporary prefix, verify `cxq -v`, create
temporary Git repositories, run `cxq install`, and exercise the task lifecycle.

## Continuous integration

`.github/workflows/test.yml` runs on every push and pull request to `main`.
It runs `make test` and `shellcheck` on `bin/cxq`, `install.sh`, and
`tests/run_tests.sh` on `ubuntu-latest`. Both steps must pass.

Caveat: files under `.github/workflows/` cannot be pushed through the
GitHub API by the Muse GitHub App (it gets a 403). Add or change the
workflow file from the GitHub web UI instead.
