#!/usr/bin/env sh
# Deterministic lifecycle/report coverage: no provider, no merge, no deletion.
set -eu

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
. "$repo_root/tests/chat-supervisor-fixture.sh"
supervisor_fixture_create "$repo_root"
tmp=$SUPERVISOR_FIXTURE_TMP
output="$tmp/output.jsonl"
parent=$SUPERVISOR_FIXTURE_PARENT
reports=$SUPERVISOR_FIXTURE_REPORTS
primary=$SUPERVISOR_FIXTURE_PRIMARY
primary_before=$SUPERVISOR_FIXTURE_PRIMARY_COMMIT
cleanup() { supervisor_fixture_cleanup; }
trap cleanup EXIT HUP INT TERM

# A created worktree is isolated, has a parent-side durable ownership record,
# remains clean, produces allow-listed JSON/HTML, and never merges/deletes.
printf '%s\n' \
  '{"op":"feedback","id":"eval-1","verdict":"reject","evidence":["verification-failed"]}' \
  '{"op":"turn","text":"credential OPENROUTER_API_KEY=never-persist"}' \
  '{"op":"checkpoint"}' \
  '{"op":"exit"}' |
  env HARNESS_CHAT_RUNNER="$repo_root/tests/fake-supervised-chat-container.sh" \
  "$repo_root/bin/chat-supervisor" \
    --create-worktree --repo "$primary" --base-ref HEAD --run-id lifecycle-red-16 \
    --worktree-parent "$parent" --session-id lifecycle-session-16 --model offline/fake \
    --report-dir "$reports" --fake --verify-command '/bin/true' >"$output"

owned_worktree=$(python3 - "$output" "$primary" "$parent" "$reports" "$primary_before" <<'PY'
import json
import pathlib
import subprocess
import sys

records = [json.loads(line) for line in pathlib.Path(sys.argv[1]).read_text().splitlines() if line]
started = next(r for r in records if r.get("type") == "session-started")
assert started["owned"] is True and started["branch"].startswith("chat-supervisor/lifecycle-red-16-"), started
worktree = pathlib.Path(started["worktree"])
parent = pathlib.Path(sys.argv[3]).resolve()
assert worktree.parent == parent and worktree != pathlib.Path(sys.argv[2]).resolve(), started
assert started["base_commit"] == sys.argv[5], started
assert subprocess.check_output(["git", "-C", sys.argv[2], "rev-parse", "HEAD"], text=True).strip() == sys.argv[5]
assert subprocess.check_output(["git", "-C", str(worktree), "status", "--porcelain"], text=True) == ""
ledger = parent / ".chat-supervisor-runs" / "lifecycle-red-16.json"
assert ledger.exists(), ledger
assert not (worktree / ".chat-supervisor-owner.json").exists()
assert any(r.get("type") == "feedback" and r["id"] == "eval-1" for r in records), records
turn = next(r for r in records if r.get("type") == "turn-record")
assert turn["evaluator_feedback_id"] == "eval-1", turn
assert set(turn["git"]) >= {"status", "diff_check", "diff_stat"}, turn
assert turn["verification"] == {"command":"/bin/true","status":"passed","exit_code":0}, turn
exited = next(r for r in records if r.get("type") == "session-exited")
json_path, html_path = map(pathlib.Path, (exited["report_json"], exited["report_html"]))
assert json_path.exists() and html_path.exists() and json_path.parent == pathlib.Path(sys.argv[4]).resolve(), exited
body = json_path.read_text() + html_path.read_text()
for forbidden in ("openrouter_api_key", "never-persist", "credential openrouter"):
    assert forbidden not in body.lower(), (forbidden, body)
report = json.loads(json_path.read_text())
assert report["schema_version"] == "chat-supervisor-session-v1", report
assert report["final_decision"] == "unresolved", report
assert report["turns"][0]["evaluator_feedback_id"] == "eval-1", report
assert not report.get("merged") and not report.get("deleted"), report
print(worktree)
PY
)

# Parent-side ownership must authorize a later pre-created session without
# dirtying the created checkout.
printf '%s\n' '{"op":"exit"}' | env HARNESS_CHAT_RUNNER="$repo_root/tests/fake-supervised-chat-container.sh" \
  "$repo_root/bin/chat-supervisor" --worktree "$owned_worktree" --worktree-parent "$parent" \
  --run-id lifecycle-red-16 --session-id resumed --report-dir "$reports/resumed" \
  --fake --verify-command /bin/true >/dev/null

# Make a registered but unowned worktree, and make the owned one dirty.
unknown="$parent/unknown"
git -C "$primary" worktree add -q -b unknown-branch "$unknown" HEAD
printf 'dirty\n' >>"$owned_worktree/README-not-present"

# Refuse: missing canonical parent, primary, unknown registered checkout, dirty
# owned checkout, duplicate run ID, outside parent, and missing report target.
for arguments in \
  "--worktree $owned_worktree --run-id lifecycle-red-16 --report-dir $reports" \
  "--worktree $primary --worktree-parent $parent --run-id lifecycle-red-16 --report-dir $reports" \
  "--worktree $unknown --worktree-parent $parent --run-id unknown --report-dir $reports" \
  "--worktree $owned_worktree --worktree-parent $parent --run-id lifecycle-red-16 --report-dir $reports" \
  "--create-worktree --repo $primary --base-ref HEAD --run-id lifecycle-red-16 --worktree-parent $parent --report-dir $reports" \
  "--create-worktree --repo $primary --base-ref HEAD --run-id outside --worktree-parent $tmp/outside --report-dir $reports" \
  "--worktree $unknown --worktree-parent $parent --run-id unknown"; do
  if "$repo_root/bin/chat-supervisor" $arguments --session-id refused --verify-command /bin/true </dev/null >/dev/null 2>&1; then
    echo "unsafe supervisor invocation unexpectedly succeeded: $arguments" >&2
    exit 1
  fi
done

# The primary still has its original commit; both supervised worktrees and
# branches still exist because supervisor lifecycle never auto-merges/deletes.
test "$(git -C "$primary" rev-parse HEAD)" = "$primary_before"
git -C "$primary" worktree list --porcelain | grep -F "worktree $owned_worktree" >/dev/null
git -C "$primary" worktree list --porcelain | grep -F "worktree $unknown" >/dev/null
git -C "$primary" show-ref --verify --quiet "refs/heads/$(git -C "$owned_worktree" branch --show-current)"
printf 'Chat supervisor lifecycle/report test passed.\n'
