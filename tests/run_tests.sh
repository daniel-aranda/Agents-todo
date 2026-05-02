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
  pass "cxq install creates project queue files"
}

test_queue_lifecycle() {
  local repo add_output id next_id prompt list review_list done_list events
  repo="$TEST_DIR/lifecycle"
  run_git_init "$repo"
  (cd "$repo" && "$CXQ" install >/dev/null)

  add_output=$(cd "$repo" && "$CXQ" add "Fix auth refresh" \
    --priority 80 \
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
  assert_contains "$prompt" "src/auth"
  assert_contains "$prompt" "npm test -- auth"

  (cd "$repo" && "$CXQ" claim "$id" --agent codex --lease 30m >/dev/null)
  list=$(cd "$repo" && "$CXQ" list)
  assert_contains "$list" "claimed"
  assert_contains "$list" "codex"

  (cd "$repo" && "$CXQ" note "$id" "Race found in refresh path" >/dev/null)
  (cd "$repo" && "$CXQ" review "$id" --summary "Added locking and tests" >/dev/null)
  review_list=$(cd "$repo" && "$CXQ" list --status review)
  assert_contains "$review_list" "review" "review status should be visible"
  assert_contains "$review_list" "Fix auth refresh"

  (cd "$repo" && "$CXQ" done "$id" --summary "Accepted" >/dev/null)
  done_list=$(cd "$repo" && "$CXQ" list --all)
  assert_contains "$done_list" "done"

  events=$(sqlite3 -batch -noheader "$repo/.codex/tasks.db" "SELECT COUNT(*) FROM task_events WHERE task_id = $id;")
  [ "$events" -ge 5 ] || fail "expected at least five task events, got $events"
  pass "task lifecycle commands work"
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
test_queue_lifecycle
test_commands_work_from_repo_subdirectory_after_install

printf '\n%s tests passed\n' "$PASS"
