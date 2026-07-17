#!/usr/bin/env sh
# Regression: supervised Docker transport keeps machine events on stderr and text on stdout.
set -eu

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
stdout=$(mktemp)
stderr=$(mktemp)
cleanup() { rm -f "$stdout" "$stderr"; }
trap cleanup EXIT HUP INT TERM

# This is intentionally real Docker, not HARNESS_CHAT_RUNNER: a TTY would merge
# the streams and Docker would reject the piped supervisor transport. The fake
# backend makes /exit a local no-provider/empty-session fixture.
printf '/exit\n' | "$repo_root/bin/chat" --supervised --fake \
  --session-id docker-transport-16 >"$stdout" 2>"$stderr"

python3 - "$stdout" "$stderr" <<'PY'
import json
import sys

stdout, stderr = sys.argv[1:]
assert open(stdout, "rb").read() == b"", "local close must not write assistant stdout"
lines = [line for line in open(stderr, encoding="utf-8").read().splitlines() if line]
# Docker build and SBCL/ASDF may report their own diagnostics before the child
# starts. Every child machine-event line is a standalone JSON object on stderr.
events = [json.loads(line) for line in lines if line.startswith("{")]
assert events, lines
assert all(line.startswith("{") and line.endswith("}") for line in lines if line.startswith("{")), lines
assert [event["event"] for event in events] == ["session-started", "session-exited"], events
assert all(event["session_id"] == "docker-transport-16" for event in events), events
assert events[-1]["reason"] == "local-exit", events
PY

printf 'Real Docker supervised transport test passed.\n'
