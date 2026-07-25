# Diagnosing Session Issues

A repeatable method for diagnosing chat/session problems in this harness —
apparent "forgetting", blank turns, provider errors, and web-UI startup
crashes — followed by a worked case study.

## Where session artifacts live

Durable session state is written to the `self-improving-agent-harness-logs`
Docker volume (mounted at `/logs` inside the web-UI container), **not** to the
repository tree. Per session you get:

- `<session-id>.jsonl` — append-only event log (turns, provider
  requests/responses, tool calls, reloads). The forensic record.
- `<session-id>.history.json` — the durable conversation snapshot replayed into
  the model on the next turn. What the model actually "remembers".
- `<session-id>.log` — plain log; often empty.

The session id is an ISO-8601 timestamp, e.g. `2026-07-25T16:33:08.866Z`.

## Live health checks

```sh
# Web UI reachable?
curl -sS -o /dev/null -w 'http=%{http_code}\n' http://127.0.0.1:17881/

# Container healthy, or stuck in a restart loop?
sg docker -c 'docker inspect harness-web-ui \
  --format "status={{.State.Status}} restarts={{.RestartCount}}"'

# What output-token budget is live? (see failure mode 2)
sg docker -c 'docker inspect harness-web-ui \
  --format "{{range .Config.Env}}{{println .}}{{end}}"' | grep HARNESS_CHAT_MAX_TOKENS

# Recent container logs (startup crashes, reconnect noise)
sg docker -c 'docker logs --tail 40 harness-web-ui'
```

Do **not** dump the full env block into shared output: it contains
`SYNTHETIC_API_KEY` and similar secrets. Grep for the one variable you need.

## Safely extract session artifacts

Mount the volume read-only into a temp dir. Keep analysis scripts in `/tmp`, not
in the repo.

```sh
mkdir -p /tmp/harness-session
sg docker -c 'docker run --rm \
  -v self-improving-agent-harness-logs:/data:ro \
  -v /tmp/harness-session:/out \
  alpine sh -c "cp /data/<session-id>.jsonl /data/<session-id>.history.json /out/"'
```

The copied files are root-owned but usually host-readable (mode `0644`). If not,
copy as a container user matching your host UID/GID.

## Parse the JSONL

Payloads are stored as **Python-repr strings**, not strict JSON. Parse with
`ast.literal_eval` and a JSON fallback — never `eval`.

```python
import ast, json
from pathlib import Path

rows = [json.loads(l) for l in Path("<file>.jsonl").read_text(errors="replace").splitlines() if l.strip()]

def payload(r):
    p = r.get("payload")
    if isinstance(p, dict):
        return p
    if isinstance(p, str):
        try:
            return ast.literal_eval(p)
        except Exception:
            try:
                return json.loads(p)
            except Exception:
                return {}
    return p or {}
```

Event types you will see (`payload.event`):

- `turn-received`, `turn-submitted`, `turn-completed`, `turn-failed`
- `provider-request`, `provider-response`, `provider-request-failed`
- `claude-sdk-request-started` / `-completed` / `-failed`
- `tool-call`, `tool-completed`, `tool-failed`
- `reload-started`, `reload-progress`, `reload-completed`
- `synthetic-followup-scheduled`

Useful key fields: `provider-request.messageCount` and `.round`;
`provider-response.finishReason`, `.responseText`, `.toolCallCount`;
`provider-request-failed.message`; `turn-submitted.messageCount`.

## Build a turn timeline

The single most useful view. For each `turn-received`, accumulate everything
until the next terminal event:

```python
current, turns = None, []
for r in rows:
    p = payload(r); e = p.get("event")
    if e == "turn-received":
        current = {"content": p.get("content",""), "reqs":0, "fails":0,
                   "resps":0, "tools":0, "finish":None, "status":None, "terminal":None}
        turns.append(current)
    elif current is not None:
        if   e == "turn-submitted":         current["msg_count"] = p.get("messageCount")
        elif e == "provider-request":       current["reqs"]  += 1
        elif e == "provider-request-failed":current["fails"] += 1
        elif e == "provider-response":      current["resps"] += 1; current["finish"] = p.get("finishReason")
        elif e == "tool-call":              current["tools"] += 1
        elif e == "turn-completed":         current["status"] = "completed"; current["terminal"] = p.get("content","")
        elif e == "turn-failed":            current["status"] = "failed";    current["terminal"] = p.get("message","")
```

Then compare the timeline against `history.json`: read its `messages` array and
check total count, roles, content types, and — critically — **whether failed
user turns appear at all**.

```python
h = json.loads(Path("<file>.history.json").read_text())
print(h["model"], h["backend"], "durable messages:", len(h["messages"]))
```

The decisive signal for "forgetting": a `turn-received` exists in the JSONL, but
that user message and its work are **absent** from `history.json`. The next
turn's provider request will not know that turn ever happened.

### Terminal `turn-summary` records

Each terminal turn now writes one `turn-summary` JSONL event and forwards it to
the Web UI observer. It contains the status; backend/model; submitted and
durable-history counts before/after; whether the snapshot persisted; provider
request/response/failure and tool-call counts; terminal finish reason; and a
normalized terminal error class.

`turn-summary.userPrompt` deliberately contains the **raw user prompt**. This is
an explicit exception for durable Harness session diagnostics: the repository's
higher-level privacy/security controls protect access to the session-log volume.
It does not change the redaction policy for provider captures, supervisor
protocols, transport logs, credentials, or raw provider errors. The terminal
summary retains an error *class*, not raw provider error text.

## Common failure modes

### 1. Provider timeout → failed turn dropped from durable history (apparent "forgetting")

**Symptoms**

- Model answers about an *older* task and seems to have forgotten a recent
  long request.
- JSONL shows many `provider-request-failed` with
  `OpenRouter request timed out after 120 seconds`, ending in `turn-failed`.
- The next turn's `turn-submitted.messageCount` equals the count from *before*
  the failed turn — the failed turn left no trace in `history.json`.

**Root cause (historical behavior; changed by the fix below)**

At the time of this session, `chat-session-turn` in `src/chat-session.lisp`
built the request `messages` by appending the new user prompt to
`chat-session-history`, then called `run-tool-loop` inside a `handler-case`.
`chat-session-history` was reassigned **only** on the successful return path.
The error clause logged a `turn-failed` event and re-signaled the condition
without appending the failed user message or any marker to history;
`note-chat-session-failure` only set a `failed-turn-p` flag.

The consequence: a timed-out repair turn was fully visible in the JSONL but
never replayed into the model's context. When the user followed up with "Still
working?", the model answered from the last *completed* durable turn, which read
as forgetting.

**Status: fixed.** The error clause in `chat-session-turn` now appends the
failed user prompt plus a sanitized, bounded `[harness]` assistant failure
marker to both the in-memory history and the durable `.history.json` resume
snapshot, then re-signals. A later "Still working?" turn replays the failed
request so the model sees it instead of silently resuming from the last
completed turn. A `history-updated-p` guard prevents writing a false marker when
the condition is signaled *after* a turn already succeeded (e.g. from
accounting/snapshot/logging). Note: only the failed user prompt and the marker
are preserved in replay history — the detailed partial tool transcript still
lives in the JSONL logs, not in `history.json`. Existing historical sessions
remain historical; the fix applies to turns run after it landed.

### 2. Empty `max_tokens` terminal response (blank turn)

**Symptoms**

- Blank assistant message; conversation looks dead (`<<< DONE`, no text).
- `provider-response.finishReason` is `max_tokens` (Anthropic) or `length`
  (OpenAI-compatible) with `responseText=""` and no tool calls.

**Status**

The tool loop recognizes both terminal reasons and makes one recovery
continuation before synthesizing a visible diagnostic (`src/backend.lisp`,
`truncated-empty-final-response-p`). If it still triggers, confirm the live
budget with the health check above; the default is `16384`.

Note: `null` assistant content in `history.json` is not by itself evidence of
the empty-`max_tokens` failure. Assistant tool-use turns routinely have no
textual content and are followed by tool-result messages — that is normal
bookkeeping. Do not diagnose "forgetting" from `null` entries alone. Diagnose
the blank terminal-response case only from the JSONL provider event: terminal
`finishReason=max_tokens`/`length`, empty `responseText`, zero tool calls, and a
blank `turn-completed` payload.

### 3. Missing Drakma dependency → web-UI restart loop

**Symptoms**

- Container flapping (`status=restarting`, climbing `RestartCount`); `curl` to
  the UI resets the connection.
- Logs show `Component #:DRAKMA not found, required by
  #<SYSTEM "self-improving-agent-harness">` and the SBCL debugger banner.

**Root cause**

The Quicklisp world (`/root/.sbclrc` → `/opt/quicklisp/setup.lisp`) was not
loaded before `--load scripts/web.lisp`, so ASDF cannot resolve `drakma`.

**Fix**

Launch with Quicklisp first:

```sh
sbcl --noinform --load /opt/quicklisp/setup.lisp --load scripts/web.lisp
```

### 4. Web disconnect / refresh artifacts

`Reconnection id ... not found. Closing the connection.` in the logs is CLOG
websocket churn, not a backend failure. Cross-check web-session events against
the JSONL turn events before blaming the backend.

## Case study: `2026-07-25T16:33:08.866Z`

**Reported symptom:** the session "looks like it's forgetting what's going on."

**Artifacts:** JSONL ≈ 710 KB / 929 rows; `history.json` = 20 durable messages;
model `claude-sonnet-5`, backend `claude-sdk`.

**Event totals:** 5 `turn-received`, 5 `turn-submitted`, 3 `turn-completed`,
2 `turn-failed`, **73 `provider-request-failed`** — every failure the same
`OpenRouter request timed out after 120 seconds`.

**Turn timeline:**

| Turn | User prompt | submit msgCount | prov req / resp / fail | tools | result |
|------|-------------|-----------------|------------------------|-------|--------|
| 1 | find the open web-UI issue | 2 | 5 / 5 / 0 | 14 | completed (found #61) |
| 2 | fix both, live E2E test | 15 | 43 / 42 / 43 | 142 | **failed** (timeout) |
| 3 | "Still working?" | 15 | 2 / 2 / 0 | 2 | completed — recapped **Turn 1** only |
| 4 | "Fix the issue" | 19 | 30 / 29 / 30 | 88 | **failed** (timeout) |
| 5 | "Still working?" | 19 | 1 / 1 / 0 | 0 | completed — recapped the lookup again |

**Diagnosis:** this is failure mode 1, not cognitive forgetting and not
`max_tokens`. Turns 2 and 4 were long tool-heavy repair attempts that died on
provider timeouts and were never written to durable history. Turn 3 resumed at
`messageCount=15` (the pre-Turn-2 snapshot) and Turn 5 at `messageCount=19`
(includes completed Turn 3, excludes failed Turn 4). With the failed repair work
absent from context, the model could only recap the last completed turn — which
reads as "forgetting" to the user.

**Basis:** this diagnosis comes from the durable session artifacts (JSONL turn
timeline vs. `history.json` message count) and source inspection of
`chat-session-turn`. A live tool-loop reproduction was not run in this pass. A
focused regression could confirm it by driving `run-tool-loop` with a provider
that raises a timeout mid-turn and asserting the failed user turn is absent from
the next durable `history.json` snapshot.

## Visibility backlog

The case study was diagnosable from the raw JSONL plus `history.json`, but it
required manual reconstruction. The following follow-up issues would make this
and future diagnoses much faster:

| Gap | Issue |
|-----|-------|
| Per-turn `turn-summary` event with provider req/resp/failure counts and durable-history persistence counts | [#91](https://github.com/browep/self-improving-agent-harness/issues/91) |
| Machine-readable `terminalErrorClass` + provider-attempt correlation ids | [#92](https://github.com/browep/self-improving-agent-harness/issues/92) |
| `bin/session-diagnose <session-id>` to automate this document's forensic workflow | [#93](https://github.com/browep/self-improving-agent-harness/issues/93) |
| Web UI live diagnostics: backend/model/token budget, last-turn status, durable-save state | [#94](https://github.com/browep/self-improving-agent-harness/issues/94) |

Related existing issues:

- [#72](https://github.com/browep/self-improving-agent-harness/issues/72) owns
  interrupted-turn persistence/recovery behavior.
- [#63](https://github.com/browep/self-improving-agent-harness/issues/63) owns
  Claude stream/MCP correlation diagnostics.

## Verify after doc-only changes

```sh
git diff --check
git status --short
```

`./bin/test` is only necessary when Lisp source changes; a docs-only change does
not require the full suite.
