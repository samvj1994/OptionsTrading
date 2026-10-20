#!/usr/bin/env sh
set -eu

ROOT_DIR=$(CDPATH= cd "$(dirname "$0")" && pwd)
cd "$ROOT_DIR"

PYTHON=${PYTHON:-python3}
if ! command -v "$PYTHON" >/dev/null 2>&1; then
  echo "Python 3.10 or newer is required. Install Python, then run this command again." >&2
  exit 1
fi

if ! "$PYTHON" -c 'import sys; raise SystemExit(sys.version_info < (3, 10))'; then
  echo "Python 3.10 or newer is required. Upgrade Python, then run this command again." >&2
  exit 1
fi

if [ "${1:-}" = "--preview" ]; then
  export DASHBOARD_TEST_PREVIEW=1
fi

exec "$PYTHON" server.py
