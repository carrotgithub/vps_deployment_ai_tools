#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="${HONGBOX_REPO_DIR:-}"

if [ -z "$REPO_DIR" ]; then
    REPO_DIR="$(cd "$SCRIPT_DIR/../../.." && pwd)"
fi

if [ ! -x "$REPO_DIR/hongbox" ]; then
    echo "hongbox-run: cannot find executable hongbox at $REPO_DIR/hongbox" >&2
    echo "Set HONGBOX_REPO_DIR=/path/to/hong-ai-box and retry." >&2
    exit 1
fi

exec "$REPO_DIR/hongbox" "$@"
