#!/usr/bin/env sh
# Opt-in, billable OpenRouter evidence for chat-supervisor tool execution.
# This is intentionally excluded from normal make test.
set -eu

skip_code=77
model=openai/gpt-4.1-mini
max_rounds=4
turn_timeout_seconds=120
session_timeout_seconds=180
verify_command="sg docker -c 'make test'"

if [ -z "${OPENROUTER_API_KEY:-}" ]; then
  printf '%s\n' 'SKIP: OPENROUTER_API_KEY is not set; live OpenRouter smoke not run.' >&2
  exit "$skip_code"
fi

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
tested_branch=$(git -C "$repo_root" branch --show-current)
[ -n "$tested_branch" ] || { printf '%s\n' 'live smoke requires a checked-out tested branch' >&2; exit 2; }
tmp=$(mktemp -d)
cleanup() { rm -rf "${tmp:-}"; }
trap cleanup EXIT HUP INT TERM

primary="$tmp/primary"
owned_parent="$tmp/owned"
reports="$tmp/reports"
jsonl="$tmp/session.jsonl"
input="$tmp/session-input.jsonl"
mkdir -p "$owned_parent" "$reports"

# The worker receives only this independent clone.  The current checkout is a
# read-only clone source and is never passed to the supervisor.
git clone --no-local --branch "$tested_branch" --single-branch "$repo_root" "$primary" >/dev/null 2>&1
primary_before=$(git -C "$primary" rev-parse HEAD)
primary_status_before=$(git -C "$primary" status --porcelain)
[ -z "$primary_status_before" ] || { printf '%s\n' 'independent primary clone is unexpectedly dirty' >&2; exit 1; }

# This string is transient JSONL input only. It is neither printed nor included
# in supervisor reports. The assistant final marker is checked alongside Git and
# provider evidence; text alone can never satisfy this smoke.
python3 - "$input" <<'PY'
import json
import pathlib
import sys

prompt = '''Use run_shell exactly once. In the owned worktree, append exactly one newline-terminated Lisp comment `; chat-supervisor-live-tool-smoke` to the tracked safe fixture file `fixtures/baseline-answer-v1.lisp`. Do not edit any other file. Then reply with exactly LIVE_TOOL_SMOKE_FINAL.'''
pathlib.Path(sys.argv[1]).write_text(
    json.dumps({"op": "turn", "text": prompt}, separators=(",", ":")) + "\n" +
    json.dumps({"op": "checkpoint"}, separators=(",", ":")) + "\n" +
    json.dumps({"op": "exit"}, separators=(",", ":")) + "\n",
    encoding="utf-8",
)
PY

# timeout bounds the whole paid session; supervisor bounds each worker turn.
# The verification command is supplied by this parent, not in worker JSONL.
timeout "$session_timeout_seconds" "$repo_root/bin/chat-supervisor" \
  --create-worktree --repo "$primary" --base-ref "$primary_before" \
  --run-id chat-supervisor-live-tool-smoke-16 --worktree-parent "$owned_parent" \
  --report-dir "$reports" --session-id chat-supervisor-live-tool-smoke-16 \
  --model "$model" --max-rounds "$max_rounds" \
  --turn-timeout-seconds "$turn_timeout_seconds" \
  --verify-command "$verify_command" <"$input" >"$jsonl"

# Inspect all sensitive-capable transport output only in the temporary directory.
# Assertions intentionally print no prompts, assistant text, provider payloads,
# tool output, credential values, diffs, or report bodies.
python3 - "$jsonl" "$primary" "$primary_before" "$owned_parent" "$reports" <<'PY'
import json
import pathlib
import subprocess
import sys

jsonl, primary, primary_before, owned_parent, reports = map(pathlib.Path, sys.argv[1:])
records = [json.loads(line) for line in jsonl.read_text(encoding="utf-8").splitlines() if line]
assert not [r for r in records if r.get("type") == "error"], "supervisor emitted an error record"
started = next(r for r in records if r.get("type") == "session-started")
owned_worktree = pathlib.Path(started["worktree"]).resolve()
assert started["owned"] is True
assert owned_worktree.parent == owned_parent.resolve() and owned_worktree != primary.resolve()
assert started["base_commit"] == primary_before.name
assert subprocess.check_output(["git", "-C", str(primary), "rev-parse", "HEAD"], text=True).strip() == primary_before.name
assert subprocess.check_output(["git", "-C", str(primary), "status", "--porcelain"], text=True) == ""
assert subprocess.check_output(["git", "-C", str(owned_worktree), "status", "--porcelain"], text=True)
assert subprocess.run(["git", "-C", str(owned_worktree), "diff", "--check"], check=False).returncode == 0
changed = subprocess.check_output(["git", "-C", str(owned_worktree), "diff", "--name-only"], text=True).splitlines()
assert changed == ["fixtures/baseline-answer-v1.lisp"], changed
assert "; chat-supervisor-live-tool-smoke\n" in subprocess.check_output(
    ["git", "-C", str(owned_worktree), "diff", "--", "fixtures/baseline-answer-v1.lisp"], text=True)

assistant = next(r for r in records if r.get("type") == "assistant")
assert "LIVE_TOOL_SMOKE_FINAL" in assistant.get("text", "")
turns = [r for r in records if r.get("type") in {"turn-record", "checkpoint"}]
assert len(turns) >= 2
assert all(r["verification"]["command"] == "sg docker -c 'make test'" and
           r["verification"]["status"] == "passed" and r["verification"]["exit_code"] == 0
           for r in turns)
accounting = next(r for r in turns if r.get("type") == "turn-record")["provider_accounting"]
assert accounting["state"] == "actual", accounting
assert accounting["provider_call_count"] >= 2, accounting
invocations = accounting["invocations"]
assert len(invocations) == accounting["provider_call_count"], accounting
costs_are_numeric = all(isinstance(call.get("cost_usd"), (int, float)) and not isinstance(call.get("cost_usd"), bool)
                        for call in invocations)
aggregate = accounting["aggregate"]
if costs_are_numeric:
    assert isinstance(aggregate.get("cost_usd"), (int, float)) and not isinstance(aggregate.get("cost_usd"), bool)
else:
    assert aggregate.get("cost_usd_state") == "unavailable" and isinstance(aggregate.get("cost_usd_reason"), str)

exited = next(r for r in records if r.get("type") == "session-exited")
report_json = pathlib.Path(exited["report_json"])
report_html = pathlib.Path(exited["report_html"])
assert report_json.exists() and report_html.exists()
assert report_json.parent.resolve() == reports.resolve() and report_html.parent.resolve() == reports.resolve()
report = json.loads(report_json.read_text(encoding="utf-8"))
assert report["schema_version"] == "chat-supervisor-session-v1"
assert report["session"] == {key: started[key] for key in ("id", "worktree", "branch", "base_commit", "owned")}
assert report["accounting"] == accounting
assert report["turns"][-1]["event"] == "checkpoint"
assert report["turns"][-1]["verification"]["status"] == "passed"
assert not report["merged"] and not report["deleted"]
body = report_json.read_text(encoding="utf-8") + report_html.read_text(encoding="utf-8")
# The run/session/worktree identifiers deliberately contain the smoke name, so
# they are expected lineage data. Only sensitive prompt/final/tool markers must
# be absent from persisted reports.
for forbidden in ("openrouter_api_key", "use run_shell exactly once", "live_tool_smoke_final", "run_shell"):
    assert forbidden not in body.lower(), forbidden
PY

printf '%s\n' 'Chat supervisor live tool smoke passed.'
