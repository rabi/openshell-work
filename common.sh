#!/usr/bin/env bash
# Shared helpers: load .env and render ${VAR} placeholders in templates.
# Real values live in ./.env (gitignored); repo files carry placeholders only.

load_env() {
  local env_file="${1:-$(dirname "${BASH_SOURCE[0]}")/.env}"
  if [ -f "$env_file" ]; then
    set -a
    # shellcheck disable=SC1090
    . "$env_file"
    set +a
  fi
}

# render <file>... : print files with ${VAR} placeholders expanded from the
# environment; missing vars expand to empty string (envsubst semantics).
render() {
  load_env
  cat "$@" | envsubst
}

# render_to <dest> <file>: render file into dest (used for temp copies)
render_to() {
  local dest=$1 file=$2
  render "$file" > "$dest"
}
