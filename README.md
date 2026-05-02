# cxq

`cxq` is a tiny local work queue for Codex-style coding agents.

It is not a project manager, kanban board, or issue tracker. It is a repo-local
SQLite queue with a small command-line interface, designed so humans and agents
can coordinate implementation work without editing ad hoc TODO files.

The intended flow is simple:

```sh
git clone https://github.com/daniel-aranda/Agents-todo.git
cd Agents-todo
./install.sh
```

That installs a global `cxq` command on macOS. Then, inside any Git project:

```sh
cxq -v
cd /path/to/your/project
cxq install
```

`cxq install` initializes the queue for that project.

## Requirements

- macOS
- `bash`
- `git`
- `sqlite3`

No package manager, Node.js, or Python runtime is required.

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

```text
SQLite      = state
cxq         = API
AGENTS.md   = agent protocol
Codex       = worker
Git         = project boundary
```

## Current platform

`cxq` is macOS-only for now.

The project is designed for people who clone this repository, run
`install.sh`, and then use the installed `cxq` command from other local Git
projects.

By default, `install.sh` installs to the first writable known macOS bin
directory that is already on `PATH`, checking `/usr/local/bin`,
`/opt/homebrew/bin`, and `$HOME/.local/bin`. If none of those work, it installs
to `$HOME/.local/bin` and prints the `PATH` update needed for your shell.

You can choose a prefix explicitly:

```sh
./install.sh --prefix "$HOME/.local"
```

## Project-local queues

`cxq` uses one queue per repository.

When you run:

```sh
cxq install
```

from the root of a Git project, it creates the local queue files needed for that
project.

Expected project layout:

```text
your-project/
  AGENTS.md
  .gitignore
  .codex/
    tasks.db
    tasks.schema.sql
    prompts/
      task.md
```

The SQLite database is local state and should not be committed:

```text
.codex/tasks.db
.codex/tasks.db-*
```

The schema and prompt templates can be committed so the project documents how
its queue works.

## Git project guardrail

`cxq install` only runs at the root of a Git project.

If you run it anywhere else, it exits without changing files and prints a clear
message:

```text
cxq install only runs at the root of a Git project.
```

This protects random directories from getting `.codex` files and makes the
project boundary explicit.

## Command surface

The current version of `cxq` is intentionally small:

```sh
cxq -v
cxq install
cxq add "Fix flaky auth refresh test"
cxq list
cxq next
cxq claim 42 --agent codex --lease 2h
cxq note 42 "Found race in token refresh path"
cxq prompt 42
cxq review 42 --summary "Implemented lock and added regression test"
cxq done 42
cxq repo 42
cxq stale
cxq release 42
```

The default workflow is:

```text
inbox -> ready -> claimed -> review -> done
```

Agents should normally stop at `review`. A human decides when a task is truly
`done`.

`cxq add` creates `ready` tasks by default so `cxq next` can immediately find
them.

## Example task

```sh
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
```

Then an agent can claim and work the task:

```sh
cxq next
cxq claim 42 --agent codex --lease 2h
cxq prompt 42
```

`cxq prompt 42` should render a deterministic prompt with the task title,
allowed paths, acceptance criteria, verification command, and finishing
instructions.

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

## Leases

Claims should have leases:

```sh
cxq claim 42 --agent codex --lease 2h
```

If an agent crashes, the task should not be stuck forever. Expired claims can be
shown as stale or made available again.

Future commands may include:

```sh
cxq stale
cxq release 42
```

## Agent contract

`cxq install` should create or update an `AGENTS.md` section that tells Codex how
to use the queue.

Recommended contract:

```md
## Local task queue

This repo uses a local Codex task queue.

Use `cxq` to read and update tasks. Do not edit `.codex/tasks.db` directly.

Before starting queued work:

1. Run `cxq next --format md`.
2. Claim exactly one task with `cxq claim <id> --agent codex`.
3. Work only on the claimed task.
4. Respect `allowed_paths` unless the task clearly requires more scope.
5. Run the task's `verify_command` when present.
6. Add notes with `cxq note <id> "..."`.
7. End by moving the task to `review`, with:
   - files changed
   - tests run
   - remaining risks
   - suggested next step

Never mark a task `done` unless explicitly instructed.
```

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
- timestamps

SQLite WAL mode should be enabled so local reads and writes behave well when a
human, watcher, or agent touches the queue.

## Future direction

After the MVP works, useful additions include:

- `cxq run-next` to claim, render a prompt, call `codex exec`, and move the task
  to review
- `cxq export-md` for a read-only Markdown mirror
- branch naming like `codex/t42-auth-refresh-flake`
- git worktree support for parallel agent runs
- a global inbox that can move captured tasks into a repo-local queue
- an MCP wrapper once the CLI contract proves useful

## Design principle

Keep the system boring.

`cxq` should be easy to inspect, easy to script, and hard for an agent to misuse.
The database is the truth, the CLI is the boundary, and `AGENTS.md` is the
protocol.

## Development

Run the dependency-free test suite:

```sh
make test
```

The tests install `cxq` into a temporary prefix, verify `cxq -v`, create
temporary Git repositories, run `cxq install`, and exercise the task lifecycle.
