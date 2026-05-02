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
  ./install.sh [--prefix <path>]

Environment:
  PREFIX=/path ./install.sh

Default prefix:
  $HOME/.local
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
  sqlite3 -batch "$db" "CREATE TABLE IF NOT EXISTS cxq_state (key TEXT PRIMARY KEY, value TEXT NOT NULL); INSERT OR REPLACE INTO cxq_state (key, value) VALUES ($(sql_quote "$key"), $(sql_quote "$value"));"
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
  printf '%s' "$HOME/.local"
}

warn_old_binaries() {
  local install_dir=$1
  local dirs old
  dirs=${CXQ_OLD_BIN_DIRS:-"/opt/homebrew/bin /usr/local/bin"}

  if [ "$install_dir" = "$HOME/.local/bin" ]; then
    for old in $dirs; do
      if [ -x "$old/cxq" ] && [ "$old/cxq" != "$install_dir/cxq" ]; then
        printf '\nWarning: found another cxq at %s\n' "$old/cxq"
        printf 'If %s appears before %s in PATH, your shell may still run the older binary.\n' "$old" "$install_dir"
      fi
    done
  fi
}

if [ "$(uname -s)" != "Darwin" ]; then
  die "cxq currently supports macOS only."
fi

command -v sqlite3 >/dev/null 2>&1 || die "sqlite3 is required but was not found."

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
source_cli="$script_dir/bin/cxq"
[ -f "$source_cli" ] || die "missing $source_cli"

prefix=${PREFIX:-}
while [ "$#" -gt 0 ]; do
  case "$1" in
    --prefix)
      [ "$#" -ge 2 ] || die "--prefix requires a value."
      prefix=$2
      shift 2
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

case ":$PATH:" in
  *":$install_dir:"*) ;;
  *)
    printf '\n%s is not currently in PATH.\n' "$install_dir"
    printf 'Add this to your shell profile:\n'
    printf '  export PATH="%s:$PATH"\n' "$install_dir"
    ;;
esac

warn_old_binaries "$install_dir"
