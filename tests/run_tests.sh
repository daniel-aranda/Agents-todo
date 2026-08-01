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

export CXQ_TEST_LATEST_VERSION="$(current_uptodate_tag)"

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
  (cd "$repo" && "$CXQ" done "$blocker" --summary "Accepted" >/dev/null)

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
  assert_not_exists "$repo/.codex"

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
  rm "$repo/.codex/prompts/task.md"

  set +e
  output=$(cd "$repo" && "$CXQ" update 2>&1)
  status=$?
  set -e
  [ "$status" -ne 0 ] || fail "plain non-interactive update should require --yes before modifying files"
  assert_contains "$output" "Run: cxq update --yes"
  assert_not_exists "$repo/.codex/prompts/task.md"
  pass "plain non-interactive update requires --yes when modifying files"
}

test_plain_update_yes_repairs_repo_and_clears_state() {
  local repo output
  repo="$TEST_DIR/update-plain-yes"
  run_git_init "$repo"
  (cd "$repo" && "$CXQ" install >/dev/null)
  rm "$repo/.codex/prompts/task.md"

  output=$(cd "$repo" && "$CXQ" update --yes)
  assert_contains "$output" "Created: .codex/prompts/task.md"
  assert_contains "$output" "Repo setup is up to date."
  assert_file "$repo/.codex/prompts/task.md"
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
  assert_not_exists "$repo/.codex"

  (cd "$repo" && "$CXQ" install >/dev/null)
  (cd "$repo" && "$CXQ" add "Doctor sample" >/dev/null)
  output=$(cd "$repo" && "$CXQ" doctor)
  assert_contains "$output" "/doctor-db/.codex/tasks.db"
  assert_contains "$output" "repo_schema_version: 3 (expected 3)"
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
  [ "$(sqlite3 -batch -noheader "$repo/.codex/tasks.db" "SELECT status FROM tasks WHERE id = $id;")" = "ready" ] ||
    fail "release from blocked should return the task to ready"
  pass "status transitions are documented and release accepts blocked tasks"
}

test_reopen_returns_tasks_to_ready() {
  local repo id output status summary
  repo="$TEST_DIR/reopen"
  run_git_init "$repo"
  (cd "$repo" && "$CXQ" install >/dev/null)

  id=$(cd "$repo" && "$CXQ" add "Reopen sample" | sed 's/.*#//')
  (cd "$repo" && "$CXQ" claim "$id" --agent codex --lease 1h >/dev/null)
  (cd "$repo" && "$CXQ" note "$id" "Found a race in the refresh path" >/dev/null)
  (cd "$repo" && "$CXQ" review "$id" --summary "Partially implemented" >/dev/null)

  set +e
  output=$(cd "$repo" && "$CXQ" reopen "$id" 2>&1)
  status=$?
  set -e
  [ "$status" -ne 0 ] || fail "reopen should require a reason"
  assert_contains "$output" "reopen reason is required"

  set +e
  output=$(cd "$repo" && "$CXQ" reopen "$id" --to done --reason "nope" 2>&1)
  status=$?
  set -e
  [ "$status" -ne 0 ] || fail "reopen should reject invalid targets"
  assert_contains "$output" "reopen target must be ready, inbox, or blocked"

  output=$(cd "$repo" && "$CXQ" reopen "$id" --reason "acceptance criteria 3 is missing")
  assert_contains "$output" "Reopened task #$id: review -> ready"
  [ "$(sqlite3 -batch -noheader "$repo/.codex/tasks.db" "SELECT status FROM tasks WHERE id = $id;")" = "ready" ] ||
    fail "reopen should move the task back to ready"
  [ "$(sqlite3 -batch -noheader "$repo/.codex/tasks.db" "SELECT COUNT(*) FROM tasks WHERE id = $id AND claimed_by IS NULL AND claimed_at IS NULL AND lease_until IS NULL;")" = "1" ] ||
    fail "reopen should clear claim fields"

  summary=$(cd "$repo" && "$CXQ" show "$id")
  assert_contains "$summary" "Partially implemented" "reopen must preserve the result summary"
  assert_contains "$summary" "Found a race in the refresh path" "reopen must preserve prior notes"
  assert_contains "$summary" "acceptance criteria 3 is missing" "reopen must record the reason"

  (cd "$repo" && "$CXQ" done "$id" --summary "Accepted" >/dev/null)
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
  (cd "$repo" && "$CXQ" claim "$parent" --agent codex --lease 1h >/dev/null)
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
  [ "$(sqlite3 -batch -noheader "$repo/.codex/tasks.db" "SELECT status FROM tasks WHERE id = $parent;")" = "done" ] ||
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
  (cd "$repo" && "$CXQ" claim "$id" --agent codex --lease 1h >/dev/null)
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
  [ "$(sqlite3 -batch -noheader "$repo/.codex/tasks.db" "SELECT value FROM cxq_meta WHERE key = 'schema_version';")" = "3" ] ||
    fail "findings require schema version 3"
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
    (cd "$repo" && "$CXQ" claim "$stale_id" --agent codex --lease 1h >/dev/null)
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

  sqlite3 -batch "$repo/.codex/tasks.db" "DROP TRIGGER IF EXISTS trg_tasks_updated_at; UPDATE tasks SET updated_at = strftime('%Y-%m-%dT%H:%M:%fZ', 'now', '-48 hours') WHERE id = $reviewed;"

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
  output=$(cd "$repo" && "$CXQ" done "$pending" --summary "Main flow works, docs are still pending" 2>&1)
  status=$?
  set -e
  [ "$status" -ne 0 ] || fail "done should refuse a summary that mentions pending work"
  assert_contains "$output" "may not be finished"
  assert_contains "$output" "the summary still mentions pending work"
  assert_contains "$output" "cxq done $pending --force"
  [ "$(sqlite3 -batch -noheader "$repo/.codex/tasks.db" "SELECT status FROM tasks WHERE id = $pending;")" != "done" ] ||
    fail "a warned task must not be closed without --force"

  output=$(cd "$repo" && "$CXQ" done "$pending" --summary "Main flow works, docs are still pending" --force)
  assert_contains "$output" "Marked task #$pending done"

  (cd "$repo" && "$CXQ" finding add "$withfinding" --severity high --note "Auth bypass on refresh" >/dev/null)
  set +e
  output=$(cd "$repo" && "$CXQ" done "$withfinding" --summary "Shipped" 2>&1)
  status=$?
  set -e
  [ "$status" -ne 0 ] || fail "done should refuse a task with open findings"
  assert_contains "$output" "1 open finding(s)"

  set +e
  output=$(cd "$repo" && CXQ_TEST_TTY_ANSWER=n "$CXQ" done "$withfinding" --summary "Shipped" 2>&1)
  status=$?
  set -e
  [ "$status" -ne 0 ] || fail "answering no should abort an interactive close"
  assert_contains "$output" "Mark task #$withfinding done anyway? [y/N]"
  assert_contains "$output" "was not closed"
  [ "$(sqlite3 -batch -noheader "$repo/.codex/tasks.db" "SELECT status FROM tasks WHERE id = $withfinding;")" != "done" ] ||
    fail "answering no must leave the task open"

  output=$(cd "$repo" && CXQ_TEST_TTY_ANSWER=y "$CXQ" done "$withfinding" --summary "Shipped" 2>&1)
  assert_contains "$output" "Marked task #$withfinding done"

  output=$(cd "$repo" && "$CXQ" done "$clean" --summary "Implemented and verified")
  assert_contains "$output" "Marked task #$clean done"
  [ "$(sqlite3 -batch -noheader "$repo/.codex/tasks.db" "SELECT status FROM tasks WHERE id = $clean;")" = "done" ] ||
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

  [ "$(sqlite3 -batch -noheader "$repo/.codex/tasks.db" "SELECT COUNT(*) FROM tasks WHERE title LIKE 'Parallel task %';")" = "6" ] ||
    fail "every concurrent add should be recorded"
  [ "$(sqlite3 -batch -noheader "$repo/.codex/tasks.db" "SELECT COUNT(*) FROM task_events WHERE task_id = $id AND event_type = 'note';")" = "6" ] ||
    fail "every concurrent note should be recorded"
  pass "concurrent reads and writes do not hit database locks"
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

printf '\n%s tests passed\n' "$PASS"
