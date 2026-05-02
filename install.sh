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
  First writable known macOS bin directory already on PATH, otherwise $HOME/.local
EOF
}

path_contains() {
  case ":$PATH:" in
    *":$1:"*) return 0 ;;
    *) return 1 ;;
  esac
}

choose_prefix() {
  local candidate bin

  for candidate in /usr/local /opt/homebrew "$HOME/.local"; do
    bin="$candidate/bin"
    if [ -d "$bin" ] && [ -w "$bin" ] && path_contains "$bin"; then
      printf '%s' "$candidate"
      return
    fi
  done

  for candidate in /usr/local /opt/homebrew; do
    bin="$candidate/bin"
    if [ -d "$bin" ] && [ -w "$bin" ]; then
      printf '%s' "$candidate"
      return
    fi
  done

  printf '%s' "$HOME/.local"
}

if [ "$(uname -s)" != "Darwin" ]; then
  die "cxq currently supports macOS only."
fi

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
cp "$source_cli" "$target"
chmod 0755 "$target"

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
