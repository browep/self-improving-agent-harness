# Chat supervisor JSONL protocol

`bin/chat-supervisor` is a host-side supervisor for one persistent `bin/chat`
worker. It is intentionally an evidence collector, **not** a promotion,
merge, deployment, or cleanup mechanism.

## Start an owned session

Creation is explicit and requires a clean primary checkout, a pre-existing
worktree parent, and a fresh run ID. The supervisor creates a branch and child
worktree below that parent; it never uses the primary checkout for worker
writes.

```sh
printf '%s\n' \
  '{"op":"feedback","id":"eval-1","verdict":"reject","evidence":["acceptance-failed"]}' \
  '{"op":"turn","text":"Make the smallest safe correction."}' \
  '{"op":"checkpoint"}' '{"op":"exit"}' |
  ./bin/chat-supervisor --create-worktree --repo "$PWD" --base-ref HEAD \
    --run-id issue-16-a --worktree-parent /home/ubuntu/.agent-worktrees \
    --report-dir reports/chat-session-issue-16-a --session-id issue-16-a \
    --model openai/gpt-4.1-mini --verify-command "sg docker -c 'make test'"
```

A safe pre-created worktree may be passed with `--worktree`, `--worktree-parent`
and `--run-id` only when it is clean, is below the configured parent, is not the
primary checkout, and contains a supervisor ownership marker
`.chat-supervisor-owner.json` with `{"run_id":"…","owned":true}`.

`session-started` contains only `{session_id, worktree, branch, base_commit,
owned}` lineage. Run IDs are 1–64 ASCII letters/digits plus `._-`; a persistent
parent lock makes a used run ID unavailable for reuse. Creation rejects dirty
starts, primary/non-primary repository misuse, invalid bases, duplicate IDs,
and target paths outside the configured parent. There is no operation or flag
for merge, worktree deletion, branch deletion, or automatic promotion.

## Input JSONL

One object per line:

* `{"op":"turn","text":"…"}` submits one worker turn. The prompt is never
  persisted in the evidence report.
* `{"op":"checkpoint"}` performs a supervisor snapshot without a worker turn.
* `{"op":"feedback","id":"id","verdict":"accept|reject|inconclusive","evidence":["safe structured evidence"]}` records external evaluator input. Evidence is an array of at least one short (160 character maximum) restricted safe string; credentials, token-like keys, raw output/error-like fields, and arbitrary free-form output are rejected. The next turn records `evaluator_feedback_id`; the worker cannot set evaluator fields or a decision.
* `{"op":"exit"}` exits the worker and writes artifacts.

Invalid JSON, operations, or feedback produce a small error record only.

## Output and artifacts

JSONL contains child lifecycle `type=event`, assistant text (transport only),
per-turn `type=turn-record`, checkpoint evidence, feedback acknowledgements,
and final `type=session-exited` paths. Every turn and checkpoint captures fresh
sanitized `git status`, `git diff --check`, and `git diff --stat` outcomes plus
the configured named verification command outcome. It retains state/counts/exit
codes only—never diff content or paths, raw logs, command output, credentials,
or tool/provider output.

On normal exit, `session.json` and self-contained `session.html` are written to
the explicit `--report-dir` from the same in-memory sanitized report. They
contain schema version, session/task lineage, selected model, unavailable
accounting unless an authoritative integration supplies it, safe tool metadata
state, feedback, per-turn Git/test data, and final decision. Decision is
`unresolved` unless a separate external supervisor supplied `--decision retain`
or `--decision reject`. The artifacts are under ignored `reports/`; paths are
reported in the final event. The supervisor does not claim provider cost, full
experiment promotion, or a worker self-assessment as evidence.
