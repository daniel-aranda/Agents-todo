#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
TMP_ROOT=${TMPDIR:-/tmp}
TEST_DIR=$(mktemp -d "$TMP_ROOT/cxq-tests.XXXXXX")
PREFIX="$TEST_DIR/prefix"
CXQ="$PREFIX/bin/cxq"
PASS=0
export HOME="$TEST_DIR/home"
export CXQ_TEST_LATEST_VERSION="v0.1.1"
export CXQ_NOW_EPOCH="1000000"

mkdir -p "$HOME"

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
  rm -rf "$HOME/.cxq"
  git init -q "$1"
  git -C "$1" config user.email test@example.com
  git -C "$1" config user.name "cxq test"
}

state_db() {
  printf '%s/.cxq/state.db' "$HOME"
}

state_get() {
  sqlite3 -batch -noheader "$(state_db)" "SELECT value FROM cxq_state WHERE key = '$1';"
}

state_set() {
  mkdir -p "$HOME/.cxq"
  sqlite3 -batch "$(state_db)" "CREATE TABLE IF NOT EXISTS cxq_state (key TEXT PRIMARY KEY, value TEXT NOT NULL); INSERT OR REPLACE INTO cxq_state (key, value) VALUES ('$1', '$2');"
}

test_installer_and_version() {
  PREFIX="$PREFIX" "$ROOT/install.sh" >/tmp/cxq-install-test.out
  assert_file "$CXQ"
  assert_file "$HOME/.cxq/state.db"
  [ "$(state_get "install_bin_path")" = "$CXQ" ] || fail "installer should record install_bin_path"
  [ "$(state_get "install_source_dir")" = "$ROOT" ] || fail "installer should record install_source_dir"
  local output
  output=$("$CXQ" -v)
  assert_contains "$output" "cxq 0.1.1" "cxq -v prints version"
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

test_update_status_creates_state_db() {
  local output
  rm -rf "$HOME/.cxq"
  output=$("$CXQ" update --status)
  assert_file "$HOME/.cxq/state.db"
  assert_contains "$output" "current_version: 0.1.1"
  assert_contains "$output" "update_required: 0"
  pass "update status creates and reports global state"
}

test_update_check_skips_before_24h() {
  local repo result
  repo="$TEST_DIR/update-skip-before-24h"
  run_git_init "$repo"
  (cd "$repo" && "$CXQ" install >/dev/null)
  state_set "last_update_check_at" "1000"
  state_set "last_update_check_result" "old-result"

  (cd "$repo" && CXQ_NOW_EPOCH=2000 CXQ_TEST_LATEST_VERSION=v9.9.9 "$CXQ" list >/dev/null)
  result=$(state_get "last_update_check_result")
  [ "$result" = "old-result" ] || fail "remote check should not run before 24h"
  [ "$(state_get "update_required")" != "1" ] || fail "update should not be marked before 24h"
  pass "daily update check does not run before 24h"
}

test_update_check_runs_after_24h() {
  local repo result checked_at
  repo="$TEST_DIR/update-runs-after-24h"
  run_git_init "$repo"
  (cd "$repo" && "$CXQ" install >/dev/null)
  state_set "last_update_check_at" "1000"
  state_set "last_update_check_result" "old-result"

  (cd "$repo" && CXQ_NOW_EPOCH=90000 CXQ_TEST_LATEST_VERSION=v0.1.1 "$CXQ" list >/dev/null)
  result=$(state_get "last_update_check_result")
  checked_at=$(state_get "last_update_check_at")
  assert_contains "$result" "up-to-date"
  [ "$checked_at" = "90000" ] || fail "expected last_update_check_at to be updated"
  pass "daily update check runs after 24h"
}

test_latest_version_marks_update_required() {
  local repo output
  repo="$TEST_DIR/update-latest-required"
  run_git_init "$repo"
  (cd "$repo" && "$CXQ" install >/dev/null)

  output=$(cd "$repo" && CXQ_TEST_LATEST_VERSION=v0.1.2 "$CXQ" update --check)
  assert_contains "$output" "update-available: v0.1.2"
  [ "$(state_get "update_required")" = "1" ] || fail "newer latest version should mark update required"
  [ "$(state_get "update_required_kind")" = "self" ] || fail "newer latest version should require self update"
  [ "$(state_get "latest_version")" = "v0.1.2" ] || fail "latest version should be recorded"
  pass "newer latest version marks self update required"
}

test_update_required_gates_normal_commands() {
  local repo output status
  repo="$TEST_DIR/update-required-gates"
  run_git_init "$repo"
  (cd "$repo" && "$CXQ" install >/dev/null)
  state_set "update_required" "1"
  state_set "update_required_kind" "self"
  state_set "update_required_reason" "test update required"

  set +e
  output=$(cd "$repo" && "$CXQ" list 2>&1)
  status=$?
  set -e
  [ "$status" -eq 90 ] || fail "expected exit 90, got $status"
  assert_contains "$output" "[update-required] cxq needs an update before continuing."
  pass "update_required gates normal commands"
}

test_interactive_update_prompt_yes() {
  local repo output count
  repo="$TEST_DIR/update-interactive-yes"
  run_git_init "$repo"
  (cd "$repo" && "$CXQ" install >/dev/null)
  rm "$repo/.codex/prompts/task.md"

  output=$(cd "$repo" && CXQ_TEST_TTY_ANSWER=y "$CXQ" add "After yes" 2>&1)
  assert_contains "$output" "Run update now? [Y/n]"
  assert_contains "$output" "Created task #"
  assert_file "$repo/.codex/prompts/task.md"
  count=$(sqlite3 -batch -noheader "$repo/.codex/tasks.db" "SELECT COUNT(*) FROM tasks WHERE title = 'After yes';")
  [ "$count" = "1" ] || fail "interactive yes should rerun original command"
  pass "interactive update prompt yes path updates and reruns"
}

test_interactive_update_prompt_no() {
  local repo output status count
  repo="$TEST_DIR/update-interactive-no"
  run_git_init "$repo"
  (cd "$repo" && "$CXQ" install >/dev/null)
  rm "$repo/.codex/prompts/task.md"

  set +e
  output=$(cd "$repo" && CXQ_TEST_TTY_ANSWER=n "$CXQ" add "After no" 2>&1)
  status=$?
  set -e
  [ "$status" -ne 0 ] || fail "interactive no should fail"
  assert_contains "$output" "Command not run."
  count=$(sqlite3 -batch -noheader "$repo/.codex/tasks.db" "SELECT COUNT(*) FROM tasks WHERE title = 'After no';")
  [ "$count" = "0" ] || fail "interactive no should not run original command"
  pass "interactive update prompt no path blocks command"
}

test_noninteractive_update_gate_exits_90() {
  local repo output status
  repo="$TEST_DIR/update-noninteractive"
  run_git_init "$repo"
  (cd "$repo" && "$CXQ" install >/dev/null)
  state_set "update_required" "1"
  state_set "update_required_kind" "repo"
  state_set "update_required_reason" "repo setup missing"

  set +e
  output=$(cd "$repo" && "$CXQ" list 2>&1)
  status=$?
  set -e
  [ "$status" -eq 90 ] || fail "non-interactive gate should exit 90"
  assert_contains "$output" "Then retry the original command."
  pass "non-interactive gate exits 90 without hanging"
}

test_no_update_check_bypasses_gate() {
  local repo status
  repo="$TEST_DIR/update-bypass"
  run_git_init "$repo"
  (cd "$repo" && "$CXQ" install >/dev/null)
  state_set "update_required" "1"
  state_set "update_required_kind" "self"
  state_set "update_required_reason" "test bypass"

  set +e
  (cd "$repo" && CXQ_NO_UPDATE_CHECK=1 "$CXQ" list >/dev/null)
  status=$?
  set -e
  [ "$status" -eq 0 ] || fail "CXQ_NO_UPDATE_CHECK should bypass the gate"
  pass "CXQ_NO_UPDATE_CHECK bypasses update gate"
}

test_assume_yes_attempts_update() {
  local repo output count
  repo="$TEST_DIR/update-assume-yes"
  run_git_init "$repo"
  (cd "$repo" && "$CXQ" install >/dev/null)
  rm "$repo/.codex/prompts/task.md"

  output=$(cd "$repo" && CXQ_ASSUME_YES=1 "$CXQ" add "Assume yes" 2>&1)
  assert_contains "$output" "Created task #"
  assert_file "$repo/.codex/prompts/task.md"
  count=$(sqlite3 -batch -noheader "$repo/.codex/tasks.db" "SELECT COUNT(*) FROM tasks WHERE title = 'Assume yes';")
  [ "$count" = "1" ] || fail "CXQ_ASSUME_YES should update and rerun original command"
  pass "CXQ_ASSUME_YES attempts automatic update"
}

test_update_check_command() {
  local repo output
  repo="$TEST_DIR/update-check-command"
  run_git_init "$repo"
  (cd "$repo" && "$CXQ" install >/dev/null)

  output=$(cd "$repo" && CXQ_TEST_LATEST_VERSION=v0.1.1 "$CXQ" update --check)
  assert_contains "$output" "up-to-date: v0.1.1"
  assert_contains "$output" "No update required."
  pass "update --check records remote check result"
}

test_prerelease_update_tags_are_ignored() {
  local repo output
  repo="$TEST_DIR/update-prerelease"
  run_git_init "$repo"
  (cd "$repo" && "$CXQ" install >/dev/null)

  output=$(cd "$repo" && CXQ_TEST_LATEST_VERSION=v9.0.0-alpha.1 "$CXQ" update --check)
  assert_contains "$output" "ok: no stable tags found"
  [ "$(state_get "update_required")" != "1" ] || fail "prerelease tags should not require updates"
  pass "prerelease update tags are ignored"
}

test_update_all_yes_repairs_repo_setup() {
  local repo output
  repo="$TEST_DIR/update-all-repo"
  run_git_init "$repo"
  (cd "$repo" && "$CXQ" install >/dev/null)
  rm "$repo/.codex/prompts/task.md"
  state_set "update_required" "1"
  state_set "update_required_kind" "repo"
  state_set "update_required_reason" "missing prompt"

  output=$(cd "$repo" && "$CXQ" update --all --yes)
  assert_contains "$output" "Created: .codex/prompts/task.md"
  assert_file "$repo/.codex/prompts/task.md"
  [ "$(state_get "update_required")" = "0" ] || fail "update --all --yes should clear repo update requirement"
  pass "update --all --yes repairs repo setup"
}

test_failed_remote_check_does_not_block() {
  local repo output result status
  repo="$TEST_DIR/update-remote-fails"
  run_git_init "$repo"
  (cd "$repo" && "$CXQ" install >/dev/null)
  state_set "install_remote_url" "/definitely/not/a/repo"
  state_set "last_update_check_at" "1000"

  set +e
  output=$(cd "$repo" && CXQ_NOW_EPOCH=90000 CXQ_TEST_LATEST_VERSION= "$CXQ" list 2>&1)
  status=$?
  set -e
  [ "$status" -eq 0 ] || fail "failed remote check should not block normal usage. Output: $output"
  result=$(state_get "last_update_check_result")
  assert_contains "$result" "failed:"
  pass "failed remote update check does not block normal usage"
}

test_repeated_update_gate_does_not_loop() {
  local repo output status
  repo="$TEST_DIR/update-rerun-loop"
  run_git_init "$repo"
  (cd "$repo" && "$CXQ" install >/dev/null)
  state_set "update_required" "1"
  state_set "update_required_kind" "self"
  state_set "update_required_reason" "still required"

  set +e
  output=$(cd "$repo" && CXQ_UPDATE_GATE_RERUN=1 "$CXQ" list 2>&1)
  status=$?
  set -e
  [ "$status" -eq 90 ] || fail "rerun gate should fail with exit 90"
  assert_contains "$output" "cxq needs an update before continuing"
  pass "repeated update gate fails instead of looping"
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
test_update_status_creates_state_db
test_update_check_skips_before_24h
test_update_check_runs_after_24h
test_latest_version_marks_update_required
test_update_required_gates_normal_commands
test_interactive_update_prompt_yes
test_interactive_update_prompt_no
test_noninteractive_update_gate_exits_90
test_no_update_check_bypasses_gate
test_assume_yes_attempts_update
test_update_check_command
test_prerelease_update_tags_are_ignored
test_update_all_yes_repairs_repo_setup
test_failed_remote_check_does_not_block
test_repeated_update_gate_does_not_loop
test_commands_work_from_repo_subdirectory_after_install

printf '\n%s tests passed\n' "$PASS"
