#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

printf '== syntax ==\n'
find "$ROOT_DIR" -path "$ROOT_DIR/.git" -prune -o -name '*.sh' -print0 \
  | xargs -0 -n1 bash -n

if command -v shellcheck >/dev/null 2>&1; then
  printf '== shellcheck ==\n'
  find "$ROOT_DIR" -path "$ROOT_DIR/.git" -prune -o -name '*.sh' -print0 \
    | xargs -0 shellcheck -x -S warning
else
  printf '== shellcheck skipped: not installed ==\n'
fi

printf '== common and crypto helpers ==\n'
"$ROOT_DIR/tests/test-common-crypto.sh"

printf '== credentials helpers ==\n'
"$ROOT_DIR/tests/test-credentials.sh"

printf '== hidden modules ==\n'
"$ROOT_DIR/tests/test-hidden-modules.sh"

printf '== smoke ==\n'
"$ROOT_DIR/install.sh" --version >/dev/null
"$ROOT_DIR/install.sh" -h >/dev/null
"$ROOT_DIR/install.sh" >/dev/null
"$ROOT_DIR/hongbox" --version >/dev/null
"$ROOT_DIR/hongbox" help >/dev/null
"$ROOT_DIR/hongbox" plan --services pi >/dev/null
"$ROOT_DIR/hongbox" status >/dev/null
"$ROOT_DIR/hongbox" doctor --services pi >/dev/null

printf 'All tests passed.\n'
