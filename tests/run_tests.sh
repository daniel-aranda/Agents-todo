#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
TMP_ROOT=${TMPDIR:-/tmp}
TEST_DIR=$(mktemp -d "$TMP_ROOT/cxq-tests.XXXXXX")
PREFIX="$TEST_DIR/prefix"
CXQ="$PREFIX/bin/cxq"
PASS=0
export HOME="$TEST_DIR/home"
export CXQ_NOW_EPOCH="1000000"

mkdir -p "$HOME"

current_repo_version() {
  local line
  line=$(grep -E '^CXQ_VERSION="' "$ROOT/bin/cxq" | head -n 1)
  line=${line#CXQ_VERSION=\"}
  line=${line%\"}
  printf '%s' "$line"
}

current_stable_base() {
  local version
  version=$(current_repo_version)
  printf '%s' "${version%-dev}"
}

# Highest stable remote tag that must never require an update for this build.
# A stable local build matches its own tag; an X.Y.Z-dev build is newer than
# every stable tag below X.Y.Z.
current_uptodate_tag() {
  local version base major minor patch
  version=$(current_repo_version)
  base=${version%-dev}
  if [ "$version" = "$base" ]; then
    printf 'v%s' "$base"
    return
  fi
  IFS=. read -r major minor patch <<<"$base"
  if [ "$((10#$patch))" -gt 0 ]; then
    patch=$((10#$patch - 1))
  elif [ "$((10#$minor))" -gt 0 ]; then
    minor=$((10#$minor - 1))
    patch=0
  else
    major=$((10#$major - 1))
    minor=0
    patch=0
  fi
  printf 'v%s.%s.%s' "$major" "$minor" "$patch"
}

# A dev build reports dev-build instead of up-to-date when it leads the tag.
current_uptodate_result() {
  case "$(current_repo_version)" in
    *-dev) printf 'dev-build' ;;
    *) printf 'up-to-date' ;;
  esac
}

CXQ_TEST_LATEST_VERSION="$(current_uptodate_tag)"
export CXQ_TEST_LATEST_VERSION

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

set_file_version() {
  local file=$1
  local version=$2
  local tmp line
  tmp="$file.version.tmp"
  rm -f "$tmp"
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      CXQ_VERSION=\"*\") printf 'CXQ_VERSION="%s"\n' "$version" >>"$tmp" ;;
      *) printf '%s\n' "$line" >>"$tmp" ;;
    esac
  done <"$file"
  chmod +x "$tmp"
  mv "$tmp" "$file"
}

set_fixture_version() {
  set_file_version "$1/bin/cxq" "$2"
}

# Copies the installed binary to a private path pinned at a given version.
build_versioned_cxq() {
  local name=$1
  local version=$2
  local dir="$TEST_DIR/versioned/$name"
  mkdir -p "$dir"
  cp "$CXQ" "$dir/cxq"
  set_file_version "$dir/cxq" "$version"
  printf '%s/cxq' "$dir"
}

# Source fixtures pin a stable version so release commands, which reject
# X.Y.Z-dev, can be exercised while the working tree is on a dev build.
run_source_fixture() {
  local repo=$1
  mkdir -p "$repo/bin" "$repo/tests"
  cp "$ROOT/bin/cxq" "$repo/bin/cxq"
  cp "$ROOT/install.sh" "$repo/install.sh"
  cp "$ROOT/tests/run_tests.sh" "$repo/tests/run_tests.sh"
  cp "$ROOT/README.md" "$repo/README.md"
  set_fixture_version "$repo" "$(current_stable_base)"
  chmod +x "$repo/bin/cxq" "$repo/install.sh" "$repo/tests/run_tests.sh"
  git init -q "$repo"
  git -C "$repo" checkout -q -B main
  git -C "$repo" config user.email test@example.com
  git -C "$repo" config user.name "cxq test"
  git -C "$repo" add .
  git -C "$repo" commit -q -m "fixture"
}

attach_source_fixture_upstream() {
  local repo=$1
  local remote=$2
  git init --bare -q "$remote"
  git -C "$repo" remote add origin "$remote"
  git -C "$repo" push -q -u origin main
  git --git-dir="$remote" symbolic-ref HEAD refs/heads/main
}

fixture_version() {
  local repo=$1
  local line
  line=$(grep -E '^CXQ_VERSION="' "$repo/bin/cxq" | head -n 1)
  line=${line#CXQ_VERSION=\"}
  line=${line%\"}
  printf '%s' "$line"
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

assert_cxq_version() {
  local expected=$1
  local output plain
  output=$("$CXQ" version)
  plain=$("$CXQ" version --plain)
  assert_contains "$output" "cxq $expected"
  [ "$plain" = "$expected" ] || fail "expected plain version $expected, got $plain"
}

test_installer_and_version() {
  PREFIX="$PREFIX" "$ROOT/install.sh" >/tmp/cxq-install-test.out
  assert_file "$CXQ"
  assert_file "$PREFIX/lib/cxq/cxq_server.py"
  assert_file "$PREFIX/lib/cxq/cxq_mcp.py"
  assert_file "$HOME/.cxq/state.db"
  [ "$(state_get "install_bin_path")" = "$CXQ" ] || fail "installer should record install_bin_path"
  [ "$(state_get "install_source_dir")" = "$ROOT" ] || fail "installer should record install_source_dir"
  assert_cxq_version "$(current_repo_version)"
  pass "installer creates a working cxq command"
}

test_installer_defaults_to_home_local() {
  local output default_cxq
  rm -rf "$HOME/.local"
  output=$("$ROOT/install.sh")
  default_cxq="$HOME/.local/bin/cxq"
  assert_file "$default_cxq"
  assert_contains "$output" "Installed cxq to $default_cxq"
  assert_contains "$output" "$HOME/.local/bin is not currently in PATH"
  pass "installer defaults to HOME/.local"
}

test_installer_explicit_prefix_and_old_binary_warning() {
  local explicit old output
  explicit="$TEST_DIR/opt-homebrew"
  PREFIX="$explicit" "$ROOT/install.sh" >/dev/null
  assert_file "$explicit/bin/cxq"

  old="$TEST_DIR/old-homebrew/bin"
  mkdir -p "$old"
  printf '#!/usr/bin/env bash\nprintf old\\n\n' >"$old/cxq"
  chmod +x "$old/cxq"
  rm -rf "$HOME/.local"
  output=$(CXQ_OLD_BIN_DIRS="$old" "$ROOT/install.sh")
  assert_contains "$output" "Warning: found another cxq at $old/cxq"
  pass "installer supports explicit prefix and warns about old PATH binaries"
}

test_installer_path_scanning_preserves_literal_paths() {
  local prefix literal_path expanded_path spaced_old output
  prefix="$TEST_DIR/path-scan-prefix"
  literal_path="$TEST_DIR/path-star-*"
  expanded_path="$TEST_DIR/path-star-expanded"
  spaced_old="$TEST_DIR/old bin with space"

  mkdir -p "$literal_path" "$expanded_path" "$spaced_old"
  printf '#!/usr/bin/env bash\nprintf expanded\\n\n' >"$expanded_path/cxq"
  chmod +x "$expanded_path/cxq"
  printf '#!/usr/bin/env bash\nprintf old\\n\n' >"$spaced_old/cxq"
  chmod +x "$spaced_old/cxq"

  output=$(PATH="$literal_path:/usr/bin:/bin" CXQ_OLD_BIN_DIRS="$spaced_old" "$ROOT/install.sh" --prefix "$prefix" --no-modify-profile)
  assert_not_contains "$output" "$expanded_path/cxq" "PATH scanner should not expand glob-like entries"
  assert_contains "$output" "Warning: found another cxq at $spaced_old/cxq"
  pass "installer PATH scanning preserves literal paths"
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
  assert_not_exists "$dir/.cxq"
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
  assert_not_exists "$repo/src/.cxq"
  assert_not_exists "$repo/.cxq"
  pass "cxq install only runs from the Git root"
}

test_project_install_creates_files() {
  local repo output
  repo="$TEST_DIR/project-install"
  run_git_init "$repo"
  output=$(cd "$repo" && "$CXQ" install)
  assert_contains "$output" "cxq installed for project"
  assert_dir "$repo/.cxq"
  assert_file "$repo/.cxq/tasks.db"
  assert_file "$repo/.cxq/tasks.schema.sql"
  assert_file "$repo/.cxq/prompts/task.md"
  assert_file "$repo/.gitignore"
  assert_file "$repo/AGENTS.md"
  grep -qxF ".cxq/tasks.db" "$repo/.gitignore" || fail "missing tasks.db gitignore entry"
  grep -qxF ".cxq/tasks.db-*" "$repo/.gitignore" || fail "missing WAL gitignore entry"
  grep -qxF "## Local task queue" "$repo/AGENTS.md" || fail "missing AGENTS.md queue contract"
  grep -qF "cxq claim-next --lease 2h --format prompt" "$repo/AGENTS.md" || fail "missing claim-next AGENTS.md guidance"
  pass "cxq install creates project queue files"
}

test_project_install_preserves_custom_files() {
  local repo output schema prompt
  repo="$TEST_DIR/non-destructive-install"
  run_git_init "$repo"
  (cd "$repo" && "$CXQ" install >/dev/null)

  schema="-- custom schema marker --"
  prompt="custom prompt marker"
  printf '%s\n' "$schema" >"$repo/.cxq/tasks.schema.sql"
  printf '%s\n' "$prompt" >"$repo/.cxq/prompts/task.md"

  output=$(cd "$repo" && "$CXQ" install)
  assert_contains "$output" "Left unchanged: .cxq/tasks.schema.sql"
  assert_contains "$output" "Left unchanged: .cxq/prompts/task.md"
  grep -qxF -e "$schema" "$repo/.cxq/tasks.schema.sql" || fail "custom schema was overwritten"
  grep -qxF -e "$prompt" "$repo/.cxq/prompts/task.md" || fail "custom prompt was overwritten"
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

  (cd "$repo" && "$CXQ" claim "$id" --agent tester --lease 30m >/dev/null)
  list=$(cd "$repo" && "$CXQ" list)
  assert_contains "$list" "claimed"
  assert_contains "$list" "tester"

  (cd "$repo" && "$CXQ" note "$id" "Race found in refresh path" >/dev/null)
  prompt=$(cd "$repo" && "$CXQ" prompt "$id")
  assert_contains "$prompt" "Race found in refresh path"
  (cd "$repo" && "$CXQ" review "$id" --summary "Added locking and tests" >/dev/null)
  review_list=$(cd "$repo" && "$CXQ" list --status review)
  assert_contains "$review_list" "review" "review status should be visible"
  assert_contains "$review_list" "Fix auth refresh"
  claim_fields=$(sqlite3 -batch -noheader "$repo/.cxq/tasks.db" "SELECT COUNT(*) FROM tasks WHERE id = $id AND claimed_by IS NULL AND claimed_at IS NULL AND lease_until IS NULL;")
  [ "$claim_fields" = "1" ] || fail "review should clear current claim fields"

  (cd "$repo" && "$CXQ" "done" "$id" --summary "Accepted" >/dev/null)
  done_list=$(cd "$repo" && "$CXQ" list --all)
  assert_contains "$done_list" "done"
  claim_fields=$(sqlite3 -batch -noheader "$repo/.cxq/tasks.db" "SELECT COUNT(*) FROM tasks WHERE id = $id AND claimed_by IS NULL AND claimed_at IS NULL AND lease_until IS NULL;")
  [ "$claim_fields" = "1" ] || fail "done should clear current claim fields"

  events=$(sqlite3 -batch -noheader "$repo/.cxq/tasks.db" "SELECT COUNT(*) FROM task_events WHERE task_id = $id;")
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
  (cd "$repo" && "$CXQ" claim "$id" --agent tester --lease 30m >/dev/null)
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
  claimed_by=$(sqlite3 -batch -noheader "$repo/.cxq/tasks.db" "SELECT claimed_by FROM tasks WHERE id = $claimed;")
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
  (cd "$repo" && "$CXQ" "done" "$first" --summary "Accepted" >/dev/null)
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
  sqlite3 -batch "$repo/.cxq/tasks.db" "UPDATE tasks SET lease_until = '2000-01-01T00:00:00.000Z' WHERE id = $id;"

  claimed=$(cd "$repo" && "$CXQ" claim-next --agent new-agent --lease 30m --format id)
  [ "$claimed" = "$id" ] || fail "claim-next should reclaim expired task $id, got $claimed"
  claimed_by=$(sqlite3 -batch -noheader "$repo/.cxq/tasks.db" "SELECT claimed_by FROM tasks WHERE id = $id;")
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

  prompt=$(cd "$repo" && "$CXQ" claim-next --agent tester --lease 2h --format prompt)
  assert_contains "$prompt" "Prompt lifecycle"
  assert_contains "$prompt" "Prompt body"
  assert_contains "$prompt" "agent"
  assert_contains "$prompt" "Move implementation work to \`review\`, not \`done\`"
  (cd "$repo" && "$CXQ" note "$id" "Implemented prompt lifecycle" >/dev/null)
  (cd "$repo" && "$CXQ" review "$id" --summary "Ready" >/dev/null)
  review_status=$(sqlite3 -batch -noheader "$repo/.cxq/tasks.db" "SELECT status FROM tasks WHERE id = $id;")
  [ "$review_status" = "review" ] || fail "claim-next prompt lifecycle should end in review"
  pass "claim-next prompt lifecycle works"
}

test_dependencies_skip_blocked_tasks() {
  local repo blocker dependent claimed deps
  repo="$TEST_DIR/deps-skip-blocked"
  run_git_init "$repo"
  (cd "$repo" && "$CXQ" install >/dev/null)

  blocker=$(cd "$repo" && "$CXQ" add "Low priority blocker" --priority 10)
  blocker=${blocker##*#}
  dependent=$(cd "$repo" && "$CXQ" add "High priority dependent" --priority 99)
  dependent=${dependent##*#}
  (cd "$repo" && "$CXQ" block "$dependent" --by "$blocker" >/dev/null)

  deps=$(cd "$repo" && "$CXQ" deps "$dependent")
  assert_contains "$deps" "#$blocker [ready] Low priority blocker"
  claimed=$(cd "$repo" && "$CXQ" claim-next --format id)
  [ "$claimed" = "$blocker" ] || fail "claim-next should skip blocked high-priority task"
  pass "claim-next skips blocked tasks"
}

test_dependencies_unblocked_task_becomes_claimable() {
  local repo blocker dependent claimed
  repo="$TEST_DIR/deps-unblock"
  run_git_init "$repo"
  (cd "$repo" && "$CXQ" install >/dev/null)

  blocker=$(cd "$repo" && "$CXQ" add "Temporary blocker" --priority 10)
  blocker=${blocker##*#}
  dependent=$(cd "$repo" && "$CXQ" add "Unblocked dependent" --priority 99)
  dependent=${dependent##*#}
  (cd "$repo" && "$CXQ" block "$dependent" --by "$blocker" >/dev/null)
  (cd "$repo" && "$CXQ" unblock "$dependent" --by "$blocker" >/dev/null)

  claimed=$(cd "$repo" && "$CXQ" claim-next --format id)
  [ "$claimed" = "$dependent" ] || fail "unblocked highest-priority task should be claimable"
  pass "unblocked tasks become claimable"
}

test_done_blocker_allows_dependent_task() {
  local repo blocker dependent claimed
  repo="$TEST_DIR/deps-done-blocker"
  run_git_init "$repo"
  (cd "$repo" && "$CXQ" install >/dev/null)

  blocker=$(cd "$repo" && "$CXQ" add "Done blocker" --priority 10)
  blocker=${blocker##*#}
  dependent=$(cd "$repo" && "$CXQ" add "Dependent after done" --priority 99)
  dependent=${dependent##*#}
  (cd "$repo" && "$CXQ" block "$dependent" --by "$blocker" >/dev/null)
  (cd "$repo" && "$CXQ" "done" "$blocker" --summary "Accepted" >/dev/null)

  claimed=$(cd "$repo" && "$CXQ" claim-next --format id)
  [ "$claimed" = "$dependent" ] || fail "dependent should be claimable once blocker is done"
  pass "done blockers allow dependent tasks"
}

test_dependency_rejects_self_and_cycle() {
  local repo first second output status
  repo="$TEST_DIR/deps-reject"
  run_git_init "$repo"
  (cd "$repo" && "$CXQ" install >/dev/null)

  first=$(cd "$repo" && "$CXQ" add "First")
  first=${first##*#}
  second=$(cd "$repo" && "$CXQ" add "Second")
  second=${second##*#}
  (cd "$repo" && "$CXQ" block "$second" --by "$first" >/dev/null)

  set +e
  output=$(cd "$repo" && "$CXQ" block "$first" --by "$first" 2>&1)
  status=$?
  set -e
  [ "$status" -ne 0 ] || fail "self dependency should fail"
  assert_contains "$output" "task cannot block itself"

  set +e
  output=$(cd "$repo" && "$CXQ" block "$first" --by "$second" 2>&1)
  status=$?
  set -e
  [ "$status" -ne 0 ] || fail "cycle dependency should fail"
  assert_contains "$output" "dependency would create a cycle"
  pass "self-dependency and dependency cycles are rejected"
}

test_release_clears_claim_fields() {
  local repo add_output id count status
  repo="$TEST_DIR/release-clears"
  run_git_init "$repo"
  (cd "$repo" && "$CXQ" install >/dev/null)
  add_output=$(cd "$repo" && "$CXQ" add "Release me")
  id=${add_output##*#}
  (cd "$repo" && "$CXQ" claim "$id" --agent tester --lease 30m >/dev/null)
  (cd "$repo" && "$CXQ" release "$id" >/dev/null)

  status=$(sqlite3 -batch -noheader "$repo/.cxq/tasks.db" "SELECT status FROM tasks WHERE id = $id;")
  [ "$status" = "ready" ] || fail "release should return task to ready"
  count=$(sqlite3 -batch -noheader "$repo/.cxq/tasks.db" "SELECT COUNT(*) FROM tasks WHERE id = $id AND claimed_by IS NULL AND claimed_at IS NULL AND lease_until IS NULL;")
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
  assert_contains "$output" "current_version: $(current_repo_version)"
  assert_contains "$output" "update_required: 0"
  pass "update status creates and reports global state"
}

test_doctor_reports_state_and_is_read_only() {
  local repo output
  repo="$TEST_DIR/doctor-repo"
  run_git_init "$repo"

  state_set "update_required" "1"
  state_set "update_required_kind" "self"
  state_set "update_required_reason" "doctor test"

  output=$(cd "$repo" && "$CXQ" doctor)
  assert_contains "$output" "current_version: $(current_repo_version)"
  assert_contains "$output" "selected_binary:"
  assert_contains "$output" "git: ok"
  assert_contains "$output" "sqlite3: ok"
  assert_contains "$output" "update_required: 1"
  assert_contains "$output" "repo_queue_installed: no"
  assert_not_exists "$repo/.cxq"

  (cd "$repo" && CXQ_NO_UPDATE_CHECK=1 "$CXQ" install >/dev/null)
  output=$(cd "$repo" && "$CXQ" doctor)
  assert_contains "$output" "repo_queue_installed: yes"
  assert_contains "$output" "repo_update_required: no"
  state_set "update_required" "0"
  state_set "update_required_kind" ""
  state_set "update_required_reason" ""
  pass "doctor reports state and does not repair repos"
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

  (cd "$repo" && CXQ_NOW_EPOCH=90000 CXQ_TEST_LATEST_VERSION="$(current_uptodate_tag)" "$CXQ" list >/dev/null)
  result=$(state_get "last_update_check_result")
  checked_at=$(state_get "last_update_check_at")
  assert_contains "$result" "$(current_uptodate_result)"
  [ "$checked_at" = "90000" ] || fail "expected last_update_check_at to be updated"
  pass "daily update check runs after 24h"
}

test_latest_version_marks_update_required() {
  local repo output
  repo="$TEST_DIR/update-latest-required"
  run_git_init "$repo"
  (cd "$repo" && "$CXQ" install >/dev/null)

  output=$(cd "$repo" && CXQ_TEST_LATEST_VERSION=v99.0.0 "$CXQ" update --check)
  assert_contains "$output" "update-available: v99.0.0"
  [ "$(state_get "update_required")" = "1" ] || fail "newer latest version should mark update required"
  [ "$(state_get "update_required_kind")" = "self" ] || fail "newer latest version should require self update"
  [ "$(state_get "latest_version")" = "v99.0.0" ] || fail "latest version should be recorded"
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
  rm "$repo/.cxq/prompts/task.md"

  output=$(cd "$repo" && CXQ_TEST_TTY_ANSWER=y "$CXQ" add "After yes" 2>&1)
  assert_contains "$output" "Run update now? [Y/n]"
  assert_contains "$output" "Created task #"
  assert_file "$repo/.cxq/prompts/task.md"
  count=$(sqlite3 -batch -noheader "$repo/.cxq/tasks.db" "SELECT COUNT(*) FROM tasks WHERE title = 'After yes';")
  [ "$count" = "1" ] || fail "interactive yes should rerun original command"
  pass "interactive update prompt yes path updates and reruns"
}

test_interactive_update_prompt_no() {
  local repo output status count
  repo="$TEST_DIR/update-interactive-no"
  run_git_init "$repo"
  (cd "$repo" && "$CXQ" install >/dev/null)
  rm "$repo/.cxq/prompts/task.md"

  set +e
  output=$(cd "$repo" && CXQ_TEST_TTY_ANSWER=n "$CXQ" add "After no" 2>&1)
  status=$?
  set -e
  [ "$status" -ne 0 ] || fail "interactive no should fail"
  assert_contains "$output" "Command not run."
  count=$(sqlite3 -batch -noheader "$repo/.cxq/tasks.db" "SELECT COUNT(*) FROM tasks WHERE title = 'After no';")
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
  rm "$repo/.cxq/prompts/task.md"

  output=$(cd "$repo" && CXQ_ASSUME_YES=1 "$CXQ" add "Assume yes" 2>&1)
  assert_contains "$output" "Created task #"
  assert_file "$repo/.cxq/prompts/task.md"
  count=$(sqlite3 -batch -noheader "$repo/.cxq/tasks.db" "SELECT COUNT(*) FROM tasks WHERE title = 'Assume yes';")
  [ "$count" = "1" ] || fail "CXQ_ASSUME_YES should update and rerun original command"
  pass "CXQ_ASSUME_YES attempts automatic update"
}

test_update_check_command() {
  local repo output
  repo="$TEST_DIR/update-check-command"
  run_git_init "$repo"
  (cd "$repo" && "$CXQ" install >/dev/null)

  output=$(cd "$repo" && CXQ_TEST_LATEST_VERSION="$(current_uptodate_tag)" "$CXQ" update --check)
  assert_contains "$output" "$(current_uptodate_result)"
  assert_contains "$output" "No update required."
  pass "update --check records remote check result"
}

test_plain_update_current() {
  local repo output
  repo="$TEST_DIR/update-plain-current"
  run_git_init "$repo"
  (cd "$repo" && "$CXQ" install >/dev/null)

  output=$(cd "$repo" && CXQ_TEST_LATEST_VERSION="$(current_uptodate_tag)" "$CXQ" update)
  assert_contains "$output" "cxq is up to date: $(current_repo_version)"
  pass "plain cxq update is the current-version happy path"
}

test_plain_update_requires_yes_when_modifying_noninteractive() {
  local repo output status
  repo="$TEST_DIR/update-plain-needs-yes"
  run_git_init "$repo"
  (cd "$repo" && "$CXQ" install >/dev/null)
  rm "$repo/.cxq/prompts/task.md"

  set +e
  output=$(cd "$repo" && "$CXQ" update 2>&1)
  status=$?
  set -e
  [ "$status" -ne 0 ] || fail "plain non-interactive update should require --yes before modifying files"
  assert_contains "$output" "Run: cxq update --yes"
  assert_not_exists "$repo/.cxq/prompts/task.md"
  pass "plain non-interactive update requires --yes when modifying files"
}

test_plain_update_yes_repairs_repo_and_clears_state() {
  local repo output
  repo="$TEST_DIR/update-plain-yes"
  run_git_init "$repo"
  (cd "$repo" && "$CXQ" install >/dev/null)
  rm "$repo/.cxq/prompts/task.md"

  output=$(cd "$repo" && "$CXQ" update --yes)
  assert_contains "$output" "Created: .cxq/prompts/task.md"
  assert_contains "$output" "Repo setup is up to date."
  assert_file "$repo/.cxq/prompts/task.md"
  [ "$(state_get "update_required")" = "0" ] || fail "plain update --yes should clear update_required"
  pass "plain update --yes repairs repo setup and clears state"
}

test_update_aliases() {
  local repo output
  repo="$TEST_DIR/update-aliases"
  run_git_init "$repo"
  (cd "$repo" && "$CXQ" install >/dev/null)

  output=$(cd "$repo" && "$CXQ" --status)
  assert_contains "$output" "current_version: $(current_repo_version)"
  output=$(cd "$repo" && CXQ_TEST_LATEST_VERSION="$(current_uptodate_tag)" "$CXQ" --check)
  assert_contains "$output" "No update required."
  pass "top-level update aliases work"
}

test_update_self_clears_state_without_shell_error() {
  local repo source target_prefix output status
  repo="$TEST_DIR/update-self-state"
  run_git_init "$repo"
  (cd "$repo" && "$CXQ" install >/dev/null)
  source="$TEST_DIR/self-source"
  run_source_fixture "$source"
  target_prefix="$TEST_DIR/self-install"
  state_set "install_source_dir" "$source"
  state_set "install_bin_path" "$target_prefix/bin/cxq"
  state_set "update_required" "1"
  state_set "update_required_kind" "self"
  state_set "update_required_reason" "test self update"
  state_set "latest_version" "$(current_uptodate_tag)"

  set +e
  output=$(cd "$repo" && CXQ_TEST_SKIP_SELF_UPDATE_GIT=1 "$CXQ" update --yes 2>&1)
  status=$?
  set -e
  [ "$status" -eq 0 ] || fail "self update should succeed. Output: $output"
  assert_file "$target_prefix/bin/cxq"
  assert_contains "$output" "cxq is now up to date: $(current_uptodate_tag)"
  assert_not_contains "$output" "command not found"
  [ "$(state_get "update_required")" = "0" ] || fail "self update should clear update_required"
  [ -z "$(state_get "update_required_kind")" ] || fail "self update should clear update_required_kind"
  pass "self update clears state without shell errors"
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
  rm "$repo/.cxq/prompts/task.md"
  state_set "update_required" "1"
  state_set "update_required_kind" "repo"
  state_set "update_required_reason" "missing prompt"

  output=$(cd "$repo" && "$CXQ" update --all --yes)
  assert_contains "$output" "Created: .cxq/prompts/task.md"
  assert_file "$repo/.cxq/prompts/task.md"
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
  output=$(cd "$repo" && CXQ_NOW_EPOCH=90000 CXQ_TEST_LATEST_VERSION='' "$CXQ" list 2>&1)
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

test_version_bump_and_set_commands() {
  local repo base output
  repo="$TEST_DIR/version-bump"
  run_source_fixture "$repo"
  base=$(fixture_version "$repo")

  output=$(cd "$repo" && "$CXQ" version bump patch)
  assert_contains "$output" "Updated cxq version: $base ->"
  [ "$(fixture_version "$repo")" = "$(bump_patch_expected "$base")" ] || fail "patch bump did not update fixture version"

  (cd "$repo" && "$CXQ" version set "$base" >/dev/null)
  output=$(cd "$repo" && "$CXQ" version bump minor)
  assert_contains "$output" "Updated cxq version: $base ->"
  (cd "$repo" && "$CXQ" version set "$base" >/dev/null)
  output=$(cd "$repo" && "$CXQ" version bump major)
  assert_contains "$output" "Updated cxq version: $base ->"
  output=$(cd "$repo" && "$CXQ" version set 1.2.3)
  assert_contains "$output" "Updated cxq version:"
  [ "$(fixture_version "$repo")" = "1.2.3" ] || fail "version set did not update fixture version"
  pass "version bump and set commands update canonical version"
}

bump_patch_expected() {
  local version=$1 major minor patch
  version=${version%-dev}
  IFS=. read -r major minor patch <<<"$version"
  printf '%s.%s.%s' "$major" "$minor" "$((10#$patch + 1))"
}

test_version_invalid_and_outside_repo() {
  local repo output status outside
  repo="$TEST_DIR/version-invalid"
  run_source_fixture "$repo"
  set +e
  output=$(cd "$repo" && "$CXQ" version set nope 2>&1)
  status=$?
  set -e
  [ "$status" -ne 0 ] || fail "invalid version should fail"
  assert_contains "$output" "version must be stable SemVer"

  outside="$TEST_DIR/not-source"
  run_git_init "$outside"
  set +e
  output=$(cd "$outside" && "$CXQ" version bump patch 2>&1)
  status=$?
  set -e
  [ "$status" -ne 0 ] || fail "version bump outside source repo should fail"
  assert_contains "$output" "cxq source repo"
  pass "version commands validate input and source repo"
}

test_release_prepare_and_dry_runs() {
  local repo version notes output status
  repo="$TEST_DIR/release-prepare"
  run_source_fixture "$repo"
  attach_source_fixture_upstream "$repo" "$TEST_DIR/release-prepare-origin.git"
  version=$(fixture_version "$repo")
  notes="/tmp/cxq-release-v$version.md"
  rm -f "$notes"

  output=$(cd "$repo" && "$CXQ" release prepare "$version" --skip-tests)
  assert_contains "$output" "Prepared release notes:"
  assert_file "$notes"
  grep -q '~~~sh' "$notes" || fail "release notes should use tildes fences"
  ! grep -q '```' "$notes" || fail "release notes should not use triple backtick fences"

  output=$(cd "$repo" && "$CXQ" release tag "$version" --dry-run --skip-tests)
  assert_contains "$output" "Dry run: would create and push tag v$version."
  ! git -C "$repo" rev-parse -q --verify "refs/tags/v$version" >/dev/null || fail "dry-run tag should not create tag"

  output=$(cd "$repo" && "$CXQ" release "$version" --dry-run)
  assert_contains "$output" "Dry run: would prepare, tag, and publish cxq v$version."
  pass "release prepare and dry-run commands work"
}

test_release_tag_checks_upstream_state() {
  local repo remote work version output status

  repo="$TEST_DIR/release-no-upstream"
  run_source_fixture "$repo"
  version=$(fixture_version "$repo")
  set +e
  output=$(cd "$repo" && "$CXQ" release tag "$version" --dry-run --skip-tests 2>&1)
  status=$?
  set -e
  [ "$status" -ne 0 ] || fail "release tag should fail without upstream"
  assert_contains "$output" "main must track an upstream"

  repo="$TEST_DIR/release-up-to-date"
  remote="$TEST_DIR/release-up-to-date-origin.git"
  run_source_fixture "$repo"
  attach_source_fixture_upstream "$repo" "$remote"
  version=$(fixture_version "$repo")
  output=$(cd "$repo" && "$CXQ" release tag "$version" --dry-run --skip-tests)
  assert_contains "$output" "Dry run: would create and push tag v$version."

  repo="$TEST_DIR/release-behind"
  remote="$TEST_DIR/release-behind-origin.git"
  work="$TEST_DIR/release-behind-work"
  run_source_fixture "$repo"
  attach_source_fixture_upstream "$repo" "$remote"
  version=$(fixture_version "$repo")
  git clone -q "$remote" "$work"
  git -C "$work" config user.email test@example.com
  git -C "$work" config user.name "cxq test"
  printf 'remote\n' >"$work/remote.txt"
  git -C "$work" add remote.txt
  git -C "$work" commit -q -m "remote advance"
  git -C "$work" push -q origin main
  git -C "$repo" fetch -q origin

  set +e
  output=$(cd "$repo" && "$CXQ" release tag "$version" --dry-run --skip-tests 2>&1)
  status=$?
  set -e
  [ "$status" -ne 0 ] || fail "release tag should fail when local main is behind"
  assert_contains "$output" "local main is behind"

  printf 'local\n' >"$repo/local.txt"
  git -C "$repo" add local.txt
  git -C "$repo" commit -q -m "local advance"
  set +e
  output=$(cd "$repo" && "$CXQ" release tag "$version" --dry-run --skip-tests 2>&1)
  status=$?
  set -e
  [ "$status" -ne 0 ] || fail "release tag should fail when local main diverged"
  assert_contains "$output" "local main has diverged"
  pass "release tag checks upstream state"
}

test_release_prepare_rejects_mismatch_and_existing_tag() {
  local repo version output status
  repo="$TEST_DIR/release-reject"
  run_source_fixture "$repo"
  version=$(fixture_version "$repo")

  set +e
  output=$(cd "$repo" && "$CXQ" release prepare 9.9.9 --skip-tests 2>&1)
  status=$?
  set -e
  [ "$status" -ne 0 ] || fail "release prepare should reject version mismatch"
  assert_contains "$output" "CXQ_VERSION does not match"

  git -C "$repo" tag "v$version"
  set +e
  output=$(cd "$repo" && "$CXQ" release prepare "$version" --skip-tests 2>&1)
  status=$?
  set -e
  [ "$status" -ne 0 ] || fail "release prepare should reject existing tag"
  assert_contains "$output" "already exists locally"
  pass "release prepare rejects mismatch and existing tags"
}

test_release_publish_requires_yes_noninteractive_and_source_repo() {
  local repo version output status outside
  repo="$TEST_DIR/release-publish"
  run_source_fixture "$repo"
  version=$(fixture_version "$repo")

  set +e
  output=$(cd "$repo" && "$CXQ" release publish "$version" 2>&1)
  status=$?
  set -e
  [ "$status" -ne 0 ] || fail "non-interactive publish should require --yes"
  assert_contains "$output" "requires --yes"

  outside="$TEST_DIR/release-outside"
  run_git_init "$outside"
  set +e
  output=$(cd "$outside" && "$CXQ" release prepare "$version" --skip-tests 2>&1)
  status=$?
  set -e
  [ "$status" -ne 0 ] || fail "release outside source repo should fail"
  assert_contains "$output" "cxq source repo"
  pass "release publish requires yes and release commands require source repo"
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

test_dev_version_update_comparisons() {
  local repo dev output
  repo="$TEST_DIR/dev-version-updates"
  run_git_init "$repo"
  (cd "$repo" && "$CXQ" install >/dev/null)
  dev=$(build_versioned_cxq "dev" "1.2.3-dev")

  assert_contains "$("$dev" version --plain)" "1.2.3-dev"

  output=$(cd "$repo" && CXQ_TEST_LATEST_VERSION=v1.2.2 "$dev" update --check)
  assert_contains "$output" "dev-build: 1.2.3-dev is ahead of latest stable v1.2.2"
  assert_contains "$output" "No update required."
  [ "$(state_get "update_required")" != "1" ] || fail "older stable tag should not gate a dev build"

  output=$(cd "$repo" && CXQ_TEST_LATEST_VERSION=v1.2.3 "$dev" update --check)
  assert_contains "$output" "update-available: v1.2.3"
  [ "$(state_get "update_required")" = "1" ] || fail "released stable tag should supersede the matching dev build"

  output=$(cd "$repo" && CXQ_TEST_LATEST_VERSION=v1.3.0 "$dev" update --check)
  assert_contains "$output" "update-available: v1.3.0"
  [ "$(state_get "update_required")" = "1" ] || fail "newer stable tag should still require an update from a dev build"

  output=$(cd "$repo" && CXQ_TEST_LATEST_VERSION=v9.9.9-alpha.1 "$dev" update --check)
  assert_contains "$output" "ok: no stable tags found"
  [ "$(state_get "update_required")" != "1" ] || fail "remote prerelease tags must stay ignored for dev builds"

  state_set "update_required" "0"
  state_set "update_required_kind" ""
  state_set "update_required_reason" ""
  pass "dev versions compare correctly against stable remote tags"
}

test_release_notes_summarize_commits() {
  local repo version notes content root_commit
  repo="$TEST_DIR/release-notes"
  run_source_fixture "$repo"
  version=$(fixture_version "$repo")
  notes="/tmp/cxq-release-v$version.md"

  rm -f "$notes"
  (cd "$repo" && "$CXQ" release prepare "$version" --skip-tests >/dev/null)
  content=$(cat "$notes")
  assert_contains "$content" "First release draft"
  grep -q '~~~sh' "$notes" || fail "release notes should use tildes fences"
  ! grep -q '```' "$notes" || fail "release notes should not use triple backtick fences"

  root_commit=$(git -C "$repo" rev-list --max-parents=0 HEAD)
  git -C "$repo" tag "v0.0.1" "$root_commit"
  printf 'change\n' >"$repo/change.txt"
  git -C "$repo" add change.txt
  git -C "$repo" commit -q -m "feat: summarize commits in release notes"

  rm -f "$notes"
  (cd "$repo" && "$CXQ" release prepare "$version" --skip-tests >/dev/null)
  content=$(cat "$notes")
  assert_contains "$content" "Changes since v0.0.1"
  assert_contains "$content" "- feat: summarize commits in release notes"
  assert_not_contains "$content" "First release draft"
  grep -q '~~~sh' "$notes" || fail "release notes should keep tildes fences"
  ! grep -q '```' "$notes" || fail "release notes should not use triple backtick fences"
  pass "release prepare summarizes commits since the previous stable tag"
}

test_release_tag_rejects_unpushed_main() {
  local repo remote version output status
  repo="$TEST_DIR/release-ahead"
  remote="$TEST_DIR/release-ahead-origin.git"
  run_source_fixture "$repo"
  attach_source_fixture_upstream "$repo" "$remote"
  version=$(fixture_version "$repo")

  printf 'local only\n' >"$repo/unpushed.txt"
  git -C "$repo" add unpushed.txt
  git -C "$repo" commit -q -m "local only commit"

  set +e
  output=$(cd "$repo" && "$CXQ" release tag "$version" --dry-run --skip-tests 2>&1)
  status=$?
  set -e
  [ "$status" -ne 0 ] || fail "release tag should fail when main is ahead of upstream"
  assert_contains "$output" "unpushed commits"
  assert_contains "$output" "push before releasing"
  ! git -C "$repo" rev-parse -q --verify "refs/tags/v$version" >/dev/null || fail "no tag should be created"
  pass "release tag refuses unpushed main"
}

test_doctor_reports_repo_database() {
  local repo output
  repo="$TEST_DIR/doctor-db"
  run_git_init "$repo"

  output=$(cd "$repo" && "$CXQ" doctor)
  assert_contains "$output" "repo_queue_installed: no"
  assert_contains "$output" "repo_db: none"
  assert_contains "$output" "repo_schema_version: none"
  assert_contains "$output" "repo_db_integrity: none"
  assert_not_exists "$repo/.cxq"

  (cd "$repo" && "$CXQ" install >/dev/null)
  (cd "$repo" && "$CXQ" add "Doctor sample" >/dev/null)
  output=$(cd "$repo" && "$CXQ" doctor)
  assert_contains "$output" "/doctor-db/.cxq/tasks.db"
  assert_contains "$output" "repo_schema_version: 6 (expected 6)"
  assert_contains "$output" "repo_task_total: 1"
  assert_contains "$output" "repo_task_counts: ready=1"
  assert_contains "$output" "repo_db_integrity: ok"

  output=$(cd "$repo" && "$CXQ" list)
  assert_contains "$output" "Doctor sample" "doctor must not mutate queue rows"
  pass "doctor reports repo database diagnostics"
}

test_status_transitions_table_and_release() {
  local repo output id status
  repo="$TEST_DIR/status-transitions"
  run_git_init "$repo"
  (cd "$repo" && "$CXQ" install >/dev/null)

  output=$(cd "$repo" && "$CXQ" status-transitions)
  assert_contains "$output" "# cxq status transitions"
  assert_contains "$output" "review    ready"
  assert_contains "$output" "review    blocked"
  assert_contains "$output" "claimed   ready"
  assert_contains "$output" "done      ready"
  assert_contains "$output" "cxq release <id>"

  id=$(cd "$repo" && "$CXQ" add "Transition sample" | sed 's/.*#//')
  set +e
  output=$(cd "$repo" && "$CXQ" release "$id" 2>&1)
  status=$?
  set -e
  [ "$status" -ne 0 ] || fail "release should reject a ready task"
  assert_contains "$output" "not claimed or blocked"
  assert_contains "$output" "cxq status-transitions"

  (cd "$repo" && "$CXQ" reopen "$id" --to blocked --reason "waiting on product" >/dev/null)
  output=$(cd "$repo" && "$CXQ" release "$id")
  assert_contains "$output" "Released task #$id"
  [ "$(sqlite3 -batch -noheader "$repo/.cxq/tasks.db" "SELECT status FROM tasks WHERE id = $id;")" = "ready" ] ||
    fail "release from blocked should return the task to ready"
  pass "status transitions are documented and release accepts blocked tasks"
}

test_reopen_returns_tasks_to_ready() {
  local repo id output status summary
  repo="$TEST_DIR/reopen"
  run_git_init "$repo"
  (cd "$repo" && "$CXQ" install >/dev/null)

  id=$(cd "$repo" && "$CXQ" add "Reopen sample" | sed 's/.*#//')
  (cd "$repo" && "$CXQ" claim "$id" --agent tester --lease 1h >/dev/null)
  (cd "$repo" && "$CXQ" note "$id" "Found a race in the refresh path" >/dev/null)
  (cd "$repo" && "$CXQ" review "$id" --summary "Partially implemented" >/dev/null)

  set +e
  output=$(cd "$repo" && "$CXQ" reopen "$id" 2>&1)
  status=$?
  set -e
  [ "$status" -ne 0 ] || fail "reopen should require a reason"
  assert_contains "$output" "reopen reason is required"

  set +e
  output=$(cd "$repo" && "$CXQ" reopen "$id" --to "done" --reason "nope" 2>&1)
  status=$?
  set -e
  [ "$status" -ne 0 ] || fail "reopen should reject invalid targets"
  assert_contains "$output" "reopen target must be ready, inbox, or blocked"

  output=$(cd "$repo" && "$CXQ" reopen "$id" --reason "acceptance criteria 3 is missing")
  assert_contains "$output" "Reopened task #$id: review -> ready"
  [ "$(sqlite3 -batch -noheader "$repo/.cxq/tasks.db" "SELECT status FROM tasks WHERE id = $id;")" = "ready" ] ||
    fail "reopen should move the task back to ready"
  [ "$(sqlite3 -batch -noheader "$repo/.cxq/tasks.db" "SELECT COUNT(*) FROM tasks WHERE id = $id AND claimed_by IS NULL AND claimed_at IS NULL AND lease_until IS NULL;")" = "1" ] ||
    fail "reopen should clear claim fields"

  summary=$(cd "$repo" && "$CXQ" show "$id")
  assert_contains "$summary" "Partially implemented" "reopen must preserve the result summary"
  assert_contains "$summary" "Found a race in the refresh path" "reopen must preserve prior notes"
  assert_contains "$summary" "acceptance criteria 3 is missing" "reopen must record the reason"

  (cd "$repo" && "$CXQ" "done" "$id" --summary "Accepted" >/dev/null)
  output=$(cd "$repo" && "$CXQ" reopen "$id" --to inbox --reason "regression reported")
  assert_contains "$output" "Reopened task #$id: done -> inbox"
  pass "reopen returns review and done tasks to an actionable status"
}

test_followup_links_residual_work() {
  local repo parent child output next_id
  repo="$TEST_DIR/followup"
  run_git_init "$repo"
  (cd "$repo" && "$CXQ" install >/dev/null)

  parent=$(cd "$repo" && "$CXQ" add "Original work" --priority 70 --files "src/a,src/b" --tag auth --verify "make check" | sed 's/.*#//')
  (cd "$repo" && "$CXQ" claim "$parent" --agent tester --lease 1h >/dev/null)
  (cd "$repo" && "$CXQ" review "$parent" --summary "Main path done" >/dev/null)

  output=$(cd "$repo" && "$CXQ" followup "$parent" "Handle the error branch")
  assert_contains "$output" "Created follow-up task #"
  child=${output#*follow-up task #}
  child=${child%% *}

  output=$(cd "$repo" && "$CXQ" show "$child")
  assert_contains "$output" "Follow-up of task #$parent"
  assert_contains "$output" "src/a" "follow-up should inherit allowed paths"
  assert_contains "$output" "auth" "follow-up should inherit tags"
  assert_contains "$output" "make check" "follow-up should inherit the verify command"
  assert_contains "$output" "#$parent [review] Original work" "follow-up should record the parent as a blocker"

  output=$(cd "$repo" && "$CXQ" show "$parent")
  assert_contains "$output" "#$child [ready] Handle the error branch" "parent should list the follow-up"

  set +e
  next_id=$(cd "$repo" && "$CXQ" next --format id 2>&1)
  set -e
  assert_contains "$next_id" "No ready tasks." "an open parent should still block its follow-up"

  output=$(cd "$repo" && "$CXQ" split "$parent" "Close it out" --close --priority 40)
  assert_contains "$output" "Created follow-up task #"
  assert_contains "$output" "Closed task #$parent with follow-up #"
  [ "$(sqlite3 -batch -noheader "$repo/.cxq/tasks.db" "SELECT status FROM tasks WHERE id = $parent;")" = "done" ] ||
    fail "--close should mark the original done"
  output=$(cd "$repo" && "$CXQ" show "$parent")
  assert_contains "$output" "Closed with follow-up #" "closing summary should mention the follow-up"
  pass "followup creates linked residual work and can close the original"
}

test_findings_lifecycle() {
  local repo id followup output finding status
  repo="$TEST_DIR/findings"
  run_git_init "$repo"
  (cd "$repo" && "$CXQ" install >/dev/null)

  id=$(cd "$repo" && "$CXQ" add "Reviewed work" | sed 's/.*#//')
  followup=$(cd "$repo" && "$CXQ" add "Fix the finding later" | sed 's/.*#//')
  (cd "$repo" && "$CXQ" claim "$id" --agent tester --lease 1h >/dev/null)
  (cd "$repo" && "$CXQ" review "$id" --summary "Ready for review" >/dev/null)

  set +e
  output=$(cd "$repo" && "$CXQ" finding add "$id" --severity nope --note "bad" 2>&1)
  status=$?
  set -e
  [ "$status" -ne 0 ] || fail "invalid severity should be rejected"
  assert_contains "$output" "finding severity must be"

  output=$(cd "$repo" && "$CXQ" finding add "$id" --severity high --status open --note "Retry loop is unbounded" --followup "$followup")
  assert_contains "$output" "Added finding #"
  finding=${output#*finding #}
  finding=${finding%% *}

  output=$(cd "$repo" && "$CXQ" finding list "$id")
  assert_contains "$output" "high"
  assert_contains "$output" "Retry loop is unbounded"
  assert_contains "$output" "$followup"

  output=$(cd "$repo" && "$CXQ" show "$id")
  assert_contains "$output" "## Findings"
  assert_contains "$output" "[high/open] Retry loop is unbounded"
  assert_contains "$output" "(follow-up #$followup)"

  output=$(cd "$repo" && "$CXQ" finding resolve "$finding" --note "bounded in #$followup")
  assert_contains "$output" "Marked finding #$finding as resolved"

  set +e
  output=$(cd "$repo" && "$CXQ" finding resolve "$finding" 2>&1)
  status=$?
  set -e
  [ "$status" -ne 0 ] || fail "resolving a closed finding should fail"
  assert_contains "$output" "is not open"

  output=$(cd "$repo" && "$CXQ" show "$id")
  assert_contains "$output" "[high/resolved] Retry loop is unbounded"
  [ "$(sqlite3 -batch -noheader "$repo/.cxq/tasks.db" "SELECT value FROM cxq_meta WHERE key = 'schema_version';")" = "6" ] ||
    fail "findings require schema version 6"
  pass "findings can be added, listed, rendered, and resolved"
}

test_operational_views() {
  local repo ready blocked reviewed clean stale_id output
  repo="$TEST_DIR/views"
  run_git_init "$repo"
  (cd "$repo" && "$CXQ" install >/dev/null)

  ready=$(cd "$repo" && "$CXQ" add "Needs work now" --priority 90 | sed 's/.*#//')
  blocked=$(cd "$repo" && "$CXQ" add "Waiting on product" --priority 80 | sed 's/.*#//')
  reviewed=$(cd "$repo" && "$CXQ" add "Review with findings" --priority 70 | sed 's/.*#//')
  clean=$(cd "$repo" && "$CXQ" add "Review without findings" --priority 60 | sed 's/.*#//')

  (cd "$repo" && "$CXQ" reopen "$blocked" --to blocked --reason "needs a decision" >/dev/null)
  for stale_id in "$reviewed" "$clean"; do
    (cd "$repo" && "$CXQ" claim "$stale_id" --agent tester --lease 1h >/dev/null)
    (cd "$repo" && "$CXQ" review "$stale_id" --summary "Please review" >/dev/null)
  done
  (cd "$repo" && "$CXQ" finding add "$reviewed" --severity medium --note "Edge case is untested" >/dev/null)

  output=$(cd "$repo" && "$CXQ" list --needs-action)
  assert_contains "$output" "Needs work now"
  assert_contains "$output" "Waiting on product"
  assert_contains "$output" "Review with findings"
  assert_not_contains "$output" "Review without findings" "clean reviews are not pending action"

  (cd "$repo" && "$CXQ" note "$ready" "DUDA: which token store should we use?" >/dev/null)
  (cd "$repo" && "$CXQ" note "$blocked" "BLOCKER: waiting on the vendor contract" >/dev/null)
  (cd "$repo" && "$CXQ" note "$clean" "Regular progress note" >/dev/null)

  output=$(cd "$repo" && "$CXQ" list --questions)
  assert_contains "$output" "DUDA: which token store should we use?"
  assert_contains "$output" "BLOCKER: waiting on the vendor contract"
  assert_not_contains "$output" "Regular progress note" "plain notes are not questions"

  output=$(cd "$repo" && "$CXQ" review-stale)
  assert_not_contains "$output" "Review with findings" "fresh reviews are not stale after 24h"

  sqlite3 -batch "$repo/.cxq/tasks.db" "DROP TRIGGER IF EXISTS trg_tasks_updated_at; UPDATE tasks SET updated_at = strftime('%Y-%m-%dT%H:%M:%fZ', 'now', '-48 hours') WHERE id = $reviewed;"

  output=$(cd "$repo" && "$CXQ" review-stale)
  assert_contains "$output" "Review with findings"
  assert_not_contains "$output" "Review without findings" "only stale reviews are listed"

  output=$(cd "$repo" && "$CXQ" review-stale --older-than 3d)
  assert_not_contains "$output" "Review with findings" "a longer window should exclude the 48h review"

  set +e
  output=$(cd "$repo" && "$CXQ" review-stale --older-than 24 2>&1)
  status=$?
  set -e
  [ "$status" -ne 0 ] || fail "review-stale should reject malformed durations"
  assert_contains "$output" "--older-than must look like 30m, 2h, or 1d"
  pass "operational views surface pending action, questions, and stale reviews"
}

test_done_warns_about_unfinished_work() {
  local repo pending clean withfinding output status
  repo="$TEST_DIR/done-warnings"
  run_git_init "$repo"
  (cd "$repo" && "$CXQ" install >/dev/null)

  pending=$(cd "$repo" && "$CXQ" add "Pending work task" | sed 's/.*#//')
  clean=$(cd "$repo" && "$CXQ" add "Clean task" | sed 's/.*#//')
  withfinding=$(cd "$repo" && "$CXQ" add "Task with finding" | sed 's/.*#//')

  set +e
  output=$(cd "$repo" && "$CXQ" "done" "$pending" --summary "Main flow works, docs are still pending" 2>&1)
  status=$?
  set -e
  [ "$status" -ne 0 ] || fail "done should refuse a summary that mentions pending work"
  assert_contains "$output" "may not be finished"
  assert_contains "$output" "the summary still mentions pending work"
  assert_contains "$output" "cxq done $pending --force"
  [ "$(sqlite3 -batch -noheader "$repo/.cxq/tasks.db" "SELECT status FROM tasks WHERE id = $pending;")" != "done" ] ||
    fail "a warned task must not be closed without --force"

  output=$(cd "$repo" && "$CXQ" "done" "$pending" --summary "Main flow works, docs are still pending" --force)
  assert_contains "$output" "Marked task #$pending done"

  (cd "$repo" && "$CXQ" finding add "$withfinding" --severity high --note "Auth bypass on refresh" >/dev/null)
  set +e
  output=$(cd "$repo" && "$CXQ" "done" "$withfinding" --summary "Shipped" 2>&1)
  status=$?
  set -e
  [ "$status" -ne 0 ] || fail "done should refuse a task with open findings"
  assert_contains "$output" "1 open finding(s)"

  set +e
  output=$(cd "$repo" && CXQ_TEST_TTY_ANSWER=n "$CXQ" "done" "$withfinding" --summary "Shipped" 2>&1)
  status=$?
  set -e
  [ "$status" -ne 0 ] || fail "answering no should abort an interactive close"
  assert_contains "$output" "Mark task #$withfinding done anyway? [y/N]"
  assert_contains "$output" "was not closed"
  [ "$(sqlite3 -batch -noheader "$repo/.cxq/tasks.db" "SELECT status FROM tasks WHERE id = $withfinding;")" != "done" ] ||
    fail "answering no must leave the task open"

  output=$(cd "$repo" && CXQ_TEST_TTY_ANSWER=y "$CXQ" "done" "$withfinding" --summary "Shipped" 2>&1)
  assert_contains "$output" "Marked task #$withfinding done"

  output=$(cd "$repo" && "$CXQ" "done" "$clean" --summary "Implemented and verified")
  assert_contains "$output" "Marked task #$clean done"
  [ "$(sqlite3 -batch -noheader "$repo/.cxq/tasks.db" "SELECT status FROM tasks WHERE id = $clean;")" = "done" ] ||
    fail "a clean close must never be blocked"
  pass "done warns before closing tasks with unfinished work"
}

test_concurrent_commands_do_not_lock() {
  local repo id i output status pids pid combined
  repo="$TEST_DIR/concurrency"
  run_git_init "$repo"
  (cd "$repo" && "$CXQ" install >/dev/null)
  id=$(cd "$repo" && "$CXQ" add "Concurrency subject" | sed 's/.*#//')

  rm -rf "$TEST_DIR/concurrency-out"
  mkdir -p "$TEST_DIR/concurrency-out"

  pids=""
  for i in 1 2 3 4 5 6; do
    (cd "$repo" && "$CXQ" show "$id" >"$TEST_DIR/concurrency-out/show-$i.log" 2>&1) &
    pids="$pids $!"
    (cd "$repo" && "$CXQ" add "Parallel task $i" >"$TEST_DIR/concurrency-out/add-$i.log" 2>&1) &
    pids="$pids $!"
    (cd "$repo" && "$CXQ" note "$id" "parallel note $i" >"$TEST_DIR/concurrency-out/note-$i.log" 2>&1) &
    pids="$pids $!"
  done

  status=0
  for pid in $pids; do
    wait "$pid" || status=1
  done

  combined=$(cat "$TEST_DIR"/concurrency-out/*.log)
  assert_not_contains "$combined" "database is locked" "concurrent commands must not fail on SQLite locks"
  [ "$status" -eq 0 ] || fail "concurrent cxq commands should all succeed. Output: $combined"

  [ "$(sqlite3 -batch -noheader "$repo/.cxq/tasks.db" "SELECT COUNT(*) FROM tasks WHERE title LIKE 'Parallel task %';")" = "6" ] ||
    fail "every concurrent add should be recorded"
  [ "$(sqlite3 -batch -noheader "$repo/.cxq/tasks.db" "SELECT COUNT(*) FROM task_events WHERE task_id = $id AND event_type = 'note';")" = "6" ] ||
    fail "every concurrent note should be recorded"
  pass "concurrent reads and writes do not hit database locks"
}


test_edit_updates_fields_and_logs_diff() {
  local repo id output
  repo="$TEST_DIR/edit"
  run_git_init "$repo"
  (cd "$repo" && "$CXQ" install >/dev/null)

  id=$(cd "$repo" && "$CXQ" add "Original title" --priority 50 --tag alpha --files "src/a" --acceptance "old criteria" --verify "make check" | sed 's/.*#//')

  output=$(cd "$repo" && "$CXQ" edit "$id" --title "New title" --body "New body" --priority 90 --acceptance "new criteria" --verify "make test" --branch feature/x --due 2026-12-01)
  assert_contains "$output" "Edited task #$id"
  assert_contains "$output" "title: Original title -> New title"
  assert_contains "$output" "priority: 50 -> 90"
  assert_contains "$output" "due_date: (empty) -> 2026-12-01"

  output=$(cd "$repo" && "$CXQ" show "$id")
  assert_contains "$output" "New title"
  assert_contains "$output" "New body"
  assert_contains "$output" "2026-12-01"
  assert_contains "$output" "feature/x"
  assert_contains "$output" "## Edit history"
  assert_contains "$output" "title: Original title -> New title"
  [ "$(sqlite3 -batch -noheader "$repo/.cxq/tasks.db" "SELECT COUNT(*) FROM task_events WHERE task_id = $id AND event_type = 'edited';")" = "1" ] ||
    fail "one edit must log exactly one edited event"
  [ "$(sqlite3 -batch -noheader "$repo/.cxq/tasks.db" "SELECT due_date FROM tasks WHERE id = $id;")" = "2026-12-01" ] ||
    fail "due_date must be stored"

  # files/tags add + remove, and --due-clear
  output=$(cd "$repo" && "$CXQ" edit "$id" --files-add "src/b" --tags-add beta --tags-remove alpha --due-clear)
  assert_contains "$output" "allowed_paths: src/a -> src/a,src/b"
  assert_contains "$output" "tags: alpha -> beta"
  assert_contains "$output" "due_date: 2026-12-01 -> (empty)"
  output=$(cd "$repo" && "$CXQ" show "$id")
  assert_contains "$output" "src/b"
  assert_contains "$output" "beta"
  # The cleared date stays in the edit history (that is the audit trail),
  # but the Due date section itself must now be empty.
  printf '%s' "$output" | grep -A1 '^## Due date$' | grep -q '^None$' ||
    fail "due-clear must leave the Due date section empty (show output was: $output)"
  pass "edit updates fields and logs one diff event"
}

test_edit_rejects_bad_input() {
  local repo id output status
  repo="$TEST_DIR/edit-rejects"
  run_git_init "$repo"
  (cd "$repo" && "$CXQ" install >/dev/null)

  id=$(cd "$repo" && "$CXQ" add "Edit target" --priority 50 | sed 's/.*#//')

  set +e
  output=$(cd "$repo" && "$CXQ" edit "$id" 2>&1); status=$?
  set -e
  [ "$status" -ne 0 ] || fail "edit with no flags must fail"
  assert_contains "$output" "at least one change flag"

  set +e
  output=$(cd "$repo" && "$CXQ" edit "$id" --title "Edit target" 2>&1); status=$?
  set -e
  [ "$status" -ne 0 ] || fail "a no-op edit must fail"
  assert_contains "$output" "made no changes"

  set +e
  output=$(cd "$repo" && "$CXQ" edit "$id" --due 2026-02-30 2>&1); status=$?
  set -e
  [ "$status" -ne 0 ] || fail "an impossible due date must fail"
  assert_contains "$output" "due date must be a valid YYYY-MM-DD date"

  set +e
  output=$(cd "$repo" && "$CXQ" edit "$id" --due 01-12-2026 2>&1); status=$?
  set -e
  [ "$status" -ne 0 ] || fail "a non-ISO due date must fail"

  set +e
  output=$(cd "$repo" && "$CXQ" edit "$id" --priority notanumber 2>&1); status=$?
  set -e
  [ "$status" -ne 0 ] || fail "a non-integer priority must fail"
  assert_contains "$output" "priority must be an integer"

  # Illegal status transition: ready -> done is not in the table.
  set +e
  output=$(cd "$repo" && "$CXQ" edit "$id" --status "done" 2>&1); status=$?
  set -e
  [ "$status" -ne 0 ] || fail "edit must reject illegal status transitions"
  assert_contains "$output" "cannot move task $id from ready to done"

  # Legal transition out of review requires a reason.
  (cd "$repo" && "$CXQ" claim "$id" --agent tester --lease 1h >/dev/null)
  (cd "$repo" && "$CXQ" review "$id" --summary "done-ish" >/dev/null)
  set +e
  output=$(cd "$repo" && "$CXQ" edit "$id" --status ready 2>&1); status=$?
  set -e
  [ "$status" -ne 0 ] || fail "moving out of review without a reason must fail"
  assert_contains "$output" "requires --reason"

  output=$(cd "$repo" && "$CXQ" edit "$id" --status ready --reason "criteria missing")
  assert_contains "$output" "status: review -> ready"
  assert_contains "$output" "reason: criteria missing"
  pass "edit rejects no-ops, bad dates, bad priorities, and illegal transitions"
}

test_delete_guardrails() {
  local repo ready claimed inbox output status
  repo="$TEST_DIR/delete"
  run_git_init "$repo"
  (cd "$repo" && "$CXQ" install >/dev/null)

  ready=$(cd "$repo" && "$CXQ" add "Deletable" | sed 's/.*#//')
  claimed=$(cd "$repo" && "$CXQ" add "Claimed task" | sed 's/.*#//')
  inbox=$(cd "$repo" && "$CXQ" add "Inbox task" --status inbox | sed 's/.*#//')
  (cd "$repo" && "$CXQ" claim "$claimed" --agent tester --lease 1h >/dev/null)
  (cd "$repo" && "$CXQ" note "$ready" "a note to keep" >/dev/null)
  (cd "$repo" && "$CXQ" finding add "$ready" --severity low --note "nit" >/dev/null)

  # Delete still requires --force in non-interactive runs, whatever the status.
  set +e
  output=$(cd "$repo" && "$CXQ" delete "$ready" 2>&1); status=$?
  set -e
  [ "$status" -ne 0 ] || fail "a ready task must not be deletable without --force"
  assert_contains "$output" "requires --force"

  set +e
  output=$(cd "$repo" && "$CXQ" delete "$inbox" 2>&1); status=$?
  set -e
  [ "$status" -ne 0 ] || fail "non-interactive delete without --force must fail"
  assert_contains "$output" "requires --force"

  set +e
  output=$(cd "$repo" && "$CXQ" delete "$claimed" 2>&1); status=$?
  set -e
  [ "$status" -ne 0 ] || fail "a claimed task must not be deletable without --force"
  assert_contains "$output" "requires --force"

  # On a TTY the prompt asks once: 'n' keeps the task, 'y' trashes it.
  set +e
  output=$(cd "$repo" && CXQ_TEST_TTY_ANSWER=n "$CXQ" delete "$inbox" 2>&1); status=$?
  set -e
  [ "$status" -ne 0 ] || fail "answering no at the delete prompt must keep the task"
  assert_contains "$output" "was not deleted"
  [ "$(sqlite3 -batch -noheader "$repo/.cxq/tasks.db" "SELECT status FROM tasks WHERE id = $inbox;")" = "inbox" ] ||
    fail "a declined delete must leave the task alone"

  output=$(cd "$repo" && CXQ_TEST_TTY_ANSWER=y "$CXQ" delete "$inbox")
  assert_contains "$output" "Trashed task #$inbox (was inbox)"

  # --force trashes instead of deleting: the row, its events, and its
  # findings survive, so the task can be restored.
  output=$(cd "$repo" && "$CXQ" delete "$ready" --force)
  assert_contains "$output" "Trashed task #$ready (was ready)"
  [ "$(sqlite3 -batch -noheader "$repo/.cxq/tasks.db" "SELECT status FROM tasks WHERE id = $ready;")" = "trashed" ] ||
    fail "delete must move the task to trashed"
  [ "$(sqlite3 -batch -noheader "$repo/.cxq/tasks.db" "SELECT trashed_from_status FROM tasks WHERE id = $ready;")" = "ready" ] ||
    fail "delete must record the pre-trash status"
  [ "$(sqlite3 -batch -noheader "$repo/.cxq/tasks.db" "SELECT COUNT(*) FROM task_events WHERE task_id = $ready;")" != "0" ] ||
    fail "delete must keep the event history"
  [ "$(sqlite3 -batch -noheader "$repo/.cxq/tasks.db" "SELECT COUNT(*) FROM task_findings WHERE task_id = $ready;")" = "1" ] ||
    fail "delete must keep findings"

  output=$(cd "$repo" && "$CXQ" remove "$claimed" --force)
  assert_contains "$output" "Trashed task #$claimed (was claimed)" "remove must be an alias of delete"

  set +e
  output=$(cd "$repo" && "$CXQ" delete 999 --force 2>&1); status=$?
  set -e
  [ "$status" -ne 0 ] || fail "deleting a missing task must fail"
  assert_contains "$output" "task not found: 999"
  pass "delete requires --force, asks on a TTY, and trashes instead of removing rows"
}

test_trash_restore_purge() {
  local repo a b c output status
  repo="$TEST_DIR/trash"
  run_git_init "$repo"
  (cd "$repo" && "$CXQ" install >/dev/null)

  a=$(cd "$repo" && "$CXQ" add "Trash me" --priority 80 | sed 's/.*#//')
  b=$(cd "$repo" && "$CXQ" add "Stay ready" --priority 70 | sed 's/.*#//')
  c=$(cd "$repo" && "$CXQ" add "Claimed one" --priority 60 | sed 's/.*#//')
  (cd "$repo" && "$CXQ" claim "$c" --agent tester --lease 1h >/dev/null)

  # Trash hides the task from the default list and board, but --status and
  # `cxq trash` still find it.
  output=$(cd "$repo" && "$CXQ" delete "$a" --force)
  assert_contains "$output" "Trashed task #$a (was ready)"
  output=$(cd "$repo" && "$CXQ" list)
  assert_not_contains "$output" "Trash me"
  assert_contains "$output" "Stay ready"
  output=$(cd "$repo" && "$CXQ" board)
  assert_not_contains "$output" "Trash me"
  output=$(cd "$repo" && "$CXQ" list --status trashed)
  assert_contains "$output" "Trash me"
  output=$(cd "$repo" && "$CXQ" trash)
  assert_contains "$output" "Trash me"
  assert_contains "$output" "ready"
  output=$(cd "$repo" && "$CXQ" stats)
  assert_contains "$output" "status_trashed: 1"

  # A trashed task cannot be claimed or edited.
  set +e
  output=$(cd "$repo" && "$CXQ" claim "$a" --agent tester --lease 1h 2>&1); status=$?
  set -e
  [ "$status" -ne 0 ] || fail "a trashed task must not be claimable"
  assert_contains "$output" "not available to claim"

  set +e
  output=$(cd "$repo" && "$CXQ" edit "$a" --title "Nope" 2>&1); status=$?
  set -e
  [ "$status" -ne 0 ] || fail "a trashed task must not be editable"
  assert_contains "$output" "is trashed; restore it first"

  # Deleting an already-trashed task errors; restoring a live task errors.
  set +e
  output=$(cd "$repo" && "$CXQ" delete "$a" --force 2>&1); status=$?
  set -e
  [ "$status" -ne 0 ] || fail "deleting an already-trashed task must fail"
  assert_contains "$output" "already trashed"

  set +e
  output=$(cd "$repo" && "$CXQ" restore "$b" 2>&1); status=$?
  set -e
  [ "$status" -ne 0 ] || fail "restoring a task that is not trashed must fail"
  assert_contains "$output" "is not trashed"

  # Restore returns the task to its pre-trash status; a claimed task lands
  # on ready because its claim was cleared when trashed.
  output=$(cd "$repo" && "$CXQ" restore "$a")
  assert_contains "$output" "Restored task #$a to ready"
  output=$(cd "$repo" && "$CXQ" list)
  assert_contains "$output" "Trash me"

  output=$(cd "$repo" && "$CXQ" delete "$c" --force)
  assert_contains "$output" "Trashed task #$c (was claimed)"
  output=$(cd "$repo" && "$CXQ" restore "$c")
  assert_contains "$output" "Restored task #$c to ready"

  # Purge with an empty trash is a no-op success; --days 30 spares a
  # freshly trashed task; --days 0 and --all empty the trash for real.
  output=$(cd "$repo" && "$CXQ" trash purge)
  assert_contains "$output" "Purged 0 trashed task(s)"
  (cd "$repo" && "$CXQ" delete "$a" --force >/dev/null)
  output=$(cd "$repo" && "$CXQ" trash purge --days 30)
  assert_contains "$output" "Purged 0 trashed task(s)"
  output=$(cd "$repo" && "$CXQ" trash purge --days 0)
  assert_contains "$output" "Purged 1 trashed task(s)"
  set +e
  output=$(cd "$repo" && "$CXQ" show "$a" 2>&1); status=$?
  set -e
  [ "$status" -ne 0 ] || fail "a purged task must be gone"
  assert_contains "$output" "task not found: $a"
  [ "$(sqlite3 -batch -noheader "$repo/.cxq/tasks.db" "SELECT COUNT(*) FROM task_events WHERE task_id = $a;")" = "0" ] ||
    fail "purge must cascade events"
  output=$(cd "$repo" && "$CXQ" trash)
  assert_contains "$output" "(empty)"

  (cd "$repo" && "$CXQ" delete "$b" --force >/dev/null)
  output=$(cd "$repo" && "$CXQ" trash purge --all)
  assert_contains "$output" "Purged 1 trashed task(s)"

  # Invalid ids and bad --days values error like elsewhere in the CLI.
  set +e
  output=$(cd "$repo" && "$CXQ" restore 999 2>&1); status=$?
  set -e
  [ "$status" -ne 0 ] || fail "restoring a missing task must fail"
  assert_contains "$output" "task not found: 999"

  set +e
  output=$(cd "$repo" && "$CXQ" trash purge --days banana 2>&1); status=$?
  set -e
  [ "$status" -ne 0 ] || fail "purge with a non-integer --days must fail"
  assert_contains "$output" "--days must be a non-negative integer"

  set +e
  output=$(cd "$repo" && "$CXQ" trash frobnicate 2>&1); status=$?
  set -e
  [ "$status" -ne 0 ] || fail "an unknown trash subcommand must fail"
  assert_contains "$output" "unknown trash command"
  pass "trash hides tasks from list/board, restore returns them, purge deletes them for real"
}

test_undo_reverts_last_edit() {
  local repo id output status
  repo="$TEST_DIR/undo"
  run_git_init "$repo"
  (cd "$repo" && "$CXQ" install >/dev/null)

  id=$(cd "$repo" && "$CXQ" add "Original title" --priority 50 --due 2026-01-15 | sed 's/.*#//')

  # Undo with no prior edit errors.
  set +e
  output=$(cd "$repo" && "$CXQ" undo "$id" 2>&1); status=$?
  set -e
  [ "$status" -ne 0 ] || fail "undo with no prior edit must fail"
  assert_contains "$output" "has nothing to undo"

  # One edit, one undo: every changed field comes back.
  (cd "$repo" && "$CXQ" edit "$id" --title "New title" --priority 90 --due 2026-12-01 >/dev/null)
  output=$(cd "$repo" && "$CXQ" undo "$id")
  assert_contains "$output" "Undid last edit of task #$id"
  assert_contains "$output" "title"
  assert_contains "$output" "priority"
  assert_contains "$output" "due_date"
  [ "$(sqlite3 -batch -noheader "$repo/.cxq/tasks.db" "SELECT title FROM tasks WHERE id = $id;")" = "Original title" ] ||
    fail "undo must restore the title"
  [ "$(sqlite3 -batch -noheader "$repo/.cxq/tasks.db" "SELECT priority FROM tasks WHERE id = $id;")" = "50" ] ||
    fail "undo must restore the priority"
  [ "$(sqlite3 -batch -noheader "$repo/.cxq/tasks.db" "SELECT due_date FROM tasks WHERE id = $id;")" = "2026-01-15" ] ||
    fail "undo must restore the due date"

  # A second undo finds nothing left to undo (each undo reverts one edit).
  set +e
  output=$(cd "$repo" && "$CXQ" undo "$id" 2>&1); status=$?
  set -e
  [ "$status" -ne 0 ] || fail "a second undo must fail once the only edit is undone"
  assert_contains "$output" "has nothing to undo"

  # Two edits, two undos: each reverts only the most recent edit.
  (cd "$repo" && "$CXQ" edit "$id" --title "Second title" >/dev/null)
  (cd "$repo" && "$CXQ" edit "$id" --priority 10 >/dev/null)
  output=$(cd "$repo" && "$CXQ" undo "$id")
  assert_contains "$output" "priority"
  [ "$(sqlite3 -batch -noheader "$repo/.cxq/tasks.db" "SELECT priority FROM tasks WHERE id = $id;")" = "50" ] ||
    fail "undo must revert the priority edit"
  [ "$(sqlite3 -batch -noheader "$repo/.cxq/tasks.db" "SELECT title FROM tasks WHERE id = $id;")" = "Second title" ] ||
    fail "undo must revert only the most recent edit"
  output=$(cd "$repo" && "$CXQ" undo "$id")
  assert_contains "$output" "title"
  [ "$(sqlite3 -batch -noheader "$repo/.cxq/tasks.db" "SELECT title FROM tasks WHERE id = $id;")" = "Original title" ] ||
    fail "a second undo must revert the earlier edit"

  # Undo restores a cleared due date, and a changed status.
  (cd "$repo" && "$CXQ" edit "$id" --due-clear >/dev/null)
  [ "$(sqlite3 -batch -noheader "$repo/.cxq/tasks.db" "SELECT COALESCE(due_date, '') FROM tasks WHERE id = $id;")" = "" ] ||
    fail "due-clear must clear the date"
  output=$(cd "$repo" && "$CXQ" undo "$id")
  assert_contains "$output" "due_date"
  [ "$(sqlite3 -batch -noheader "$repo/.cxq/tasks.db" "SELECT due_date FROM tasks WHERE id = $id;")" = "2026-01-15" ] ||
    fail "undo must restore a cleared due date"

  (cd "$repo" && "$CXQ" claim "$id" --agent tester --lease 1h >/dev/null)
  (cd "$repo" && "$CXQ" review "$id" --summary "done-ish" >/dev/null)
  (cd "$repo" && "$CXQ" edit "$id" --status ready --reason "recheck" >/dev/null)
  output=$(cd "$repo" && "$CXQ" undo "$id")
  assert_contains "$output" "status"
  [ "$(sqlite3 -batch -noheader "$repo/.cxq/tasks.db" "SELECT status FROM tasks WHERE id = $id;")" = "review" ] ||
    fail "undo must restore the previous status"

  # Undo on a trashed task errors (restore first); every undo logs one event.
  (cd "$repo" && "$CXQ" delete "$id" --force >/dev/null)
  set +e
  output=$(cd "$repo" && "$CXQ" undo "$id" 2>&1); status=$?
  set -e
  [ "$status" -ne 0 ] || fail "undo on a trashed task must fail"
  assert_contains "$output" "is trashed; restore it first"
  [ "$(sqlite3 -batch -noheader "$repo/.cxq/tasks.db" "SELECT COUNT(*) FROM task_events WHERE task_id = $id AND event_type = 'undone';")" = "5" ] ||
    fail "each undo must log exactly one undone event"

  # Invalid ids error like elsewhere in the CLI.
  set +e
  output=$(cd "$repo" && "$CXQ" undo notanid 2>&1); status=$?
  set -e
  [ "$status" -ne 0 ] || fail "undo with a non-integer id must fail"
  assert_contains "$output" "task id must be an integer"
  pass "undo reverts the most recent edit, one edit at a time"
}

test_board_stats_activity() {
  local repo a b c output
  repo="$TEST_DIR/visibility"
  run_git_init "$repo"
  (cd "$repo" && "$CXQ" install >/dev/null)

  a=$(cd "$repo" && "$CXQ" add "Overdue ready" --priority 90 --due 2000-01-01 | sed 's/.*#//')
  b=$(cd "$repo" && "$CXQ" add "Future ready" --priority 80 --due 2999-01-01 | sed 's/.*#//')
  c=$(cd "$repo" && "$CXQ" add "Claimed one" --priority 70 | sed 's/.*#//')
  (cd "$repo" && "$CXQ" claim "$c" --agent tester --lease 1h >/dev/null)
  (cd "$repo" && "$CXQ" block "$b" --by "$a" >/dev/null)

  output=$(cd "$repo" && "$CXQ" board)
  assert_contains "$output" "## ready (2)"
  assert_contains "$output" "## claimed (1)"
  assert_contains "$output" "Overdue ready OVERDUE (due 2000-01-01)"
  assert_contains "$output" "Future ready due 2999-01-01"

  output=$(cd "$repo" && "$CXQ" stats)
  assert_contains "$output" "tasks_total: 3"
  assert_contains "$output" "status_ready: 2"
  assert_contains "$output" "status_claimed: 1"
  assert_contains "$output" "overdue: 1"
  assert_contains "$output" "oldest_ready: #$a Overdue ready"
  assert_contains "$output" "done_last_7d: 0"
  assert_contains "$output" "top_blockers:"
  assert_contains "$output" "Overdue ready blocks 1 task(s)"

  output=$(cd "$repo" && "$CXQ" activity --limit 2)
  assert_contains "$output" "blocked_by"
  assert_contains "$output" "claimed"

  output=$(cd "$repo" && "$CXQ" activity)
  assert_contains "$output" "created"
  pass "board, stats, and activity render counts, overdue, and blockers"
}

test_list_filters_and_formats() {
  local repo a b output
  repo="$TEST_DIR/list-filters"
  run_git_init "$repo"
  (cd "$repo" && "$CXQ" install >/dev/null)

  a=$(cd "$repo" && "$CXQ" add "Alpha auth work" --priority 90 --tag auth --due 2000-01-01 | sed 's/.*#//')
  b=$(cd "$repo" && "$CXQ" add "Beta billing work" --priority 40 --tag billing --due 2999-01-01 | sed 's/.*#//')
  (cd "$repo" && "$CXQ" claim "$b" --agent mira --lease 1h >/dev/null)

  output=$(cd "$repo" && "$CXQ" list --tag auth)
  assert_contains "$output" "Alpha auth work"
  assert_not_contains "$output" "Beta billing work"

  output=$(cd "$repo" && "$CXQ" list --agent mira)
  assert_contains "$output" "Beta billing work"
  assert_not_contains "$output" "Alpha auth work"

  output=$(cd "$repo" && "$CXQ" list --priority-min 80)
  assert_contains "$output" "Alpha auth work"
  assert_not_contains "$output" "Beta billing work"

  output=$(cd "$repo" && "$CXQ" list --search billing)
  assert_contains "$output" "Beta billing work"
  assert_not_contains "$output" "Alpha auth work"

  output=$(cd "$repo" && "$CXQ" list --overdue)
  assert_contains "$output" "Alpha auth work"
  assert_not_contains "$output" "Beta billing work"

  output=$(cd "$repo" && "$CXQ" list --due-before 2025-01-01)
  assert_contains "$output" "Alpha auth work"
  assert_not_contains "$output" "Beta billing work"

  output=$(cd "$repo" && "$CXQ" list --format json)
  assert_contains "$output" '"title":"Alpha auth work"'
  assert_contains "$output" '"due_date":"2000-01-01"'

  output=$(cd "$repo" && "$CXQ" list --format md)
  assert_contains "$output" "| id | status | priority | title |"
  assert_contains "$output" "Alpha auth work"

  # Default output keeps the legacy column set (no due_date column appears
  # without the new flags); sqlite -column pads widths to the widest value,
  # so assert on the columns, not on exact inter-column spacing.
  output=$(cd "$repo" && "$CXQ" list)
  assert_contains "$output" "claimed_by"
  assert_contains "$output" "lease_until"
  assert_not_contains "$output" "due_date"
  pass "list filters, search, overdue, and json/md formats work"
}

test_export_and_watch() {
  local repo id output status
  repo="$TEST_DIR/export"
  run_git_init "$repo"
  (cd "$repo" && "$CXQ" install >/dev/null)
  id=$(cd "$repo" && "$CXQ" add "Exportable task" --priority 70 --due 2999-01-01 | sed 's/.*#//')

  output=$(cd "$repo" && "$CXQ" export-md)
  assert_contains "$output" "# cxq board"
  assert_contains "$output" "## ready (1)"
  assert_contains "$output" "Exportable task"

  output=$(cd "$repo" && "$CXQ" export --format json)
  assert_contains "$output" '"title":"Exportable task"'

  output=$(cd "$repo" && "$CXQ" export --format csv)
  assert_contains "$output" "id,title,body,status,priority,due_date"
  assert_contains "$output" "Exportable task"

  set +e
  output=$(cd "$repo" && "$CXQ" export --format yaml 2>&1); status=$?
  set -e
  [ "$status" -ne 0 ] || fail "export must reject unknown formats"
  assert_contains "$output" "export format must be json or csv"

  # || true intentionally swallows the watch timeout exit.
  # shellcheck disable=SC2015
  output=$(cd "$repo" && timeout 3 "$CXQ" watch --interval 1s 2>&1 || true)
  assert_contains "$output" "# cxq board"
  assert_contains "$output" "Exportable task"
  pass "export-md, export json/csv, and watch render the board"
}

# Builds a hand-made schema-v3 queue DB (no due_date column, meta = 3).
build_v3_db() {
  local repo=$1
  mkdir -p "$repo/.cxq/prompts"
  printf 'x\n' >"$repo/.cxq/prompts/task.md"
  printf '## Local task queue\n\nUse cxq.\n' >"$repo/AGENTS.md"
  printf -- "-- old stock v1 schema template\nVALUES ('schema_version', '1');\n" >"$repo/.cxq/tasks.schema.sql"
  sqlite3 -batch "$repo/.cxq/tasks.db" "
CREATE TABLE tasks(id INTEGER PRIMARY KEY AUTOINCREMENT,title TEXT NOT NULL,body TEXT NOT NULL DEFAULT '',status TEXT NOT NULL DEFAULT 'inbox',priority INTEGER NOT NULL DEFAULT 50,repo_path TEXT NOT NULL,branch TEXT,allowed_paths_json TEXT NOT NULL DEFAULT '[]',tags_json TEXT NOT NULL DEFAULT '[]',deps_json TEXT NOT NULL DEFAULT '[]',acceptance TEXT NOT NULL DEFAULT '',verify_command TEXT NOT NULL DEFAULT '',claimed_by TEXT,claimed_at TEXT,lease_until TEXT,result_summary TEXT NOT NULL DEFAULT '',transcript_path TEXT,created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')),updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')));
CREATE TABLE task_events(id INTEGER PRIMARY KEY AUTOINCREMENT,task_id INTEGER NOT NULL,event_type TEXT NOT NULL,actor TEXT NOT NULL,note TEXT NOT NULL DEFAULT '',data_json TEXT NOT NULL DEFAULT '{}',created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')));
CREATE TABLE task_dependencies(task_id INTEGER NOT NULL,blocker_task_id INTEGER NOT NULL,created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')),PRIMARY KEY(task_id,blocker_task_id));
CREATE TABLE task_findings(id INTEGER PRIMARY KEY AUTOINCREMENT,task_id INTEGER NOT NULL,severity TEXT NOT NULL DEFAULT 'medium',status TEXT NOT NULL DEFAULT 'open',note TEXT NOT NULL DEFAULT '',followup_task_id INTEGER,created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')),updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')));
CREATE TABLE cxq_meta(key TEXT PRIMARY KEY,value TEXT NOT NULL);
INSERT INTO cxq_meta VALUES('schema_version','3');
INSERT INTO tasks(title,status,priority,repo_path) VALUES('Legacy task','ready',70,'$repo');
INSERT INTO task_events(task_id,event_type,actor,note) VALUES(1,'created','tester','Legacy task');
"
}

test_schema_migration_v3_to_v6() {
  local repo output
  repo="$TEST_DIR/migrate-v3"
  run_git_init "$repo"
  build_v3_db "$repo"

  output=$(cd "$repo" && "$CXQ" migrate)
  assert_contains "$output" "Migrated schema v3 -> v6"
  [ "$(sqlite3 -batch -noheader "$repo/.cxq/tasks.db" "SELECT value FROM cxq_meta WHERE key = 'schema_version';")" = "6" ] ||
    fail "migrate must bump schema_version to 6"
  [ "$(sqlite3 -batch -noheader "$repo/.cxq/tasks.db" "SELECT COUNT(*) FROM pragma_table_info('tasks') WHERE name = 'due_date';")" = "1" ] ||
    fail "migrate must add the due_date column"
  [ "$(sqlite3 -batch -noheader "$repo/.cxq/tasks.db" "SELECT COUNT(*) FROM pragma_table_info('tasks') WHERE name IN ('trashed_from_status', 'trashed_at');")" = "2" ] ||
    fail "migrate must add the trash columns"
  [ "$(sqlite3 -batch -noheader "$repo/.cxq/tasks.db" "SELECT title FROM tasks WHERE id = 1;")" = "Legacy task" ] ||
    fail "migrate must preserve existing tasks"
  [ "$(sqlite3 -batch -noheader "$repo/.cxq/tasks.db" "SELECT COUNT(*) FROM task_events WHERE task_id = 1;")" = "1" ] ||
    fail "migrate must preserve events"
  output=$(cd "$repo" && "$CXQ" list)
  assert_contains "$output" "Legacy task"
  output=$(cd "$repo" && "$CXQ" edit 1 --due 2026-12-01)
  assert_contains "$output" "due_date: (empty) -> 2026-12-01"

  # Idempotent: a second migrate is a no-op report, not an error.
  output=$(cd "$repo" && "$CXQ" migrate)
  assert_contains "$output" "Migrated schema v6 -> v6"

  # Auto-migrate on open: a fresh v3 DB migrates when any command touches it.
  repo="$TEST_DIR/migrate-auto"
  run_git_init "$repo"
  build_v3_db "$repo"
  output=$(cd "$repo" && "$CXQ" list 2>/dev/null)
  assert_contains "$output" "Legacy task"
  [ "$(sqlite3 -batch -noheader "$repo/.cxq/tasks.db" "SELECT value FROM cxq_meta WHERE key = 'schema_version';")" = "6" ] ||
    fail "opening a v3 queue must auto-migrate it to v6"
  pass "schema v3 -> v6 migration preserves data and auto-migrates on open"
}

build_v4_db() {
  local repo=$1
  mkdir -p "$repo/.cxq/prompts"
  printf 'x\n' >"$repo/.cxq/prompts/task.md"
  printf '## Local task queue\n\nUse cxq.\n' >"$repo/AGENTS.md"
  printf -- "-- old stock v4 schema template\nVALUES ('schema_version', '4');\n" >"$repo/.cxq/tasks.schema.sql"
  sqlite3 -batch "$repo/.cxq/tasks.db" "
CREATE TABLE tasks(id INTEGER PRIMARY KEY AUTOINCREMENT,title TEXT NOT NULL,body TEXT NOT NULL DEFAULT '',status TEXT NOT NULL DEFAULT 'inbox' CHECK (status IN ('inbox','ready','claimed','blocked','review','done','wontfix')),priority INTEGER NOT NULL DEFAULT 50,due_date TEXT,repo_path TEXT NOT NULL,branch TEXT,allowed_paths_json TEXT NOT NULL DEFAULT '[]',tags_json TEXT NOT NULL DEFAULT '[]',deps_json TEXT NOT NULL DEFAULT '[]',acceptance TEXT NOT NULL DEFAULT '',verify_command TEXT NOT NULL DEFAULT '',claimed_by TEXT,claimed_at TEXT,lease_until TEXT,result_summary TEXT NOT NULL DEFAULT '',transcript_path TEXT,created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')),updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')));
CREATE TABLE task_events(id INTEGER PRIMARY KEY AUTOINCREMENT,task_id INTEGER NOT NULL,event_type TEXT NOT NULL,actor TEXT NOT NULL,note TEXT NOT NULL DEFAULT '',data_json TEXT NOT NULL DEFAULT '{}',created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')));
CREATE TABLE task_dependencies(task_id INTEGER NOT NULL,blocker_task_id INTEGER NOT NULL,created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')),PRIMARY KEY(task_id,blocker_task_id));
CREATE TABLE task_findings(id INTEGER PRIMARY KEY AUTOINCREMENT,task_id INTEGER NOT NULL,severity TEXT NOT NULL DEFAULT 'medium',status TEXT NOT NULL DEFAULT 'open',note TEXT NOT NULL DEFAULT '',followup_task_id INTEGER,created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')),updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')));
CREATE TABLE cxq_meta(key TEXT PRIMARY KEY,value TEXT NOT NULL);
CREATE INDEX idx_tasks_status_priority ON tasks(status, priority DESC, created_at ASC);
CREATE INDEX idx_tasks_repo_status ON tasks(repo_path, status);
CREATE INDEX idx_tasks_due ON tasks(due_date);
CREATE TRIGGER trg_tasks_updated_at AFTER UPDATE ON tasks FOR EACH ROW BEGIN UPDATE tasks SET updated_at = strftime('%Y-%m-%dT%H:%M:%fZ', 'now') WHERE id = OLD.id; END;
INSERT INTO cxq_meta VALUES('schema_version','4');
INSERT INTO tasks(title,status,priority,repo_path) VALUES('Legacy task','ready',70,'$repo');
INSERT INTO task_events(task_id,event_type,actor,note) VALUES(1,'created','tester','Legacy task');
"
}

test_schema_migration_v4_to_v6() {
  local repo output
  repo="$TEST_DIR/migrate-v4"
  run_git_init "$repo"
  build_v4_db "$repo"

  output=$(cd "$repo" && "$CXQ" migrate)
  assert_contains "$output" "Migrated schema v4 -> v6"
  [ "$(sqlite3 -batch -noheader "$repo/.cxq/tasks.db" "SELECT value FROM cxq_meta WHERE key = 'schema_version';")" = "6" ] ||
    fail "migrate must bump schema_version to 6"
  [ "$(sqlite3 -batch -noheader "$repo/.cxq/tasks.db" "SELECT COUNT(*) FROM pragma_table_info('tasks') WHERE name IN ('trashed_from_status', 'trashed_at');")" = "2" ] ||
    fail "migrate must add the trash columns"
  case "$(sqlite3 -batch -noheader "$repo/.cxq/tasks.db" "SELECT sql FROM sqlite_master WHERE type = 'table' AND name = 'tasks';")" in
    *trashed*) ;;
    *) fail "migrate must add 'trashed' to the status CHECK" ;;
  esac
  [ "$(sqlite3 -batch -noheader "$repo/.cxq/tasks.db" "SELECT COUNT(*) FROM sqlite_master WHERE type = 'trigger' AND name = 'trg_tasks_updated_at';")" = "1" ] ||
    fail "migrate must keep the updated_at trigger"
  [ "$(sqlite3 -batch -noheader "$repo/.cxq/tasks.db" "SELECT title FROM tasks WHERE id = 1;")" = "Legacy task" ] ||
    fail "migrate must preserve existing tasks"
  [ "$(sqlite3 -batch -noheader "$repo/.cxq/tasks.db" "SELECT COUNT(*) FROM task_events WHERE task_id = 1;")" = "1" ] ||
    fail "migrate must preserve events"
  output=$(cd "$repo" && "$CXQ" list)
  assert_contains "$output" "Legacy task"
  # The new CHECK accepts 'trashed', so the migrated queue can trash tasks.
  output=$(cd "$repo" && "$CXQ" delete 1 --force)
  assert_contains "$output" "Trashed task #1 (was ready)"
  output=$(cd "$repo" && "$CXQ" restore 1)
  assert_contains "$output" "Restored task #1 to ready"

  # Idempotent: a second migrate is a no-op report, not an error.
  output=$(cd "$repo" && "$CXQ" migrate)
  assert_contains "$output" "Migrated schema v6 -> v6"

  # Auto-migrate on open: a fresh v4 DB migrates when any command touches it.
  repo="$TEST_DIR/migrate-auto-v4"
  run_git_init "$repo"
  build_v4_db "$repo"
  output=$(cd "$repo" && "$CXQ" list 2>&1)
  assert_contains "$output" "migrated queue schema v4 -> v6"
  assert_contains "$output" "Legacy task"
  [ "$(sqlite3 -batch -noheader "$repo/.cxq/tasks.db" "SELECT value FROM cxq_meta WHERE key = 'schema_version';")" = "6" ] ||
    fail "opening a v4 queue must auto-migrate it to v6"
  pass "schema v4 -> v6 migration preserves data, rebuilds the CHECK, and auto-migrates on open"
}

# Builds a hand-made schema-v5 queue DB (trashed status + trash columns,
# no recurs column, meta = 5).
build_v5_db() {
  local repo=$1
  mkdir -p "$repo/.cxq/prompts"
  printf 'x\n' >"$repo/.cxq/prompts/task.md"
  printf '## Local task queue\n\nUse cxq.\n' >"$repo/AGENTS.md"
  printf -- "-- old stock v5 schema template\nVALUES ('schema_version', '5');\n" >"$repo/.cxq/tasks.schema.sql"
  sqlite3 -batch "$repo/.cxq/tasks.db" "
CREATE TABLE tasks(id INTEGER PRIMARY KEY AUTOINCREMENT,title TEXT NOT NULL,body TEXT NOT NULL DEFAULT '',status TEXT NOT NULL DEFAULT 'inbox' CHECK (status IN ('inbox','ready','claimed','blocked','review','done','wontfix','trashed')),priority INTEGER NOT NULL DEFAULT 50,due_date TEXT,trashed_from_status TEXT,trashed_at TEXT,repo_path TEXT NOT NULL,branch TEXT,allowed_paths_json TEXT NOT NULL DEFAULT '[]',tags_json TEXT NOT NULL DEFAULT '[]',deps_json TEXT NOT NULL DEFAULT '[]',acceptance TEXT NOT NULL DEFAULT '',verify_command TEXT NOT NULL DEFAULT '',claimed_by TEXT,claimed_at TEXT,lease_until TEXT,result_summary TEXT NOT NULL DEFAULT '',transcript_path TEXT,created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')),updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')));
CREATE TABLE task_events(id INTEGER PRIMARY KEY AUTOINCREMENT,task_id INTEGER NOT NULL,event_type TEXT NOT NULL,actor TEXT NOT NULL,note TEXT NOT NULL DEFAULT '',data_json TEXT NOT NULL DEFAULT '{}',created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')));
CREATE TABLE task_dependencies(task_id INTEGER NOT NULL,blocker_task_id INTEGER NOT NULL,created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')),PRIMARY KEY(task_id,blocker_task_id));
CREATE TABLE task_findings(id INTEGER PRIMARY KEY AUTOINCREMENT,task_id INTEGER NOT NULL,severity TEXT NOT NULL DEFAULT 'medium',status TEXT NOT NULL DEFAULT 'open',note TEXT NOT NULL DEFAULT '',followup_task_id INTEGER,created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')),updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')));
CREATE TABLE cxq_meta(key TEXT PRIMARY KEY,value TEXT NOT NULL);
CREATE INDEX idx_tasks_status_priority ON tasks(status, priority DESC, created_at ASC);
CREATE INDEX idx_tasks_repo_status ON tasks(repo_path, status);
CREATE INDEX idx_tasks_due ON tasks(due_date);
CREATE TRIGGER trg_tasks_updated_at AFTER UPDATE ON tasks FOR EACH ROW BEGIN UPDATE tasks SET updated_at = strftime('%Y-%m-%dT%H:%M:%fZ', 'now') WHERE id = OLD.id; END;
INSERT INTO cxq_meta VALUES('schema_version','5');
INSERT INTO tasks(title,status,priority,repo_path) VALUES('Legacy task','ready',70,'$repo');
INSERT INTO task_events(task_id,event_type,actor,note) VALUES(1,'created','tester','Legacy task');
"
}

test_schema_migration_v5_to_v6() {
  local repo output
  repo="$TEST_DIR/migrate-v5"
  run_git_init "$repo"
  build_v5_db "$repo"

  output=$(cd "$repo" && "$CXQ" migrate)
  assert_contains "$output" "Migrated schema v5 -> v6"
  [ "$(sqlite3 -batch -noheader "$repo/.cxq/tasks.db" "SELECT value FROM cxq_meta WHERE key = 'schema_version';")" = "6" ] ||
    fail "migrate must bump schema_version to 6"
  [ "$(sqlite3 -batch -noheader "$repo/.cxq/tasks.db" "SELECT COUNT(*) FROM pragma_table_info('tasks') WHERE name = 'recurs';")" = "1" ] ||
    fail "migrate must add the recurs column"
  [ "$(sqlite3 -batch -noheader "$repo/.cxq/tasks.db" "SELECT title FROM tasks WHERE id = 1;")" = "Legacy task" ] ||
    fail "migrate must preserve existing tasks"
  [ "$(sqlite3 -batch -noheader "$repo/.cxq/tasks.db" "SELECT COUNT(*) FROM task_events WHERE task_id = 1;")" = "1" ] ||
    fail "migrate must preserve events"
  # A migrated queue can use recurrence right away.
  output=$(cd "$repo" && "$CXQ" add "Recurring legacy" --due 2026-03-10 --recurs daily)
  assert_contains "$output" "Created task #2"

  # Idempotent: a second migrate is a no-op report, not an error.
  output=$(cd "$repo" && "$CXQ" migrate)
  assert_contains "$output" "Migrated schema v6 -> v6"
  pass "schema v5 -> v6 migration adds recurs and preserves data"
}

test_due_lists_overdue_today_tomorrow() {
  local repo output status yesterday today tomorrow after done_id trash_id
  repo="$TEST_DIR/due"
  run_git_init "$repo"
  (cd "$repo" && "$CXQ" install >/dev/null)
  yesterday=$(sqlite3 -batch -noheader :memory: "SELECT date('now', '-1 day');")
  today=$(sqlite3 -batch -noheader :memory: "SELECT date('now');")
  tomorrow=$(sqlite3 -batch -noheader :memory: "SELECT date('now', '+1 day');")
  after=$(sqlite3 -batch -noheader :memory: "SELECT date('now', '+2 days');")

  (cd "$repo" && "$CXQ" add "Overdue task" --due "$yesterday" >/dev/null)
  (cd "$repo" && "$CXQ" add "Today task" --due "$today" >/dev/null)
  (cd "$repo" && "$CXQ" add "Tomorrow task" --due "$tomorrow" >/dev/null)
  (cd "$repo" && "$CXQ" add "Day after task" --due "$after" >/dev/null)
  (cd "$repo" && "$CXQ" add "No due task" >/dev/null)
  done_id=$(cd "$repo" && "$CXQ" add "Done overdue task" --due "$yesterday" | sed 's/.*#//')
  (cd "$repo" && "$CXQ" done "$done_id" --force >/dev/null)
  trash_id=$(cd "$repo" && "$CXQ" add "Trashed overdue task" --due "$yesterday" | sed 's/.*#//')
  (cd "$repo" && "$CXQ" delete "$trash_id" --force >/dev/null)
  (cd "$repo" && "$CXQ" add "Wontfix overdue task" --due "$yesterday" --status wontfix >/dev/null)

  output=$(cd "$repo" && "$CXQ" due)
  assert_contains "$output" "Overdue:"
  assert_contains "$output" "Due today:"
  assert_contains "$output" "Due tomorrow:"
  assert_contains "$output" "Overdue task"
  assert_contains "$output" "Today task"
  assert_contains "$output" "Tomorrow task"
  assert_not_contains "$output" "Day after task"
  assert_not_contains "$output" "No due task"
  assert_not_contains "$output" "Done overdue task"
  assert_not_contains "$output" "Trashed overdue task"
  assert_not_contains "$output" "Wontfix overdue task"
  # Section placement: each task under its own heading, not another's.
  printf '%s' "$output" | sed -n '/^Overdue:/,/^Due today:/p' | grep -q "Overdue task" ||
    fail "overdue task must sit under the Overdue heading"
  printf '%s' "$output" | sed -n '/^Overdue:/,/^Due today:/p' | grep -q "Today task" &&
    fail "today task must not sit under the Overdue heading"
  printf '%s' "$output" | sed -n '/^Due today:/,/^Due tomorrow:/p' | grep -q "Today task" ||
    fail "today task must sit under the Due today heading"
  printf '%s' "$output" | sed -n '/^Due tomorrow:/,$p' | grep -q "Tomorrow task" ||
    fail "tomorrow task must sit under the Due tomorrow heading"

  # `cxq stats` counts the same overdue set: the trashed overdue task
  # above must not inflate it (only "Overdue task" is overdue).
  output=$(cd "$repo" && "$CXQ" stats)
  assert_contains "$output" "overdue: 1"

  # The formats agree with the table output.
  output=$(cd "$repo" && "$CXQ" due --format json)
  assert_contains "$output" '"due_group":"overdue"'
  assert_contains "$output" '"due_group":"today"'
  assert_contains "$output" '"due_group":"tomorrow"'
  assert_not_contains "$output" "Day after task"
  output=$(cd "$repo" && "$CXQ" due --format md)
  assert_contains "$output" "| Overdue task |"
  assert_contains "$output" "| Today task |"
  assert_contains "$output" "| Tomorrow task |"
  assert_not_contains "$output" "Day after task"
  set +e
  output=$(cd "$repo" && "$CXQ" due --format bogus 2>&1); status=$?
  set -e
  [ "$status" -ne 0 ] || fail "an unknown due format must fail"
  assert_contains "$output" "invalid format: bogus"
  pass "due lists overdue, today, and tomorrow with exact boundaries"
}

test_recurrence_daily_weekly_monthly() {
  local repo output status daily weekly monthly monthly_mid next_id
  repo="$TEST_DIR/recurrence"
  run_git_init "$repo"
  (cd "$repo" && "$CXQ" install >/dev/null)

  daily=$(cd "$repo" && "$CXQ" add "Daily chore" --due 2026-03-10 --recurs daily --priority 70 --tag ops --files "src/a" --body "Do it daily" --acceptance "done daily" | sed 's/.*#//')
  weekly=$(cd "$repo" && "$CXQ" add "Weekly chore" --due 2026-03-10 --recurs weekly | sed 's/.*#//')
  monthly=$(cd "$repo" && "$CXQ" add "Monthly chore" --due 2026-01-31 --recurs monthly | sed 's/.*#//')
  monthly_mid=$(cd "$repo" && "$CXQ" add "Mid-month chore" --due 2026-03-15 --recurs monthly | sed 's/.*#//')

  # The claim on the completed task must not leak into the next occurrence.
  (cd "$repo" && "$CXQ" claim "$daily" --agent tester --lease 1h >/dev/null)
  output=$(cd "$repo" && "$CXQ" done "$daily" --force)
  assert_contains "$output" "Marked task #$daily done"
  assert_contains "$output" "Created next occurrence #"
  next_id=$(printf '%s' "$output" | sed -n 's/.*Created next occurrence #\([0-9]*\).*/\1/p')
  [ -n "$next_id" ] || fail "done must report the next occurrence id"
  [ "$(sqlite3 -batch -noheader "$repo/.cxq/tasks.db" "SELECT due_date FROM tasks WHERE id = $next_id;")" = "2026-03-11" ] ||
    fail "daily recurrence must advance one day"
  [ "$(sqlite3 -batch -noheader "$repo/.cxq/tasks.db" "SELECT status FROM tasks WHERE id = $next_id;")" = "ready" ] ||
    fail "next occurrence must start ready"
  [ "$(sqlite3 -batch -noheader "$repo/.cxq/tasks.db" "SELECT COALESCE(claimed_by, '') FROM tasks WHERE id = $next_id;")" = "" ] ||
    fail "next occurrence must not inherit the claim"
  [ "$(sqlite3 -batch -noheader "$repo/.cxq/tasks.db" "SELECT title FROM tasks WHERE id = $next_id;")" = "Daily chore" ] ||
    fail "next occurrence must inherit the title"
  [ "$(sqlite3 -batch -noheader "$repo/.cxq/tasks.db" "SELECT body FROM tasks WHERE id = $next_id;")" = "Do it daily" ] ||
    fail "next occurrence must inherit the body"
  [ "$(sqlite3 -batch -noheader "$repo/.cxq/tasks.db" "SELECT priority FROM tasks WHERE id = $next_id;")" = "70" ] ||
    fail "next occurrence must inherit the priority"
  [ "$(sqlite3 -batch -noheader "$repo/.cxq/tasks.db" "SELECT tags_json FROM tasks WHERE id = $next_id;")" = '["ops"]' ] ||
    fail "next occurrence must inherit the tags"
  [ "$(sqlite3 -batch -noheader "$repo/.cxq/tasks.db" "SELECT allowed_paths_json FROM tasks WHERE id = $next_id;")" = '["src/a"]' ] ||
    fail "next occurrence must inherit the allowed paths"
  [ "$(sqlite3 -batch -noheader "$repo/.cxq/tasks.db" "SELECT acceptance FROM tasks WHERE id = $next_id;")" = "done daily" ] ||
    fail "next occurrence must inherit the acceptance criteria"
  [ "$(sqlite3 -batch -noheader "$repo/.cxq/tasks.db" "SELECT recurs FROM tasks WHERE id = $next_id;")" = "daily" ] ||
    fail "next occurrence must carry the recurs value"
  [ "$(sqlite3 -batch -noheader "$repo/.cxq/tasks.db" "SELECT COUNT(*) FROM task_events WHERE task_id = $daily AND event_type = 'recurrence';")" = "1" ] ||
    fail "completing a recurring task must log one recurrence event"
  [ "$(sqlite3 -batch -noheader "$repo/.cxq/tasks.db" "SELECT note FROM task_events WHERE task_id = $daily AND event_type = 'recurrence';")" = "next occurrence #$next_id (due 2026-03-11, recurs daily)" ] ||
    fail "recurrence event must name the next occurrence and its due date"

  # A second done on the same task must not spawn a duplicate.
  output=$(cd "$repo" && "$CXQ" done "$daily" --force)
  case "$output" in
    *"next occurrence"*) fail "a second done must not create another occurrence" ;;
  esac
  [ "$(sqlite3 -batch -noheader "$repo/.cxq/tasks.db" "SELECT COUNT(*) FROM tasks WHERE title = 'Daily chore';")" = "2" ] ||
    fail "exactly one next occurrence per done"

  # Weekly advances 7 days; monthly clamps Jan 31 -> Feb 28 and keeps
  # mid-month days unchanged.
  output=$(cd "$repo" && "$CXQ" done "$weekly" --force)
  next_id=$(printf '%s' "$output" | sed -n 's/.*Created next occurrence #\([0-9]*\).*/\1/p')
  [ "$(sqlite3 -batch -noheader "$repo/.cxq/tasks.db" "SELECT due_date FROM tasks WHERE id = $next_id;")" = "2026-03-17" ] ||
    fail "weekly recurrence must advance seven days"
  output=$(cd "$repo" && "$CXQ" done "$monthly" --force)
  next_id=$(printf '%s' "$output" | sed -n 's/.*Created next occurrence #\([0-9]*\).*/\1/p')
  [ "$(sqlite3 -batch -noheader "$repo/.cxq/tasks.db" "SELECT due_date FROM tasks WHERE id = $next_id;")" = "2026-02-28" ] ||
    fail "monthly recurrence must clamp Jan 31 to Feb 28"
  output=$(cd "$repo" && "$CXQ" done "$monthly_mid" --force)
  next_id=$(printf '%s' "$output" | sed -n 's/.*Created next occurrence #\([0-9]*\).*/\1/p')
  [ "$(sqlite3 -batch -noheader "$repo/.cxq/tasks.db" "SELECT due_date FROM tasks WHERE id = $next_id;")" = "2026-04-15" ] ||
    fail "monthly recurrence must keep a mid-month day"

  # followup --close is a done path too: it closes the parent and spawns.
  output=$(cd "$repo" && "$CXQ" followup "$next_id" "Leftover" --close)
  assert_contains "$output" "Closed task #$next_id"
  assert_contains "$output" "Created next occurrence #"
  pass "recurrence creates the next occurrence on done with exact date math"
}

test_recurrence_validation_and_clear() {
  local repo id output status
  repo="$TEST_DIR/recurrence-validation"
  run_git_init "$repo"
  (cd "$repo" && "$CXQ" install >/dev/null)

  set +e
  output=$(cd "$repo" && "$CXQ" add "Bad interval" --due 2026-12-01 --recurs yearly 2>&1); status=$?
  set -e
  [ "$status" -ne 0 ] || fail "an invalid recurs value must fail on add"
  assert_contains "$output" "invalid recurrence: yearly"

  set +e
  output=$(cd "$repo" && "$CXQ" add "No due recur" --recurs daily 2>&1); status=$?
  set -e
  [ "$status" -ne 0 ] || fail "recurring without a due date must fail on add"
  assert_contains "$output" "recurring tasks require a due date"

  id=$(cd "$repo" && "$CXQ" add "Plain task" | sed 's/.*#//')

  set +e
  output=$(cd "$repo" && "$CXQ" edit "$id" --recurs hourly 2>&1); status=$?
  set -e
  [ "$status" -ne 0 ] || fail "an invalid recurs value must fail on edit"
  assert_contains "$output" "invalid recurrence: hourly"

  set +e
  output=$(cd "$repo" && "$CXQ" edit "$id" --recurs daily 2>&1); status=$?
  set -e
  [ "$status" -ne 0 ] || fail "setting recurs on a dateless task must fail on edit"
  assert_contains "$output" "recurring tasks require a due date"

  output=$(cd "$repo" && "$CXQ" edit "$id" --due 2026-12-01 --recurs weekly)
  assert_contains "$output" "recurs: (empty) -> weekly"
  output=$(cd "$repo" && "$CXQ" show "$id")
  printf '%s' "$output" | grep -A1 '^## Recurrence$' | grep -q '^weekly$' ||
    fail "show must render the recurrence value"

  set +e
  output=$(cd "$repo" && "$CXQ" edit "$id" --due-clear 2>&1); status=$?
  set -e
  [ "$status" -ne 0 ] || fail "clearing the due date of a recurring task must fail"
  assert_contains "$output" "recurring tasks require a due date"

  # --recurs none clears it, and undo puts it back.
  output=$(cd "$repo" && "$CXQ" edit "$id" --recurs none)
  assert_contains "$output" "recurs: weekly -> (empty)"
  [ "$(sqlite3 -batch -noheader "$repo/.cxq/tasks.db" "SELECT recurs FROM tasks WHERE id = $id;")" = "" ] ||
    fail "recurs none must clear the column"
  output=$(cd "$repo" && "$CXQ" edit "$id" --recurs daily)
  assert_contains "$output" "recurs: (empty) -> daily"
  output=$(cd "$repo" && "$CXQ" undo "$id")
  assert_contains "$output" "recurs"
  [ "$(sqlite3 -batch -noheader "$repo/.cxq/tasks.db" "SELECT recurs FROM tasks WHERE id = $id;")" = "" ] ||
    fail "undo must revert the recurs change"
  pass "recurrence validation, clearing, and undo work"
}

test_recurrence_via_edit_status_done() {
  local repo id output next_id
  repo="$TEST_DIR/recurrence-edit-done"
  run_git_init "$repo"
  (cd "$repo" && "$CXQ" install >/dev/null)

  id=$(cd "$repo" && "$CXQ" add "Edit-done chore" --due 2026-03-10 --recurs daily | sed 's/.*#//')
  (cd "$repo" && "$CXQ" claim "$id" --agent tester --lease 1h >/dev/null)
  (cd "$repo" && "$CXQ" review "$id" --summary "did it" >/dev/null)
  output=$(cd "$repo" && "$CXQ" edit "$id" --status done --reason "accepted")
  assert_contains "$output" "status: review -> done"
  assert_contains "$output" "Created next occurrence #"
  next_id=$(printf '%s' "$output" | sed -n 's/.*Created next occurrence #\([0-9]*\).*/\1/p')
  [ "$(sqlite3 -batch -noheader "$repo/.cxq/tasks.db" "SELECT due_date FROM tasks WHERE id = $next_id;")" = "2026-03-11" ] ||
    fail "edit --status done must spawn the next occurrence one day later"
  pass "recurrence fires on edit --status done"
}

test_legacy_codex_dir_migrates_to_cxq() {
  local repo output
  repo="$TEST_DIR/migrate-codex-dir"
  run_git_init "$repo"
  (cd "$repo" && "$CXQ" install >/dev/null)
  (cd "$repo" && "$CXQ" add "Legacy dir task" --priority 70 >/dev/null)
  # Simulate a pre-0.4.0 queue: move the whole directory back to .codex/.
  mv "$repo/.cxq" "$repo/.codex"
  printf '.codex/tasks.db\n.codex/tasks.db-*\n' >"$repo/.gitignore"

  output=$(cd "$repo" && "$CXQ" list 2>&1)
  assert_contains "$output" "Legacy dir task"
  assert_contains "$output" "migrated queue directory .codex -> .cxq"
  [ -d "$repo/.cxq" ] || fail ".cxq must exist after migration"
  [ ! -e "$repo/.codex" ] || fail ".codex must be gone after migration"
  [ "$(sqlite3 -batch -noheader "$repo/.cxq/tasks.db" "SELECT title FROM tasks WHERE id = 1;")" = "Legacy dir task" ] ||
    fail "migration must preserve existing tasks"
  grep -qxF ".cxq/tasks.db" "$repo/.gitignore" ||
    fail ".gitignore must point at .cxq after migration"
  # Second open is a no-op: no second migration notice.
  output=$(cd "$repo" && "$CXQ" list 2>&1)
  case "$output" in
    *migrated*) fail "migration must be idempotent" ;;
  esac

  # Half-moved queue: template files already in .cxq/, database still in
  # .codex/. The migration finishes the move instead of refusing.
  repo="$TEST_DIR/migrate-codex-half"
  run_git_init "$repo"
  (cd "$repo" && "$CXQ" install >/dev/null)
  (cd "$repo" && "$CXQ" add "Half-moved task" --priority 70 >/dev/null)
  mkdir "$repo/.codex"
  mv "$repo/.cxq/tasks.db" "$repo/.codex/tasks.db"
  output=$(cd "$repo" && "$CXQ" list 2>&1)
  assert_contains "$output" "Half-moved task"
  assert_contains "$output" "migrated queue database .codex -> .cxq"
  [ ! -e "$repo/.codex" ] || fail ".codex must be gone after finishing a half-moved queue"
  pass "legacy .codex directory migrates to .cxq, preserving tasks"
}

free_port() {
  python3 -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1]); s.close()'
}

test_server_smoke_and_remote_mode() {
  command -v python3 >/dev/null 2>&1 || fail "python3 is required for the server test"
  command -v curl >/dev/null 2>&1 || fail "curl is required for the remote test"
  local port db="$TEST_DIR/server.db" pid output status
  port=$(free_port)
  rm -f "$db" "$db-wal" "$db-shm"

  CXQ_TOKEN="test-token-xyz" python3 "$ROOT/server/cxq_server.py" --port "$port" --db "$db" >"$TEST_DIR/server.log" 2>&1 &
  pid=$!
  local i=0
  while [ "$i" -lt 20 ]; do
    if curl -s --max-time 2 "http://127.0.0.1:$port/api/v1/health" >/dev/null 2>&1; then break; fi
    sleep 0.5
    i=$((i + 1))
  done
  output=$(curl -s "http://127.0.0.1:$port/api/v1/health")
  assert_contains "$output" '"schema_version": 4'
  assert_contains "$output" '"version": "0.4.0-dev"'

  # Unauthenticated API access is rejected.
  set +e
  output=$(curl -s -w " %{http_code}" "http://127.0.0.1:$port/api/v1/tasks"); status=$?
  set -e
  assert_contains "$output" "401"

  # Create / patch / claim over HTTP.
  output=$(curl -s -H "Authorization: Bearer test-token-xyz" -H "Content-Type: application/json" \
    -d '{"title":"Server task","priority":80,"tags":["alpha"],"due_date":"2000-01-01"}' \
    "http://127.0.0.1:$port/api/v1/tasks")
  assert_contains "$output" '"title": "Server task"'
  assert_contains "$output" '"overdue": true'

  output=$(curl -s -H "Authorization: Bearer test-token-xyz" -H "Content-Type: application/json" \
    -X PATCH -d '{"title":"Server task edited","priority":90}' \
    "http://127.0.0.1:$port/api/v1/tasks/1")
  assert_contains "$output" "title: Server task -> Server task edited"

  set +e
  output=$(curl -s -H "Authorization: Bearer test-token-xyz" -H "Content-Type: application/json" \
    -X PATCH -d '{"due_date":"2026-02-30"}' "http://127.0.0.1:$port/api/v1/tasks/1"); status=$?
  set -e
  assert_contains "$output" "due date must be a valid YYYY-MM-DD date"

  output=$(curl -s -H "Authorization: Bearer test-token-xyz" -H "Content-Type: application/json" \
    -X POST -d '{"agent":"tester","lease":"2h"}' "http://127.0.0.1:$port/api/v1/tasks/1/claim")
  assert_contains "$output" '"status": "claimed"'

  # Dashboard HTML is served and contains the kanban shell.
  output=$(curl -s "http://127.0.0.1:$port/")
  assert_contains "$output" "cxq board"
  assert_contains "$output" "polling every 5s"
  assert_contains "$output" "Dark / light"

  # Remote-mode CLI round-trip against the same server.
  output=$(cd "$TEST_DIR" && CXQ_REMOTE_URL="http://127.0.0.1:$port" CXQ_REMOTE_TOKEN="test-token-xyz" "$CXQ" remote status)
  assert_contains "$output" "reachable: yes"
  assert_contains "$output" "schema_version"

  output=$(cd "$TEST_DIR" && CXQ_REMOTE_URL="http://127.0.0.1:$port" CXQ_REMOTE_TOKEN="test-token-xyz" "$CXQ" add "Remote CLI task" --priority 60 --tag remote)
  assert_contains "$output" "Created task #2"

  output=$(cd "$TEST_DIR" && CXQ_REMOTE_URL="http://127.0.0.1:$port" CXQ_REMOTE_TOKEN="test-token-xyz" "$CXQ" edit 2 --title "Remote CLI task edited" --tags-add "done")
  assert_contains "$output" "title: Remote CLI task -> Remote CLI task edited"
  assert_contains "$output" "tags: remote -> remote,done"

  output=$(cd "$TEST_DIR" && CXQ_REMOTE_URL="http://127.0.0.1:$port" CXQ_REMOTE_TOKEN="test-token-xyz" "$CXQ" list)
  assert_contains "$output" "Remote CLI task edited"
  assert_contains "$output" "Server task edited"

  output=$(cd "$TEST_DIR" && CXQ_REMOTE_URL="http://127.0.0.1:$port" CXQ_REMOTE_TOKEN="test-token-xyz" "$CXQ" board)
  assert_contains "$output" "## claimed (1)"
  assert_contains "$output" "## ready (1)"

  # Remote mode without a token fails clearly instead of hanging.
  set +e
  output=$(cd "$TEST_DIR" && CXQ_REMOTE_URL="http://127.0.0.1:$port" "$CXQ" list 2>&1); status=$?
  set -e
  [ "$status" -ne 0 ] || fail "remote mode without a token must fail"
  assert_contains "$output" "CXQ_REMOTE_TOKEN is required"

  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  pass "server smoke test and remote-mode CLI round-trip work"
}

test_server_due_and_recurrence() {
  command -v python3 >/dev/null 2>&1 || fail "python3 is required for the server test"
  command -v curl >/dev/null 2>&1 || fail "curl is required for the remote test"
  local port db="$TEST_DIR/due-server.db" pid output status yesterday today tomorrow
  port=$(free_port)
  rm -f "$db" "$db-wal" "$db-shm"
  yesterday=$(sqlite3 -batch -noheader :memory: "SELECT date('now', '-1 day');")
  today=$(sqlite3 -batch -noheader :memory: "SELECT date('now');")
  tomorrow=$(sqlite3 -batch -noheader :memory: "SELECT date('now', '+1 day');")

  # The server must add the recurs column to a queue created before it
  # existed: build the DB with the pre-recurrence task columns only.
  sqlite3 -batch "$db" "
CREATE TABLE tasks(id INTEGER PRIMARY KEY AUTOINCREMENT,title TEXT NOT NULL,body TEXT NOT NULL DEFAULT '',status TEXT NOT NULL DEFAULT 'inbox',priority INTEGER NOT NULL DEFAULT 50,due_date TEXT,repo_path TEXT NOT NULL,branch TEXT,allowed_paths_json TEXT NOT NULL DEFAULT '[]',tags_json TEXT NOT NULL DEFAULT '[]',deps_json TEXT NOT NULL DEFAULT '[]',acceptance TEXT NOT NULL DEFAULT '',verify_command TEXT NOT NULL DEFAULT '',claimed_by TEXT,claimed_at TEXT,lease_until TEXT,result_summary TEXT NOT NULL DEFAULT '',transcript_path TEXT,created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')),updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')));
"

  CXQ_TOKEN="test-token-due" python3 "$ROOT/server/cxq_server.py" --port "$port" --db "$db" >"$TEST_DIR/due-server.log" 2>&1 &
  pid=$!
  local i=0
  while [ "$i" -lt 20 ]; do
    if curl -s --max-time 2 "http://127.0.0.1:$port/api/v1/health" >/dev/null 2>&1; then break; fi
    sleep 0.5
    i=$((i + 1))
  done

  # Recurring task over HTTP, plus one due today and one due tomorrow.
  output=$(curl -s -H "Authorization: Bearer test-token-due" -H "Content-Type: application/json" \
    -d "{\"title\":\"Server recurring\",\"due_date\":\"$yesterday\",\"recurs\":\"daily\"}" \
    "http://127.0.0.1:$port/api/v1/tasks")
  assert_contains "$output" '"recurs": "daily"'
  output=$(curl -s -H "Authorization: Bearer test-token-due" -H "Content-Type: application/json" \
    -d "{\"title\":\"Server today\",\"due_date\":\"$today\"}" \
    "http://127.0.0.1:$port/api/v1/tasks")
  assert_contains "$output" '"title": "Server today"'
  output=$(curl -s -H "Authorization: Bearer test-token-due" -H "Content-Type: application/json" \
    -d "{\"title\":\"Server tomorrow\",\"due_date\":\"$tomorrow\"}" \
    "http://127.0.0.1:$port/api/v1/tasks")
  assert_contains "$output" '"title": "Server tomorrow"'

  output=$(curl -s -H "Authorization: Bearer test-token-due" "http://127.0.0.1:$port/api/v1/due")
  printf '%s' "$output" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert [t["title"] for t in d["overdue"]] == ["Server recurring"], d; assert [t["title"] for t in d["today"]] == ["Server today"], d; assert [t["title"] for t in d["tomorrow"]] == ["Server tomorrow"], d' ||
    fail "due endpoint must group overdue/today/tomorrow"

  # Validation errors over HTTP.
  output=$(curl -s -H "Authorization: Bearer test-token-due" -H "Content-Type: application/json" \
    -d '{"title":"Bad interval","due_date":"2026-12-01","recurs":"hourly"}' \
    "http://127.0.0.1:$port/api/v1/tasks")
  assert_contains "$output" "invalid recurrence: hourly"
  output=$(curl -s -H "Authorization: Bearer test-token-due" -H "Content-Type: application/json" \
    -d '{"title":"No due recur","recurs":"daily"}' \
    "http://127.0.0.1:$port/api/v1/tasks")
  assert_contains "$output" "recurring tasks require a due date"

  # Marking the recurring task done spawns the next occurrence (due today).
  output=$(curl -s -H "Authorization: Bearer test-token-due" -H "Content-Type: application/json" \
    -X POST -d '{"summary":"done","force":true}' \
    "http://127.0.0.1:$port/api/v1/tasks/1/done")
  assert_contains "$output" '"next_occurrence_id": 4'
  assert_contains "$output" "\"next_occurrence_due\": \"$today\""
  output=$(curl -s -H "Authorization: Bearer test-token-due" "http://127.0.0.1:$port/api/v1/tasks/4")
  assert_contains "$output" '"status": "ready"'
  assert_contains "$output" '"recurs": "daily"'

  # Dashboard serves the overdue badge element and the recurs field.
  output=$(curl -s "http://127.0.0.1:$port/")
  assert_contains "$output" 'id="overdue-badge"'
  assert_contains "$output" 'id="m-recurs"'
  assert_contains "$output" 'Overdue: " + s.overdue'

  # Remote-mode CLI round-trip: due groups, add --recurs, done spawns.
  # (The next occurrence of "Server recurring" still carries that title
  # and is due today, so it shows under Due today.)
  output=$(cd "$TEST_DIR" && CXQ_REMOTE_URL="http://127.0.0.1:$port" CXQ_REMOTE_TOKEN="test-token-due" "$CXQ" due)
  assert_contains "$output" "Overdue:"
  assert_contains "$output" "Due today:"
  assert_contains "$output" "Server recurring"
  output=$(cd "$TEST_DIR" && CXQ_REMOTE_URL="http://127.0.0.1:$port" CXQ_REMOTE_TOKEN="test-token-due" "$CXQ" add "Remote recurring" --due "$yesterday" --recurs weekly)
  assert_contains "$output" "Created task #5"
  output=$(cd "$TEST_DIR" && CXQ_REMOTE_URL="http://127.0.0.1:$port" CXQ_REMOTE_TOKEN="test-token-due" "$CXQ" done 5 --force)
  assert_contains "$output" "Marked task #5 done"
  assert_contains "$output" "Created next occurrence #6"

  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  pass "server due endpoint, recurrence, badge, and remote due work"
}

test_server_per_agent_tokens() {
  command -v python3 >/dev/null 2>&1 || fail "python3 is required for the server test"
  command -v curl >/dev/null 2>&1 || fail "curl is required for the remote test"
  local port db="$TEST_DIR/tokens.db" pid output status token_alpha token_alpha2
  port=$(free_port)
  rm -f "$db" "$db-wal" "$db-shm"

  CXQ_TOKEN="legacy-token-abc" python3 "$ROOT/server/cxq_server.py" --port "$port" --db "$db" >"$TEST_DIR/tokens-server.log" 2>&1 &
  pid=$!
  local i=0
  while [ "$i" -lt 20 ]; do
    if curl -s --max-time 2 "http://127.0.0.1:$port/api/v1/health" >/dev/null 2>&1; then break; fi
    sleep 0.5
    i=$((i + 1))
  done

  # Unknown and missing tokens are rejected with 401.
  output=$(curl -s -w " %{http_code}" -H "Authorization: Bearer nope-not-a-token" "http://127.0.0.1:$port/api/v1/tasks")
  assert_contains "$output" "401"
  output=$(curl -s -w " %{http_code}" "http://127.0.0.1:$port/api/v1/tasks")
  assert_contains "$output" "401"

  # Token management runs on the server host against the server DB.
  output=$("$CXQ" tokens list --db "$db")
  assert_contains "$output" "No per-agent tokens yet"

  output=$("$CXQ" tokens add alpha --db "$db")
  assert_contains "$output" "Token for agent alpha"
  token_alpha=$(printf '%s' "$output" | tail -n 1)
  [ -n "$token_alpha" ] || fail "tokens add must print the new token on its own last line"

  # Duplicate add, bad agent name, and unknown-agent revoke/rotate fail.
  set +e
  output=$("$CXQ" tokens add alpha --db "$db" 2>&1); status=$?
  set -e
  [ "$status" -ne 0 ] || fail "duplicate tokens add must fail"
  assert_contains "$output" "already has a token"

  set +e
  output=$("$CXQ" tokens add "bad name!" --db "$db" 2>&1); status=$?
  set -e
  [ "$status" -ne 0 ] || fail "tokens add with an invalid agent name must fail"
  assert_contains "$output" "agent name must be"

  set +e
  output=$("$CXQ" tokens revoke ghost --db "$db" 2>&1); status=$?
  set -e
  [ "$status" -ne 0 ] || fail "revoking an unknown agent must fail"
  assert_contains "$output" "no token for agent 'ghost'"

  set +e
  output=$("$CXQ" tokens rotate ghost --db "$db" 2>&1); status=$?
  set -e
  [ "$status" -ne 0 ] || fail "rotating an unknown agent must fail"
  assert_contains "$output" "no token for agent 'ghost'"

  output=$("$CXQ" tokens list --db "$db")
  assert_contains "$output" "alpha"
  assert_contains "$output" "active"
  assert_contains "$output" "never"

  # A per-agent token authenticates, and its events record the agent.
  output=$(curl -s -H "Authorization: Bearer $token_alpha" -H "Content-Type: application/json" \
    -d '{"title":"Alpha task"}' "http://127.0.0.1:$port/api/v1/tasks")
  assert_contains "$output" '"title": "Alpha task"'
  assert_contains "$output" '"actor": "alpha"'

  output=$(curl -s -H "Authorization: Bearer $token_alpha" -H "Content-Type: application/json" \
    -X POST -d '{"note":"hello from alpha"}' "http://127.0.0.1:$port/api/v1/tasks/1/note")
  assert_contains "$output" '"noted": 1'
  output=$(curl -s -H "Authorization: Bearer $token_alpha" "http://127.0.0.1:$port/api/v1/activity?limit=5")
  assert_contains "$output" '"actor": "alpha"'

  # Remote-mode CLI works with a per-agent token as CXQ_REMOTE_TOKEN.
  output=$(cd "$TEST_DIR" && CXQ_REMOTE_URL="http://127.0.0.1:$port" CXQ_REMOTE_TOKEN="$token_alpha" "$CXQ" remote status)
  assert_contains "$output" "reachable: yes"

  # last-used is recorded after the token is used.
  output=$("$CXQ" tokens list --db "$db")
  assert_not_contains "$output" "never"

  # The legacy CXQ_TOKEN still works and keeps the old actor behaviour.
  output=$(curl -s -H "Authorization: Bearer legacy-token-abc" -H "Content-Type: application/json" \
    -d '{"title":"Legacy task"}' "http://127.0.0.1:$port/api/v1/tasks")
  assert_contains "$output" '"title": "Legacy task"'
  assert_contains "$output" '"actor": "remote"'

  # Revoke: the token is rejected with 401, and re-revoking fails.
  output=$("$CXQ" tokens revoke alpha --db "$db")
  assert_contains "$output" "Revoked token for agent alpha"
  output=$(curl -s -w " %{http_code}" -H "Authorization: Bearer $token_alpha" "http://127.0.0.1:$port/api/v1/tasks")
  assert_contains "$output" "401"
  output=$("$CXQ" tokens list --db "$db")
  assert_contains "$output" "revoked"

  set +e
  output=$("$CXQ" tokens revoke alpha --db "$db" 2>&1); status=$?
  set -e
  [ "$status" -ne 0 ] || fail "revoking an already-revoked token must fail"
  assert_contains "$output" "already revoked"

  # Rotate: the old token stays rejected, the new one works.
  output=$("$CXQ" tokens rotate alpha --db "$db")
  assert_contains "$output" "New token for agent alpha"
  token_alpha2=$(printf '%s' "$output" | tail -n 1)
  [ -n "$token_alpha2" ] || fail "tokens rotate must print the new token on its own last line"
  [ "$token_alpha2" != "$token_alpha" ] || fail "tokens rotate must issue a different token"
  output=$(curl -s -w " %{http_code}" -H "Authorization: Bearer $token_alpha" "http://127.0.0.1:$port/api/v1/tasks")
  assert_contains "$output" "401"
  output=$(curl -s -H "Authorization: Bearer $token_alpha2" -H "Content-Type: application/json" \
    -d '{"title":"Alpha task two"}' "http://127.0.0.1:$port/api/v1/tasks")
  assert_contains "$output" '"title": "Alpha task two"'
  assert_contains "$output" '"actor": "alpha"'
  output=$("$CXQ" tokens list --db "$db")
  assert_contains "$output" "active"

  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  pass "per-agent tokens authenticate, record the actor, and revoke/rotate independently"
}

test_mcp_server_smoke() {
  command -v python3 >/dev/null 2>&1 || fail "python3 is required for the MCP test"
  local repo output status driver
  repo="$TEST_DIR/mcp-repo"
  run_git_init "$repo"
  output=$(cd "$repo" && "$CXQ" install)
  assert_contains "$output" "cxq installed for project"
  output=$(cd "$repo" && "$CXQ" add "MCP smoke task" --priority 70)
  assert_contains "$output" "Created task #1"

  # Drive the server over stdio: initialize, notification, tools/list,
  # one tools/call per tool, an unknown method, and a malformed line.
  # The driver asserts every response and the clean EOF exit.
  driver="$TEST_DIR/mcp_driver.py"
  cat >"$driver" <<'PYEOF'
import json
import subprocess
import sys

server_path, repo, expected_version = sys.argv[1], sys.argv[2], sys.argv[3]

requests = [
    {"jsonrpc": "2.0", "id": 1, "method": "initialize",
     "params": {"protocolVersion": "2024-11-05", "capabilities": {},
                "clientInfo": {"name": "cxq-test", "version": "0"}}},
    {"jsonrpc": "2.0", "method": "notifications/initialized"},
    {"jsonrpc": "2.0", "id": 2, "method": "tools/list"},
    {"jsonrpc": "2.0", "id": 3, "method": "tools/call",
     "params": {"name": "list_tasks", "arguments": {}}},
    {"jsonrpc": "2.0", "id": 4, "method": "tools/call",
     "params": {"name": "add_task",
                "arguments": {"title": "MCP added task", "priority": 80,
                              "tags": ["mcp"]}}},
    {"jsonrpc": "2.0", "id": 5, "method": "tools/call",
     "params": {"name": "claim_task", "arguments": {"id": 2}}},
    {"jsonrpc": "2.0", "id": 6, "method": "tools/call",
     "params": {"name": "note",
                "arguments": {"id": 2, "text": "hello from mcp"}}},
    {"jsonrpc": "2.0", "id": 7, "method": "tools/call",
     "params": {"name": "update_task",
                "arguments": {"id": 2, "priority": 90}}},
    {"jsonrpc": "2.0", "id": 8, "method": "tools/call",
     "params": {"name": "board", "arguments": {}}},
    {"jsonrpc": "2.0", "id": 9, "method": "tools/call",
     "params": {"name": "stats", "arguments": {}}},
    {"jsonrpc": "2.0", "id": 10, "method": "tools/call",
     "params": {"name": "claim_task", "arguments": {"id": 999}}},
    {"jsonrpc": "2.0", "id": 11, "method": "bogus/method"},
    "this is not json",
    {"jsonrpc": "2.0", "id": 12, "method": "tools/call",
     "params": {"name": "nope", "arguments": {}}},
]

stdin = "\n".join(
    r if isinstance(r, str) else json.dumps(r) for r in requests
) + "\n"

proc = subprocess.run(
    [sys.executable, server_path],
    input=stdin,
    capture_output=True,
    text=True,
    cwd=repo,
    timeout=60,
)

def fail(msg):
    print("MCP driver failure: %s" % msg, file=sys.stderr)
    print("stdout was: %s" % proc.stdout, file=sys.stderr)
    print("stderr was: %s" % proc.stderr, file=sys.stderr)
    sys.exit(1)

if proc.returncode != 0:
    fail("expected clean exit 0 on stdin EOF, got %d" % proc.returncode)
if "Traceback" in proc.stderr:
    fail("server wrote a traceback to stderr")

lines = [line for line in proc.stdout.splitlines() if line.strip()]
responses = {}
for line in lines:
    try:
        resp = json.loads(line)
    except ValueError:
        fail("server wrote a non-JSON line: %s" % line)
    responses[resp.get("id")] = resp

# 12 requests with ids (the notification gets no reply) + 1 parse error
# reply with id null = 13 responses.
if len(lines) != 13:
    fail("expected 13 response lines, got %d" % len(lines))

init = responses[1]["result"]
if init["protocolVersion"] != "2024-11-05":
    fail("initialize must return a protocol version")
if init["serverInfo"]["name"] != "cxq-mcp":
    fail("initialize must identify the server as cxq-mcp")
if init["serverInfo"]["version"] != expected_version:
    fail("serverInfo version %r != %r"
         % (init["serverInfo"]["version"], expected_version))

tools = responses[2]["result"]["tools"]
names = [t["name"] for t in tools]
expected = ["list_tasks", "add_task", "claim_task", "update_task",
            "note", "board", "stats"]
if names != expected:
    fail("tools/list must list the 7 tools, got %r" % names)

def tool_text(resp_id):
    resp = responses[resp_id]
    if resp.get("result", {}).get("isError"):
        fail("tool call %s returned an error: %s"
             % (resp_id, resp["result"]))
    return resp["result"]["content"][0]["text"]

if "MCP smoke task" not in tool_text(3):
    fail("list_tasks must return the queued task")
if "Created task #2" not in tool_text(4):
    fail("add_task must create a task")
if "Claimed task #2 as mcp" not in tool_text(5):
    fail("claim_task must claim with the default agent 'mcp'")
if "Noted task #2" not in tool_text(6):
    fail("note must append the note")
if "priority: 80 -> 90" not in tool_text(7):
    fail("update_task must edit the task")
if "MCP added task" not in tool_text(8):
    fail("board must show the claimed task")
if "tasks_total: 2" not in tool_text(9):
    fail("stats must count both tasks")

# CLI failure surfaces as a tool error, not a crash.
if not responses[10]["result"].get("isError"):
    fail("claiming a missing task must be a tool error")
if "task not found: 999" not in responses[10]["result"]["content"][0]["text"]:
    fail("tool error must carry the CLI's stderr")

# Unknown method -> -32601, malformed JSON -> -32700, unknown tool -> isError.
if responses[11].get("error", {}).get("code") != -32601:
    fail("unknown method must return -32601")
if responses[None].get("error", {}).get("code") != -32700:
    fail("malformed JSON must return -32700")
if not responses[12]["result"].get("isError"):
    fail("unknown tool must be a tool error")

print("MCP_OK")
PYEOF

  set +e
  output=$(cd "$repo" && CXQ_BIN="$ROOT/bin/cxq" CXQ_NO_UPDATE_CHECK=1 python3 "$driver" "$ROOT/mcp/cxq_mcp.py" "$repo" "$(current_repo_version)" 2>&1)
  status=$?
  set -e
  [ "$status" -eq 0 ] || fail "MCP smoke test failed (exit $status): $output"
  assert_contains "$output" "MCP_OK"
  pass "MCP server smoke test: initialize + tools/list + all 7 tools + error paths, clean EOF exit"
}

test_serve_requires_token_and_starts() {
  command -v python3 >/dev/null 2>&1 || fail "python3 is required for the serve test"
  local repo output status pid port
  port=$(free_port)
  repo="$TEST_DIR/serve"
  run_git_init "$repo"
  (cd "$repo" && "$CXQ" install >/dev/null)

  # Without a token, serve refuses loudly.
  set +e
  output=$(cd "$repo" && "$CXQ" serve --port "$port" 2>&1); status=$?
  set -e
  [ "$status" -ne 0 ] || fail "serve without CXQ_TOKEN must fail"
  assert_contains "$output" "CXQ_TOKEN is required"

  # With --generate-token it starts and answers health.
  (cd "$repo" && exec "$CXQ" serve --port "$port" --generate-token >"$TEST_DIR/serve.log" 2>&1 & echo $! >"$TEST_DIR/serve.pid")
  pid=$(cat "$TEST_DIR/serve.pid")
  local i=0
  while [ "$i" -lt 20 ]; do
    if curl -s --max-time 2 "http://127.0.0.1:$port/api/v1/health" >/dev/null 2>&1; then break; fi
    sleep 0.5
    i=$((i + 1))
  done
  output=$(curl -s "http://127.0.0.1:$port/api/v1/health")
  assert_contains "$output" '"status": "ok"'
  assert_contains "$(cat "$TEST_DIR/serve.log")" "Generated CXQ_TOKEN"
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  pass "serve requires a token and starts with --generate-token"
}

test_doctor_reports_remote_mode() {
  local repo output
  repo="$TEST_DIR/doctor-remote"
  run_git_init "$repo"
  (cd "$repo" && "$CXQ" install >/dev/null)
  output=$(cd "$repo" && CXQ_REMOTE_URL="http://127.0.0.1:18791" "$CXQ" doctor)
  assert_contains "$output" "remote_mode: yes"
  assert_contains "$output" "remote_url: http://127.0.0.1:18791"
  assert_contains "$output" "repo_schema_version: 6 (expected 6)"
  output=$(cd "$repo" && "$CXQ" doctor)
  assert_contains "$output" "remote_mode: no"
  pass "doctor reports schema v6 and remote mode"
}

test_installer_and_version
test_installer_defaults_to_home_local
test_installer_explicit_prefix_and_old_binary_warning
test_installer_path_scanning_preserves_literal_paths
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
test_dependencies_skip_blocked_tasks
test_dependencies_unblocked_task_becomes_claimable
test_done_blocker_allows_dependent_task
test_dependency_rejects_self_and_cycle
test_release_clears_claim_fields
test_files_globs_are_preserved_literally
test_update_status_creates_state_db
test_doctor_reports_state_and_is_read_only
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
test_plain_update_current
test_plain_update_requires_yes_when_modifying_noninteractive
test_plain_update_yes_repairs_repo_and_clears_state
test_update_aliases
test_update_self_clears_state_without_shell_error
test_prerelease_update_tags_are_ignored
test_update_all_yes_repairs_repo_setup
test_failed_remote_check_does_not_block
test_repeated_update_gate_does_not_loop
test_version_bump_and_set_commands
test_version_invalid_and_outside_repo
test_release_prepare_and_dry_runs
test_release_tag_checks_upstream_state
test_release_prepare_rejects_mismatch_and_existing_tag
test_release_publish_requires_yes_noninteractive_and_source_repo
test_commands_work_from_repo_subdirectory_after_install
test_dev_version_update_comparisons
test_release_notes_summarize_commits
test_release_tag_rejects_unpushed_main
test_doctor_reports_repo_database
test_status_transitions_table_and_release
test_reopen_returns_tasks_to_ready
test_followup_links_residual_work
test_findings_lifecycle
test_operational_views
test_done_warns_about_unfinished_work
test_concurrent_commands_do_not_lock
test_doctor_reports_remote_mode
test_serve_requires_token_and_starts
test_server_smoke_and_remote_mode
test_server_due_and_recurrence
test_server_per_agent_tokens
test_mcp_server_smoke
test_schema_migration_v3_to_v6
test_schema_migration_v4_to_v6
test_schema_migration_v5_to_v6
test_due_lists_overdue_today_tomorrow
test_recurrence_daily_weekly_monthly
test_recurrence_validation_and_clear
test_recurrence_via_edit_status_done
test_legacy_codex_dir_migrates_to_cxq
test_export_and_watch
test_list_filters_and_formats
test_board_stats_activity
test_delete_guardrails
test_trash_restore_purge
test_undo_reverts_last_edit
test_edit_rejects_bad_input
test_edit_updates_fields_and_logs_diff

printf '\n%s tests passed\n' "$PASS"
