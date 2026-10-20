#!/usr/bin/env sh
set -eu

ROOT_DIR=$(CDPATH= cd "$(dirname "$0")" && pwd)
cd "$ROOT_DIR"

if ! command -v ruby >/dev/null 2>&1; then
  echo "Ruby is required. Install Ruby 2.6 or newer, then run this command again." >&2
  exit 1
fi

if ! command -v bundle >/dev/null 2>&1; then
  echo "Bundler is required. Install it with: gem install bundler" >&2
  exit 1
fi

if ! bundle check >/dev/null 2>&1; then
  echo "Installing dashboard dependencies..."
  bundle install
fi

if [ "${1:-}" = "--preview" ]; then
  export DASHBOARD_TEST_PREVIEW=1
fi

exec bundle exec ruby server.rb
