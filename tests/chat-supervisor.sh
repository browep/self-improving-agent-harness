#!/usr/bin/env sh
# Exercise the supervised forced-interactive fake path with two persistent turns.
set -eu

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
output=$(mktemp)
cleanup() { rm -f "$output"; }
trap cleanup EXIT HUP INT TERM

# The protocol is JSONL. The fake child is the real scripts/chat.lisp session
# with a deterministic backend, launched by the supervisor through ordinary pipes.
if ! printf '%s\n' \
  '{"op":"turn","text":"first request"}' \
  '{"op":"checkpoint"}' \
  '{"op":"turn","text":"second request"}' \
  '{"op":"exit"}' |
  env HARNESS_CHAT_RUNNER="$repo_root/tests/fake-supervised-chat-container.sh" \
    "$repo_root/bin/chat-supervisor" \
      --worktree "$repo_root" \
      --session-id supervised-test-16 \
      --fake \
      --verify-command '/bin/true' >"$output"; then
  cat "$output" >&2
  exit 1
fi

# Use Python only for JSON parsing and exact field assertions; no provider is used.
python3 - "$output" <<'PY'
import json
import sys

records = [json.loads(line) for line in open(sys.argv[1], encoding="utf-8") if line.strip()]
events = [record for record in records if record.get("type") == "event"]
assistant = [record for record in records if record.get("type") == "assistant"]
checkpoint = [record for record in records if record.get("type") == "checkpoint"]
assert [record["text"] for record in assistant] == ["fake assistant turn 1", "fake assistant turn 2"], records
assert [record["turn"] for record in assistant] == [1, 2], records
assert any(record.get("event") == "session-started" for record in events), records
assert [record["event"] for record in events if record.get("event") == "turn-completed"] == ["turn-completed", "turn-completed"], records
assert any(record.get("event") == "session-exited" and record.get("reason") == "local-exit" for record in events), records
assert len(checkpoint) == 1, records
result = checkpoint[0]
# The Docker test mount intentionally excludes the parent worktree's gitdir;
# assert that the adapter returns a sanitized git failure rather than paths/error text.
assert result["git"]["status"] == "unavailable", result
assert result["git"]["diff_check"] == "failed", result
assert result["git"]["diff_check_exit_code"] == 128, result
assert result["verification"] == {"command": "/bin/true", "status": "passed", "exit_code": 0}, result
assert result["provider_usage"] == "unavailable", result
assert "chat.log" not in "\n".join(map(json.dumps, records)), records
PY

printf 'Chat supervisor multi-turn fake session test passed.\n'
