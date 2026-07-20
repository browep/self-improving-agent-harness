#!/usr/bin/env sh
# Deterministic, Docker-free test of bin/verify-codex-chatgpt-auth opt-in gating.
# The live path (real app-server, billing) is NOT exercised here.
set -eu

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
script="$repo_root/bin/verify-codex-chatgpt-auth"

# 1. Without opt-in, it must SKIP with exit 77 and never invoke Docker.
set +e
output=$(env -u HARNESS_LIVE_CODEX_SMOKE "$script" 2>&1)
status=$?
set -e
[ "$status" -eq 77 ] || {
  printf 'Test failed: expected exit 77 without opt-in, got %s\n' "$status" >&2
  exit 1
}
case "$output" in
  *'HARNESS_LIVE_CODEX_SMOKE=1'*) ;;
  *) printf 'Test failed: skip message should name the opt-in var: %s\n' "$output" >&2; exit 1 ;;
esac

# 2. The skip path must not leak any docker invocation error (proves the gate is
#    BEFORE bin/container, so a machine without Docker still cleanly skips).
case "$output" in
  *docker*) printf 'Test failed: skip path unexpectedly reached docker: %s\n' "$output" >&2; exit 1 ;;
  *) ;;
esac

printf 'Codex verify CLI opt-in gating test passed.\n'
