#!/usr/bin/env bash
# Formats the single file an agent just edited. Reads hook JSON from stdin.
set -euo pipefail
f=$(jq -r '.tool_input.file_path // empty')
[ -z "$f" ] && exit 0
case "$f" in
  *.rs) rustfmt --edition 2024 "$f" 2>/dev/null || true ;;
  *.ts|*.tsx|*.js|*.json|*.css) npx --no-install biome format --write "$f" >/dev/null 2>&1 || true ;;
esac
