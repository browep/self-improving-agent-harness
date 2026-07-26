#!/usr/bin/env sh
# End-to-end contract for bin/session-diagnose.  Uses only synthetic artifacts.
set -eu

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
session_id='2026-07-25T16:33:08.866Z'

python3 - "$tmp" "$session_id" <<'PY'
import json
import pathlib
import sys

root = pathlib.Path(sys.argv[1])
session = sys.argv[2]
rows = []

def event(name, **fields):
    payload = {"event": name, **fields}
    rows.append({"type": "user", "sessionId": session, "payload": payload})

# Five received turns; turns 2 and 4 fail and never enter durable history.
event("turn-received", content="find the open web-UI issue")
event("turn-submitted", messageCount=2)
event("provider-request", round=0, messageCount=2)
event("provider-response", round=0, finishReason="tool_use")
event("turn-completed")

event("turn-received", content="fix both, live E2E test")
event("turn-submitted", messageCount=15)
event("provider-request", round=0, messageCount=15)
event("provider-request-failed", message="OpenRouter request timed out after 120 seconds; Authorization: Bearer sk-secret-value")
event("turn-failed")

event("turn-received", content="Still working?")
event("turn-submitted", messageCount=15)
event("provider-request", round=0, messageCount=15)
event("provider-response", round=0, finishReason="end_turn")
event("turn-completed")

event("turn-received", content="Fix the issue")
event("turn-submitted", messageCount=19)
event("provider-request", round=0, messageCount=19)
event("provider-request-failed", message="OpenRouter request timed out after 120 seconds")
event("turn-failed")

event("turn-received", content="Still working?")
event("turn-submitted", messageCount=19)
event("provider-request", round=0, messageCount=19)
event("provider-response", round=0, finishReason="end_turn")
event("turn-completed")

(root / f"{session}.jsonl").write_text("".join(json.dumps(row) + "\n" for row in rows))
history = {
    "sessionId": session,
    "messages": [
        {"role": "system", "content": "system"},
        {"role": "user", "content": "find the open web-UI issue"},
        {"role": "assistant", "content": "done"},
        {"role": "user", "content": "Still working?"},
        {"role": "assistant", "content": "recap"},
        {"role": "user", "content": "Still working?"},
        {"role": "assistant", "content": "recap"},
    ],
}
(root / f"{session}.history.json").write_text(json.dumps(history))
PY

output=$("$repo_root/bin/session-diagnose" --path "$tmp/$session_id.jsonl")
printf '%s\n' "$output"

printf '%s\n' "$output" | grep -F 'Session: 2026-07-25T16:33:08.866Z'
printf '%s\n' "$output" | grep -F 'Event counts: turn-received=5 turn-completed=3 turn-failed=2'
printf '%s\n' "$output" | grep -F 'Failure classes: provider-timeout=2'
printf '%s\n' "$output" | grep -F 'Received vs durable history: 2 missing'
printf '%s\n' "$output" | grep -F 'fix both, live E2E test'
printf '%s\n' "$output" | grep -F 'Fix the issue'
if printf '%s\n' "$output" | grep -F 'sk-secret-value'; then
  echo 'session-diagnose leaked a secret' >&2
  exit 1
fi

echo 'session-diagnose tests passed.'
