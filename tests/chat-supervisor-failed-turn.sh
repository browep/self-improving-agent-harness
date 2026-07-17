#!/usr/bin/env sh
# Failed turns are terminal protocol events, not a 300-second supervisor stall.
set -eu

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
. "$repo_root/tests/chat-supervisor-fixture.sh"
output=$(mktemp)
supervisor_fixture_create "$repo_root"
cleanup() { rm -f "$output"; supervisor_fixture_cleanup; }
trap cleanup EXIT HUP INT TERM

printf '%s\n' \
  '{"op":"turn","text":"will fail"}' \
  '{"op":"turn","text":"then works"}' \
  '{"op":"exit"}' |
  timeout 8 env HARNESS_CHAT_RUNNER="$repo_root/tests/fake-supervisor-protocol-runner.sh" \
    "$repo_root/bin/chat-supervisor" \
      --create-worktree --repo "$SUPERVISOR_FIXTURE_PRIMARY" --base-ref HEAD \
      --run-id supervised-failed-16 --worktree-parent "$SUPERVISOR_FIXTURE_PARENT" \
      --session-id supervised-failed-16 --fake --verify-command '/bin/true' \
      --report-dir "$SUPERVISOR_FIXTURE_REPORTS/failed-turn" >"$output"

python3 - "$output" <<'PY'
import json
import sys

records = [json.loads(line) for line in open(sys.argv[1], encoding="utf-8") if line.strip()]
events = [record for record in records if record.get("type") == "event"]
assistant = [record for record in records if record.get("type") == "assistant"]
assert [event["event"] for event in events if event["event"] in ("turn-failed", "turn-completed")] == ["turn-failed", "turn-completed"], records
completed = next(event for event in events if event["event"] == "turn-completed")
assert completed["assistant_bytes"] == len("two\nπline".encode("utf-8")), records
assert [(record["turn"], record["text"]) for record in assistant] == [(2, "two\nπline")], records
assert records.index(next(event for event in events if event["event"] == "turn-completed")) < records.index(assistant[0]), records
PY

printf 'Chat supervisor failed-turn recovery and multiline-output test passed.\n'