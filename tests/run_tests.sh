#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
TMP_ROOT=${TMPDIR:-/tmp}
TEST_DIR=$(mktemp -d "$TMP_ROOT/cxq-tests.XXXXXX")
PREFIX="$TEST_DIR/prefix"
CXQ="$PREFIX/bin/cxq"
PASS=0

cleanup() {
  rm -rf "$TEST_DIR"
}
trap cleanup EXIT

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

pass() {
  PASS=$((PASS + 1))
  printf 'ok %s - %s\n' "$PASS" "$*"
}

assert_contains() {
  local haystack=$1
  local needle=$2
  local label=${3:-"expected output to contain '$needle'"}
  case "$haystack" in
    *"$needle"*) ;;
    *) fail "$label. Output was: $haystack" ;;
  esac
}

assert_not_contains() {
  local haystack=$1
  local needle=$2
  local label=${3:-"expected output not to contain '$needle'"}
  case "$haystack" in
    *"$needle"*) fail "$label. Output was: $haystack" ;;
    *) ;;
  esac
}

assert_file() {
  [ -f "$1" ] || fail "expected file to exist: $1"
}

assert_dir() {
  [ -d "$1" ] || fail "expected directory to exist: $1"
}

assert_not_exists() {
  [ ! -e "$1" ] || fail "expected path not to exist: $1"
}

run_git_init() {
  git init -q "$1"
  git -C "$1" config user.email test@example.com
  git -C "$1" config user.name "cxq test"
}

test_installer_and_version() {
  PREFIX="$PREFIX" "$ROOT/install.sh" >/tmp/cxq-install-test.out
  assert_file "$CXQ"
  local output
  output=$("$CXQ" -v)
  assert_contains "$output" "cxq 0.1.0" "cxq -v prints version"
  pass "installer creates a working cxq command"
}

test_install_rejects_non_git_directory() {
  local dir output status
  dir="$TEST_DIR/not-git"
  mkdir -p "$dir"
  set +e
  output=$(cd "$dir" && "$CXQ" install 2>&1)
  status=$?
  set -e
  [ "$status" -ne 0 ] || fail "cxq install should fail outside Git"
  assert_contains "$output" "root of a Git project"
  assert_not_exists "$dir/.codex"
  pass "cxq install does nothing outside Git projects"
}

test_install_rejects_git_subdirectory() {
  local repo output status
  repo="$TEST_DIR/subdir-repo"
  run_git_init "$repo"
  mkdir -p "$repo/src"
  set +e
  output=$(cd "$repo/src" && "$CXQ" install 2>&1)
  status=$?
  set -e
  [ "$status" -ne 0 ] || fail "cxq install should fail from Git subdirectories"
  assert_contains "$output" "root of a Git project"
  assert_not_exists "$repo/src/.codex"
  assert_not_exists "$repo/.codex"
  pass "cxq install only runs from the Git root"
}

test_project_install_creates_files() {
  local repo output
  repo="$TEST_DIR/project-install"
  run_git_init "$repo"
  output=$(cd "$repo" && "$CXQ" install)
  assert_contains "$output" "cxq installed for project"
  assert_dir "$repo/.codex"
  assert_file "$repo/.codex/tasks.db"
  assert_file "$repo/.codex/tasks.schema.sql"
  assert_file "$repo/.codex/prompts/task.md"
  assert_file "$repo/.gitignore"
  assert_file "$repo/AGENTS.md"
  grep -qxF ".codex/tasks.db" "$repo/.gitignore" || fail "missing tasks.db gitignore entry"
  grep -qxF ".codex/tasks.db-*" "$repo/.gitignore" || fail "missing WAL gitignore entry"
  grep -qxF "## Local task queue" "$repo/AGENTS.md" || fail "missing AGENTS.md queue contract"
  grep -qF "cxq claim-next --agent codex --lease 2h --format prompt" "$repo/AGENTS.md" || fail "missing claim-next AGENTS.md guidance"
  pass "cxq install creates project queue files"
}

test_project_install_preserves_custom_files() {
  local repo output schema prompt
  repo="$TEST_DIR/non-destructive-install"
  run_git_init "$repo"
  (cd "$repo" && "$CXQ" install >/dev/null)

  schema="-- custom schema marker --"
  prompt="custom prompt marker"
  printf '%s\n' "$schema" >"$repo/.codex/tasks.schema.sql"
  printf '%s\n' "$prompt" >"$repo/.codex/prompts/task.md"

  output=$(cd "$repo" && "$CXQ" install)
  assert_contains "$output" "Left unchanged: .codex/tasks.schema.sql"
  assert_contains "$output" "Left unchanged: .codex/prompts/task.md"
  grep -qxF -e "$schema" "$repo/.codex/tasks.schema.sql" || fail "custom schema was overwritten"
  grep -qxF -e "$prompt" "$repo/.codex/prompts/task.md" || fail "custom prompt was overwritten"
  pass "cxq install preserves customized schema and prompt files"
}

test_queue_lifecycle() {
  local repo add_output id next_id prompt list review_list done_list events claim_fields
  repo="$TEST_DIR/lifecycle"
  run_git_init "$repo"
  (cd "$repo" && "$CXQ" install >/dev/null)

  add_output=$(cd "$repo" && "$CXQ" add "Fix auth refresh" \
    --priority 80 \
    --body "Refresh should not double-spend a token." \
    --files "src/auth,tests/auth" \
    --tag auth \
    --acceptance "- identify failure
- add regression test" \
    --verify "npm test -- auth")
  assert_contains "$add_output" "Created task #"
  id=${add_output##*#}

  next_id=$(cd "$repo" && "$CXQ" next --format id)
  [ "$next_id" = "$id" ] || fail "expected next task id $id, got $next_id"

  prompt=$(cd "$repo" && "$CXQ" prompt "$id")
  assert_contains "$prompt" "Fix auth refresh"
  assert_contains "$prompt" "Refresh should not double-spend a token."
  assert_contains "$prompt" "auth"
  assert_contains "$prompt" "src/auth"
  assert_contains "$prompt" "npm test -- auth"

  (cd "$repo" && "$CXQ" claim "$id" --agent codex --lease 30m >/dev/null)
  list=$(cd "$repo" && "$CXQ" list)
  assert_contains "$list" "claimed"
  assert_contains "$list" "codex"

  (cd "$repo" && "$CXQ" note "$id" "Race found in refresh path" >/dev/null)
  prompt=$(cd "$repo" && "$CXQ" prompt "$id")
  assert_contains "$prompt" "Race found in refresh path"
  (cd "$repo" && "$CXQ" review "$id" --summary "Added locking and tests" >/dev/null)
  review_list=$(cd "$repo" && "$CXQ" list --status review)
  assert_contains "$review_list" "review" "review status should be visible"
  assert_contains "$review_list" "Fix auth refresh"
  claim_fields=$(sqlite3 -batch -noheader "$repo/.codex/tasks.db" "SELECT COUNT(*) FROM tasks WHERE id = $id AND claimed_by IS NULL AND claimed_at IS NULL AND lease_until IS NULL;")
  [ "$claim_fields" = "1" ] || fail "review should clear current claim fields"

  (cd "$repo" && "$CXQ" done "$id" --summary "Accepted" >/dev/null)
  done_list=$(cd "$repo" && "$CXQ" list --all)
  assert_contains "$done_list" "done"
  claim_fields=$(sqlite3 -batch -noheader "$repo/.codex/tasks.db" "SELECT COUNT(*) FROM tasks WHERE id = $id AND claimed_by IS NULL AND claimed_at IS NULL AND lease_until IS NULL;")
  [ "$claim_fields" = "1" ] || fail "done should clear current claim fields"

  events=$(sqlite3 -batch -noheader "$repo/.codex/tasks.db" "SELECT COUNT(*) FROM task_events WHERE task_id = $id;")
  [ "$events" -ge 5 ] || fail "expected at least five task events, got $events"
  pass "task lifecycle commands work"
}

test_show_renders_task_context() {
  local repo add_output id show
  repo="$TEST_DIR/show"
  run_git_init "$repo"
  (cd "$repo" && "$CXQ" install >/dev/null)

  add_output=$(cd "$repo" && "$CXQ" add "Show everything" \
    --priority 65 \
    --body "Detailed body context." \
    --files "src/core,tests/core" \
    --tag cli \
    --tag safety \
    --acceptance "- render fields" \
    --verify "make test")
  id=${add_output##*#}
  (cd "$repo" && "$CXQ" claim "$id" --agent codex --lease 30m >/dev/null)
  (cd "$repo" && "$CXQ" note "$id" "Important note" >/dev/null)
  (cd "$repo" && "$CXQ" review "$id" --summary "Ready for human review" >/dev/null)

  show=$(cd "$repo" && "$CXQ" show "$id")
  assert_contains "$show" "# Task #$id"
  assert_contains "$show" "Show everything"
  assert_contains "$show" "review"
  assert_contains "$show" "65"
  assert_contains "$show" "Detailed body context."
  assert_contains "$show" "src/core"
  assert_contains "$show" "cli"
  assert_contains "$show" "safety"
  assert_contains "$show" "render fields"
  assert_contains "$show" "make test"
  assert_contains "$show" "Ready for human review"
  assert_contains "$show" "Important note"
  assert_contains "$show" "\`note\`"
  assert_not_contains "$show" "Claimed by:" "reviewed task should not show stale current claim ownership"
  pass "cxq show renders task fields and recent events"
}

test_claim_next_claims_ready_task() {
  local repo first second claimed_by
  repo="$TEST_DIR/claim-next-ready"
  run_git_init "$repo"
  (cd "$repo" && "$CXQ" install >/dev/null)
  first=$(cd "$repo" && "$CXQ" add "Low priority" --priority 10)
  first=${first##*#}
  second=$(cd "$repo" && "$CXQ" add "High priority" --priority 90)
  second=${second##*#}

  claimed=$(cd "$repo" && "$CXQ" claim-next --agent worker-a --lease 30m --format id)
  [ "$claimed" = "$second" ] || fail "claim-next should pick highest priority task, expected $second got $claimed"
  claimed_by=$(sqlite3 -batch -noheader "$repo/.codex/tasks.db" "SELECT claimed_by FROM tasks WHERE id = $claimed;")
  [ "$claimed_by" = "worker-a" ] || fail "claim-next should set claimed_by"
  pass "claim-next claims the highest-priority ready task"
}

test_claim_next_ignores_done_and_review() {
  local repo first second output status
  repo="$TEST_DIR/claim-next-ignores-closed"
  run_git_init "$repo"
  (cd "$repo" && "$CXQ" install >/dev/null)
  first=$(cd "$repo" && "$CXQ" add "Done task")
  first=${first##*#}
  second=$(cd "$repo" && "$CXQ" add "Review task")
  second=${second##*#}
  (cd "$repo" && "$CXQ" done "$first" --summary "Accepted" >/dev/null)
  (cd "$repo" && "$CXQ" review "$second" --summary "Needs human review" >/dev/null)

  set +e
  output=$(cd "$repo" && "$CXQ" claim-next 2>&1)
  status=$?
  set -e
  [ "$status" -ne 0 ] || fail "claim-next should fail when only done/review tasks exist"
  assert_contains "$output" "No available tasks."
  pass "claim-next does not claim done or review tasks"
}

test_claim_next_reclaims_expired_task() {
  local repo add_output id claimed_by
  repo="$TEST_DIR/claim-next-expired"
  run_git_init "$repo"
  (cd "$repo" && "$CXQ" install >/dev/null)
  add_output=$(cd "$repo" && "$CXQ" add "Expired claim")
  id=${add_output##*#}
  (cd "$repo" && "$CXQ" claim "$id" --agent old-agent --lease 30m >/dev/null)
  sqlite3 -batch "$repo/.codex/tasks.db" "UPDATE tasks SET lease_until = '2000-01-01T00:00:00.000Z' WHERE id = $id;"

  claimed=$(cd "$repo" && "$CXQ" claim-next --agent new-agent --lease 30m --format id)
  [ "$claimed" = "$id" ] || fail "claim-next should reclaim expired task $id, got $claimed"
  claimed_by=$(sqlite3 -batch -noheader "$repo/.codex/tasks.db" "SELECT claimed_by FROM tasks WHERE id = $id;")
  [ "$claimed_by" = "new-agent" ] || fail "claim-next should replace expired claim owner"
  pass "claim-next reclaims expired claimed tasks"
}

test_claim_next_second_attempt_fails_cleanly() {
  local repo add_output output status
  repo="$TEST_DIR/claim-next-clean-fail"
  run_git_init "$repo"
  (cd "$repo" && "$CXQ" install >/dev/null)
  add_output=$(cd "$repo" && "$CXQ" add "Only task")
  assert_contains "$add_output" "Created task #"
  (cd "$repo" && "$CXQ" claim-next --format id >/dev/null)

  set +e
  output=$(cd "$repo" && "$CXQ" claim-next --format id 2>&1)
  status=$?
  set -e
  [ "$status" -ne 0 ] || fail "second claim-next should fail when no tasks remain available"
  assert_contains "$output" "No available tasks."
  pass "second claim-next fails cleanly when no task is available"
}

test_claim_next_prompt_lifecycle() {
  local repo add_output id prompt review_status
  repo="$TEST_DIR/claim-next-prompt"
  run_git_init "$repo"
  (cd "$repo" && "$CXQ" install >/dev/null)
  add_output=$(cd "$repo" && "$CXQ" add "Prompt lifecycle" --body "Prompt body" --tag agent)
  id=${add_output##*#}

  prompt=$(cd "$repo" && "$CXQ" claim-next --agent codex --lease 2h --format prompt)
  assert_contains "$prompt" "Prompt lifecycle"
  assert_contains "$prompt" "Prompt body"
  assert_contains "$prompt" "agent"
  assert_contains "$prompt" "Move implementation work to \`review\`, not \`done\`"
  (cd "$repo" && "$CXQ" note "$id" "Implemented prompt lifecycle" >/dev/null)
  (cd "$repo" && "$CXQ" review "$id" --summary "Ready" >/dev/null)
  review_status=$(sqlite3 -batch -noheader "$repo/.codex/tasks.db" "SELECT status FROM tasks WHERE id = $id;")
  [ "$review_status" = "review" ] || fail "claim-next prompt lifecycle should end in review"
  pass "claim-next prompt lifecycle works"
}

test_release_clears_claim_fields() {
  local repo add_output id count status
  repo="$TEST_DIR/release-clears"
  run_git_init "$repo"
  (cd "$repo" && "$CXQ" install >/dev/null)
  add_output=$(cd "$repo" && "$CXQ" add "Release me")
  id=${add_output##*#}
  (cd "$repo" && "$CXQ" claim "$id" --agent codex --lease 30m >/dev/null)
  (cd "$repo" && "$CXQ" release "$id" >/dev/null)

  status=$(sqlite3 -batch -noheader "$repo/.codex/tasks.db" "SELECT status FROM tasks WHERE id = $id;")
  [ "$status" = "ready" ] || fail "release should return task to ready"
  count=$(sqlite3 -batch -noheader "$repo/.codex/tasks.db" "SELECT COUNT(*) FROM tasks WHERE id = $id AND claimed_by IS NULL AND claimed_at IS NULL AND lease_until IS NULL;")
  [ "$count" = "1" ] || fail "release should clear all current claim fields"
  pass "release clears current claim fields"
}

test_files_globs_are_preserved_literally() {
  local repo add_output id prompt
  repo="$TEST_DIR/glob-paths"
  run_git_init "$repo"
  mkdir -p "$repo/src/auth" "$repo/tests/auth"
  touch "$repo/src/auth/a" "$repo/src/auth/b" "$repo/tests/auth/t"
  (cd "$repo" && "$CXQ" install >/dev/null)

  add_output=$(cd "$repo" && "$CXQ" add "Glob paths" --files "src/auth/*,tests/auth/*")
  id=${add_output##*#}
  prompt=$(cd "$repo" && "$CXQ" prompt "$id")

  assert_contains "$prompt" "src/auth/*"
  assert_contains "$prompt" "tests/auth/*"
  assert_not_contains "$prompt" "src/auth/a"
  assert_not_contains "$prompt" "src/auth/b"
  assert_not_contains "$prompt" "tests/auth/t"
  pass "file globs are preserved literally in allowed paths"
}

test_commands_work_from_repo_subdirectory_after_install() {
  local repo output
  repo="$TEST_DIR/subdir-use"
  run_git_init "$repo"
  mkdir -p "$repo/packages/app"
  (cd "$repo" && "$CXQ" install >/dev/null)
  output=$(cd "$repo/packages/app" && "$CXQ" add "Subdir task")
  assert_contains "$output" "Created task #"
  output=$(cd "$repo/packages/app" && "$CXQ" next --format md)
  assert_contains "$output" "Subdir task"
  pass "queue commands work from subdirectories after install"
}

test_installer_and_version
test_install_rejects_non_git_directory
test_install_rejects_git_subdirectory
test_project_install_creates_files
test_project_install_preserves_custom_files
test_queue_lifecycle
test_show_renders_task_context
test_claim_next_claims_ready_task
test_claim_next_ignores_done_and_review
test_claim_next_reclaims_expired_task
test_claim_next_second_attempt_fails_cleanly
test_claim_next_prompt_lifecycle
test_release_clears_claim_fields
test_files_globs_are_preserved_literally
test_commands_work_from_repo_subdirectory_after_install

printf '\n%s tests passed\n' "$PASS"
