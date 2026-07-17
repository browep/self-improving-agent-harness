---
name: harness-chat-feedback-loop
description: Use when a supervising agent needs to drive the self-improving harness's persistent bin/chat session as a feedback-loop worker, with isolated workspace changes and independently verified evaluator evidence.
version: 1.0.0
author: Hermes Agent
license: MIT
metadata:
  hermes:
    tags: [agent-orchestration, feedback-loop, interactive-chat, common-lisp, experiments]
    related_skills: []
---

# Harness Chat Feedback Loop

## Overview

`bin/chat` is a real, persistent OpenRouter chat worker, not a mock or a
one-shot patch generator. In an interactive terminal it retains ordered
conversation and tool-call history, exposes `run_shell`, and can edit its
mounted workspace. A supervising agent can use it as one worker in an
experiment loop:

```text
supervisor task / hypothesis
  → persistent harness-chat turn
  → worker tool actions and final response
  → independent Git + test + artifact inspection
  → evaluator evidence
  → next worker turn or candidate decision
```

The worker's final text is never sufficient acceptance evidence. The supervisor
must independently inspect the workspace, execute relevant Docker-backed
verification, and persist the evidence used for the next decision.

## When to Use

Use this skill when:

- a supervisor needs a multi-turn agent worker rather than a one-shot model
  completion;
- the worker should inspect, edit, test, or explain a harness worktree through
  `run_shell`;
- evaluator/test results need to become explicit feedback for the next turn;
- an experiment needs session lineage, tool metadata, Git evidence, and actual
  provider accounting.

Do not use this skill for:

- a one-shot question that `./bin/chat --prompt` can answer;
- direct editing of the primary checkout;
- treating a model self-report as a test/evaluation result;
- automatic merge or deployment.

## Prerequisites

1. Verify the repository and baseline before starting a session:

   ```sh
   git status --short
   sg docker -c 'make test'
   ./bin/chat --help
   ```

   Completion criterion: the primary checkout is clean, the Docker suite passes,
   and interactive chat help is available.

2. Confirm a runtime `OPENROUTER_API_KEY` is available without printing it. The
   key may be exported or supplied through the untracked `.env` contract.

3. Select an exact OpenRouter model ID that supports tools. Do not use a display
   name or an undocumented alias.

## Isolate Every Mutation-Capable Session

Create one worktree and branch per session. Never launch writable chat from the
primary checkout when the worker may edit files.

```sh
git fetch origin --prune
git worktree add -b experiment/chat-<run-id> \
  /home/ubuntu/.agent-worktrees/self-improving-agent-harness-<run-id> \
  origin/main
```

Run all worker commands from that worktree. Record the worktree path, branch,
base commit, session ID, model ID, prompt version, and budgets in the experiment
record.

Completion criterion: `git -C <worktree> status --short` is clean before the
first worker turn and the primary checkout remains untouched.

## Start a Persistent Worker

The session requires TTY stdin and stdout. A supervisor should start it through
a PTY-capable process manager rather than piping a transcript, because piped
stdin is intentionally one-shot mode.

```sh
sg docker -c './bin/chat --model <exact-model-id> --max-rounds <n>'
```

The startup text identifies the model and prints `chat>`. It accepts `/exit`,
`/quit`, EOF, and Ctrl-C for local exit.

Recommended initial explicit budgets:

| Limit | Purpose |
|---|---|
| `--max-rounds` | Bounds model/tool-loop continuations within a turn. |
| supervisor max turns | Bounds conversation length. |
| provider-call cap | Bounds all completions across the session. |
| token/cost cap | Bounds actual aggregate use across all completions. |
| wall-clock timeout | Bounds worker and evaluator runtime. |

Keep the supervisor's budget ledger separate from worker console text. Account
for every completion, not only a final response.

### Current CLI telemetry gap

The current `bin/chat` console and JSONL log do **not** expose a session ID,
turn IDs, per-invocation input/output tokens, provider-call totals, or actual
cost. A supervisor adapter must generate correlation IDs itself and obtain
provider accounting from an external/provider source. If authoritative
accounting is unavailable, record it as unavailable rather than estimating or
inventing it.

Completion criterion: the process reaches `chat>` without a provider call being
made for startup alone.

## Turn Protocol

For each turn, the supervisor must:

1. Submit one concrete task or feedback message through the PTY stdin channel.
2. Capture final assistant text from stdout and `TOOL_CALL` / `OUTCOME` events
   from stderr.
3. Record the current JSONL log location only as supporting diagnostics. The
   current `chat.log` is append-only and shared across sessions; it logs raw user
   prompts, assistant content, shell commands, and failure messages. It omits raw
   successful tool output but is **not** a uniformly redacted session transcript.
   Minimize sensitive prompts/commands and never copy unreviewed log content into
   an evaluator report.
4. Snapshot the worktree after the turn:

   ```sh
   git -C <worktree> status --short
   git -C <worktree> diff --check
   git -C <worktree> diff --stat
   ```

5. Run the relevant real Docker command in the worktree. For a normal source
   change, begin with:

   ```sh
   sg docker -c 'make test'
   ```

6. Collect generated JSON/HTML report paths when the turn runs an experiment.
   Confirm both artifacts exist, are nonempty, and derive from the same live run
   record.
7. Convert observed evidence into the next feedback turn. State the exact
   failing command, sanitized error/outcome, changed files, and evaluator result;
   do not merely say that the worker was unsuccessful.

Completion criterion: every completed turn has a session/turn ID, a Git state
snapshot, command outcome, and either evaluator evidence or an explicit reason
why no evaluation ran.

## Feedback Messages

A useful feedback message distinguishes worker opinion from measured results:

```text
Independent evaluator feedback for turn 2:
- git diff: src/example.lisp and tests/example.lisp changed
- sg docker -c 'make test': failed
- failing acceptance: expected <X>, received <Y>
- evaluator verdict: reject
Keep the prior successful behavior, inspect the failure, make the smallest
correction, and rerun the named command. Do not change the evaluator or budget.
```

Keep the evaluator, acceptance criteria, and promotion rule pinned for the
candidate being judged. This is an experimental-design requirement, not a
restriction on the worker's general ability to edit a workspace.

## Session End and Promotion

Send `/exit` after the final verified turn. Then independently inspect:

```sh
git -C <worktree> status --short
git -C <worktree> diff --check
git -C <worktree> log -1 --oneline
```

A session may be retained as a candidate only when its pinned evaluator evidence
meets the experiment's rule. Retention does not merge the branch. A human or a
separate, documented promotion workflow decides whether to commit, push, merge,
or discard the worktree.

## Evidence Record

Persist a report with at least:

- task prompt and acceptance criteria;
- supervisor-generated session/turn correlation IDs, branch, worktree, and base
  commit;
- selected/available models before invoked model history;
- actual per-invocation input/output tokens and cost only when supplied by an
  authoritative provider/accounting source; otherwise an explicit unavailable
  value, plus aggregate budgets;
- sanitized tool metadata and the diagnostic-log location (not copied raw log
  content);
- Git diff/status and verification command results;
- JSON/HTML artifact paths and evaluator evidence;
- final candidate decision and rationale.

The supervisor's persisted report must never include `OPENROUTER_API_KEY`,
credentials, raw tool/provider output, or other secret-bearing material. Review
and redact console/log excerpts before persistence; existing `chat.log` content
is diagnostic input, not pre-sanitized evidence. Preserve usage and cost
accounting when authoritative values are available.

## Common Pitfalls

1. **Piping multiple lines to `bin/chat`.** Piped stdin is deliberately a
   one-shot prompt, not an interactive transcript. Use a PTY process and submit
   each turn through stdin.

2. **Starting in the primary checkout.** `bin/chat` mounts its workspace
   writable. Use a dedicated worktree for any mutation-capable session.

3. **Trusting “done.”** A final response proves only that a model responded.
   Inspect the diff and rerun the evaluator/test command independently.

4. **Counting only the final completion.** Tool loops can make multiple provider
   calls. Aggregate calls, tokens, and cost across the entire turn/session.

5. **Feeding raw errors back into the worker.** Redact credentials and raw tool
   output before including failure evidence in a follow-up message or report.

6. **Letting a candidate edit its judge.** A candidate can propose such a patch,
   but its current run must be evaluated by a separately pinned parent evaluator
   and decision rule.

## Verification Checklist

- [ ] Primary checkout stayed clean throughout the mutable session.
- [ ] Worker ran from a dedicated worktree and branch.
- [ ] Interactive PTY mode reached `chat>` and `/exit` ended it cleanly.
- [ ] Every worker turn has independently captured Git/test/evaluator evidence.
- [ ] Aggregate call, token, cost, and time budgets are recorded.
- [ ] Report artifacts are nonempty, mutually consistent, and redacted.
- [ ] Evaluator/promotion independence was preserved for the candidate run.
- [ ] Retention/rejection is based on persisted evidence, not worker self-report.
- [ ] Any merge or deployment decision occurred outside the worker session.
