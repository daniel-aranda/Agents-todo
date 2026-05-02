#!/usr/bin/env bash
set -euo pipefail

die() {
  printf 'install.sh: %s\n' "$*" >&2
  exit 1
}

usage() {
  cat <<'EOF'
Install cxq.

Usage:
  ./install.sh [--prefix <path>] [--modify-profile] [--no-modify-profile]

Environment:
  PREFIX=/path ./install.sh
  PROFILE=/path/to/profile ./install.sh --modify-profile

Default prefix:
  $HOME/.local

Examples:
  ./install.sh
  ./install.sh --modify-profile
  ./install.sh --no-modify-profile
  PREFIX=/opt/homebrew ./install.sh
  ./install.sh --prefix "$HOME/.local"
EOF
}

path_contains() {
  case ":$PATH:" in
    *":$1:"*) return 0 ;;
    *) return 1 ;;
  esac
}

sql_quote() {
  local value=${1-}
  value=${value//\'/\'\'}
  printf "'%s'" "$value"
}

state_set() {
  local db key value

  db="$HOME/.cxq/state.db"
  key=$1
  value=${2-}

  mkdir -p "$(dirname "$db")"

  sqlite3 -batch "$db" "
CREATE TABLE IF NOT EXISTS cxq_state (
  key TEXT PRIMARY KEY,
  value TEXT NOT NULL
);

INSERT OR REPLACE INTO cxq_state (key, value)
VALUES ($(sql_quote "$key"), $(sql_quote "$value"));
"
}

record_install_metadata() {
  local source_dir=$1
  local bin_path=$2
  local remote_url=""

  if [ -d "$source_dir/.git" ]; then
    remote_url=$(git -C "$source_dir" config --get remote.origin.url 2>/dev/null || true)
  fi

  state_set "install_source_dir" "$source_dir"
  state_set "install_bin_path" "$bin_path"
  state_set "install_remote_url" "$remote_url"
}

choose_prefix() {
  printf '%s\n' "$HOME/.local"
}

profile_path() {
  if [ -n "${PROFILE:-}" ]; then
    printf '%s\n' "$PROFILE"
    return 0
  fi

  case "${SHELL:-}" in
    */zsh)
      printf '%s\n' "$HOME/.zshrc"
      ;;
    */bash)
      printf '%s\n' "$HOME/.bash_profile"
      ;;
    *)
      printf '%s\n' "$HOME/.profile"
      ;;
  esac
}

path_line_for_install_dir() {
  local install_dir=$1

  if [ "$install_dir" = "$HOME/.local/bin" ]; then
    printf '%s\n' 'export PATH="$HOME/.local/bin:$PATH"'
  else
    printf 'export PATH="%s:$PATH"\n' "$install_dir"
  fi
}

profile_has_cxq_path() {
  local profile=$1
  local install_dir=$2
  local path_line

  [ -f "$profile" ] || return 1

  path_line=$(path_line_for_install_dir "$install_dir")

  if grep -F "$path_line" "$profile" >/dev/null 2>&1; then
    return 0
  fi

  if [ "$install_dir" = "$HOME/.local/bin" ] &&
    grep -F 'export PATH="$HOME/.local/bin:$PATH"' "$profile" >/dev/null 2>&1; then
    return 0
  fi

  if grep -F "$install_dir" "$profile" >/dev/null 2>&1; then
    return 0
  fi

  return 1
}

modify_profile() {
  local profile=$1
  local install_dir=$2
  local path_line

  path_line=$(path_line_for_install_dir "$install_dir")

  mkdir -p "$(dirname "$profile")"
  touch "$profile"

  if profile_has_cxq_path "$profile" "$install_dir"; then
    printf 'PATH entry already present in %s\n' "$profile"
    return 0
  fi

  {
    printf '\n# cxq\n'
    printf '%s\n' "$path_line"
  } >> "$profile"

  printf 'Added cxq PATH entry to %s\n' "$profile"
}

is_interactive() {
  [ -t 0 ] && [ -t 1 ] && [ -r /dev/tty ]
}

prompt_modify_profile() {
  local profile=$1
  local install_dir=$2
  local answer=""

  printf '\n%s is not currently in PATH.\n' "$install_dir"
  printf 'Add it to %s now? [y/N] ' "$profile"

  if ! read -r answer </dev/tty; then
    answer=""
  fi

  case "$answer" in
    y|Y|yes|YES|Yes)
      modify_profile "$profile" "$install_dir"
      printf 'Restart your shell or run:\n'
      printf '  source %s\n' "$profile"
      ;;
    *)
      print_manual_path_instructions "$install_dir"
      ;;
  esac
}

print_manual_path_instructions() {
  local install_dir=$1
  local path_line

  path_line=$(path_line_for_install_dir "$install_dir")

  printf '\n%s is not currently in PATH.\n' "$install_dir"
  printf 'Add this to your shell profile:\n'
  printf '  %s\n' "$path_line"
}

split_path_find_cxq() {
  local old_ifs=$IFS
  local dir
  local path_entry

  IFS=:
  for path_entry in $PATH; do
    IFS=$old_ifs

    if [ -z "$path_entry" ]; then
      path_entry="."
    fi

    if [ -x "$path_entry/cxq" ]; then
      dir=$(cd "$path_entry" 2>/dev/null && pwd -P || printf '%s' "$path_entry")
      printf '%s/cxq\n' "$dir"
    fi

    IFS=:
  done

  IFS=$old_ifs
}

first_cxq_on_path() {
  split_path_find_cxq | sed -n '1p'
}

target_is_first_on_path() {
  local target=$1
  local first=""

  first=$(first_cxq_on_path || true)

  [ -n "$first" ] && [ "$first" = "$target" ]
}

warn_path_resolution() {
  local target=$1
  local first=""

  first=$(first_cxq_on_path || true)

  if [ -z "$first" ]; then
    printf '\nNote: cxq is installed, but your current PATH does not resolve cxq yet.\n'
    return 0
  fi

  if [ "$first" = "$target" ]; then
    printf 'cxq is ready.\n'
    return 0
  fi

  printf '\nWarning: your shell currently resolves cxq to:\n'
  printf '  %s\n' "$first"
  printf 'but this install wrote:\n'
  printf '  %s\n' "$target"
  printf '\nYour PATH order may still select the older binary.\n'
  printf 'Restart your shell, update PATH order, or remove the old binary if appropriate.\n'
}

warn_old_binaries() {
  local install_dir=$1
  local target=$2
  local dirs old

  dirs=${CXQ_OLD_BIN_DIRS:-"/opt/homebrew/bin /usr/local/bin"}

  for old in $dirs; do
    if [ -x "$old/cxq" ] && [ "$old/cxq" != "$target" ]; then
      printf '\nWarning: found another cxq at %s\n' "$old/cxq"

      if [ "$install_dir" = "$HOME/.local/bin" ]; then
        printf 'If %s appears before %s in PATH, your shell may still run the older binary.\n' "$old" "$install_dir"
      fi
    fi
  done
}

maybe_update_profile() {
  local install_dir=$1
  local mode=$2
  local profile

  if path_contains "$install_dir"; then
    return 0
  fi

  profile=$(profile_path)

  case "$mode" in
    modify)
      modify_profile "$profile" "$install_dir"
      printf 'Restart your shell or run:\n'
      printf '  source %s\n' "$profile"
      ;;
    no_modify)
      print_manual_path_instructions "$install_dir"
      ;;
    prompt)
      if is_interactive; then
        prompt_modify_profile "$profile" "$install_dir"
      else
        print_manual_path_instructions "$install_dir"
      fi
      ;;
    *)
      die "internal error: unknown profile mode: $mode"
      ;;
  esac
}

prefix=""
profile_mode="prompt"

while [ "$#" -gt 0 ]; do
  case "$1" in
    --prefix)
      [ "$#" -ge 2 ] || die "--prefix requires a value."
      prefix=$2
      shift 2
      ;;
    --modify-profile)
      profile_mode="modify"
      shift
      ;;
    --no-modify-profile)
      profile_mode="no_modify"
      shift
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      die "unknown option: $1"
      ;;
  esac
done

if [ "$(uname -s)" != "Darwin" ]; then
  die "cxq currently supports macOS only."
fi

command -v sqlite3 >/dev/null 2>&1 || die "sqlite3 is required but was not found."

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
source_cli="$script_dir/bin/cxq"

[ -f "$source_cli" ] || die "missing $source_cli"

if [ -z "$prefix" ]; then
  prefix=${PREFIX:-}
fi

if [ -z "$prefix" ]; then
  prefix=$(choose_prefix)
fi

install_dir="$prefix/bin"
target="$install_dir/cxq"

mkdir -p "$install_dir"

tmp_target="$target.tmp.$$"
cp "$source_cli" "$tmp_target"
chmod 0755 "$tmp_target"
mv "$tmp_target" "$target"

record_install_metadata "$script_dir" "$target"

printf 'Installed cxq to %s\n' "$target"
"$target" -v

maybe_update_profile "$install_dir" "$profile_mode"
warn_old_binaries "$install_dir" "$target"
warn_path_resolution "$target"