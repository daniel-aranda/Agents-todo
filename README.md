# cxq

`cxq` is a tiny local work queue for Codex-style coding agents.

It is not a project manager, kanban board, or issue tracker. It is a repo-local
SQLite queue with a small command-line interface, designed so humans and agents
can coordinate implementation work without editing ad hoc TODO files.

The intended flow is simple:

~~~sh
git clone https://github.com/daniel-aranda/Agents-todo.git
cd Agents-todo
./install.sh
~~~

That installs a global `cxq` command on macOS. Then, inside any Git project:

~~~sh
cxq -v
cd /path/to/your/project
cxq install
~~~

`cxq install` initializes the queue for that project.

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
cxq claim-next --agent codex --lease 2h --format prompt
~~~

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

~~~text
SQLite      = state
cxq         = API
AGENTS.md   = agent protocol
Codex       = worker
Git         = project boundary
~~~

## Current platform

`cxq` is macOS-only for now.

The project is designed for people who clone this repository, run
`install.sh`, and then use the installed `cxq` command from other local Git
projects.

By default, `install.sh` installs to `$HOME/.local/bin`. If that directory is
not already on `PATH`, the installer prints the shell profile update needed for
your shell.

You can choose a prefix explicitly:

~~~sh
PREFIX=/opt/homebrew ./install.sh
./install.sh --prefix "$HOME/.local"
~~~

## Project-local queues

`cxq` uses one queue per repository.

When you run:

~~~sh
cxq install
~~~

from the root of a Git project, it creates the local queue files needed for that
project.

`cxq install` is non-destructive. If `.codex/tasks.schema.sql` or
`.codex/prompts/task.md` already exists, it leaves the file unchanged and prints
a message saying so.

Expected project layout:

~~~text
your-project/
  AGENTS.md
  .gitignore
  .codex/
    tasks.db
    tasks.schema.sql
    prompts/
      task.md
~~~

The SQLite database is local state and should not be committed:

~~~text
.codex/tasks.db
.codex/tasks.db-*
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

This protects random directories from getting `.codex` files and makes the
project boundary explicit.

## Command surface

The current version of `cxq` is intentionally small:

~~~sh
cxq -v
cxq version --plain
cxq doctor
cxq install
cxq update
cxq update --status
cxq update --check
cxq version bump patch
cxq version set 0.2.1
cxq release prepare 0.2.1
cxq add "Fix flaky auth refresh test"
cxq list
cxq next
cxq show 42
cxq claim 42 --agent codex --lease 2h
cxq claim-next --agent codex --lease 2h --format prompt
cxq block 42 --by 17
cxq deps 42
cxq unblock 42 --by 17
cxq note 42 "Found race in token refresh path"
cxq prompt 42
cxq review 42 --summary "Implemented lock and added regression test"
cxq done 42
cxq repo 42
cxq stale
cxq release 42
~~~

`cxq doctor` is read-only. It reports the installed version, PATH resolution,
required tools, install metadata, update state, and current repo queue setup.

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
cxq claim-next --agent codex --lease 2h --format prompt
~~~

`cxq show 42` renders the current task fields and recent events.

`cxq prompt 42` renders a deterministic agent prompt with the task body, tags,
allowed paths, acceptance criteria, verification command, recent events, result
summary when present, and finishing instructions.

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

## Leases

Claims should have leases:

~~~sh
cxq claim 42 --agent codex --lease 2h
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
cxq version set 0.2.1
~~~

Release preparation is explicit and local-first:

~~~sh
cxq release prepare 0.2.1
cxq release tag 0.2.1
cxq release publish 0.2.1
cxq release 0.2.1
~~~

`cxq release prepare` verifies the requested version and writes release notes to
`/tmp/cxq-release-vX.Y.Z.md`. `cxq release tag` creates and pushes the Git tag;
it must run from `main` with an up-to-date upstream. `cxq release publish`
requires `gh` and publishes the GitHub release. The full `cxq release X.Y.Z`
path asks before publishing interactively and requires `--yes` when
non-interactive. Use `--dry-run` to print actions without changing Git or
GitHub.

## Agent contract

`cxq install` should create or update an `AGENTS.md` section that tells Codex how
to use the queue.

Recommended contract:

~~~md
## Local task queue

This repo uses a local Codex task queue.

Use `cxq` to read and update tasks. Do not edit `.codex/tasks.db` directly.

Before starting queued work:

1. Claim exactly one task with `cxq claim-next --agent codex --lease 2h --format prompt`.
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
- timestamps

Task dependencies are stored in `task_dependencies`, not in the legacy
`deps_json` field.

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

~~~sh
make test
~~~

The tests install `cxq` into a temporary prefix, verify `cxq -v`, create
temporary Git repositories, run `cxq install`, and exercise the task lifecycle.
