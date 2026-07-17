#!/usr/bin/env sh
# A supervisor turn can end empty; it must remain usable rather than waiting for
# a turn-completed event that the child correctly does not emit.
set -eu

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
. "$repo_root/tests/chat-supervisor-fixture.sh"
output=$(mktemp)
supervisor_fixture_create "$repo_root"
cleanup() { rm -f "$output"; supervisor_fixture_cleanup; }
trap cleanup EXIT HUP INT TERM

if ! printf '%s\n' \
  '{"op":"turn","text":""}' \
  '{"op":"turn","text":"after empty"}' \
  '{"op":"exit"}' |
  timeout 8 env HARNESS_CHAT_RUNNER="$repo_root/tests/fake-supervised-chat-container.sh" \
    "$repo_root/bin/chat-supervisor" \
      --create-worktree --repo "$SUPERVISOR_FIXTURE_PRIMARY" --base-ref HEAD \
      --run-id supervised-empty-16 --worktree-parent "$SUPERVISOR_FIXTURE_PARENT" \
      --session-id supervised-empty-16 --fake --verify-command '/bin/true' \
      --report-dir "$SUPERVISOR_FIXTURE_REPORTS/empty-turn" >"$output"; then
  cat "$output" >&2
  printf '%s\n' 'Test failed: empty supervised turn must complete without timing out.' >&2
  exit 1
fi

python3 - "$output" <<'PY'
import json
import sys

records = [json.loads(line) for line in open(sys.argv[1], encoding="utf-8") if line.strip()]
events = [record for record in records if record.get("type") == "event"]
assistant = [record for record in records if record.get("type") == "assistant"]
assert [event["event"] for event in events if event["event"] in ("turn-empty", "turn-completed")] == ["turn-empty", "turn-completed"], records
assert next(event for event in events if event.get("event") == "turn-completed")["assistant_bytes"] == len("fake assistant turn 1".encode("utf-8")), records
assert [(record["turn"], record["text"]) for record in assistant] == [(2, "fake assistant turn 1")], records
PY

printf 'Chat supervisor empty-turn recovery test passed.\n'