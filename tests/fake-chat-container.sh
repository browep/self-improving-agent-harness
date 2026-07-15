#!/usr/bin/env sh
# Test-only stand-in for bin/container; it never starts Docker.
set -eu

status=${HARNESS_FAKE_CONTAINER_STATUS:-0}
if [ "$status" -ne 0 ]; then
  printf '%s\n' 'driver failure propagates' >&2
  exit "$status"
fi
printf 'FAKE_CHAT_DRIVER prompt=%s model=%s max-rounds=%s\n' \
  "$HARNESS_CHAT_PROMPT" "$HARNESS_CHAT_MODEL" "$HARNESS_CHAT_MAX_ROUNDS"
