# AGENTS.md

Guidance for Codex and other AI agents working on this repository.

## Project

This repo contains `cxq`, a small macOS-first CLI for a repo-local SQLite task queue for Codex/local coding agents.

The implementation is intentionally boring:

- Bash
- git
- sqlite3
- no Node
- no Python
- no server
- no daemon
- no external runtime dependencies

Keep it that way unless explicitly instructed.

## Files

Important files:

- `bin/cxq`: main CLI implementation.
- `install.sh`: installs the local `cxq` command.
- `tests/run_tests.sh`: shell test suite.
- `Makefile`: test entrypoint.
- `README.md`: public docs.

## Coding rules

- Keep Bash portable for macOS.
- Do not use GNU-only flags unless macOS supports them by default.
- Do not depend on `sort -V`.
- Quote variables.
- Validate task ids as integers before using them in SQL.
- Do not silently overwrite user-customized files.
- Keep command output stable when tests rely on it.
- Prefer small helper functions over large rewrites.
- Do not add broad refactors unless necessary.
- Keep the CLI local-first and repo-first.
- Avoid network behavior unless it is part of the explicit update/check workflow.
- Do not add telemetry.
- Do not add hidden background daemons.
- Do not make destructive changes without explicit user intent.

## Test commands

Before finishing any code change, run:

~~~sh
bash -n bin/cxq install.sh tests/run_tests.sh
make test
~~~

If tests cannot be run, say exactly why.

## Versioning and release discipline

This project uses SemVer-style versions and GitHub releases.

The CLI version lives in `bin/cxq` as `CXQ_VERSION`.

Every meaningful code change must include a version decision before completion.

Use this policy:

- `fix`, reliability improvements, install/update fixes, and backwards-compatible bug fixes bump PATCH.
  - Example: `0.1.1` -> `0.1.2`
- New backwards-compatible CLI behavior bumps MINOR.
  - Example: `0.1.1` -> `0.2.0`
- Breaking CLI behavior, incompatible DB changes, or removed commands bump MAJOR.
  - Example: `0.1.1` -> `1.0.0` only when the project is stable enough.
- Docs-only, comments-only, test-only, or internal cleanup may skip version bump.

When a version bump is needed, update:

1. `CXQ_VERSION` in `bin/cxq`
2. README references if needed
3. tests if behavior changed
4. release notes draft if the change is release-worthy

Do not create a Git tag.
Do not publish a GitHub release.
Do not run `gh release create`.
Only prepare the version bump unless explicitly asked to release.

Never publish or recommend publishing a release with a version lower than the local stable `CXQ_VERSION`.

Never leave the public latest release behind the stable local CLI version.

## Local dev versions

Avoid installing unreleased stable versions locally.

Bad:

~~~text
CXQ_VERSION="0.1.2"
~~~

when `v0.1.2` does not exist publicly.

Prefer dev versions while work is not released:

~~~text
CXQ_VERSION="0.1.2-dev"
~~~

Then, when explicitly preparing a release, switch to:

~~~text
CXQ_VERSION="0.1.2"
~~~

and only after that create the tag/release.

If the updater compares local version against remote tags, dev versions should not masquerade as published stable releases.

## Commit message guidance

Use Conventional Commits-style messages when suggesting commits.

Examples:

- `fix: preserve literal glob patterns in allowed paths`
- `feat: add proactive update gate`
- `docs: document release workflow`
- `test: cover non-destructive repo updates`
- `chore: bump cxq to 0.1.2`

## Required final response from Codex

At the end of every task, report:

- Summary of changes
- Tests run
- Version decision
- Suggested commit message

The version decision must be one of:

- `no version bump`
- `patch bump to X.Y.Z`
- `minor bump to X.Y.Z`
- `major bump to X.Y.Z`

If a version bump is needed but was not made, explain why.

## Release workflow

Only release when explicitly instructed.

Manual release flow:

~~~sh
git checkout main
git pull --ff-only origin main
make test

git tag -a vX.Y.Z -m "cxq vX.Y.Z"
git push origin vX.Y.Z

gh release create vX.Y.Z \
  --repo daniel-aranda/Agents-todo \
  --title "cxq vX.Y.Z" \
  --notes-file /tmp/cxq-release-vX.Y.Z.md \
  --verify-tag \
  --latest
~~~

Before creating the release, verify:

~~~sh
cxq version
grep 'CXQ_VERSION=' bin/cxq
git tag --list 'v*'
gh release list --repo daniel-aranda/Agents-todo
~~~

The version in `bin/cxq`, the Git tag, and the GitHub release must match.

Example:

~~~text
bin/cxq:        CXQ_VERSION="0.1.2"
git tag:        v0.1.2
GitHub release: cxq v0.1.2
~~~

## Release notes style

Use short, practical release notes.

Good structure:

~~~md
## cxq vX.Y.Z

Short summary.

### Highlights

- Change one
- Change two
- Change three

### Update

~~~sh
git pull --ff-only origin main
./install.sh
cxq version
cxq update --status
~~~

### Notes

Any caveats.
~~~

When writing Markdown that contains code fences, prefer `~~~` fences to avoid nested Markdown breakage.

## cxq task queue behavior

This repo is itself a good test subject for `cxq`.

For local task work, prefer:

~~~sh
cxq claim-next --agent codex --lease 2h --format prompt
~~~

When working on a claimed task:

- Work only on the claimed task.
- Respect allowed paths unless the task clearly requires more scope.
- Use `cxq note <id> "..."` for important discoveries.
- Run the verification command when present.
- Move implementation work to `review`, not `done`, unless explicitly instructed.

If `cxq` exits with an update-required message, run:

~~~sh
cxq update --all --yes
~~~

Then retry the original command.

## Update behavior

`cxq` has local update/check behavior.

Expected commands include:

~~~sh
cxq version
cxq doctor
cxq update --status
cxq update --check
cxq update --repo
cxq update --self
cxq update --all
~~~

Rules:

- `cxq update --check` may check remote tags.
- Normal commands may run a lightweight update gate.
- Do not make normal commands hang in non-interactive mode.
- Do not prompt unless attached to a TTY.
- Do not silently overwrite customized repo files.
- Preserve escape hatches:
  - `CXQ_NO_UPDATE_CHECK=1`
  - `CXQ_ASSUME_YES=1`

## Non-destructive repo files

These files may be user-customized and must not be silently overwritten:

- `.codex/tasks.schema.sql`
- `.codex/prompts/task.md`
- `AGENTS.md`

If a newer default differs from an existing customized file, write a `.new` file instead:

- `.codex/tasks.schema.sql.new`
- `.codex/prompts/task.md.new`
- `AGENTS.md.cxq.new`

## Database rules

Use SQLite carefully.

- Validate integer ids before using them in SQL.
- Use helper functions for SQL quoting.
- Keep schema migrations explicit.
- Preserve user data.
- Do not delete `.codex/tasks.db` unless explicitly instructed.
- Store schema version with `PRAGMA user_version` when applicable.
- Keep event history append-only when possible.

## Shell portability

This project targets macOS.

Avoid GNU-only assumptions.

Examples:

- Do not use `sort -V`.
- Be careful with `date` flags.
- Be careful with `readlink -f`.
- Avoid Bash features unavailable in macOS Bash unless the shebang/runtime guarantees support.
- Prefer simple POSIX-compatible patterns where practical, but Bash is allowed because the project is Bash-based.

## Security and safety

Do not introduce:

- telemetry
- background daemons
- credential storage
- `curl | sh` installers
- arbitrary remote code execution
- network calls outside explicit update/check commands
- silent self-modification

Self-update should be explicit, understandable, and reversible.

## Documentation rules

When adding or changing CLI behavior, update `README.md`.

Docs should include:

- command name
- short explanation
- minimal example
- safety caveats if relevant

Keep the README concise. This is a CLI tool, not a project-management manifesto.

## Final checklist before completion

Before finishing, verify:

- Syntax checks pass.
- Tests pass or failure is explained.
- README is updated if CLI behavior changed.
- `CXQ_VERSION` decision is made.
- No customized files are silently overwritten.
- No release is published unless explicitly requested.
- Suggested commit message is provided.